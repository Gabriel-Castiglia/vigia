// Vigia: tabs. Several documents in one window, as on Windows (3.2.0), with the tabs of macOS: each tab is a
// document window of its own (DocWindow), so it keeps its editor, undo history, cursor and scroll position while
// another one is shown. Plus the closed tabs (⇧⌘T) and the tabs of the last session (File → Reopen Tabs at Start).
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 24, 2026
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

enum Tabs {
    static let identifier = "io.github.gabriel-castiglia.vigia.document"

    /// The files of the tabs closed lately, the last one at the end (⇧⌘T reopens it).
    static var closed: [URL] = []

    /// While a session is being opened again, its half-opened state is not written over it.
    static var restoring = false

    /// Every document window, window by window and in the order of its tabs.
    static func ordered() -> [DocWindow] {
        var out: [DocWindow] = [], seen = Set<ObjectIdentifier>()
        for d in DocWindow.all {
            let group = d.window?.tabbedWindows ?? d.window.map { [$0] } ?? []
            for w in group {
                if let x = w.windowController as? DocWindow, seen.insert(ObjectIdentifier(x)).inserted { out.append(x) }
            }
            if seen.insert(ObjectIdentifier(d)).inserted { out.append(d) }
        }
        return out
    }

    /// The files of the tabs in order, each once, and which of them is shown. Untitled documents are left out.
    /// `front`: the document whose window is in front (the key window's, when nil); the self-test, which has no key
    /// window, names it.
    static func files(front: DocWindow? = nil) -> (files: [String], active: Int) {
        var files: [String] = [], active = 0
        // the shown tab of the window in front
        let key = front ?? (NSApp.delegate as? AppDelegate)?.current
        let shown = (key?.window?.tabGroup?.selectedWindow?.windowController as? DocWindow) ?? key
        for d in ordered() {
            guard let p = d.filePath?.path else { continue }
            if let i = files.firstIndex(of: p) { if d === shown { active = i }; continue }
            if d === shown { active = files.count }
            files.append(p)
        }
        return (files, active)
    }

    /// The passing tab (DocWindow.preview) of the window of `doc` that a click in the panel may take: one nobody typed
    /// in and that is not being saved.
    static func passing(near doc: DocWindow?) -> DocWindow? {
        let group = doc?.window?.tabbedWindows ?? doc?.window.map { [$0] } ?? []
        return group.compactMap { $0.windowController as? DocWindow }.first { $0.preview && !$0.model.dirty && !$0.saving }
    }

    /// With Reopen Tabs at Start on, the session is written as the tabs change, not only on quitting, so it
    /// survives a crash too. Closing the last window keeps it as it was: the next start opens those tabs again.
    static func changed(after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { saveNow() }
    }

    /// `prefs` and `force`: the self-test writes into a Prefs of its own that is never saved.
    static func saveNow(_ prefs: Prefs = .shared, force: Bool = false, front: DocWindow? = nil) {
        guard prefs.persist || force, !restoring else { return }
        guard prefs.restoreTabs else {
            if !prefs.openTabs.isEmpty || prefs.activeTab != 0 { prefs.openTabs = []; prefs.activeTab = 0 }
            return
        }
        guard !DocWindow.all.isEmpty else { return }
        let s = files(front: front)
        if s.files != prefs.openTabs { prefs.openTabs = s.files }
        if s.active != prefs.activeTab { prefs.activeTab = s.active }
    }

    /// What the app opens at start: the tabs of the last session when Reopen Tabs at Start is on, the tabs an update
    /// closed, then the files it was asked to open; the last of these is shown, or else the tab shown last time.
    static func startList(_ asked: [URL]) -> (urls: [URL], show: Int) {
        let prefs = Prefs.shared
        let fm = FileManager.default
        var list: [URL] = []
        func add(_ p: String) {
            let u = URL(fileURLWithPath: p).standardizedFileURL
            if fm.fileExists(atPath: u.path), !list.contains(u) { list.append(u) }
        }
        var show = 0
        if prefs.restoreTabs { prefs.openTabs.forEach(add); show = min(max(prefs.activeTab, 0), max(list.count - 1, 0)) }
        for p in prefs.takeUpdateTabs() where !list.contains(URL(fileURLWithPath: p).standardizedFileURL) {
            add(p); show = max(list.count - 1, 0)
        }
        for u in asked {
            let u = u.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let i = list.firstIndex(of: u) { show = i } else { list.append(u); show = list.count - 1 }
        }
        return (list, show)
    }
}

