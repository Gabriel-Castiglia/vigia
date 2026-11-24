// Vigia: start-up, menus, opening files and folders, recovery, updates.
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 10, 2026
// SPDX-License-Identifier: GPL-2.0-only
//
// One window per document. The menus are built here in the app's language (English or
// Spanish, switched at run time). Besides opening files, the program answers to:
//   --self-test           checks the page, the link rules, saving and live reload (SelfTest.swift)
//   --screenshot FILE     draws a window into a PNG and quits, for the manuals; with
//                         --view main|theme|about, --lang en|es, --theme light|dark,
//                         --accent KEY, --mode visual|source|preview, --open FILE, --size WxH
// Those two never read or write the preferences.

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    var isOn: () -> Bool = { false }
    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

final class MenuStates: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for case let i as ClosureItem in menu.items { i.state = i.isOn() ? .on : .off }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Prefs.shared
    private let states = MenuStates()
    private var bag: Set<AnyCancellable> = []
    private var themeWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var appearanceWatch: NSKeyValueObservation?
    private var launchFiles: [URL] = []
    private var launched = false

    var current: DocWindow? {
        (NSApp.keyWindow?.windowController as? DocWindow) ?? (NSApp.mainWindow?.windowController as? DocWindow) ?? DocWindow.all.last
    }

    func argument(after flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        if !launched { launchFiles += urls }
        else if urls.count == 1 { open(urls[0], from: nil) }
        else { openAll(urls.map(\.standardizedFileURL), show: urls.count - 1) }
    }

    /// The self-test without visible windows (see applicationDidFinishLaunching).
    static var quiet = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let shot = argument(after: "--screenshot")
        let selfTest = CommandLine.arguments.contains("--self-test")
        // The self-test runs out of sight unless asked (--visible): no Dock icon, no focus taken, and its
        // windows transparent and click-through, so it never covers what Gabriel is doing (13-nov-2026).
        AppDelegate.quiet = selfTest && !CommandLine.arguments.contains("--visible")
        if AppDelegate.quiet { NSApp.setActivationPolicy(.accessory) }
        prefs.persist = shot == nil && !selfTest
        prefs.load()
        if shot != nil {
            if let l = argument(after: "--lang") { prefs.lang = Prefs.language(l) }
            if let t = argument(after: "--theme") { prefs.theme = t }
            if let a = argument(after: "--accent") { prefs.accent = a }
            if let m = argument(after: "--mode") { prefs.mode = m }
            prefs.showPanes()
        }
        if prefs.persist { prefs.applyStartupFolders() }
        if Instance.isDedicated && prefs.persist { startDedicated() }
        prefs.applyAppearance()
        prefs.applyDockIcon()
        buildMenus()
        prefs.$lang.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.buildMenus()
                for d in DocWindow.all { Task { await d.applyLanguage() } }
                self?.themeWindow?.title = L("ThemeMenu").replacingOccurrences(of: "…", with: "")
                self?.aboutWindow?.title = L("About")
            }
        }.store(in: &bag)
        prefs.$dark.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { _ in
            DispatchQueue.main.async { for d in DocWindow.all { Task { await d.applyTheme() } } }
        }.store(in: &bag)
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.prefs.refreshDark() }
        }
        launched = true

        if selfTest { SelfTest.start(); return }
        if let shot { screenshot(to: shot); return }

        let files = launchFiles
        // The tabs of the last session (File → Reopen Tabs at Start) and the files asked for, a tab each (Tabs.swift).
        let start = Tabs.startList(files)
        if Instance.isDedicated {
            if !start.urls.isEmpty { openAll(start.urls, show: start.show) }
            else if let h = Instance.home, FileManager.default.fileExists(atPath: h) { open(URL(fileURLWithPath: h), from: nil) }
            else { newWindow() }
            files.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.forEach { open($0, from: nil) }
            offerRecovery()
            return
        }
        Migration.drafts()
        Migration.instances(from: Bundle.main.bundleURL)
        Instance.refreshAll()
        // Updates that install themselves (SelfUpdate.swift); only the main app checks, the dedicated instances are
        // rebuilt from it when it opens.
        let up = SelfUpdate.shared
        up.appName = "Vigia"
        up.displayName = "Vigía"
        up.repo = appRepo
        up.version = appVersion
        up.language = { Prefs.shared.lang }
        up.cleanUpAtStart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { up.checkDaily() }
        if start.urls.isEmpty {
            let d = newWindow()
            // Until a file of one's own has been opened, the app starts on the sample.
            if files.isEmpty && (!prefs.sampleShown || prefs.recent.isEmpty) { prefs.sampleShown = true; openSample(in: d) }
        } else {
            openAll(start.urls, show: start.show)
        }
        // folders asked for go to the Files panel
        files.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.forEach { open($0, from: nil) }
        offerRecovery()
    }

    /// A dedicated instance: the folders and colour it was made with when it has none of its own, and
    /// read-only and the view it must start with, whatever the last session left.
    private func startDedicated() {
        if prefs.folders.isEmpty { prefs.folders = Instance.folders }
        if UserDefaults.standard.object(forKey: "Accent") == nil, let a = Instance.accent { prefs.accent = a }
        if Instance.startReadOnly { prefs.readOnly = true }
        if let m = Instance.startMode, ["visual", "source", "preview"].contains(m) { prefs.mode = m }
        prefs.showPanes()
        prefs.sampleShown = true
    }

    /// "Convert to TXT" (right click on a Markdown file in the Files panel): writes the file as it reads in the
    /// GitHub view, as plain UTF-8 text, next to it as name.txt; the Markdown file is not touched, and an existing
    /// .txt is never overwritten (name (2).txt, name (3).txt...).
    func convertToText(_ url: URL, from doc: DocWindow) {
        Task { @MainActor in
            guard let data = try? Data(contentsOf: url) else { doc.flash(L("ItemGone")); return }
            let source = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            guard let text = await doc.web.call("return mdApp.plainText(t)", ["t": source]) as? String else {
                doc.flash(String(format: L("TxtFailed"), url.lastPathComponent)); return
            }
            let target = AppDelegate.textTarget(for: url)
            do {
                try Data(text.utf8).write(to: target, options: .withoutOverwriting)
                doc.flash(String(format: L("TxtDone"), target.lastPathComponent))
            } catch {
                doc.flash(String(format: L("TxtFailed"), error.localizedDescription))
            }
        }
    }

    static func textTarget(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent
        var target = dir.appendingPathComponent(base + ".txt"), n = 2
        while FileManager.default.fileExists(atPath: target.path) { target = dir.appendingPathComponent("\(base) (\(n)).txt"); n += 1 }
        return target
    }

    /// Files panel → Open in a dedicated instance: the file or folder in its own Vigia, made the
    /// first time (in ~/Applications, with this window's colour), brought forward afterwards.
    func openDedicated(_ url: URL, from doc: DocWindow?) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let name = Instance.name(for: url)
        let made = Instance.bundleURL(name)
        if Instance.spec(of: made) != nil { Instance.launch(made, files: isDir.boolValue ? [] : [url]); return }
        guard let source = Instance.mainBundle else { doc?.flash(L("InstanceFail", "Vigía")); return }
        let spec = Instance.Spec(name: name, accent: prefs.accent,
                                 folders: [isDir.boolValue ? url.path : url.deletingLastPathComponent().path],
                                 home: isDir.boolValue ? nil : url.path)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let app = try Instance.make(spec, from: source)
                DispatchQueue.main.async { Instance.launch(app); doc?.flash(L("InstanceMade", app.deletingPathExtension().lastPathComponent)) }
            } catch {
                DispatchQueue.main.async { doc?.flash(L("InstanceFail", error.localizedDescription)) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        Tabs.saveNow()
        prefs.keepTabsForUpdate(Tabs.files().files)
        SelfUpdate.shared.finishIfStaged()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = DocWindow.all.filter { $0.model.dirty }
        guard !dirty.isEmpty else { return .terminateNow }
        Task { @MainActor in
            for d in dirty {
                d.window?.makeKeyAndOrderFront(nil)
                if !(await d.confirmDiscard()) { NSApp.reply(toApplicationShouldTerminate: false); return }
                d.model.dirty = false
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: windows and files

    @discardableResult
    func newWindow() -> DocWindow {
        let d = DocWindow()
        if let w = d.window {
            let first = DocWindow.all.count == 1
            if first {
                // The saved frame is used only by the app itself, never by the self-test or the
                // screenshot mode, and it may be smaller than the window allows or off screen.
                if !(prefs.persist && w.setFrameUsingName("Document")) { w.center() }
                w.setFrame(AppDelegate.fitted(w.frame, min: w.frameRect(forContentRect: NSRect(origin: .zero, size: DocWindow.minContent)).size, on: (w.screen ?? NSScreen.main)?.visibleFrame), display: false)
            } else if let prev = DocWindow.all.dropLast().last?.window {
                w.setFrame(prev.frame.offsetBy(dx: 26, dy: -26), display: false)
            }
            if prefs.persist { w.setFrameAutosaveName(first ? "Document" : "") }
        }
        if AppDelegate.quiet, let w = d.window { w.alphaValue = 0; w.ignoresMouseEvents = true; w.orderBack(nil) }
        else { d.showWindow(nil); NSApp.activate() }
        return d
    }

    /// A window frame no smaller than `min` and inside `screen`.
    static func fitted(_ f: NSRect, min: NSSize, on screen: NSRect?) -> NSRect {
        var r = f
        r.size.width = max(r.width, min.width)
        r.size.height = max(r.height, min.height)
        if let v = screen {
            r.size.width = Swift.min(r.width, v.width)
            r.size.height = Swift.min(r.height, v.height)
            r.origin.x = Swift.min(Swift.max(r.minX, v.minX), v.maxX - r.width)
            r.origin.y = Swift.min(Swift.max(r.minY, v.minY), v.maxY - r.height)
        }
        return r
    }

    /// Opens a file, as on Windows since 3.2.0: the tab that already has it is shown; otherwise it goes into the
    /// tab of `from` (or the shown one) when nobody typed in it, or into a new tab next to it. `inNewWindow`: a
    /// window of its own instead.
    func open(_ url: URL, from doc: DocWindow?, inNewWindow: Bool = false) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            addFolder(url); return
        }
        if let open = DocWindow.all.first(where: { $0.filePath == url }) { show(open); return }
        let here = doc ?? current
        let target: DocWindow
        if inNewWindow || here == nil { target = newWindow() }
        else if let h = here, h.isPristine { target = h }
        else { target = newTab(after: here) }
        target.openFresh(url)
        show(target)
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"].compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = true
        if let d = current?.model.path?.deletingLastPathComponent() { p.directoryURL = d }
        guard p.runModal() == .OK else { return }
        if p.urls.count == 1 { open(p.urls[0], from: nil) } else { openAll(p.urls.map(\.standardizedFileURL), show: p.urls.count - 1) }
    }

    func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        guard p.runModal() == .OK, let u = p.url else { return }
        addFolder(u)
    }

    func addFolder(_ u: URL) {
        if !prefs.folders.contains(u.path) { prefs.folders.append(u.path) }
        prefs.recentFolders = Array(([u.path] + prefs.recentFolders.filter { $0 != u.path }).prefix(6))
        prefs.showFiles()
    }

    static var samplePath: URL? {
        Bundle.main.url(forResource: "sample_\(Prefs.shared.lang)", withExtension: "md", subdirectory: "samples")
            ?? Bundle.main.url(forResource: "sample_en", withExtension: "md", subdirectory: "samples")
    }

    /// The sample opens as an untitled copy, so the installed file is never overwritten.
    func openSample(in doc: DocWindow? = nil) {
        guard let p = AppDelegate.samplePath, let text = try? String(contentsOf: p, encoding: .utf8) else { return }
        let d = doc ?? (current?.isPristine == true ? current! : newTab())
        let go = { Task { @MainActor in await d.loadText(text, sample: true) } }
        if d.model.ready { _ = go() } else { d.onReady = { _ = go() } }
    }

    func openManual() {
        let u = Bundle.main.url(forResource: "Vigia-manual-" + prefs.lang, withExtension: "pdf", subdirectory: "docs")
            ?? Bundle.main.url(forResource: "Vigia-manual-en", withExtension: "pdf", subdirectory: "docs")
        if let u { NSWorkspace.shared.open(u) }
    }

    func showTheme() {
        if themeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 608, height: 440), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ThemeView(prefs: prefs))
            w.center()
            themeWindow = w
        }
        themeWindow?.title = L("ThemeMenu").replacingOccurrences(of: "…", with: "")
        themeWindow?.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 520), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AboutView(prefs: prefs))
            w.center()
            aboutWindow = w
        }
        aboutWindow?.title = L("About")
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: recovery and updates

    /// Drafts left by a session that ended without saving are offered once, at start.
    func offerRecovery() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: DocWindow.recoveryFolder, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = d["text"] as? String else { try? fm.removeItem(at: f); continue }
            let path = (d["path"] as? String) ?? ""
            let a = NSAlert()
            a.messageText = L("Recover", path.isEmpty ? L("Untitled") : (path as NSString).lastPathComponent, (d["time"] as? String) ?? "")
            a.addButton(withTitle: L("RecoverBtn"))
            a.addButton(withTitle: L("DiscardBtn"))
            let take = a.runModal() == .alertFirstButtonReturn
            try? fm.removeItem(at: f)
            guard take else { continue }
            let doc = current?.isPristine == true ? current! : newTab()
            let go = {
                Task { @MainActor in
                    if !path.isEmpty, fm.fileExists(atPath: path) { await doc.load(URL(fileURLWithPath: path)) }
                    await doc.web.call("mdApp.load(t, b)", ["t": text, "b": doc.model.path == nil ? NSNull() : Schemes.docBase(for: doc.model.path?.deletingLastPathComponent())])
                    doc.model.dirty = true
                    doc.updateTitle()
                    doc.flash(L("Recovered"))
                }
            }
            if doc.model.ready { _ = go() } else { doc.onReady = { _ = go() } }
        }
    }

    // MARK: menus

    private func top(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = states
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private func item(_ t: String, key: String = "", mods: NSEvent.ModifierFlags = .command,
                      on: @escaping () -> Bool = { false }, _ run: @escaping () -> Void) -> ClosureItem {
        let i = ClosureItem(t, key: key, mods: mods, run)
        i.isOn = on
        return i
    }

    private func doc(_ f: @escaping (DocWindow) -> Void) -> () -> Void { { [weak self] in if let d = self?.current { f(d) } } }

    private func send(_ sel: Selector) -> () -> Void { { _ = NSApp.sendAction(sel, to: nil, from: nil) } }

    /// View → Layout: the six layouts and the swap, as on Windows (Layout.swift).
    private func layoutItem() -> NSMenuItem {
        let sub = NSMenu(title: L("Layout"))
        sub.delegate = states
        for preset in Layouts.presets {
            sub.addItem(item(L(preset.key), on: { [weak self] in self.map { Layouts.isPreset(preset, $0.prefs) } ?? false }) { [weak self] in
                if let p = self?.prefs { Layouts.apply(preset, p) }
            })
        }
        sub.addItem(.separator())
        sub.addItem(item(L("LayoutSwap")) { [weak self] in if let p = self?.prefs { Layouts.swap(p) } })
        let top = NSMenuItem(title: L("Layout"), action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    /// View → Text width: the column of the Visual and GitHub views, in every window.
    private func widthItem() -> NSMenuItem {
        let sub = NSMenu(title: L("TextWidth"))
        sub.delegate = states
        for (px, label) in [(980, "WidthNormal"), (1280, "WidthWide"), (1600, "WidthWider"), (0, "WidthFull")] {
            sub.addItem(item(L(label), on: { [weak self] in self?.prefs.textWidth == px }) { [weak self] in
                self?.prefs.textWidth = px
                for d in DocWindow.all { Task { await d.web.call("mdApp.setWidth(w)", ["w": px]) } }
            })
        }
        let top = NSMenuItem(title: L("TextWidth"), action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    /// File → Reopen Tabs at Start.
    private func restoreTabsItem() -> NSMenuItem {
        let i = item(L("RestoreTabs"), on: { [weak self] in self?.prefs.restoreTabs == true }) { [weak self] in self?.toggleRestoreTabs() }
        i.toolTip = L("RestoreTabsTip")
        return i
    }

    /// File → Folders at start: the same three choices as the ⋯ menu of the Files panel.
    private func startupItem() -> NSMenuItem {
        let sub = NSMenu(title: L("StartupMenu"))
        sub.delegate = states
        for (key, label, tip) in [("restore", "StartupRestore", "StartupRestoreTip"), ("clean", "StartupClean", "StartupCleanTip"),
                                  ("pinned", "StartupPinned", "StartupPinnedTip")] {
            let i = item(L(label), on: { [weak self] in self?.prefs.startupFolders == key }) { [weak self] in self?.prefs.startupFolders = key }
            i.toolTip = L(tip)
            sub.addItem(i)
        }
        let top = NSMenuItem(title: L("StartupMenu"), action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    func buildMenus() {
        let bar = NSMenu()
        bar.addItem(top("Vigía", [
            item(L("About")) { [weak self] in self?.showAbout() },
            item(L("CheckUpdates")) { SelfUpdate.shared.check(interactive: true) },
            .separator(),
            item(L("ThemeMenu"), key: ",") { [weak self] in self?.showTheme() },
            .separator(),
            item(L("Hide"), key: "h") { NSApp.hide(nil) },
            item(L("HideOthers"), key: "h", mods: [.command, .option]) { NSApp.hideOtherApplications(nil) },
            item(L("ShowAll")) { NSApp.unhideAllApplications(nil) },
            .separator(),
            item(L("Quit"), key: "q") { NSApp.terminate(nil) },
        ]))

        let recent = NSMenu(title: L("Recent"))
        recent.delegate = states
        let recentItem = NSMenuItem(title: L("Recent"), action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        // as on Windows: the sample first (unless hidden), the files, then the folders opened lately
        if AppDelegate.samplePath != nil && !prefs.sampleHidden {
            recent.addItem(item(L("SampleItem")) { [weak self] in self?.openSample() })
            recent.addItem(item(L("SampleHide")) { [weak self] in self?.prefs.sampleHidden = true; self?.buildMenus() })
            recent.addItem(.separator())
        }
        if prefs.recent.isEmpty && prefs.recentFolders.isEmpty {
            let e = NSMenuItem(title: L("RecentEmpty"), action: nil, keyEquivalent: ""); e.isEnabled = false
            recent.addItem(e)
        } else {
            for p in prefs.recent {
                recent.addItem(item((p as NSString).lastPathComponent) { [weak self] in self?.open(URL(fileURLWithPath: p), from: nil) })
            }
            if !prefs.recentFolders.isEmpty {
                if !prefs.recent.isEmpty { recent.addItem(.separator()) }
                let h = NSMenuItem(title: L("RecentFolders"), action: nil, keyEquivalent: ""); h.isEnabled = false
                recent.addItem(h)
                for p in prefs.recentFolders {
                    recent.addItem(item((p as NSString).lastPathComponent) { [weak self] in self?.addFolder(URL(fileURLWithPath: p)) })
                }
            }
            recent.addItem(.separator())
            recent.addItem(item(L("RecentClear")) { [weak self] in self?.prefs.recent = []; self?.prefs.recentFolders = []; self?.buildMenus() })
        }

        bar.addItem(top(L("File"), [
            item(L("NewTab"), key: "t") { [weak self] in self?.newTab() },
            item(L("New"), key: "n") { [weak self] in self?.newWindow() },
            item(L("Open"), key: "o") { [weak self] in self?.openPanel() },
            recentItem,
            item(L("TabReopen"), key: "t", mods: [.command, .shift]) { [weak self] in self?.reopenClosedTab() },
            item(L("OpenDir"), key: "o", mods: [.command, .shift]) { [weak self] in self?.pickFolder() },
            item(L("CloseDir")) { [weak self] in self?.prefs.folders = [] },
            startupItem(),
            restoreTabsItem(),
            .separator(),
            item(L("CloseWindow"), key: "w") { NSApp.keyWindow?.performClose(nil) },
            item(L("Save"), key: "s", doc { d in Task { await d.save(as: false) } }),
            item(L("SaveAs"), key: "s", mods: [.command, .shift], doc { d in Task { await d.save(as: true) } }),
            item(L("AutoSave"), on: { [weak self] in self?.prefs.autoSave == true }) { DocWindow.setAutoSave(!Prefs.shared.autoSave) },
            item(L("FavCurrent"), on: { [weak self] in self?.current?.model.path.map { Prefs.shared.isFavorite($0.path) } == true },
                 doc { d in
                     guard let p = d.model.path?.path else { return }
                     Prefs.shared.toggleFavorite(p)
                     d.flash(L(Prefs.shared.isFavorite(p) ? "FavAdded" : "FavRemoved", URL(fileURLWithPath: p).lastPathComponent))
                 }),
            item(L("ExportHtml"), key: "e", doc { $0.exportHtml() }),
            item(L("Print"), key: "p", doc { $0.command("print") }),
            .separator(),
            item(L("OpenFolder"), doc { d in if let p = d.model.path { NSWorkspace.shared.activateFileViewerSelecting([p]) } }),
        ]))

        bar.addItem(top(L("Edit"), [
            item(L("Undo"), key: "z", doc { $0.exec("undo") }),
            item(L("Redo"), key: "z", mods: [.command, .shift], doc { $0.exec("redo") }),
            .separator(),
            item(L("Cut"), key: "x", send(#selector(NSText.cut(_:)))),
            item(L("Copy"), key: "c", send(#selector(NSText.copy(_:)))),
            item(L("Paste"), key: "v", send(#selector(NSText.paste(_:)))),
            item(L("SelectAll"), key: "a", send(#selector(NSText.selectAll(_:)))),
            .separator(),
            item(L("Find"), key: "f", doc { $0.showFind(replace: false) }),
            item(L("Replace"), key: "f", mods: [.command, .option], doc { $0.showFind(replace: true) }),
            item(L("SearchFolders"), key: "f", mods: [.command, .shift], doc { $0.focusTreeSearch() }),
            item(L("FindNext"), key: "g", doc { $0.find(step: 1) }),
            item(L("Prev").components(separatedBy: " (")[0], key: "g", mods: [.command, .shift], doc { $0.find(step: -1) }),
            .separator(),
            item(L("ReadOnly"), key: "l", mods: [.command, .shift], on: { [weak self] in self?.prefs.readOnly == true },
                 doc { $0.setReadOnly(!Prefs.shared.readOnly) }),
            item(L("Spell"), on: { [weak self] in self?.prefs.spell == true }) { [weak self] in
                guard let self else { return }
                self.prefs.spell.toggle()
                for d in DocWindow.all { Task { await d.applySpell() } }
            },
        ]))

        let headings: [NSMenuItem] = (1 ... 6).map { n in item("H\(n)", key: "\(n)", mods: [.command, .option], doc { $0.exec("heading", ["level": n]) }) }
            + [item(L("Paragraph"), key: "0", mods: [.command, .option], doc { $0.exec("heading", ["level": 0]) })]
        let headingItem = NSMenuItem(title: L("Heading"), action: nil, keyEquivalent: "")
        let hm = NSMenu(title: L("Heading")); headings.forEach(hm.addItem); headingItem.submenu = hm
        bar.addItem(top(L("Format"), [
            item(L("Bold"), key: "b", doc { $0.exec("bold") }),
            item(L("Italic"), key: "i", doc { $0.exec("italic") }),
            item(L("Strike"), key: "x", mods: [.command, .shift], doc { $0.exec("strike") }),
            item(L("Code"), key: "k", mods: [.command, .shift], doc { $0.exec("code") }),
            headingItem,
            .separator(),
            item(L("Quote"), doc { $0.exec("blockQuote") }),
            item(L("Ul"), doc { $0.exec("bulletList") }),
            item(L("Ol"), doc { $0.exec("orderedList") }),
            item(L("Task"), doc { $0.exec("taskList") }),
            item(L("CodeBlock"), doc { $0.exec("codeBlock") }),
            item(L("Hr"), doc { $0.exec("hr") }),
            .separator(),
            item(L("Table"), doc { $0.insertTable() }),
            item(L("Link"), key: "k", doc { $0.insertLink() }),
            item(L("Image"), doc { $0.insertImage() }),
        ]))

        bar.addItem(top(L("View"), [
            item(L("ModeVisual"), key: "1", on: { [weak self] in self?.prefs.mode == "visual" }, doc { $0.setMode("visual") }),
            item(L("ModeSource"), key: "2", on: { [weak self] in self?.prefs.mode == "source" }, doc { $0.setMode("source") }),
            item(L("ModePreview"), key: "3", on: { [weak self] in self?.prefs.mode == "preview" }, doc { $0.setMode("preview") }),
            .separator(),
            item(L("Sidebar"), key: "e", mods: [.command, .shift], on: { [weak self] in self?.prefs.panesShown == true }) { [weak self] in
                self?.prefs.togglePanes()
            },
            layoutItem(),
            item(L("RecentPanelMenu"), on: { [weak self] in self?.prefs.recentPanel == true }) { [weak self] in self?.prefs.recentPanel.toggle() },
            widthItem(),
            .separator(),
            item(L("ZoomIn"), key: "+", doc { $0.setZoom(Prefs.shared.zoom + 0.1) }),
            item(L("ZoomOut"), key: "-", doc { $0.setZoom(Prefs.shared.zoom - 0.1) }),
            item(L("ZoomReset"), key: "0", doc { $0.setZoom(1) }),
            .separator(),
            item(L("ThemeMenu")) { [weak self] in self?.showTheme() },
        ]))

        bar.addItem(top(L("Language"), Prefs.languages.map { code, name in
            item(name, on: { [weak self] in self?.prefs.lang == code }) { [weak self] in self?.prefs.lang = code }
        }))

        let window = top(L("Window"), [
            item(L("Minimize"), key: "m") { NSApp.keyWindow?.miniaturize(nil) },
            item(L("ZoomWindow")) { NSApp.keyWindow?.zoom(nil) },
            .separator(),
        ] + tabMenuItems())
        bar.addItem(window)
        let help = top(L("Help"), [
            item(L("Manual"), key: "?") { [weak self] in self?.openManual() },
            item(L("Guide")) {
                let page = Prefs.shared.lang
                NSWorkspace.shared.open(URL(string: "https://docs.github.com/\(page)/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax")!)
            },
            item(L("Sample")) { [weak self] in self?.openSample() },
            item(L("SampleInRecent"), on: { [weak self] in self?.prefs.sampleHidden == false }) { [weak self] in
                self?.prefs.sampleHidden.toggle(); self?.buildMenus()
            },
        ])
        bar.addItem(help)
        NSApp.mainMenu = bar
        NSApp.windowsMenu = window.submenu
        NSApp.helpMenu = help.submenu
    }

    // MARK: screenshots

    private func screenshot(to path: String) {
        let view = argument(after: "--view") ?? "main"
        let d = newWindow()
        let size = argument(after: "--size")?.split(separator: "x").compactMap { Double($0) }
        d.window?.setContentSize(size?.count == 2 ? NSSize(width: size![0], height: size![1]) : NSSize(width: 1180, height: 760))
        d.window?.center()
        let file = argument(after: "--open").map { URL(fileURLWithPath: $0) }
        if let folder = argument(after: "--folder") { prefs.folders = [folder]; prefs.showFiles() }   // the Files panel
        if let list = argument(after: "--folders") { prefs.folders = list.split(separator: ":").map(String.init); prefs.showFiles() }
        if let pin = argument(after: "--pin") { prefs.pinned = [pin] }
        if let c = argument(after: "--folder-colors") { prefs.folderColors = c }
        if let l = argument(after: "--layout"), let preset = Layouts.presets.first(where: { $0.key == l }) { Layouts.apply(preset, prefs) }
        d.onReady = { [weak self] in
            if let file { d.open(file) } else { self?.openSample(in: d) }
            var target: NSWindow? = d.window
            if view == "theme" { self?.showTheme(); target = self?.themeWindow }
            if view == "about" { self?.showAbout(); target = self?.aboutWindow }
            if view == "layouts", let prefs = self?.prefs { target = AppDelegate.layoutPanelWindow(prefs) }   // the layout button's panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                Task { @MainActor in
                    var ok = false
                    if let t = target { ok = await AppDelegate.savePicture(of: t, web: t === d.window ? d.web.view : nil, to: path) }
                    FileHandle.standardError.write(Data((ok ? "screenshot saved: \(path)\n" : "screenshot failed\n").utf8))
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// The layout button's panel in a window of its own, for the manual's picture (a popover is not drawn into a cache).
    static func layoutPanelWindow(_ prefs: Prefs) -> NSWindow {
        let host = NSHostingView(rootView: LayoutPanel(prefs: prefs).background(Color(nsColor: .windowBackgroundColor)))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.center()
        w.orderFront(nil)
        return w
    }

    /// The window as drawn by AppKit, with the web page's own snapshot laid where the page is
    /// (a web view does not draw into an AppKit cache).
    @MainActor
    static func savePicture(of window: NSWindow, web: WKWebView?, to path: String) async -> Bool {
        guard let root = window.contentView?.superview ?? window.contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: rep)
        if let web, let shot = try? await web.takeSnapshot(configuration: nil) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            shot.draw(in: web.convert(web.bounds, to: root))
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
