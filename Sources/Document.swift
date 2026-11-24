// Vigia: one document window: open, save, live reload, find, export, print.
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 10, 2026
// SPDX-License-Identifier: GPL-2.0-only
//
// Live reload is the heart of Vigia: when another program (often an AI assistant) changes
// the open file, the new text shows at once, in place, and every view keeps its scroll position.
// The file is watched with a kernel event source, and so is its folder, because many tools save by
// writing a new file and renaming it over the old one: the old file's watcher then sees a delete
// or a rename, and the folder watcher sees the new one arrive. Each event leads to one read; if the
// text on disk differs from what the window last read or saved, it is reloaded. With unsaved
// changes in the window, the user is asked first.

import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

final class DocModel: ObservableObject {
    @Published var path: URL?
    @Published var dirty = false
    @Published var words = 0
    @Published var outline: [(level: Int, text: String)] = []
    @Published var findVisible = false
    @Published var replaceVisible = false
    @Published var findQuery = ""
    @Published var replaceText = ""
    @Published var findCase = false
    @Published var findInfo = ""
    @Published var flash = ""
    @Published var ready = false
    var isSample = false
    var bom = false
    var crlf = false
}

final class DocWindow: NSWindowController, NSWindowDelegate {
    let model = DocModel()
    let web = EditorWeb()
    let search = SearchState()                // the search box above the Files tree (Search.swift)
    let prefs = Prefs.shared
    private var watcher: FileWatcher?
    private var diskText: String?            // the text last read from or written to disk
    private var askingReload = false
    private var lastEditSeq = 0               // the last edit the page reported (app.js editSeq)
    private var saving = false
    private var autoSaveTimer: Timer?
    private var pendingOpen: URL?
    private var pendingExport: URL?
    private var recoveryTimer: Timer?
    let recoveryID = UUID().uuidString
    var onReady: (() -> Void)?
    private(set) var reach: [URL] = []       // what the document's links and pictures may reach (Wiki.reach)
    private var foldersWatch: AnyCancellable?
    private var pathWatch: AnyCancellable?

