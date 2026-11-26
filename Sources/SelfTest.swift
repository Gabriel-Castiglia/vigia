// Vigia: --self-test, run in the real window with the real page.
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 10, 2026
// SPDX-License-Identifier: GPL-2.0-only
//
// Checks, each with a case that must fail when the thing is broken:
//   - the page starts in WebKit and loads the sample (words and contents counted);
//   - a hostile document cannot run script: event handlers, <script> and javascript: links
//     are removed from the GitHub view, and a marker set by them stays unset;
//   - the link rules (programs are only shown in the Finder, never run);
//   - saving writes back the file's own BOM and CRLF line endings, byte for byte;
//   - live reload: a save by rename over the file, a delete and re-create, and a plain write
//     each show the new text, without marking the document modified; with unsaved changes the
//     window keeps its text and asks instead;
//   - export to HTML carries the text and no scripts;
//   - reach: a document inside a Files panel folder links with ../ to every panel folder, a document
//     outside them only to its own folder, and nothing outside is ever opened;
//   - [[name]] links: found in the other panel folder, the nearest wins, missing ones are marked in the
//     GitHub view, code is left alone, and a click opens the file;
//   - a dedicated instance: its own identifier and icon, no Markdown file types, a valid signature,
//     the spec read back, and its settings seeded apart from the main app's.
// Temporary files go to a fresh folder that is removed at the end. Exit 0 when all pass.

import AppKit
import ImageIO

enum SelfTest {
    private static var failures = 0

    private static var skipped = 0

    private static func skip(_ name: String) {
        skipped += 1
        FileHandle.standardError.write(Data("skip \(name) (needs --visible)\n".utf8))
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        lastCheck = name
        FileHandle.standardError.write(Data("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": " + detail())\n".utf8))
    }

    /// Out of sight nothing may be seen: the window is transparent, but a question (a sheet) or any other window
    /// comes with its own opacity (17-nov-2026: «live.md was changed by another program» showed on Gabriel's
    /// screen at every run). Each one is made transparent at once, and what showed is a failure at the end.
    private static var shown = Set<String>()
    private static var lastCheck = "start"
    private static var parked: [(CheckedContinuation<NSApplication.ModalResponse, Never>, String)] = []

    /// A question asked out of sight waits here until the test answers it.
    static func park(_ c: CheckedContinuation<NSApplication.ModalResponse, Never>, _ text: String) { parked.append((c, text)) }
    static var asking: Bool { !parked.isEmpty }
    static func answer(_ r: NSApplication.ModalResponse) { if !parked.isEmpty { parked.removeFirst().0.resume(returning: r) } }
    /// What would have been shown out of sight: a failure at the end.
    static func note(_ what: String) { shown.insert(what + " after «\(lastCheck)»") }