extension AppDelegate {
    /// A new tab in the window of `host` (the shown document when nil), next to its shown tab; a new window when
    /// there is no document window.
    @discardableResult
    func newTab(after host: DocWindow? = nil) -> DocWindow {
        guard let hostWindow = (host ?? current)?.window else { return newWindow() }
        let d = DocWindow()
        guard let w = d.window else { return d }
        // out of sight in the self-test before it joins the window, as newWindow does
        if AppDelegate.quiet { w.alphaValue = 0; w.ignoresMouseEvents = true }
        let anchor = hostWindow.tabGroup?.selectedWindow ?? hostWindow
        anchor.addTabbedWindow(w, ordered: .above)
        show(d)
        Tabs.changed()
        return d
    }

    /// Brings a document forward: its window, and its tab within the window. The self-test only selects the tab,
    /// so that nothing comes to the front of Gabriel's screen.
    func show(_ d: DocWindow) {
        guard let w = d.window else { return }
        if AppDelegate.quiet { w.tabGroup?.selectedWindow = w; return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens several files at once (a session, files dropped together): a tab each in one window, `show` in front.
    func openAll(_ urls: [URL], show index: Int, into host: DocWindow? = nil) {
        guard !urls.isEmpty else { return }
        Tabs.restoring = true
        var docs: [DocWindow] = []
        for u in urls {
            if let open = DocWindow.all.first(where: { $0.filePath == u }) { docs.append(open); continue }
            let d: DocWindow
            if docs.isEmpty, let h = host ?? current, h.isPristine { d = h }
            else { d = newTab(after: docs.last ?? host) }
            d.openFresh(u)
            docs.append(d)
        }
        Tabs.restoring = false
        if docs.indices.contains(index) { show(docs[index]) }
        Tabs.changed()
    }

    /// The next (1) or previous (-1) tab of the window of `d`, round the end (the page's Ctrl+Tab and Ctrl+Shift+Tab).
    func selectTab(from d: DocWindow, _ step: Int) {
        guard let g = d.window?.tabGroup, g.windows.count > 1,
              let i = g.windows.firstIndex(where: { $0 === (g.selectedWindow ?? d.window) }) else { return }
        let n = g.windows.count
        if let next = g.windows[(i + step + n) % n].windowController as? DocWindow { show(next) }
    }

    /// File → Reopen Closed Tab (⇧⌘T): the last tab closed whose file is still there.
    func reopenClosedTab() {
        while let u = Tabs.closed.popLast() {
            if FileManager.default.fileExists(atPath: u.path) { open(u, from: current); return }
        }
        current?.flash(L("TabNoClosed"))
    }

    func toggleRestoreTabs() {
        prefs.restoreTabs.toggle()
        Tabs.saveNow()
        current?.flash(L(prefs.restoreTabs ? "RestoreTabsOn" : "RestoreTabsOff"))
    }

    /// Window menu: the tab commands, with the actions AppKit knows, so it does not add its own items in the Mac's
    /// language (the menus follow the app's language).
    func tabMenuItems() -> [NSMenuItem] {
        func std(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        return [
            std(L("TabPrev"), #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]),
            std(L("TabNext"), #selector(NSWindow.selectNextTab(_:)), "\t", [.control]),
            std(L("TabToWindow"), #selector(NSWindow.moveTabToNewWindow(_:))),
            std(L("TabMerge"), #selector(NSWindow.mergeAllWindows(_:))),
            .separator(),
            std(L("TabShowAll"), #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
            std(L("TabBarShow"), #selector(NSWindow.toggleTabBar(_:))),
        ]
    }
}