    static var all: [DocWindow] = []
    static let minContent = NSSize(width: 760, height: 452)

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = false
        // Tabs (3.2.0): each tab is a document window of its own (Tabs.swift).
        w.tabbingMode = .automatic
        w.tabbingIdentifier = Tabs.identifier
        super.init(window: w)
        w.delegate = self
        w.contentView = NSHostingViewFor(self).make()
        web.view.pageZoom = prefs.zoom
        web.onMessage = { [weak self] m in self?.handle(m) }
        web.onLink = { [weak self] href in self?.openLink(href) }
        web.onFileDrop = { [weak self] url in (NSApp.delegate as? AppDelegate)?.open(url, from: self) }
        DocWindow.all.append(self)
        updateTitle()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.writeRecovery() }
        // A folder added to or closed in the Files panel changes what the open document may reach.
        pathWatch = model.$path.dropFirst().removeDuplicates().sink { _ in Tabs.changed() }
        foldersWatch = prefs.$folders.dropFirst().receive(on: RunLoop.main).sink { [weak self] f in
            guard let self, let dir = self.model.path?.deletingLastPathComponent() else { return }
            self.applyReach(dir, panel: f)
            Task { @MainActor in await self.markWikiLinks() }
        }
    }

    /// Serves and lets links open only what the document in `dir` may reach.
    func applyReach(_ dir: URL?, panel: [String]? = nil) {
        reach = Wiki.reach(docFolder: dir, panel: panel ?? prefs.folders)
        web.setReach(reach)
    }

    /// The GitHub view asks which [[names]] exist again (after the panel folders changed).
    @MainActor
    func markWikiLinks() async { await web.call("mdApp.refreshWikiLinks()") }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: messages from the page

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ready":
            Task { @MainActor in
                await web.call("mdApp.init(lang, theme, mode, spell, locked, true)", [
                    "lang": prefs.lang, "theme": prefs.dark ? "dark" : "light", "mode": prefs.mode,
                    "spell": prefs.spell, "locked": prefs.readOnly])
                await web.call("mdApp.setWidth(w)", ["w": prefs.textWidth])
                model.ready = true
                lastEditSeq = 0       // a new page counts its edits from zero
                if let p = pendingOpen { pendingOpen = nil; await load(p) }
                onReady?()
            }
        case "dirty":
            if let w = m["words"] as? Int { model.words = w }
            if let n = m["seq"] as? Int { lastEditSeq = max(lastEditSeq, n) }
            if !model.dirty { model.dirty = true; updateTitle() }
            scheduleAutoSave()
        case "outline":
            let items = (m["items"] as? [[String: Any]]) ?? []
            model.outline = items.map { (($0["level"] as? Int) ?? 1, ($0["text"] as? String) ?? "") }
        case "find":
            let i = m["index"] as? Int ?? -1, t = m["total"] as? Int ?? 0
            model.findInfo = model.findQuery.isEmpty ? "" : t == 0 ? L("NoResults") : L("OfCount", i + 1, t)
        case "lockedHint": flash(L("LockedHint"))
        case "cmd": if let c = m["cmd"] as? String { command(c) }
        case "link": if let h = m["href"] as? String { openLink(h) }
        case "wikilink": if let n = m["name"] as? String { openWiki(n) }
        case "wikinames":
            let names = (m["names"] as? [String]) ?? []
            let dir = model.path?.deletingLastPathComponent(), panel = prefs.folders
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = Wiki.exist(names, from: dir, panel: panel)
                DispatchQueue.main.async { Task { @MainActor in await self?.web.call("mdApp.wikiState(s)", ["s": found]) } }
            }
        case "findfile":
            let name = (m["name"] as? String) ?? ""
            let dir = model.path?.deletingLastPathComponent(), panel = prefs.folders
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let f = Wiki.findFile(name, from: dir, panel: panel)
                DispatchQueue.main.async { Task { @MainActor in
                    await self?.web.call("mdApp.fileFound(n, u)", ["n": name, "u": f.map { Schemes.address(of: $0) as Any } ?? NSNull()])
                } }
            }
        case "export": writeExport(m)
        case "printReady": printNow()
        case "crashed": web.view.reload()
        default: break
        }
    }

    func flash(_ s: String) {
        model.flash = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.model.flash == s { self?.model.flash = "" } }
    }

    /// Commands from the menus, the toolbar and the page's own keys.
    func command(_ c: String) {
        let app = NSApp.delegate as? AppDelegate
        switch c {
        case "new": app?.newTab(after: self)
        case "nexttab": app?.selectTab(from: self, 1)
        case "prevtab": app?.selectTab(from: self, -1)
        case "reopentab": app?.reopenClosedTab()
        case "open": app?.openPanel()
        case "save": Task { await save(as: false) }
        case "saveas": Task { await save(as: true) }
        case "print": Task { await web.call("await mdApp.preparePrint()") }
        case "close": window?.performClose(nil)
        case "find": showFind(replace: false)
        case "replace": showFind(replace: true)
        case "findnext": find(step: 1)
        case "findprev": find(step: -1)
        case "findclose": hideFind()
        case "outline", "files": prefs.togglePanes()
        case "search", "treesearch": focusTreeSearch()
        case "readonly": setReadOnly(!prefs.readOnly)
        case "mode1": setMode("visual")
        case "mode2": setMode("source")
        case "mode3": setMode("preview")
        case "zoom+": setZoom(prefs.zoom + 0.1)
        case "zoom-": setZoom(prefs.zoom - 0.1)
        case "zoom0": setZoom(1)
        case "manual": app?.openManual()
        default: break
        }
    }

    func exec(_ cmd: String, _ payload: Any? = nil) {
        Task {
            if let p = payload { await web.call("mdApp.exec(c, p)", ["c": cmd, "p": p]) }
            else { await web.call("mdApp.exec(c)", ["c": cmd]) }
        }
    }

    // MARK: views and settings that every window follows

    func setMode(_ m: String) {
        prefs.mode = m
        for d in DocWindow.all { Task { await d.web.call("mdApp.setMode(m)", ["m": m]) } }
    }

    func setReadOnly(_ on: Bool) {
        prefs.readOnly = on
        for d in DocWindow.all { Task { await d.web.call("mdApp.setLocked(v)", ["v": on]) } }
    }

    func setZoom(_ z: Double) {
        prefs.zoom = max(0.5, min(3, (z * 10).rounded() / 10))
        for d in DocWindow.all { d.web.view.pageZoom = prefs.zoom }
    }

    func applyTheme() async { await web.call("mdApp.setTheme(t)", ["t": prefs.dark ? "dark" : "light"]) }
    func applyLanguage() async { await web.call("mdApp.setLang(l)", ["l": prefs.lang]); updateTitle() }
    func applySpell() async { await web.call("mdApp.setSpell(v)", ["v": prefs.spell]) }

    // MARK: title

    func updateTitle() {
        let name = model.path?.lastPathComponent ?? (model.isSample ? L("SampleTitle") : L("Untitled"))
        window?.title = Instance.profile.map { name + " — " + $0 } ?? name
        window?.representedURL = model.path
        window?.isDocumentEdited = model.dirty
    }

    // MARK: open

    var isEmptyUntitled: Bool { model.path == nil && !model.dirty && !model.isSample }

    /// An untitled tab nobody typed in, or the sample as it came: a file opened now takes its place.
    var isPristine: Bool { model.path == nil && pendingOpen == nil && !model.dirty }

    /// The file of this tab: the one shown, or the one waiting for the page to be ready.
    var filePath: URL? { model.path ?? pendingOpen }

    /// Opens `url` in a tab with no text of its own: no question, and while the page is still starting the file
    /// waits for it (its name is already the tab's title).
    func openFresh(_ url: URL) {
        let url = url.standardizedFileURL
        if model.ready { Task { @MainActor in await load(url) }; return }
        pendingOpen = url
        window?.title = url.lastPathComponent
        Tabs.changed()
    }

    /// The + button of the tab bar.
    @IBAction override func newWindowForTab(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.newTab(after: self) }

    /// Opens `url` here (asking about unsaved changes first).
    func open(_ url: URL) {
        Task { @MainActor in
            guard await confirmDiscard() else { return }
            await load(url)
        }
    }

    /// The file as text; remembers its BOM and line endings so a save writes them back.
    static func read(_ url: URL) throws -> (text: String, bom: Bool, crlf: Bool) {
        let data = try Data(contentsOf: url)
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? data.dropFirst(3) : data[...]
        guard let text = String(data: Data(body), encoding: .utf8) ?? String(data: Data(body), encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return (text, bom, text.contains("\r\n"))
    }

    @MainActor
    func load(_ url: URL) async {
        guard model.ready else { pendingOpen = url.standardizedFileURL; return }
        let url = url.standardizedFileURL
        do {
            let r = try DocWindow.read(url)
            applyReach(url.deletingLastPathComponent())
            await web.call("mdApp.load(t, b)", ["t": r.text, "b": Schemes.docBase(for: url.deletingLastPathComponent())])
            model.path = url; model.dirty = false; model.isSample = false
            model.bom = r.bom; model.crlf = r.crlf
            diskText = r.text
            model.words = (await web.call("return mdApp.words()") as? Int) ?? 0
            watch(url)
            clearRecovery()
            prefs.addRecent(url.path)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            updateTitle()
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                prefs.recent.removeAll { $0 == url.path }
                alert(L("NotFound", url.path))
            } else {
                alert(L("ErrOpen", error.localizedDescription))
            }
        }
    }

    @MainActor
    func loadText(_ text: String, sample: Bool) async {
        applyReach(nil)
        await web.call("mdApp.load(t, null)", ["t": text])
        model.path = nil; model.dirty = false; model.isSample = sample
        model.bom = false; model.crlf = false
        diskText = nil
        watch(nil)
        model.words = (await web.call("return mdApp.words()") as? Int) ?? 0
        updateTitle()
    }

    /// The open file was renamed or moved from the Files panel (FileOps): the window follows it.
    @MainActor
    func relocate(to url: URL) async {
        let url = url.standardizedFileURL
        model.path = url
        applyReach(url.deletingLastPathComponent())
        await web.call("mdApp.setBase(b)", ["b": Schemes.docBase(for: url.deletingLastPathComponent())])
        watch(url)
        prefs.addRecent(url.path)
        updateTitle()
    }

    // MARK: save

    /// Writes the document. auto: an autosave, which says nothing when it works and reports a failure
    /// in the status line instead of an alert.
    @MainActor
    @discardableResult
    func save(as forceDialog: Bool, auto: Bool = false) async -> Bool {
        var target = model.path
        if forceDialog || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = target?.lastPathComponent ?? L("Untitled") + ".md"
            if let t = target { panel.directoryURL = t.deletingLastPathComponent() }
            guard let w = window, await panel.ask(for: w) == .OK, let u = panel.url else { return false }
            target = u
        }
        guard let target else { return false }
        saving = true
        defer { saving = false }
        // untouched blocks keep their original Markdown; line endings and BOM as the file had them.
        // The text is taken and marked as saved in one call; seq is the last edit it holds.
        guard let snap = await web.call("return mdApp.takeForSave()") as? [String: Any], let md = snap["text"] as? String else {
            if auto { flash(L("ErrAutoSave", "the page did not answer")) } else { alert(L("ErrSave", "the page did not answer")) }
            return false
        }
        let seq = snap["seq"] as? Int ?? lastEditSeq
        let disk = model.crlf ? md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : md
        var data = Data(disk.utf8)
        if model.bom { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        do {
            diskText = disk
            try data.write(to: target, options: .atomic)
            let moved = target != model.path
            model.path = target; model.isSample = false
            model.dirty = lastEditSeq > seq     // typed while saving: still modified, and saved again shortly
            if model.dirty { scheduleAutoSave() }
            if moved {
                applyReach(target.deletingLastPathComponent())
                await web.call("mdApp.setBase(b)", ["b": Schemes.docBase(for: target.deletingLastPathComponent())])
            }
            watch(target)
            clearRecovery()
            prefs.addRecent(target.path)
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            updateTitle()
            if !auto { flash(L("Saved")) }
            return true
        } catch {
            if auto { flash(L("ErrAutoSave", error.localizedDescription)) } else { alert(L("ErrSave", error.localizedDescription)) }
            return false
        }
    }

    /// True when it is fine to drop the current text (saved, or the user chose).
    @MainActor
    func confirmDiscard() async -> Bool {
        guard model.dirty, let w = window else { return true }
        // With autosave on, a file with a name is saved without asking, unless another program
        // changed it meanwhile: then the question below decides.
        if canAutoSave(), await save(as: false, auto: true) { return true }
        let a = NSAlert()
        a.messageText = L("AskSave", model.path?.lastPathComponent ?? L("Untitled"))
        a.addButton(withTitle: L("SaveBtn"))
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("DontSave"))
        switch await a.ask(for: w) {
        case .alertFirstButtonReturn: return await save(as: false)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Vigía"
        a.informativeText = text
        if let w = window { Task { _ = await a.ask(for: w) } } else { a.runModal() }
    }

    // MARK: closing

    private var closeConfirmed = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || !model.dirty { return true }
        Task { @MainActor in
            if await confirmDiscard() { closeConfirmed = true; window?.close() }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) { Tabs.changed() }

    func windowWillClose(_ notification: Notification) {
        if let p = model.path { Tabs.closed.removeAll { $0 == p }; Tabs.closed.append(p) }
        // after the whole window has closed: closing the last one keeps the session (Tabs.saveNow)
        Tabs.changed(after: 0.3)
        watcher = nil
        autoSaveTimer?.invalidate()
        recoveryTimer?.invalidate()
        clearRecovery()
        DocWindow.all.removeAll { $0 === self }
    }

    // MARK: live reload

    func watch(_ url: URL?) {
        watcher = url.map { FileWatcher(file: $0) { [weak self] in self?.diskChanged() } }
    }

    /// Something happened to the file or its folder: read it once and act.
    private func diskChanged() {
        guard let url = model.path, !askingReload else { return }
        guard let r = try? DocWindow.read(url) else {
            if !FileManager.default.fileExists(atPath: url.path) { flash(L("DeletedOnDisk")) }
            return
        }
        guard r.text != diskText else { return }          // our own save, or a touch without a change
        if !model.dirty {
            reloadInPlace(r)
            return
        }
        askingReload = true
        Task { @MainActor in
            defer { askingReload = false }
            guard let w = window else { return }
            let a = NSAlert()
            a.messageText = L("ChangedOnDisk", url.lastPathComponent)
            a.addButton(withTitle: L("ReloadBtn"))
            a.addButton(withTitle: L("KeepMine"))
            if await a.ask(for: w) == .alertFirstButtonReturn, let again = try? DocWindow.read(url) {
                reloadInPlace(again)
            } else {
                diskText = r.text      // asked about this version; a newer one asks again
            }
        }
    }

    private var reloading = false
    private var reloadAgain = false

    /// Swaps in the text from disk. The "modified" mark is cleared before the swap, never after:
    /// an edit typed while the page is reloading posts its own "dirty" and must keep it. Reloads
    /// never overlap; changes that arrive during one lead to one more read at its end.
    private func reloadInPlace(_ r: (text: String, bom: Bool, crlf: Bool)) {
        if reloading { reloadAgain = true; return }
        reloading = true
        diskText = r.text
        model.bom = r.bom; model.crlf = r.crlf
        model.dirty = false
        updateTitle()
        Task { @MainActor in
            await web.call("return await mdApp.reload(t)", ["t": r.text])
            if let w = await web.call("return mdApp.words()") as? Int { model.words = w }
            flash(L("Reloaded"))
            reloading = false
            if reloadAgain { reloadAgain = false; diskChanged() }
        }
    }

    // MARK: autosave

    // On by default: a document with a name is written 1.5 s after the typing stops. It never writes
    // over a change made by another program (the live reload asks first), never a new untitled
    // document or the sample, and never while saving or reloading.
    private func canAutoSave() -> Bool {
        guard prefs.autoSave, model.ready, let url = model.path, !model.isSample, !saving, !reloading, !askingReload,
              let r = try? DocWindow.read(url) else { return false }
        return r.text == diskText
    }

    private func scheduleAutoSave() {
        autoSaveTimer?.invalidate()
        guard prefs.autoSave, model.path != nil else { return }
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.autoSave() }
        }
    }

    @MainActor
    func autoSave() async {
        autoSaveTimer?.invalidate()
        guard model.dirty, model.path != nil else { return }
        if saving || reloading || askingReload { scheduleAutoSave(); return }   // busy: later
        if canAutoSave() { await save(as: false, auto: true) }
    }

    /// The switch in the toolbar and File → Autosave: for every window.
    static func setAutoSave(_ on: Bool) {
        Prefs.shared.autoSave = on
        for d in DocWindow.all {
            if !on { d.autoSaveTimer?.invalidate() } else if d.model.dirty { Task { @MainActor in await d.autoSave() } }
        }
        (NSApp.keyWindow?.windowController as? DocWindow)?.flash(L(on ? "AutoSaveOn" : "AutoSaveOff"))
    }

    // MARK: crash recovery

    static var recoveryFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // each dedicated instance keeps its drafts apart, so the main app never offers them
        let own = Instance.profile.map { "Vigia/profiles/" + Instance.bundleID($0) + "/recovery" } ?? "Vigia/recovery"
        return base.appendingPathComponent(own, isDirectory: true)
    }

    private var recoveryFile: URL { DocWindow.recoveryFolder.appendingPathComponent(recoveryID + ".json") }

    /// While there are unsaved changes, a draft is kept every few seconds; it goes away on save or close.
    private func writeRecovery() {
        guard model.dirty, model.ready, prefs.persist else { return }
        Task { @MainActor in
            guard let text = await web.call("return mdApp.getMarkdownPreserving()") as? String else { return }
            let draft: [String: Any] = ["path": model.path?.path ?? "", "text": text,
                                        "time": ISO8601DateFormatter().string(from: Date())]
            try? FileManager.default.createDirectory(at: DocWindow.recoveryFolder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if let data = try? JSONSerialization.data(withJSONObject: draft) {
                try? data.write(to: recoveryFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryFile.path)
            }
        }
    }

    func clearRecovery() { try? FileManager.default.removeItem(at: recoveryFile) }

    // MARK: links

    /// What the self-test's links asked for outside Vigia (a Finder window, a viewer, a web page): recorded and
    /// never done. 16-nov-2026: the hostile document's clicked links revealed the temporary folder, and a Finder
    /// window called "T" stayed open after every run.
    static var heldOutside: [LinkAction] = []
    static let inSelfTest = CommandLine.arguments.contains("--self-test")

    func openLink(_ href: String) {
        let action = LinkPolicy.decide(href, reach: reach)
        if DocWindow.inSelfTest, action != .ignore, { if case .openDocument = action { return false }; return true }() {
            DocWindow.heldOutside.append(action); return
        }
        switch action {
        case .openDocument(let u): (NSApp.delegate as? AppDelegate)?.open(u, from: self)
        case .openViewer(let u): NSWorkspace.shared.open(u)
        case .reveal(let u): NSWorkspace.shared.activateFileViewerSelecting([u])
        case .external(let u): NSWorkspace.shared.open(u)
        case .ignore: break
        }
    }

    /// A [[name]] of the GitHub view: the file of that name nearest the document, in the panel folders
    /// or next to the document.
    func openWiki(_ name: String) {
        Wiki.forget()
        if let u = Wiki.resolve(name, from: model.path?.deletingLastPathComponent(), panel: prefs.folders) {
            (NSApp.delegate as? AppDelegate)?.open(u, from: self)
        } else {
            flash(L("WikiMissing", Wiki.key(name)))
        }
    }

    // MARK: find

    func showFind(replace: Bool) {
        model.findVisible = true
        model.replaceVisible = replace
        Task { @MainActor in
            if let sel = await web.call("return mdApp.selectedText()") as? String, !sel.isEmpty, !sel.contains("\n") {
                model.findQuery = sel
            }
            find(step: 0)
        }
    }

    func find(step: Int) {
        guard !model.findQuery.isEmpty else { model.findInfo = ""; return }
        Task { await web.call("mdApp.find(q, c, s)", ["q": model.findQuery, "c": model.findCase, "s": step]) }
    }

    func replaceOne() {
        Task { await web.call("mdApp.replace(q, c, r)", ["q": model.findQuery, "c": model.findCase, "r": model.replaceText]) }
    }

    func replaceAll() {
        Task { @MainActor in
            let n = (await web.call("return mdApp.replaceAll(q, c, r)",
                                    ["q": model.findQuery, "c": model.findCase, "r": model.replaceText]) as? Int) ?? 0
            model.findInfo = L("Replaced", n)
        }
    }

    func hideFind() {
        model.findVisible = false
        Task { await web.call("mdApp.findClose()"); await web.call("mdApp.focus()") }
    }

    // MARK: insert dialogs

    func insertLink() {
        Task { @MainActor in
            let sel = (await web.call("return mdApp.selectedText()") as? String) ?? ""
            guard let v = await Dialogs.ask(L("Link"), fields: [(L("LinkText"), sel), (L("LinkUrl"), "https://")], in: window),
                  !v[1].isEmpty else { return }
            exec("addLink", ["linkUrl": v[1], "linkText": v[0].isEmpty ? v[1] : v[0]])
        }
    }

    func insertImage() {
        Task { @MainActor in
            let browse: () -> (String, String)? = {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.png, .jpeg, .gif, .svg, .webP, .bmp]
                if let d = self.model.path?.deletingLastPathComponent() { p.directoryURL = d }
                guard p.runModal() == .OK, let u = p.url else { return nil }
                var f = u.path
                if let dir = self.model.path?.deletingLastPathComponent().path, f.hasPrefix(dir + "/") {
                    f = String(f.dropFirst(dir.count + 1))
                }
                return (f.replacingOccurrences(of: " ", with: "%20"), u.deletingPathExtension().lastPathComponent)
            }
            guard let v = await Dialogs.ask(L("Image"), fields: [(L("ImageUrl"), ""), (L("ImageAlt"), "")],
                                            browse: browse, in: window), !v[0].isEmpty else { return }
            exec("addImage", ["imageUrl": v[0], "altText": v[1]])
        }
    }

    func insertTable() {
        Task { @MainActor in
            guard let v = await Dialogs.ask(L("Table"), fields: [(L("Columns"), "3"), (L("Rows"), "3")], in: window) else { return }
            let cols = max(1, min(20, Int(v[0]) ?? 3)), rows = max(1, min(100, Int(v[1]) ?? 3))
            exec("addTable", ["columnCount": cols, "rowCount": rows + 1])
        }
    }

    // MARK: export and print

    func exportHtml() {
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            let base = model.path?.deletingPathExtension().lastPathComponent ?? L("Untitled")
            panel.nameFieldStringValue = base + ".html"
            if let d = model.path?.deletingLastPathComponent() { panel.directoryURL = d }
            guard let w = window, await panel.ask(for: w) == .OK, let u = panel.url else { return }
            exportTo(u)
        }
    }

    /// The page renders (diagrams included) and answers with an "export" message.
    func exportTo(_ u: URL) {
        pendingExport = u
        Task { await web.call("await mdApp.exportHtml(t)", ["t": u.deletingPathExtension().lastPathComponent]) }
    }

    private func writeExport(_ m: [String: Any]) {
        guard let file = pendingExport, let lib = EditorWeb.webFolder?.appendingPathComponent("lib") else { return }
        pendingExport = nil
        let dark = (m["theme"] as? String) == "dark"
        let math = (m["math"] as? Bool) ?? false
        let css = (try? String(contentsOf: lib.appendingPathComponent(dark ? "github-markdown-dark.css" : "github-markdown-light.css"), encoding: .utf8)) ?? ""
        let hl = (try? String(contentsOf: lib.appendingPathComponent(dark ? "hljs-dark.css" : "hljs-light.css"), encoding: .utf8)) ?? ""
        let title = ((m["title"] as? String) ?? "").replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let body = (m["body"] as? String) ?? ""
        let html = """
            <!doctype html>
            <html lang="\(prefs.lang)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="Vigía \(appVersion)">
            <title>\(title)</title>
            \(math ? "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@\(katexVersion)/dist/katex.min.css\">" : "")
            <style>
            \(css)
            \(hl)
            body { margin: 0; background: \(dark ? "#0d1117" : "#ffffff"); }
            .markdown-body { box-sizing: border-box; max-width: 980px; margin: 0 auto; padding: 45px; }
            @media (max-width: 767px) { .markdown-body { padding: 15px; } }
            </style>
            </head>
            <body>
            <article class="markdown-body">
            \(body)
            </article>
            </body>
            </html>
            """
        do { try Data(html.utf8).write(to: file, options: .atomic) }
        catch { alert(L("ErrSave", error.localizedDescription)) }
    }

    private func printNow() {
        guard let w = window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let op = web.view.printOperation(with: info)
        op.view?.frame = web.view.bounds
        op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// The KaTeX of the web bundle (see _npm/package.json), for the stylesheet of exported pages.
let katexVersion = "0.19.1"

/// Watches a file and its folder; `changed` runs on the main queue, at most every 80 ms.
final class FileWatcher {
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private let url: URL
    private let changed: () -> Void
    private var pending = false

    init(file: URL, changed: @escaping () -> Void) {
        url = file
        self.changed = changed
        dirSource = FileWatcher.source(url.deletingLastPathComponent().path, [.write, .rename, .delete]) { [weak self] in self?.poke() }
        armFile()
    }

    deinit { fileSource?.cancel(); dirSource?.cancel() }

    private static func source(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                               _ handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler(handler: handler)
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    /// The file watcher follows one inode; after a replace or a delete it is set on the new file.
    private func armFile() {
        fileSource?.cancel()
        fileSource = FileWatcher.source(url.path, [.write, .extend, .delete, .rename, .attrib]) { [weak self] in
            guard let self else { return }
            if let ev = self.fileSource?.data, !ev.intersection([.delete, .rename]).isEmpty { self.fileSource?.cancel(); self.fileSource = nil }
            self.poke()
        }
    }

    private func poke() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.pending = false
            if self.fileSource == nil { self.armFile() }
            self.changed()
        }
    }
}