    private static func keepOutOfSight() {
        func hide(_ w: NSWindow) {
            guard w.isVisible, w.alphaValue > 0 else { return }
            shown.insert((w.title.isEmpty ? String(describing: type(of: w)) : w.title) + " after «\(lastCheck)»")
            w.alphaValue = 0; w.ignoresMouseEvents = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: nil) { n in
            guard let w = n.object as? NSWindow else { return }
            (w.sheets + [w.attachedSheet].compactMap { $0 }).forEach { $0.alphaValue = 0; $0.ignoresMouseEvents = true }
        }
        let t = Timer(timeInterval: 0.005, repeats: true) { _ in NSApp.windows.forEach(hide) }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .modalPanel)
    }

    static func start() {
        if AppDelegate.quiet { keepOutOfSight() }
        let app = NSApp.delegate as! AppDelegate
        let d = app.newWindow()
        d.onReady = { Task { @MainActor in await run(d) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            FileHandle.standardError.write(Data("self-test: timed out\n".utf8)); exit(2)
        }
    }

    @MainActor
    private static func wait(_ seconds: Double, until: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await until() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await until()
    }

    /// Autosave (on by default, off on request, a pending edit saved when it is turned on), a save that
    /// keeps an edit typed after it, and the visual view's scrollbar at the window's edge.
    @MainActor
    private static func autoSaveAndScroll(_ d: DocWindow, _ tmp: URL) async {
        let auto = tmp.appendingPathComponent("auto.md")
        let disk = { (try? String(contentsOf: auto, encoding: .utf8)) ?? "" }
        try? Data("# Auto\n\nbody\n".utf8).write(to: auto)
        await d.load(auto)
        check("autosave: on by default", Prefs.shared.autoSave)
        await d.web.call("mdApp.setLocked(false); mdApp.focus(); mdApp.insertText('typed ')")
        var ok = await wait(4) { !d.model.dirty && disk().contains("typed") }
        check("autosave: the file is written after a pause and the window is clean", ok, disk())
        DocWindow.setAutoSave(false)
        await d.web.call("mdApp.focus(); mdApp.insertText('manual ')")
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        check("autosave: off leaves the file alone", d.model.dirty && !disk().contains("manual"), disk())
        DocWindow.setAutoSave(true)
        ok = await wait(3) { !d.model.dirty && disk().contains("manual") }
        check("autosave: turning it on saves what was pending", ok, disk())
        // a save takes the text and marks it saved in one step: an edit typed right after is kept for the next one
        let r = await d.web.call("""
            mdApp.focus(); mdApp.insertText('a1 '); await new Promise(r => setTimeout(r, 100));
            const s1 = mdApp.takeForSave(); mdApp.insertText('b2 '); await new Promise(r => setTimeout(r, 100));
            const s2 = mdApp.takeForSave();
            return [s1.text.includes('a1') && !s1.text.includes('b2'), s2.text.includes('a1 b2'), s2.seq > s1.seq]
            """) as? [Bool] ?? []
        check("save: an edit typed after the text was taken stays for the next save", r == [true, true, true], "\(r)")
        _ = await wait(4) { !d.model.dirty }

        // The visual view scrolls in an element as wide as the page, so its scrollbar is at the window's
        // edge; the text keeps GitHub's 980 px column. At 50 % zoom the page is wider than the column.
        await d.loadText((1 ... 200).map { "Line \($0)" }.joined(separator: "\n\n"), sample: false)
        d.web.view.pageZoom = 0.5
        try? await Task.sleep(nanoseconds: 400_000_000)
        let m = await d.web.call("""
            mdApp.setMode('visual'); await new Promise(r => setTimeout(r, 200));
            const sc = document.querySelector('.toastui-editor-ww-container .ProseMirror'), cs = getComputedStyle(sc);
            return [innerWidth, sc.getBoundingClientRect().right, sc.scrollHeight > sc.clientHeight ? 1 : 0,
                    sc.offsetWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)]
            """) as? [Double] ?? []
        d.web.view.pageZoom = Prefs.shared.zoom
        await d.web.call("mdApp.setMode(m)", ["m": Prefs.shared.mode])
        check("scroll: the visual view's scrollbar is at the window's edge, the text in its 980 px column",
              m.count == 4 && m[0] > 1100 && abs(m[1] - m[0]) < 1 && m[2] == 1 && abs(m[3] - 890) < 2, "\(m)")
        await d.loadText("", sample: false)
    }

    @MainActor
    private static func markdown(_ d: DocWindow) async -> String {
        (await d.web.call("return mdApp.getMarkdown()") as? String) ?? ""
    }

    @MainActor
    static func run(_ d: DocWindow) async {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("vigia-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Texts: both languages present and filled.
        check("strings: every text in the three languages", STRINGS.values.allSatisfy { $0.count == 3 && $0.allSatisfy { !$0.isEmpty } },
              STRINGS.filter { $0.value.count != 3 || $0.value.contains { $0.isEmpty } }.keys.sorted().joined(separator: ", "))
        check("theme: sky blue is the default colour, and an unknown one falls back to it",
              Prefs().accent == "sky" && Accent.get("nope").key == "sky")

        // The page and the sample.
        let app = NSApp.delegate as! AppDelegate
        app.openSample(in: d)
        let sampleOK = await wait(10) { d.model.isSample && d.model.words > 100 && !d.model.outline.isEmpty }
        check("sample: loaded with words and contents", sampleOK, "words \(d.model.words), headings \(d.model.outline.count)")

        // The window resizes freely: the content never holds it taller or wider than asked.
        if let w = d.window {
            w.setContentSize(NSSize(width: 800, height: 500))
            try? await Task.sleep(nanoseconds: 300_000_000)
            let small = w.contentRect(forFrameRect: w.frame).size
            w.setContentSize(NSSize(width: 1000, height: 700))
            try? await Task.sleep(nanoseconds: 300_000_000)
            let big = w.contentRect(forFrameRect: w.frame).size
            let fill = d.web.view.convert(d.web.view.bounds, to: nil)
            let content = w.contentView?.bounds ?? .zero
            check("window: the page reaches the status line, the toolbar the top", fill.minY < 40 && content.height - fill.maxY < 60,
                  "page \(fill) in \(content)")
            check("window: resizes in both directions", abs(small.height - 500) < 2 && abs(big.height - 700) < 2 &&
                  abs(small.width - 800) < 2, "\(small) \(big)")
            // At its narrowest the toolbar folds into a menu instead of pushing the content past the
            // window's edges (1.0.0 cut both sides off), and the document keeps the room, not the sidebar.
            w.setContentSize(NSSize(width: 300, height: 200))     // asks for less than allowed
            try? await Task.sleep(nanoseconds: 400_000_000)
            let narrow = d.web.view.convert(d.web.view.bounds, to: nil)
            let cw = w.contentRect(forFrameRect: w.frame).width
            check("window: never narrower than its minimum, and nothing spills past the edges",
                  cw >= DocWindow.minContent.width - 1 && narrow.minX >= 150 && narrow.maxX <= cw + 1,
                  "page \(narrow) in width \(cw)")
            w.setContentSize(NSSize(width: 1180, height: 700))
            try? await Task.sleep(nanoseconds: 400_000_000)
            let wide = d.web.view.convert(d.web.view.bounds, to: nil)
            check("window: a wider window widens the document, not the sidebar", wide.minX < 300, "page \(wide)")
            // The sidebar and the split between Files and Contents follow their dividers when dragged, and keep the
            // sizes (1.1.2 and earlier: a sidebar of 240 to 420 forgotten on every start, and no divider between the two).
            let p = Prefs.shared
            Layouts.apply(Layouts.presets[0], p); p.layoutWidths = [:]; p.outlineShare = 0.45
            try? await Task.sleep(nanoseconds: 300_000_000)
            func drag(_ from: NSPoint, _ dx: CGFloat, _ dy: CGFloat) async {
                func send(_ type: NSEvent.EventType, _ at: NSPoint) {
                    if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseUp ? 0 : 1) { w.sendEvent(e) }
                }
                send(.leftMouseDown, from)
                for i in 1...6 {
                    send(.leftMouseDragged, NSPoint(x: from.x + dx * CGFloat(i) / 6, y: from.y + dy * CGFloat(i) / 6))
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                send(.leftMouseUp, NSPoint(x: from.x + dx, y: from.y + dy))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            // A drag needs the window active (an inactive one takes the first click to come forward), which only
            // the visible self-test may do: out of sight these two are skipped (--visible runs them).
            if !AppDelegate.quiet {
                // An inactive window takes the first click to come forward and the drag never starts: activate it first.
                NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let before = d.web.view.convert(d.web.view.bounds, to: nil)
                await drag(NSPoint(x: before.minX - SplitHandle.thickness / 2, y: before.midY), 120, 0)
                let after = d.web.view.convert(d.web.view.bounds, to: nil)
                check("sidebar: its divider is dragged wider and the width is kept",
                      abs(after.minX - before.minX - 120) < 4 && abs(Layouts.width("left", p) - 380) < 4,
                      "page from \(before.minX) to \(after.minX), saved \(Layouts.width("left", p))")
                // a double click on it puts the usual width back
                let at = NSPoint(x: after.minX - SplitHandle.thickness / 2, y: after.midY)
                for n in 1...2 {
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: t, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n,
                                                      pressure: t == .leftMouseUp ? 0 : 1) { w.sendEvent(e) }
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                check("sidebar: a double click on its divider gives the usual width", abs(Layouts.width("left", p) - Prefs.defaultSidebar) < 1,
                      "width \(Layouts.width("left", p))")
                Layouts.setWidth("left", 380, p)
                try? await Task.sleep(nanoseconds: 300_000_000)
                // Files above, Contents below: the sidebar runs from the bottom of the window to the top of the page.
                let usable = Double(after.maxY - SplitHandle.thickness)
                let handleY = CGFloat((usable * 0.45).rounded()) + SplitHandle.thickness / 2
                await drag(NSPoint(x: after.minX / 2, y: handleY), 0, CGFloat(usable * 0.2))
                check("sidebar: the divider between Files and Contents is dragged and the split is kept",
                      abs(p.outlineShare - 0.65) < 0.03, "share \(p.outlineShare), usable \(usable)")
                // a pane dragged by its title to the other edge goes there (as on Windows)
                let cw = w.contentView?.bounds.width ?? 0
                // the title is a line of text: the drag starts at the first height of the header that takes it
                var tried: [CGFloat] = []
                for down in stride(from: CGFloat(10), through: 30, by: 4) where p.filesSide == "left" {
                    tried.append(down)
                    await drag(NSPoint(x: 30, y: after.maxY - down), cw - 86, 0)
                }
                check("panes: Files dragged by its title to the right edge goes to the right",
                      p.filesSide == "right" && p.outlineSide == "left", "files \(p.filesSide), contents \(p.outlineSide), tried \(tried) below the top")
                Layouts.apply(Layouts.presets[0], p)
            } else {
                skip("sidebar: its divider is dragged wider and the width is kept")
                skip("sidebar: the divider between Files and Contents is dragged and the split is kept")
                skip("sidebar: a double click on its divider gives the usual width")
                skip("panes: Files dragged by its title to the right edge goes to the right")
            }
            Layouts.setWidth("left", 700, p)
            w.setContentSize(NSSize(width: 800, height: 600))
            try? await Task.sleep(nanoseconds: 400_000_000)
            let squeezed = d.web.view.convert(d.web.view.bounds, to: nil)
            check("sidebar: a wide sidebar in a narrow window leaves the document its 380",
                  squeezed.width >= 379 && squeezed.maxX <= 801, "page \(squeezed)")
            p.layoutWidths = [:]; p.outlineShare = 0.45
            w.setContentSize(NSSize(width: 1180, height: 700))
            try? await Task.sleep(nanoseconds: 300_000_000)
            let minFrame = w.frameRect(forContentRect: NSRect(origin: .zero, size: DocWindow.minContent)).size
            let saved = AppDelegate.fitted(NSRect(x: 145, y: 177, width: 432, height: 732), min: minFrame,
                                           on: NSRect(x: 0, y: 0, width: 1470, height: 890))
            check("window: a saved frame smaller than allowed is enlarged", saved.width >= minFrame.width && saved.height >= minFrame.height,
                  "\(saved)")
        }

        // Dark theme: its stylesheets load from the app's own scheme.
        Prefs.shared.theme = "dark"
        _ = await wait(3) { Prefs.shared.dark }
        await d.applyTheme()
        let darkOK = await wait(5) {
            (await d.web.call("""
                const s = Array.from(document.styleSheets).find(x => (x.href || '').includes('github-markdown-dark'));
                try { return s ? s.cssRules.length : 0 } catch (e) { return -1 }
                """) as? Int ?? 0) > 10
        }
        check("theme: dark stylesheets load", darkOK)
        // Every kind of text in the dark visual view is light: 1.0.0 left list items and table
        // headers almost black, from Toast's own colours.
        let dim = await d.web.call("""
            const sel = ['p', 'li', 'th', 'td', 'h2'];
            const root = document.querySelector('.toastui-editor-ww-container .toastui-editor-contents');
            if (!root) return 'no visual view';
            const out = [];
            for (const t of sel) {
              const el = root.querySelector(t);
              if (!el) { out.push(t + ' missing'); continue; }
              const m = getComputedStyle(el).color.match(/[0-9.]+/g).map(Number);
              const lum = (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255;
              if (lum < 0.6) out.push(t + ' ' + getComputedStyle(el).color);
            }
            return out.join(', ');
            """) as? String ?? "no answer"
        check("theme: dark visual text is light (lists, tables, headings)", dim.isEmpty, dim)
        Prefs.shared.theme = "light"
        _ = await wait(3) { !Prefs.shared.dark }
        await d.applyTheme()

        // A Mermaid diagram draws (the library loads on demand from the app's scheme).
        await d.loadText("# D\n\n```mermaid\ngraph TD; A-->B\n```\n", sample: false)
        d.setMode("preview")
        let mermaidOK = await wait(8) {
            (await d.web.call("return document.querySelectorAll('#preview svg').length") as? Int ?? 0) > 0
        }
        check("mermaid: diagram drawn in the GitHub view", mermaidOK)
        d.setMode("visual")

        // A table with an empty <tbody> (pandoc writes one for every one-row table) opens in every view;
        // up to 1.1.1 the editor library threw on it and the page stayed blank.
        let emptyBody = "# T\n\n<table>\n<thead>\n<tr>\n<th>solo</th>\n</tr>\n</thead>\n<tbody>\n</tbody>\n</table>\n"
        var blank: [String] = []
        try? await Task.sleep(nanoseconds: 300_000_000)   // let the setMode above (run in a Task) finish first
        for (mode, sel) in [("preview", "#preview"), ("visual", ".toastui-editor-ww-container .ProseMirror"),
                            ("source", ".toastui-editor-md-container .ProseMirror")] {
            await d.web.call("mdApp.setMode(m)", ["m": mode])
            await d.loadText(emptyBody, sample: false)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let shown = await d.web.call("const e = document.querySelector(s); return !!(e && e.textContent.includes('solo')) && !mdApp.editorBroken() && mdApp.getMarkdownPreserving() === t",
                                         ["s": sel, "t": emptyBody]) as? Bool ?? false
            if !shown {
                let why = await d.web.call("const e = document.querySelector(s); return JSON.stringify({found: !!e, text: e ? e.textContent.slice(0, 60) : null, broken: mdApp.editorBroken(), same: mdApp.getMarkdownPreserving() === t, body: document.body.className})",
                                           ["s": sel, "t": emptyBody]) as? String ?? "?"
                blank.append(mode + " " + why)
            }
        }
        check("tables: an empty <tbody> opens in every view and saves unchanged", blank.isEmpty, "failed in \(blank)")

        // Files panel: opening a file opens its folders, compared with links resolved (/var is /private/var).
        let treeRoot = tmp.appendingPathComponent("tree")
        try? FileManager.default.createDirectory(at: treeRoot.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        let deep = treeRoot.appendingPathComponent("a/b/c.md")
        try? Data("# C\n".utf8).write(to: deep)
        let state = TreeState()
        let other = deep.path.hasPrefix("/private/") ? String(deep.path.dropFirst(8)) : "/private" + deep.path
        let viaTmp = URL(fileURLWithPath: other)          // the same file under its other name
        state.reveal(viaTmp, roots: [treeRoot.path + "/"])
        check("files: the open file's folders open, named as the tree names them",
              state.open == [treeRoot.path + "/a", treeRoot.path + "/a/b"], "\(state.open.sorted())")

        // Folders of the panel: order, pinned ones first, moving, closing, start-up choices and colours (as on Windows).
        let p = Prefs.shared
        let saved = (p.folders, p.pinned, p.folderSort, p.startupFolders, p.folderColors, p.folderColorMap)
        let fa = tmp.appendingPathComponent("f-beta").path, fb = tmp.appendingPathComponent("f-alfa").path, fc = tmp.appendingPathComponent("f-gamma").path
        p.folders = [fa, fb, fc]; p.pinned = [fc]; p.folderSort = "opened"; p.folderColorMap = [:]
        let opened = p.orderedFolders
        p.folderSort = "az"; let az = p.orderedFolders
        p.folderSort = "za"; let za = p.orderedFolders
        check("folders: pinned first, then the chosen order", opened == [fc, fa, fb] && az == [fc, fb, fa] && za == [fc, fa, fb],
              "opened \(opened.map { ($0 as NSString).lastPathComponent }), az \(az.map { ($0 as NSString).lastPathComponent })")
        p.moveFolder(fa, by: 1)
        let moved = p.folders, sortAfterMove = p.folderSort
        p.folderColorMap[fc] = 120
        p.closeFolder(fc)
        check("folders: moving swaps with the neighbour and returns to order opened; closing unpins and forgets the colour",
              moved == [fb, fa, fc] && sortAfterMove == "opened" && p.folders == [fb, fa] && p.pinned.isEmpty && p.folderColorMap.isEmpty,
              "moved \(moved), folders \(p.folders), pinned \(p.pinned)")
        p.folders = [fa, fb]; p.pinned = [fc]
        p.startupFolders = "restore"; p.applyStartupFolders(); let restore = p.folders
        p.startupFolders = "pinned"; p.applyStartupFolders(); let onlyPinned = p.folders
        p.startupFolders = "clean"; p.applyStartupFolders(); let clean = p.folders
        check("folders: at start, the last session plus the pinned, only the pinned, or none",
              restore == [fa, fb, fc] && onlyPinned == [fc] && clean.isEmpty && p.pinned == [fc], "\(restore) \(onlyPinned) \(clean)")
        p.folders = [fa, fb]
        p.folderColors = "theme"; let themeTint = p.folderTint(fa) != nil && p.folderTint(fb) != nil
        p.folderColors = "none"; let noneTint = p.folderTint(fa) == nil
        check("folders: coloured in the theme tones, none when colours are off", themeTint && noneTint)
        (p.folders, p.pinned, p.folderSort, p.startupFolders, p.folderColors, p.folderColorMap) = saved

        // Convert to TXT: a .txt next to the file, the Markdown untouched, an existing .txt never overwritten.
        let mdFile = tmp.appendingPathComponent("conv.md")
        let mdText = "# Title\n\n- one\n- **two**\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        try? Data(mdText.utf8).write(to: mdFile)
        let txt1 = tmp.appendingPathComponent("conv.txt"), txt2 = tmp.appendingPathComponent("conv (2).txt")
        (NSApp.delegate as? AppDelegate)?.convertToText(mdFile, from: d)
        _ = await wait(5) { FileManager.default.fileExists(atPath: txt1.path) }
        (NSApp.delegate as? AppDelegate)?.convertToText(mdFile, from: d)
        _ = await wait(5) { FileManager.default.fileExists(atPath: txt2.path) }
        let plain = (try? String(contentsOf: txt1, encoding: .utf8)) ?? ""
        let expected = "Title\n=====\n\n• one\n• two\n\na  b\n-  -\n1  2\n"
        check("txt: converted next to the file, a second time as (2), the Markdown untouched",
              plain == expected && FileManager.default.fileExists(atPath: txt2.path)
                  && (try? String(contentsOf: mdFile, encoding: .utf8)) == mdText, plain.debugDescription)
        d.setMode("visual")

        // A hostile document.
        let hostile = """
            # Hostile

            <img src="nothing.png" onerror="window.__pwned = 1">

            <script>window.__pwned = 2</script>

            <a href="javascript:window.__pwned = 3">click</a> <iframe src="https://example.com"></iframe>

            <svg><a href="javascript:window.__pwned=4"><text>x</text></a></svg>
            """
        let hostileFile = tmp.appendingPathComponent("hostile.md")
        try? Data(hostile.utf8).write(to: hostileFile)
        await d.load(hostileFile)
        d.setMode("preview")
        try? await Task.sleep(nanoseconds: 800_000_000)
        let html = (await d.web.call("return document.getElementById('preview').innerHTML") as? String) ?? ""
        let pwned = await d.web.call("return window.__pwned === undefined ? 0 : window.__pwned") as? Int ?? -1
        check("hostile: no script ran", pwned == 0, "marker \(pwned)")
        check("hostile: handlers, scripts, frames and javascript: links removed",
              !html.contains("onerror") && !html.lowercased().contains("<script") && !html.contains("javascript:") &&
                  !html.lowercased().contains("<iframe") && html.contains("Hostile"), String(html.prefix(300)))
        // Clicking every link in the view must not run anything either.
        await d.web.call("document.querySelectorAll('#preview a').forEach(a => a.click())")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterClick = await d.web.call("return window.__pwned === undefined ? 0 : window.__pwned") as? Int ?? -1
        check("hostile: clicked links run nothing", afterClick == 0, "marker \(afterClick)")
        // what they asked outside Vigia was held, not done: no Finder window is left open by the self-test
        check("hostile: links to the Finder or other apps are held during the self-test",
              !DocWindow.heldOutside.isEmpty && DocWindow.heldOutside.allSatisfy { if case .external = $0 { return true }; if case .reveal = $0 { return true }; if case .openViewer = $0 { return true }; return false },
              "\(DocWindow.heldOutside)")
        d.setMode("visual")

        // Link rules.
        for (name, content) in [("run.command", "#!/bin/sh\n"), ("note.md", "# n\n"), ("pic.png", "x"), ("app.sh", "#!/bin/sh\n")] {
            try? Data(content.utf8).write(to: tmp.appendingPathComponent(name))
        }
        let base = Schemes.docBase(for: tmp)
        let rules: [(String, LinkAction)] = [
            (base + "run.command", .reveal(tmp.appendingPathComponent("run.command").standardizedFileURL)),
            (base + "app.sh", .reveal(tmp.appendingPathComponent("app.sh").standardizedFileURL)),
            (base + "note.md", .openDocument(tmp.appendingPathComponent("note.md").standardizedFileURL)),
            (base + "pic.png", .openViewer(tmp.appendingPathComponent("pic.png").standardizedFileURL)),
            (base + "../../etc/hosts", .ignore),
            (base + "missing.md", .ignore),
            (Schemes.docBase + "etc/hosts", .ignore),
            ("file://" + tmp.appendingPathComponent("run.command").path, .ignore),
            ("javascript:alert(1)", .ignore),
            ("x-apple.systempreferences:", .ignore),
            ("https://example.com/", .external(URL(string: "https://example.com/")!)),
            ("mailto:?subject=hello", .external(URL(string: "mailto:?subject=hello")!)),
        ]
        var badRule = ""
        for (href, want) in rules {
            let got = LinkPolicy.decide(href, reach: [tmp])
            if got != want {
                badRule = "\(href) -> \(got)"
            }
        }
        // ../../etc/hosts leaves the document folder: it may at most be revealed, never opened or run.
        let escape = LinkPolicy.decide(base + "../../../../../../etc/hosts", reach: [tmp])
        check("links: programs only shown in the Finder, nothing else opens", badRule.isEmpty, badRule)
        check("links: a path out of the folder is never opened", escape == .ignore || { if case .reveal = escape { return true }; return false }(),
              "\(escape)")

        // Save keeps BOM and CRLF.
        let crlfFile = tmp.appendingPathComponent("crlf.md")
        let original = Data([0xEF, 0xBB, 0xBF] + Array("# Title\r\n\r\nSome *text* with __bold__.\r\n\r\n- one\r\n- two\r\n".utf8))
        try? original.write(to: crlfFile)
        await d.load(crlfFile)
        await d.save(as: false)
        let back = (try? Data(contentsOf: crlfFile)) ?? Data()
        check("save: BOM and CRLF written back byte for byte", back == original,
              String(decoding: back.prefix(80), as: UTF8.self))

        // Live reload.
        let live = tmp.appendingPathComponent("live.md")
        try? Data("# One\n\nfirst\n".utf8).write(to: live)
        await d.load(live)
        let side = tmp.appendingPathComponent(".live.md.tmp")
        try? Data("# Two\n\nsecond\n".utf8).write(to: side)
        _ = try? fm.replaceItemAt(live, withItemAt: side)
        var ok = await wait(3) { await markdown(d).contains("Two") }
        let md1 = await markdown(d)
        check("live reload: save by replacing the file", ok && !d.model.dirty, md1)
        try? fm.removeItem(at: live)
        try? await Task.sleep(nanoseconds: 150_000_000)
        try? Data("# Three\n\nthird\n".utf8).write(to: live)
        ok = await wait(3) { await markdown(d).contains("Three") }
        let md2 = await markdown(d)
        check("live reload: delete and create again", ok && !d.model.dirty, md2)
        if let h = try? FileHandle(forWritingTo: live) { h.seekToEndOfFile(); h.write(Data("\nfourth line\n".utf8)); try? h.close() }
        ok = await wait(3) { await markdown(d).contains("fourth line") }
        let md3 = await markdown(d)
        check("live reload: plain write", ok && !d.model.dirty, md3)
        let marked = (await d.web.call("return mdApp.changesMarked()") as? Int) ?? 0
        check("live reload: what another program changed is marked in green", marked > 0, "\(marked) blocks")
        // Several quick saves: the last one is what shows.
        for i in 1 ... 6 { try? Data("# Burst \(i)\n".utf8).write(to: live); try? await Task.sleep(nanoseconds: 20_000_000) }
        ok = await wait(3) { await markdown(d).contains("Burst 6") }
        let md4 = await markdown(d)
        check("live reload: a burst of saves ends with the last one", ok, md4)
        // With unsaved changes the window keeps its text (a question is asked instead).
        await d.web.call("mdApp.setLocked(false); mdApp.focus(); mdApp.insertText('local edit ')")
        _ = await wait(2) { d.model.dirty }
        try? Data("# Outside\n".utf8).write(to: live)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let kept = await markdown(d)
        check("live reload: unsaved changes are not overwritten", d.model.dirty && kept.contains("local edit") && !kept.contains("Outside"), kept)
        // autosave (on) waits for the question: the other program's text stays on disk
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        let outside = (try? String(contentsOf: live, encoding: .utf8)) ?? ""
        check("autosave: never writes over another program's change", outside == "# Outside\n", outside)
        if AppDelegate.quiet {
            check("live reload: with unsaved changes the window asks", asking)
            answer(.alertSecondButtonReturn)
        } else {
            d.window?.attachedSheet.map { d.window?.endSheet($0, returnCode: .alertSecondButtonReturn) }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        d.model.dirty = false

        await autoSaveAndScroll(d, tmp)
        // As on Windows: folders opened lately in Open recent, Copy info in About, the sample in the menu.
        let xapp = NSApp.delegate as! AppDelegate, xp = Prefs.shared
        let savedFolders = xp.folders, savedRecent = xp.recentFolders
        xapp.addFolder(tmp)
        check("recent: an opened folder is first in the recent folders", xp.recentFolders.first == tmp.path, "\(xp.recentFolders)")
        xp.folders = savedFolders; xp.recentFolders = savedRecent
        check("about: Copy info gives the version and the system",
              AboutView.info.contains("Vigía \(appVersion)") && AboutView.info.contains("macOS "), AboutView.info)
        xapp.buildMenus()
        let recentMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.title == L("Recent") } ?? false })?
            .submenu?.items.first(where: { $0.title == L("Recent") })?.submenu
        check("recent: the sample is in Open recent until hidden",
              recentMenu?.items.first?.title == L("SampleItem") && !xp.sampleHidden, "\(recentMenu?.items.map(\.title) ?? [])")
        await reachAndWiki(d, tmp)
        await picturesFilesLayouts(d, tmp)
        await searchAndPicker(d, tmp)
        await dedicated(tmp)
        await tabsAndJapanese(d, tmp)
        await spellPreviewSave(d, tmp)
        await newAndDelete(d, tmp)

        // Export.
        await d.loadText("# Exported\n\nA paragraph with `code`.\n\n<script>alert(1)</script>\n", sample: false)
        let out = tmp.appendingPathComponent("out.html")
        d.exportTo(out)
        ok = await wait(5) { fm.fileExists(atPath: out.path) }
        let exported = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        check("export: HTML with the text and no scripts", ok && exported.contains("Exported") && exported.contains("markdown-body")
              && !exported.lowercased().contains("<script"), String(exported.suffix(200)))

        if AppDelegate.quiet {
            while let (c, text) = parked.first { parked.removeFirst(); note("a question left unanswered: \(text)"); c.resume(returning: .cancel) }
            check("out of sight: no window or question was shown", shown.isEmpty, shown.sorted().joined(separator: ", "))
        }
        let skips = skipped > 0 ? " (\(skipped) skipped: they need --visible)" : ""
        FileHandle.standardError.write(Data((failures == 0 ? "self-test: all passed\(skips)\n" : "self-test: \(failures) failed\(skips)\n").utf8))
        try? fm.removeItem(at: tmp)
        exit(failures == 0 ? 0 : 1)
    }

    // 3.2.0, as on Windows. Tabs: a file opens in a new tab next to the shown one, or in the shown tab when nobody
    // typed in it; a file already open shows its tab; the tabs of a session and the files asked for, in order;
    // the closed tab comes back; an untitled tab with changes asks before closing; the tab commands of the Window
    // menu are ours, once each. Expand all. The interface and the editor in Japanese.
    @MainActor
    private static func tabsAndJapanese(_ d: DocWindow, _ tmp: URL) async {
        let fm = FileManager.default
        let app = NSApp.delegate as! AppDelegate
        let dir = tmp.appendingPathComponent("tabs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ["one", "two", "three"].map { n -> URL in
            let u = dir.appendingPathComponent(n + ".md").standardizedFileURL
            try? Data("# \(n)\n\nText of \(n).\n".utf8).write(to: u)
            return u
        }
        // a window of its own for the tabs, so that closing them never closes d
        let host = app.newWindow()
        _ = await wait(10) { host.model.ready }
        await host.loadText("typed here", sample: false)
        host.model.dirty = true
        let before = DocWindow.all.count
        app.open(files[0], from: host)
        app.open(files[1], from: host)
        let loaded = await wait(10) { files[0 ... 1].allSatisfy { f in DocWindow.all.contains { $0.model.path == f } } }
        let group = host.window?.tabbedWindows?.compactMap { $0.windowController as? DocWindow } ?? []
        check("tabs: files open in new tabs of the same window, each next to the shown one",
              loaded && DocWindow.all.count == before + 2 && group.map { $0.filePath } == [nil, files[0], files[1]],
              "\(DocWindow.all.count - before) new, group \(group.map { $0.filePath?.lastPathComponent ?? "untitled" })")
        app.open(files[0], from: host)
        check("tabs: a file already open shows its tab, no new one",
              DocWindow.all.count == before + 2 && host.window?.tabGroup?.selectedWindow?.windowController as? DocWindow === group.first { $0.filePath == files[0] })
        let blank = app.newTab(after: host)
        _ = await wait(10) { blank.model.ready }
        app.open(files[2], from: blank)
        let intoBlank = await wait(10) { blank.model.path == files[2] }
        check("tabs: an untitled tab nobody typed in takes the file", intoBlank && DocWindow.all.count == before + 3, blank.filePath?.path ?? "-")
        let order = Tabs.files().files
        check("tabs: the session lists the files in the order of the tabs, untitled left out",
              Array(order.suffix(3)) == [files[0].path, files[1].path, files[2].path] || order.contains(files[2].path) && order.firstIndex(of: files[0].path)! < order.firstIndex(of: files[1].path)!,
              order.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " "))
        // the page's own keys: Ctrl+Tab goes to the next tab of the window
        let shownBefore = host.window?.tabGroup?.selectedWindow
        (shownBefore?.windowController as? DocWindow)?.command("nexttab")
        check("tabs: the next-tab command shows another tab", host.window?.tabGroup?.selectedWindow !== shownBefore)
        // closed and reopened
        if let two = DocWindow.all.first(where: { $0.model.path == files[1] }) { two.window?.performClose(nil) }
        _ = await wait(3) { !DocWindow.all.contains { $0.model.path == files[1] } }
        check("tabs: a closed tab is remembered", Tabs.closed.last == files[1], Tabs.closed.last?.path ?? "-")
        app.reopenClosedTab()
        let back = await wait(10) { DocWindow.all.contains { $0.model.path == files[1] } }
        check("tabs: Reopen Closed Tab brings it back", back)
        // an untitled tab with changes asks before it closes; Cancel keeps it
        let typed = app.newTab(after: host)
        _ = await wait(10) { typed.model.ready }
        typed.model.dirty = true
        typed.window?.performClose(nil)
        let asked = await wait(3) { SelfTest.asking }
        SelfTest.answer(.alertSecondButtonReturn)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("tabs: closing a tab with changes asks, and Cancel keeps it", asked && DocWindow.all.contains { $0 === typed })
        typed.model.dirty = false
        // the session at start: the saved tabs that still exist, then the files asked for, the last one shown
        let p = Prefs.shared
        let saved = (p.restoreTabs, p.openTabs, p.activeTab)
        p.restoreTabs = true
        p.openTabs = [files[0].path, dir.appendingPathComponent("gone.md").path, files[1].path]
        p.activeTab = 1
        let s1 = Tabs.startList([]), s2 = Tabs.startList([files[2], files[0]])
        check("tabs: at start, the saved tabs that still exist, the shown one kept",
              s1.urls == [files[0], files[1]] && s1.show == 1, "\(s1.urls.map(\.lastPathComponent)) \(s1.show)")
        check("tabs: files asked for at start are added, the last one shown",
              s2.urls == [files[0], files[1], files[2]] && s2.show == 0, "\(s2.urls.map(\.lastPathComponent)) \(s2.show)")
        p.restoreTabs = false
        check("tabs: off, nothing is reopened", Tabs.startList([]).urls.isEmpty)
        // what is written as the tabs change: the files in order and the shown one; off, nothing
        let own = Prefs()
        own.persist = false
        own.restoreTabs = true
        // the window in front is the one with the tabs; its shown tab, "one", is the session's shown one
        if let one = DocWindow.all.first(where: { $0.model.path == files[0] }) { app.show(one) }
        Tabs.saveNow(own, force: true, front: host)
        let wrote = own.openTabs.filter { $0.hasPrefix(dir.path) }
        check("tabs: the session written as the tabs change, with the shown tab",
              wrote.count == 3 && own.openTabs.indices.contains(own.activeTab) && own.openTabs[own.activeTab] == files[0].path,
              "\(own.openTabs.map { URL(fileURLWithPath: $0).lastPathComponent }) shown \(own.activeTab)")
        own.restoreTabs = false
        Tabs.saveNow(own, force: true)
        check("tabs: off, the session is forgotten", own.openTabs.isEmpty && own.activeTab == 0)
        (p.restoreTabs, p.openTabs, p.activeTab) = saved
        // the Window menu: our tab commands, each once (AppKit adds its own, in the Mac's language, when none is there)
        let saveLang = p.lang
        p.lang = "ja"
        app.buildMenus()
        NSApp.mainMenu?.items.forEach { $0.submenu?.update() }
        func all(_ m: NSMenu?) -> [NSMenuItem] { (m?.items ?? []).flatMap { [$0] + all($0.submenu) } }
        let items = all(NSApp.mainMenu)
        let actions: [Selector] = [#selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.selectPreviousTab(_:)),
                                   #selector(NSWindow.moveTabToNewWindow(_:)), #selector(NSWindow.mergeAllWindows(_:)),
                                   #selector(NSWindow.toggleTabOverview(_:)), #selector(NSWindow.toggleTabBar(_:))]
        let counts = actions.map { a in items.filter { $0.action == a }.count }
        let bar = items.first { $0.action == #selector(NSWindow.toggleTabBar(_:)) }?.title ?? "-"
        check("tabs: the Window menu has each tab command once", counts == [1, 1, 1, 1, 1, 1], "\(counts)")
        check("japanese: the menus in Japanese, the tab bar item too",
              items.contains { $0.title == "ファイル" } && [L("TabBarShow"), L("TabBarHide")].contains(bar), bar)
        // the editor in Japanese: TOAST UI's own texts, and the words of a text without spaces
        await d.applyLanguage()
        await d.loadText("日本語の文章を数えます。もう一つの文。", sample: false)
        // TOAST UI's own texts show in the menu of a table cell
        let keepMode = Prefs.shared.mode
        d.setMode("visual")
        await d.loadText("| a | b |\n|---|---|\n| 1 | 2 |\n", sample: false)
        _ = await wait(3) { ((await d.web.call("return document.querySelectorAll('.toastui-editor-ww-container td').length") as? Int) ?? 0) > 0 }
        let label = (await d.web.call("""
            const td = document.querySelector('.toastui-editor-ww-container td');
            const r = td.getBoundingClientRect();
            td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 2, clientY: r.top + 2 }));
            await new Promise(f => setTimeout(f, 100));
            const m = document.querySelector('.toastui-editor-context-menu');
            const t = m ? m.textContent : '';
            document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
            return t;
            """) as? String) ?? ""
        d.setMode(keepMode)
        let words = (await d.web.call("return mdApp.words()") as? Int) ?? 0
        check("japanese: the editor's own texts (the menu of a table cell)", label.range(of: "[\\u3040-\\u30ff\\u4e00-\\u9fff]", options: .regularExpression) != nil, label)
        check("japanese: a text without spaces counts its words", words > 3, "\(words)")
        check("japanese: colours and folder colours", Accent.get("sky").name == "スカイブルー" && Prefs.pick("a", "b", "c") == "c")
        p.lang = saveLang
        app.buildMenus()
        await d.applyLanguage()
        check("japanese: a language it does not know is English", Prefs.language("xx") == "en" && Prefs.language("ja") == "ja")
        // Expand all: every folder of the tree, every level, as the tree names them
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        for sub in ["a/b", "a/c", "d"] { try? fm.createDirectory(at: tree.appendingPathComponent(sub), withIntermediateDirectories: true) }
        for f in ["a/b/x.md", "a/c/y.md", "d/z.md", "a/w.md"] { try? Data("# x\n".utf8).write(to: tree.appendingPathComponent(f)) }
        let found = TreeState.allFolders([tree.path])
        let want: Set<String> = Set(["a", "a/b", "a/c", "d"].map { TreeState.canonical(tree.appendingPathComponent($0).path) })
        check("files: Expand all opens every folder, every level", Set(found.ids.map(TreeState.canonical)) == want && !found.capped,
              found.ids.sorted().joined(separator: " "))
        // the close button of a window with tabs (measured: how many of its tabs it closes)
        let groupNow = host.window?.tabbedWindows?.count ?? 1
        for x in DocWindow.all where x !== d { x.model.dirty = false }
        (host.window?.tabGroup?.selectedWindow ?? host.window)?.standardWindowButton(.closeButton)?.performClick(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let left = DocWindow.all.filter { $0 !== d }.count
        FileHandle.standardError.write(Data("info tabs: the close button of a window with \(groupNow) tabs left \(left) of them\n".utf8))
        for x in DocWindow.all where x !== d { x.close() }
        _ = await wait(3) { DocWindow.all.count == 1 }
    }

    // 3.3.1 (Windows 3.2.1 and 3.3.0 on the Mac): spell check in several languages with the voseo, the preview tab,
    // undo after opening, tables whose cells end in inline HTML, the rare highlight languages, and a save that keeps
    // links and extended attributes.
    @MainActor
    private static func spellPreviewSave(_ d: DocWindow, _ tmp: URL) async {
        let fm = FileManager.default
        let app = NSApp.delegate as! AppDelegate
        let prefs = Prefs.shared
        let dir = tmp.appendingPathComponent("v331", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String) -> URL {
            let u = dir.appendingPathComponent(name).standardizedFileURL
            try? Data(text.utf8).write(to: u)
            return u
        }

        // spell check, without the page
        let langs = ["en", "es", "es-UY", "ja"]
        let bad = await Spell.misspelled(["hello", "mundo", "canción", "xqzwrt", "日本語", "tenés", "mirá", "decíselo", "don’t"], langs, own: [])
        check("spell: several languages at once, Japanese never marked, the voseo known", bad == ["xqzwrt"], bad.joined(separator: ","))
        let badEs = await Spell.misspelled(["tenés", "mirá"], ["es"], own: [])
        check("spell: without es-UY the Mac's Spanish marks the voseo", badEs.count == 2, badEs.joined(separator: ","))
        check("spell: suggestions", Spell.suggest("helo", langs).contains("hello"), Spell.suggest("helo", langs).joined(separator: ","))
        check("spell: every language of the Mac can be chosen", Spell.available(chosen: langs).count > 10 && Spell.available(chosen: langs).prefix(4) == ArraySlice(langs))

        // the page marks what the app reports; Ignore and Add to dictionary unmark it
        let host = app.newWindow()
        _ = await wait(10) { host.model.ready }
        let wasLangs = prefs.spellLangs, wasSpell = prefs.spell
        prefs.spellLangs = langs
        Spell.setOn(true)
        let spf = file("spell.md", "# Spell\n\nhello mundo tenés xqzwrt vbnmqp\n")
        host.openFresh(spf)
        let js = "return [...new Set(Array.from(document.querySelectorAll('.gm-misspelled')).map(e => e.dataset.word))].sort().join(',')"
        func marked() async -> String { (await host.web.call(js) as? String) ?? "?" }
        var ok = await wait(8) { await marked() == "vbnmqp,xqzwrt" }
        var m = await marked()
        check("spell: the page marks the unknown words only", ok, m)
        Spell.accept("xqzwrt", permanent: false)
        ok = await wait(4) { await marked() == "vbnmqp" }
        m = await marked()
        check("spell: Ignore unmarks the word", ok && Spell.session.contains("xqzwrt"), m)
        Spell.accept("vbnmqp", permanent: true)
        ok = await wait(4) { await marked() == "" }
        m = await marked()
        check("spell: Add to dictionary unmarks it and keeps it", ok && prefs.spellWords.contains("vbnmqp"), m)
        Spell.setOn(false)
        ok = await wait(3) { await marked() == "" }
        let nativeOff = (await host.web.call("return Array.from(document.querySelectorAll('.ProseMirror')).every(e => e.getAttribute('spellcheck') === 'false')") as? Bool) == true
        check("spell: off, nothing is marked, and the browser's own checker stays off", ok && nativeOff)
        prefs.spellWords.removeAll { $0 == "vbnmqp" }; Spell.session.remove("xqzwrt")
        prefs.spellLangs = wasLangs; Spell.setOn(wasSpell)

        // undo right after opening must not empty the document
        let und = file("undo.md", "# Undo\n\nkept text\n")
        host.openFresh(und)
        _ = await wait(8) { guard host.model.path == und else { return false }; return (await markdown(host)).contains("kept text") }
        host.exec("undo")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterUndo = await markdown(host)
        check("undo: right after opening a file it takes nothing back", afterUndo.contains("kept text") && !host.model.dirty, afterUndo)

        // a table whose cells end in inline HTML shows in the visual view
        let tab = file("table.md", "# T\n\n| a | b |\n|---|---|\n| x <sub>L-02</sub> | y |\n| z <sub>L-03</sub> | w |\n")
        host.setMode("visual")
        host.openFresh(tab)
        ok = await wait(8) { guard host.model.path == tab else { return false }; return (await markdown(host)).contains("L-03") }
        let tableText = await markdown(host)
        check("tables: cells that end in inline HTML show in the visual view", ok && host.model.words > 3, tableText)

        // a code block in a language the page does not carry: highlighted once the full set loads
        let rare = file("rare.md", "# R\n\n```fortran\nprogram hello\n  print *, 'hi'\nend program hello\n```\n")
        host.setMode("preview")
        host.openFresh(rare)
        ok = await wait(8) { (await host.web.call("return !!document.querySelector('#preview code.language-fortran span[class^=hljs-]')") as? Bool) == true }
        check("code: a rare language is highlighted (lib/hljs-all.js loads)", ok)
        host.setMode("visual")

        // how long a new tab takes until its page is ready (Windows 3.3.0 starts one ahead: 0.8 to 1.2 s there)
        var times: [Int] = []
        for _ in 0 ..< 3 {
            let t0 = Date()
            let nt = app.newTab(after: host)
            _ = await wait(10) { nt.model.ready }
            times.append(Int(Date().timeIntervalSince(t0) * 1000))
            nt.close()
        }
        FileHandle.standardError.write(Data("info tabs: a new tab is ready in \(times.map { "\($0) ms" }.joined(separator: ", "))\n".utf8))

        // the preview tab: a click in the panel reuses the passing tab; typing keeps it
        let p1 = file("p1.md", "# P1\n"), p2 = file("p2.md", "# P2\n"), p3 = file("p3.md", "# P3\n")
        let wasPreview = prefs.previewTab
        prefs.previewTab = true
        await host.loadText("typed here", sample: false); host.model.dirty = true
        app.open(p1, from: host, preview: true)
        _ = await wait(8) { DocWindow.all.contains { $0.model.path == p1 } }
        let t1 = DocWindow.all.first { $0.model.path == p1 }
        check("preview tab: a click in the panel opens a passing tab", t1?.preview == true)
        let count = DocWindow.all.count
        app.open(p2, from: host, preview: true)
        ok = await wait(8) { t1?.model.path == p2 }
        check("preview tab: the next click reuses it", ok && DocWindow.all.count == count && t1?.preview == true,
              "\(DocWindow.all.count - count) more, \(t1?.model.path?.lastPathComponent ?? "-")")
        await t1?.web.call("mdApp.setLocked(false); mdApp.focus(); mdApp.insertText('typed ')")
        _ = await wait(3) { t1?.model.dirty == true }
        check("preview tab: typing keeps it", t1?.preview == false)
        app.open(p3, from: host, preview: true)
        ok = await wait(8) { DocWindow.all.contains { $0.model.path == p3 } }
        check("preview tab: a kept tab is not reused", ok && t1?.model.path == p2 && DocWindow.all.count == count + 1)
        prefs.previewTab = wasPreview
        for x in DocWindow.all where x !== d { x.model.dirty = false; x.close() }
        _ = await wait(3) { DocWindow.all.count == 1 }

        // a save keeps a link a link, and the extended attributes of the file
        let real = file("real.md", "# Real\n"), link = dir.appendingPathComponent("link.md")
        try? fm.createSymbolicLink(at: link, withDestinationURL: real)
        _ = real.withUnsafeFileSystemRepresentation { p in setxattr(p!, "com.vigia.test", "1", 1, 0, 0) }
        try? AtomicFile.write(Data("# Saved through the link\n".utf8), to: link)
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
        let text = (try? String(contentsOf: real, encoding: .utf8)) ?? ""
        let attr = real.withUnsafeFileSystemRepresentation { p in getxattr(p!, "com.vigia.test", nil, 0, 0, 0) }
        check("save: through a link the file is written and the link stays", isLink && text.contains("through the link"), text)
        check("save: the extended attributes stay", attr == 1, "\(attr)")
        let ro = file("ro.md", "# RO\n")
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ro.path)
        var refused = false
        do { try AtomicFile.write(Data("x".utf8), to: ro) } catch { refused = true }
        check("save: a read-only file is refused, not replaced", refused && ((try? String(contentsOf: ro, encoding: .utf8)) ?? "") == "# RO\n")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ro.path)
        let left = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter(AtomicFile.isTemporary)
        check("save: no temporary file is left", left.isEmpty, left.joined(separator: " "))
    }

    // 3.5.2 (Windows 3.4.0 to 3.5.1 on the Mac): new files and folders, and deleting, from the Files panel.
    @MainActor
    private static func newAndDelete(_ d: DocWindow, _ tmp: URL) async {
        let fm = FileManager.default
        let ops = FileOps.shared, prefs = Prefs.shared
        let dir = tmp.appendingPathComponent("v352", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = FileOps.freeName("New document", ext: ".md", in: dir)
        try? Data("x".utf8).write(to: dir.appendingPathComponent(first))
        let second = FileOps.freeName("New document", ext: ".md", in: dir)
        check("new: a free name is offered", first == "New document.md" && second == "New document 2.md", "\(first) / \(second)")
        let made = try? FileOps.createItem(in: dir, name: "Notas", folder: false)
        let text = made.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check("new: a file without a Markdown extension gets .md and its name as a heading", made?.lastPathComponent == "Notas.md" && text == "# Notas\n", text)
        var refused = 0
        for n in ["Notas.md", "a/b", ".."] { if (try? FileOps.createItem(in: dir, name: n, folder: false)) == nil { refused += 1 } }
        check("new: a name taken, with a slash or .. is refused, nothing written over", refused == 3 && (try? String(contentsOf: dir.appendingPathComponent("Notas.md"), encoding: .utf8)) == "# Notas\n")
        let folder = try? FileOps.createItem(in: dir, name: "Sub", folder: true)
        var isDir: ObjCBool = false
        check("new: a folder", folder.map { fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue } == true)
        check("new: the folder asked for is the one used", ops.targetFolder(dir, doc: d).standardizedFileURL == dir.standardizedFileURL)
        // deleting a folder closes the tab of a file inside it and takes it out of the lists
        let inside = dir.appendingPathComponent("Sub/dentro.md")
        try? Data("# Dentro\n".utf8).write(to: inside)
        let app = NSApp.delegate as! AppDelegate
        let host = app.newWindow()
        _ = await wait(10) { host.model.ready }
        host.openFresh(inside)
        _ = await wait(8) { host.model.path == inside.standardizedFileURL }
        let wasFav = prefs.favorites, wasRecent = prefs.recent
        prefs.favorites.append(inside.path); prefs.recent.insert(inside.path, at: 0)
        var ok = true
        do { try ops.deleteWithoutAsking(dir.appendingPathComponent("Sub"), permanently: true) } catch { ok = false }
        _ = await wait(3) { !DocWindow.all.contains { $0 === host } }
        check("delete: the folder goes, its tab closes, it leaves Favourites and Open recent",
              ok && !fm.fileExists(atPath: dir.appendingPathComponent("Sub").path) && !DocWindow.all.contains { $0 === host }
              && !prefs.favorites.contains(inside.path) && !prefs.recent.contains(inside.path))
        prefs.favorites = wasFav; prefs.recent = wasRecent
        var gone = false
        do { try ops.deleteWithoutAsking(dir.appendingPathComponent("no such file"), permanently: true) } catch { gone = true }
        check("delete: a file that is not there is reported", gone)
    }

    // Two panel folders, as the wiki of indices and memories: indices/home.md and memories/topic/a.md.
    @MainActor
    private static func reachAndWiki(_ d: DocWindow, _ tmp: URL) async {
        let fm = FileManager.default
        let idx = tmp.appendingPathComponent("indices", isDirectory: true)
        let mem = tmp.appendingPathComponent("memories/topic", isDirectory: true)
        let other = tmp.appendingPathComponent("elsewhere", isDirectory: true)
        for f in [idx, mem, other, tmp.appendingPathComponent("memories/far", isDirectory: true)] {
            try? fm.createDirectory(at: f, withIntermediateDirectories: true)
        }
        let a = mem.appendingPathComponent("note-a.md"), far = tmp.appendingPathComponent("memories/far/note-a.md")
        let home = idx.appendingPathComponent("home.md"), lone = other.appendingPathComponent("lone.md")
        try? Data("# A\n\nBack to [[home|the start]].\n".utf8).write(to: a)
        try? Data("# far A\n".utf8).write(to: far)
        try? Data("# Home\n\n[[note-a]] · [[Note-A.md|same]] · [[gone]] · `[[in code]]` · [rel](../memories/topic/note-a.md)\n".utf8).write(to: home)
        try? Data("# Lone\n".utf8).write(to: lone)
        let panel = [idx.path, tmp.appendingPathComponent("memories").path]

        let inReach = Wiki.reach(docFolder: idx, panel: panel)
        let resolved = URL(string: "../memories/topic/note-a.md", relativeTo: URL(string: Schemes.docBase(for: idx)))?.absoluteString ?? ""
        check("reach: ../ from a panel folder opens a file of another panel folder",
              LinkPolicy.decide(resolved, reach: inReach) == .openDocument(a.standardizedFileURL), "\(resolved) -> \(LinkPolicy.decide(resolved, reach: inReach))")
        let outReach = Wiki.reach(docFolder: other, panel: panel)
        check("reach: a document outside the panel folders reaches only its own folder",
              outReach == [other.standardizedFileURL] && LinkPolicy.decide(Schemes.docBase(for: a.deletingLastPathComponent()) + "note-a.md", reach: outReach) == .ignore,
              "\(outReach)")
        check("reach: a file outside every folder is never opened",
              LinkPolicy.decide(Schemes.docBase + "etc/hosts", reach: inReach) == .ignore)

        check("wiki: a name is found in the other panel folder, the nearest copy wins",
              Wiki.resolve("note-a", from: mem, panel: panel) == a.standardizedFileURL
                  && Wiki.resolve("note-a", from: far.deletingLastPathComponent(), panel: panel) == far.standardizedFileURL
                  && Wiki.resolve("HOME.md#top", from: mem, panel: panel) == home.standardizedFileURL,
              "\(String(describing: Wiki.resolve("note-a", from: mem, panel: panel)))")
        check("wiki: a missing name is missing", Wiki.resolve("gone", from: idx, panel: panel) == nil)

        // The GitHub view: links made, the missing one marked, code left alone; a click opens the file.
        let saved = Prefs.shared.folders
        Prefs.shared.folders = panel
        await d.load(home)
        d.setMode("preview")
        let marked = await wait(5) {
            ((await d.web.call("return document.querySelectorAll('#preview a.wikilink.missing').length") as? Int) ?? 0) == 1
        }
        let links = (await d.web.call("return Array.from(document.querySelectorAll('#preview a.wikilink')).map(a => a.dataset.wiki + '=' + a.textContent + (a.classList.contains('missing') ? '!' : '')).join(' ')") as? String) ?? ""
        let code = (await d.web.call("return document.querySelector('#preview code').textContent") as? String) ?? ""
        let text = (await d.web.call("return mdApp.getMarkdownPreserving()") as? String) ?? ""
        check("wiki: links in the GitHub view, the missing one marked, code and text untouched",
              marked && links == "note-a=note-a Note-A.md=same gone=gone!" && code == "[[in code]]" && text.contains("[[note-a]]"),
              "\(marked) \(links) | \(code) | \(text)")
        await d.web.call("document.querySelector('#preview a.wikilink').click()")
        let opened = await wait(5) { DocWindow.all.contains { $0.model.path == a.standardizedFileURL } }
        check("wiki: a click opens the file", opened, "\(DocWindow.all.compactMap { $0.model.path?.path })")
        if d.model.path != home { await d.load(home) }
        // the same with a plain ../ link, resolved by WebKit against the document's base
        for w in DocWindow.all where w !== d { w.model.dirty = false; w.close() }
        d.setMode("preview")
        _ = await wait(3) { ((await d.web.call("return document.querySelectorAll('#preview a.wikilink').length") as? Int) ?? 0) == 3 }
        await d.web.call("document.querySelector('#preview a:not(.wikilink)').click()")
        let relOpened = await wait(5) { DocWindow.all.contains { $0.model.path == a.standardizedFileURL } }
        check("reach: a ../ link clicked in the GitHub view opens the file", relOpened,
              "\(DocWindow.all.compactMap { $0.model.path?.path })")
        if d.model.path != home { await d.load(home) }
        d.setMode("visual")
        // an edit in the visual view of the paragraph that holds the links keeps them as written
        await d.web.call("const v = mdApp._view(); v.dispatch(v.state.tr.insertText(' edited', v.state.doc.content.size - 1))")
        let edited = (await d.web.call("return mdApp.getMarkdownPreserving()") as? String) ?? ""
        check("wiki: editing in the visual view keeps the [[links]]",
              edited.contains("edited") && edited.contains("[[note-a]] · [[Note-A.md|same]] · [[gone]]"), edited)
        d.model.dirty = false
        await d.load(home)
        Prefs.shared.folders = saved
    }

    // 2.0.0, as on Windows. Pictures: beside the document, in ../, by an absolute path and a file: address outside
    // every folder, a ![[name]] found in another folder of the panel, and a missing one boxed; outside the reach only
    // pictures are served or opened. The tree: rename, move, undo and redo on disk, an unsaved edit saved first, a
    // folder renamed only in case, names refused, the open document and Open recent following. The three layouts.
    @MainActor
    private static func picturesFilesLayouts(_ d: DocWindow, _ tmp: URL) async {
        let fm = FileManager.default, prefs = Prefs.shared, ops = FileOps.shared
        let root = tmp.appendingPathComponent("pics").standardizedFileURL, docDir = root.appendingPathComponent("notes/doc")
        try? fm.createDirectory(at: docDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("att"), withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEklEQVR4nGNgYGD4z8DAwMDAAAAMAAH0xGq5AAAAAElFTkSuQmCC")!
        for p in ["notes/doc/here.png", "notes/up one.png", "att/far.png"] { try? png.write(to: root.appendingPathComponent(p)) }
        let outside = tmp.appendingPathComponent("outside dir/out.png").standardizedFileURL
        try? fm.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: outside)
        let doc = docDir.appendingPathComponent("pics.md")
        let fileAddress = "file://" + (outside.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? outside.path)
        try? "# P\n\n![a](here.png)\n\n![b](<../up one.png>)\n\n![c](\(outside.path))\n\n![d](\(fileAddress))\n\n![[far.png]]\n\n![gone](nothing.png)\n"
            .write(to: doc, atomically: true, encoding: .utf8)
        let saved = prefs.folders
        prefs.folders = [root.path]
        await d.load(doc)
        d.setMode("preview")
        let shown = await wait(6) {
            let loaded = (await d.web.call("return Array.from(document.querySelectorAll('#preview img')).filter(i => i.complete && i.naturalWidth === 2).length") as? Int) ?? 0
            let boxed = (await d.web.call("return document.querySelectorAll('#preview .gm-img-missing').length") as? Int) ?? 0
            return loaded == 5 && boxed == 1
        }
        let seen = (await d.web.call("return Array.from(document.querySelectorAll('#preview img, #preview .gm-img-missing')).map(i => (i.getAttribute('src') || i.title) + ':' + (i.naturalWidth ?? '-')).join(' ')") as? String) ?? ""
        check("pictures: beside, in ../, by absolute path and a file: address, ![[name]] in another folder; a missing one boxed", shown, seen)
        check("pictures: outside the reach only pictures are served or opened",
              LinkPolicy.decide(Schemes.address(of: outside), reach: d.reach) == .openViewer(outside)
                  && LinkPolicy.decide(Schemes.address(of: tmp.appendingPathComponent("x.md")), reach: d.reach) == .ignore,
              "\(LinkPolicy.decide(Schemes.address(of: outside), reach: d.reach))")
        d.setMode("visual")

        // the tree's file operations
        let n1 = root.appendingPathComponent("one.md"), n2 = root.appendingPathComponent("two.md")
        let sub = root.appendingPathComponent("sub"), n3 = sub.appendingPathComponent("two.md")
        try? "# One\n".write(to: n1, atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        await d.load(n1)
        var good = await ops.move(n1, to: n2, doc: d)
        check("files: rename on disk, the open document and Open recent follow",
              good && fm.fileExists(atPath: n2.path) && !fm.fileExists(atPath: n1.path) && d.model.path == n2
                  && prefs.recent.first == n2.path && !prefs.recent.contains(n1.path),
              "\(d.model.path?.path ?? "-") \(prefs.recent.prefix(3))")
        check("files: drop rules", FileOps.canDrop(n2, into: sub) && !FileOps.canDrop(n2, into: root) && !FileOps.canDrop(sub, into: sub)
              && !FileOps.canDrop(root, into: sub) && FileOps.isRoot(root))
        good = await ops.move(n2, to: n3, doc: d)
        check("files: a move into a folder, the document follows", good && fm.fileExists(atPath: n3.path) && d.model.path == n3, d.model.path?.path ?? "-")
        await d.web.call("mdApp.focus(); mdApp.insertText('typed ')")
        _ = await wait(2) { d.model.dirty }
        await ops.undo(doc: d)
        let u1 = fm.fileExists(atPath: n2.path) && d.model.path == n2 && ((try? String(contentsOf: n2, encoding: .utf8)) ?? "").contains("typed")
        await ops.undo(doc: d)
        let u2 = fm.fileExists(atPath: n1.path) && d.model.path == n1 && ops.undoStack.isEmpty && ops.redoStack.count == 2
        check("files: undo twice goes back, an unsaved edit saved first", u1 && u2, "\(u1) \(u2) \(d.model.path?.path ?? "-")")
        await ops.redo(doc: d); await ops.redo(doc: d)
        check("files: redo twice comes back", fm.fileExists(atPath: n3.path) && d.model.path == n3 && ops.redoStack.isEmpty, d.model.path?.path ?? "-")
        let cased = root.appendingPathComponent("Sub")
        good = await ops.move(sub, to: cased, doc: d)
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        check("files: a folder renamed only in case, with the open file inside",
              good && names.contains("Sub") && !names.contains("sub") && d.model.path?.path.hasSuffix("/Sub/two.md") == true,
              "\(names) \(d.model.path?.path ?? "-")")
        let clash = await ops.move(cased.appendingPathComponent("two.md"), to: doc, doc: d)
        check("files: two items cannot share a name; names macOS refuses are refused", !clash && fm.fileExists(atPath: doc.path)
              && FileOps.validName("a.md") && !FileOps.validName("a/b") && !FileOps.validName("..") && !FileOps.validName(" ") && !FileOps.validName("a:b"))
        d.model.dirty = false

        // the six layouts, in a window wide enough for each: the page sits between the sidebars
        if let w = d.window {
            w.setContentSize(NSSize(width: 1400, height: 800))
            prefs.showPanes()
            func page() -> NSRect { d.web.view.convert(d.web.view.bounds, to: nil) }
            let cw = w.contentView?.bounds.width ?? 0
            var bad: [String] = []
            for preset in Layouts.presets {
                Layouts.apply(preset, prefs)
                try? await Task.sleep(nanoseconds: 400_000_000)
                let r = page(), s = Layouts.shape(prefs)
                let lw = Layouts.width("left", prefs), rw = Layouts.width("right", prefs)
                let ok = (s.panes("left").isEmpty ? r.minX < 2 : abs(r.minX - lw - SplitHandle.thickness) < 3)
                    && (s.panes("right").isEmpty ? r.maxX > cw - 2 : abs(cw - r.maxX - rw - SplitHandle.thickness) < 3)
                if !ok { bad.append("\(preset.key): page \(r), left \(lw), right \(rw)") }
            }
            check("layout: each of the six layouts puts the page between its sidebars", bad.isEmpty, bad.joined(separator: "; ") + " in \(cw)")
            Layouts.apply(Layouts.presets[0], prefs)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        prefs.folders = saved
    }

    /// The search box above the tree (by name and in the text, accents and capitals aside, only what the tree
    /// shows), a found line opening the document's find bar there, and the layout picker.
    @MainActor
    private static func searchAndPicker(_ d: DocWindow, _ tmp: URL) async {
        let fm = FileManager.default, prefs = Prefs.shared
        let root = tmp.appendingPathComponent("search").standardizedFileURL
        try? fm.createDirectory(at: root.appendingPathComponent("Notas/sub"), withIntermediateDirectories: true)
        let found = root.appendingPathComponent("Notas/Búsqueda.md")
        try? "# Título\n\nLa búsqueda rápida\n\nOtra línea con BUSQUEDA y nada más\n\nLa última búsqueda\n".write(to: found, atomically: true, encoding: .utf8)
        try? "busqueda escondida\n".write(to: root.appendingPathComponent("Notas/.oculto.md"), atomically: true, encoding: .utf8)
        try? "busqueda en texto plano\n".write(to: root.appendingPathComponent("Notas/lista.txt"), atomically: true, encoding: .utf8)
        try? "nada que ver\n".write(to: root.appendingPathComponent("Notas/sub/otro.md"), atomically: true, encoding: .utf8)
        let byName = TreeSearch.byName("BUSQ", roots: [root.path])
        check("search: by name, accents and capitals aside, no hidden files and no .txt",
              byName.map(\.url) == [found] && byName.first?.name?.hit == "Búsq" && byName.first?.folder == "search/Notas",
              "\(byName.map { $0.url.lastPathComponent }) \(byName.first?.folder ?? "-")")
        let text = TreeSearch.byContent("busqueda", roots: [root.path])
        let lines = text.hits.first?.lines ?? []
        check("search: in the text, every match with its line, as written in the file",
              text.hits.map(\.url) == [found] && text.total == 3 && lines.map(\.line) == [3, 5, 7] && lines.map(\.hit) == ["búsqueda", "BUSQUEDA", "búsqueda"]
                  && lines.map(\.occurrence) == [0, 0, 1]
                  && lines.count == 3 && lines[1].after == " y nada más" && !text.cut,
              "\(text.hits.map { $0.url.lastPathComponent }) \(text.total) \(lines)")
        let many = String(repeating: "x ", count: TreeSearch.maxMatches + 50)
        try? many.write(to: root.appendingPathComponent("Notas/sub/x.md"), atomically: true, encoding: .utf8)
        let cut = TreeSearch.byContent("x", roots: [root.path])
        check("search: stops at its limit and says so", cut.cut && cut.total == TreeSearch.maxMatches, "\(cut.total) \(cut.cut)")

        // the box in the window: the panel shows it, the results replace the tree, a line opens the find bar there
        let saved = prefs.folders, savedMode = prefs.searchMode
        prefs.folders = [root.path]; Layouts.apply(Layouts.presets[0], prefs)
        let boxShown = await wait(3) { d.search.field?.window === d.window }
        check("search: the box sits above the tree", boxShown, "field \(String(describing: d.search.field)) in \(String(describing: d.search.field?.window)) not \(String(describing: d.window))")
        d.focusTreeSearch()
        let focused = await wait(2) {
            guard let w = d.window, let f = d.search.field else { return false }
            return w.firstResponder === f || (w.firstResponder as? NSTextView)?.delegate === f
        }
        check("search: Edit → Search in folders puts the caret in the box", focused,
              String(describing: d.window?.firstResponder))
        prefs.searchMode = "content"
        d.search.query = "busqueda"
        await d.search.run()
        _ = await wait(3) { !d.search.busy && d.search.rows.count == 3 }
        check("search: the window's results and the count", d.search.rows.count == 3 && d.search.info.contains("3"),
              "info «\(d.search.info)» rows \(d.search.rows.count) results \(d.search.results.count) busy \(d.search.busy) query «\(d.search.query)» field «\(d.search.field?.stringValue ?? "-")» mode \(prefs.searchMode)")
        // the third line is the second «búsqueda» of the file: the find bar must stand on it, not on the first
        d.search.move(1); d.search.move(1); d.search.move(1)
        d.search.openSelected(in: d)
        let opened = await wait(4) {
            d.model.path == found && d.model.findVisible && d.model.findQuery == "búsqueda" && d.model.findInfo == L("OfCount", 2, 2)
        }
        check("search: ↓ ↓ ↓ Return opens the file and the find bar on that very match", opened,
              "\(d.model.path?.lastPathComponent ?? "-") \(d.model.findQuery) \(d.model.findInfo)")
        d.hideFind()
        d.search.query = ""
        check("search: an empty box gives the tree back", !d.search.active && d.search.rows.isEmpty)

        // the layout picker and View → Layout: each layout, the swap, a pane dropped on an edge, the switches
        var picked: [String] = []
        for p in Layouts.presets { Layouts.apply(p, prefs); picked.append(Layouts.presets.first { Layouts.isPreset($0, prefs) }?.key ?? "-") }
        check("layout: each of the six layouts is the one View → Layout marks", picked == Layouts.presets.map(\.key), "\(picked)")
        Layouts.apply(Layouts.presets[2], prefs); Layouts.swap(prefs)
        let swappedSides = prefs.filesSide == "right" && prefs.outlineSide == "left"
        Layouts.apply(Layouts.presets[0], prefs); Layouts.swap(prefs)
        let swappedOrder = Layouts.shape(prefs).panes("left") == [.outline, .files]
        prefs.outlineFirst = false
        check("layout: the swap trades the sides, or the order on one side", swappedSides && swappedOrder)
        let area = CGSize(width: 1000, height: 600)            // edges of 220
        let toRight = Layouts.target(.outline, at: CGPoint(x: 900, y: 300), in: area, prefs)
        let above = Layouts.target(.outline, at: CGPoint(x: 50, y: 100), in: area, prefs)
        let beside = Layouts.target(.outline, at: CGPoint(x: 200, y: 300), in: area, prefs)
        let nowhere = Layouts.target(.outline, at: CGPoint(x: 500, y: 300), in: area, prefs)
        check("layout: where a dragged pane would go (edge, above, beside, nowhere)",
              toRight?.side == "right" && toRight?.arrange == nil && above?.side == "left" && above?.arrange == "rows" && above?.first == true
              && beside?.arrange == "cols" && beside?.first == false && nowhere == nil,
              "\(String(describing: toRight)) \(String(describing: above)) \(String(describing: beside))")
        if let above { Layouts.dock(.outline, above, prefs) }
        let wentAbove = Layouts.shape(prefs).panes("left") == [.outline, .files] && prefs.leftArrange == "rows"
        if let toRight { Layouts.dock(.outline, toRight, prefs) }
        let wentRight = prefs.outlineSide == "right" && Layouts.shape(prefs).panes("left") == [.files]
        check("layout: a pane dropped above the other, then on the other edge", wentAbove && wentRight)
        prefs.togglePane(.outline); let oneOff = !prefs.outlinePanel && prefs.panesShown
        prefs.togglePane(.files); let bothOff = !prefs.panesShown
        prefs.togglePanes(); let back = prefs.filesPanel && prefs.outlinePanel && prefs.panesShown
        check("layout: each pane on and off, and ⇧⌘E brings both back", oneOff && bothOff && back)
        Layouts.apply(Layouts.presets[0], prefs); prefs.outlineFirst = false
        // the three layouts of 3.0 become the new values, with their widths, once
        let suite = "io.github.gabriel-castiglia.vigia.selftest-layout"
        if let ud = UserDefaults(suiteName: suite) {
            ud.removePersistentDomain(forName: suite)
            ud.set("right", forKey: "SideLayout"); ud.set(300.0, forKey: "SidebarWidth"); ud.set(280.0, forKey: "OutlineWidthRight")
            let m = Prefs.layoutValues(ud), again = Prefs.layoutValues(ud)
            check("layout: the settings of 3.0 become the new ones, with their widths",
                  m.filesSide == "left" && m.outlineSide == "right" && m.widths["right:outline"] == 280 && m.widths["left:files"] == 300
                  && ud.object(forKey: "SideLayout") == nil && again.outlineSide == "right" && again.widths == m.widths, "\(m)")
            ud.removePersistentDomain(forName: suite)
        }

        // the line goes with a click on a found line, for the page to pick the match in a view that hides Markdown
        check("search: the whole line goes with the click", lines.first?.text == "La búsqueda rápida", lines.first?.text ?? "-")

        // favourites: one list for every folder, folders first, moving, sorting, following a rename, cleaning
        let savedFav = prefs.favorites
        let favA = root.appendingPathComponent("Notas/Búsqueda.md").path, favDir = root.appendingPathComponent("Notas/sub").path
        let favGone = root.appendingPathComponent("Notas/gone.md").path
        prefs.favorites = []
        prefs.toggleFavorite(favA); prefs.toggleFavorite(favGone); prefs.toggleFavorite(favDir)
        check("favourites: folders first, then files in their order", prefs.favoritesShown == [favDir, favA, favGone], "\(prefs.favoritesShown)")
        prefs.moveFavorite(favGone, by: -1)
        prefs.moveFavorite(favDir, by: 1)     // a folder does not go among the files
        check("favourites: move up and down among the same kind", prefs.favoritesShown == [favDir, favGone, favA], "\(prefs.favoritesShown)")
        prefs.moveFavorite(favA, onto: favGone)
        check("favourites: dragged onto another one, it takes its place", prefs.favoritesShown == [favDir, favA, favGone], "\(prefs.favoritesShown)")
        prefs.follow(from: favA, to: favA + ".renamed.md", isDir: false)
        check("favourites: a rename from the panel is followed", prefs.isFavorite(favA + ".renamed.md") && !prefs.isFavorite(favA))
        prefs.removeMissingFavorites()
        check("favourites: the ones that no longer exist are removed", prefs.favorites == [favDir], "\(prefs.favorites)")
        prefs.toggleFavorite(favDir)
        check("favourites: the star takes it out again", prefs.favorites.isEmpty)
        prefs.favorites = savedFav

        for (what, ok) in SelfUpdate.selfTest() { check(what, ok) }
        prefs.folders = saved; prefs.searchMode = savedMode
        d.model.dirty = false
    }

    // A dedicated instance made from this app into a temporary Applications folder.
    @MainActor
    private static func dedicated(_ tmp: URL) async {
        let fm = FileManager.default
        let keep = Instance.appsFolder
        Instance.appsFolder = tmp.appendingPathComponent("Applications", isDirectory: true)
        defer { Instance.appsFolder = keep }
        let name = "Self-test Ñandú \(Int.random(in: 1000...9999))"
        let spec = Instance.Spec(name: name, accent: "red", folders: [tmp.path], home: tmp.appendingPathComponent("x.md").path,
                                 startReadOnly: true, startMode: "preview")
        let id = Instance.bundleID(name)
        defer { UserDefaults.standard.removePersistentDomain(forName: id) }
        do {
            let app = try Instance.make(spec, from: Bundle.main.bundleURL)
            let p = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            let icns = app.appendingPathComponent("Contents/Resources/Vigia.icns")
            let widths: [Int] = CGImageSourceCreateWithURL(icns as CFURL, nil).map { s in
                (0..<CGImageSourceGetCount(s)).compactMap { CGImageSourceCreateImageAtIndex(s, $0, nil)?.width }
            } ?? []
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--strict", app.path]
            try verify.run(); verify.waitUntilExit()
            let seeded = UserDefaults(suiteName: id)
            check("instance: own identifier and name, no Markdown file types",
                  p["CFBundleIdentifier"] as? String == id && id.hasPrefix(Instance.mainID + ".profile.self-test-nandu-")
                      && p["CFBundleDocumentTypes"] == nil && app.lastPathComponent == name + " (Vigía).app",
                  "\(p["CFBundleIdentifier"] ?? "nil") \(app.lastPathComponent)")
            check("instance: icon in its colour and a valid signature",
                  widths.contains(16) && widths.contains(512) && verify.terminationStatus == 0, "sizes \(widths), codesign \(verify.terminationStatus)")
            check("instance: the spec reads back", Instance.spec(of: app) == spec, "\(String(describing: Instance.spec(of: app)))")
            check("instance: settings seeded apart from the main app",
                  seeded?.string(forKey: "Accent") == "red" && seeded?.stringArray(forKey: "Folders") == [tmp.path]
                      && seeded?.bool(forKey: "ReadOnly") == true && seeded?.string(forKey: "Mode") == "preview",
                  "\(seeded?.dictionaryRepresentation().filter { ["Accent", "Folders", "ReadOnly", "Mode"].contains($0.key) } ?? [:])")
            // rebuilt in place: still one app, same spec
            _ = try Instance.make(spec, from: Bundle.main.bundleURL)
            let same = { (u: URL) in u.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            check("instance: a rebuild replaces it in place", Instance.all().map(same) == [same(app)] && fm.fileExists(atPath: icns.path),
                  "\(Instance.all().map(same)) vs \(same(app))")
            LSRegisterURL(app as CFURL, false)
            try? fm.removeItem(at: app)
        } catch {
            check("instance: made", false, error.localizedDescription)
        }
    }
}

extension NSAlert {
    /// A question on the window. In the self-test out of sight it is not shown at all (a sheet comes with a glass
    /// backdrop of its own that no transparency hides): it waits for SelfTest.answer instead.
    @MainActor
    func ask(for w: NSWindow) async -> NSApplication.ModalResponse {
        guard AppDelegate.quiet else { return await beginSheetModal(for: w) }
        return await withCheckedContinuation { SelfTest.park($0, messageText) }
    }
}

extension NSSavePanel {
    @MainActor
    func ask(for w: NSWindow) async -> NSApplication.ModalResponse {
        guard AppDelegate.quiet else { return await beginSheetModal(for: w) }
        SelfTest.note("a file panel (answered Cancel)")
        return .cancel
    }
}
