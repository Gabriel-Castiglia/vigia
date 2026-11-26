// Vigia: renaming and moving files and folders from the Files panel, with undo and redo (as on Windows).
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 16, 2026
// SPDX-License-Identifier: GPL-2.0-only
//
// Everything happens on disk. Right-click → Rename… renames a file or folder; with the tree unlocked (the padlock
// in the panel header) files and folders dragged onto a folder, or onto a file of that folder, are moved there.
// Every rename and move can be undone and redone with the two arrows of the header. An open document follows its
// file, and is saved first if it had changes; File → Open recent follows too. The open folders themselves are not
// renamed or moved from the tree.

import AppKit

@MainActor
final class FileOps: ObservableObject {
    static let shared = FileOps()
    struct Op { let from: URL; let to: URL }

    @Published private(set) var undoStack: [Op] = []
    @Published private(set) var redoStack: [Op] = []
    @Published private(set) var generation = 0          // the trees reload when it changes

    /// What a drag of the tree carries: this prefix and the path (nothing else is taken as a drop).
    nonisolated static let dragPrefix = "vigia-tree:"

    static func isUnder(_ p: URL, _ dir: URL) -> Bool {
        let d = dir.standardizedFileURL.path
        return p.standardizedFileURL.path.lowercased().hasPrefix((d.hasSuffix("/") ? d : d + "/").lowercased())
    }

    /// A name macOS takes as one item: not empty, not . or .., without / or : (the Finder shows : as /).
    static func validName(_ n: String) -> Bool {
        !n.trimmingCharacters(in: .whitespaces).isEmpty && n != "." && n != ".." && !n.contains("/") && !n.contains(":") && !n.contains("\0")
    }

    /// One of the open folders of the panel: never renamed or moved from the tree.
    static func isRoot(_ u: URL) -> Bool {
        Prefs.shared.folders.contains { TreeState.canonical($0) == TreeState.canonical(u.path) }
    }

    /// A drop of `src` into `dir` is possible: not where it already is, not into itself.
    static func canDrop(_ src: URL, into dir: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, !isRoot(src) else { return false }
        let parent = src.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        return parent != dir.standardizedFileURL.path.lowercased()
            && src.standardizedFileURL.path.lowercased() != dir.standardizedFileURL.path.lowercased() && !isUnder(dir, src)
    }

    static func describe(_ op: Op) -> String {
        op.from.deletingLastPathComponent().path == op.to.deletingLastPathComponent().path
            ? "\(op.from.lastPathComponent) → \(op.to.lastPathComponent)"
            : "\(op.from.lastPathComponent) → \(op.to.deletingLastPathComponent().lastPathComponent)"
    }

    /// Moves or renames on disk. False, with a message in the status line of `doc`, when it could not be done.
    @discardableResult
    func move(_ from: URL, to: URL, record: Bool = true, doc: DocWindow?) async -> Bool {
        let fm = FileManager.default
        let from = from.standardizedFileURL, to = to.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { doc?.flash(L("ItemGone")); generation += 1; return false }
        if from.path == to.path { return false }
        let caseOnly = from.path.lowercased() == to.path.lowercased()
        if !caseOnly && fm.fileExists(atPath: to.path) { doc?.flash(L("NameExists", to.lastPathComponent)); return false }
        if isDir.boolValue && FileOps.isUnder(to, from) { doc?.flash(L("MoveIntoItself")); return false }

        // the open documents in it: saved first, then they follow their file
        let affected = DocWindow.all.filter { d in
            guard let p = d.model.path else { return false }
            return p.path.lowercased() == from.path.lowercased() || (isDir.boolValue && FileOps.isUnder(p, from))
        }
        for d in affected where d.model.dirty { guard await d.save(as: false) else { return false } }
        for d in affected { d.watch(nil) }
        do {
            if caseOnly {
                let hop = from.deletingLastPathComponent().appendingPathComponent(from.lastPathComponent + ".gm-rename-" + UUID().uuidString.prefix(6))
                try fm.moveItem(at: from, to: hop)
                try fm.moveItem(at: hop, to: to)
            } else {
                try fm.moveItem(at: from, to: to)
            }
        } catch {
            for d in affected { if let p = d.model.path { d.watch(p) } }
            doc?.flash(L("MoveFailed", error.localizedDescription))
            return false
        }
        for d in affected {
            guard let p = d.model.path else { continue }
            await d.relocate(to: URL(fileURLWithPath: to.path + String(p.path.dropFirst(from.path.count))))
        }
        Prefs.shared.follow(from: from.path, to: to.path, isDir: isDir.boolValue)
        if record { undoStack.append(Op(from: from, to: to)); redoStack.removeAll() }
        Wiki.forget()
        generation += 1
        return true
    }

    func undo(doc: DocWindow?) async {
        guard let op = undoStack.last else { return }
        if await move(op.to, to: op.from, record: false, doc: doc) { undoStack.removeLast(); redoStack.append(op) }
    }

    func redo(doc: DocWindow?) async {
        guard let op = redoStack.last else { return }
        if await move(op.from, to: op.to, record: false, doc: doc) { redoStack.removeLast(); undoStack.append(op) }
    }

    /// Right-click → Rename…: asks the new name, with the part before the extension selected.
    func rename(_ url: URL, doc: DocWindow?) {
        guard !FileOps.isRoot(url) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { doc?.flash(L("ItemGone")); generation += 1; return }
        let a = NSAlert()
        a.messageText = L("RenameTitle")
        a.informativeText = L("RenameName")
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("RenameButton"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        DispatchQueue.main.async { field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length) }
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        if name == url.lastPathComponent || name.isEmpty { return }
        guard FileOps.validName(name) else { doc?.flash(L("NameInvalid", name)); return }
        Task { await move(url, to: url.deletingLastPathComponent().appendingPathComponent(name), doc: doc) }
    }

    /// A drop on a row of the tree: the provider's text names what was dragged.
    func drop(_ providers: [NSItemProvider], into dir: URL, doc: DocWindow?) -> Bool {
        guard !Prefs.shared.treeLocked, let p = providers.first, p.canLoadObject(ofClass: NSString.self) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, s.hasPrefix(FileOps.dragPrefix) else { return }
            let src = URL(fileURLWithPath: String(s.dropFirst(FileOps.dragPrefix.count)))
            DispatchQueue.main.async {
                guard FileOps.canDrop(src, into: dir) else { return }
                Task { await FileOps.shared.move(src, to: dir.appendingPathComponent(src.lastPathComponent), doc: doc) }
            }
        }
        return true
    }

    // MARK: new files and folders, and deleting (3.5.2: what Vigía for Windows brought in 3.4.0 to 3.5.1)
    // Only with the tree unlocked (the padlock of the panel), as dragging. Nothing is ever written over: a name already
    // taken, or one macOS would not take as one item, is refused with a message.

    /// The folder a new file or folder is made in: the one asked (a folder's right-click menu), else the folder made
    /// last from here, else the folder of the shown document when it is in the panel, else the first open folder, else
    /// ~/Documents/Vigia (made, and added to the panel).
    private var lastNewFolder: URL?

    func targetFolder(_ asked: URL?, doc: DocWindow?) -> URL {
        let fm = FileManager.default
        func isDir(_ u: URL?) -> Bool { var d: ObjCBool = false; return u.map { fm.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue } ?? false }
        if isDir(asked) { return asked! }
        if isDir(lastNewFolder) { return lastNewFolder! }
        let roots = Prefs.shared.folders.map { URL(fileURLWithPath: $0) }
        if let dir = doc?.model.path?.deletingLastPathComponent(), roots.contains(where: { FileOps.isUnder(dir, $0) || $0.standardizedFileURL == dir.standardizedFileURL }) {
            return dir
        }
        if let first = roots.first(where: isDir) { return first }
        let mine = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Vigia", isDirectory: true)
        try? fm.createDirectory(at: mine, withIntermediateDirectories: true)
        if !Prefs.shared.folders.contains(mine.path) { Prefs.shared.folders.append(mine.path) }
        return mine
    }

    /// A name not taken in `dir`: "New document.md", "New document 2.md"...
    static func freeName(_ base: String, ext: String, in dir: URL) -> String {
        let fm = FileManager.default
        for n in 1 ... 999 {
            let name = (n == 1 ? base : "\(base) \(n)") + ext
            if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        }
        return base + " " + UUID().uuidString.prefix(6) + ext
    }

    /// Makes the file or folder; a file without a Markdown extension gets .md and starts with its name as a heading.
    static func createItem(in dir: URL, name: String, folder: Bool) throws -> URL {
        guard validName(name) else { throw Failure(L("NameInvalid", name)) }
        var name = name.trimmingCharacters(in: .whitespaces)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if folder {
            let u = dir.appendingPathComponent(name, isDirectory: true)
            guard !fm.fileExists(atPath: u.path) else { throw Failure(L("NameExists", name)) }
            try fm.createDirectory(at: u, withIntermediateDirectories: false)
            return u
        }
        if !["md", "markdown", "mdown", "mkd"].contains((name as NSString).pathExtension.lowercased()) { name += ".md" }
        let u = dir.appendingPathComponent(name)
        let title = (name as NSString).deletingPathExtension
        // withoutOverwriting: never over a file made meanwhile
        do { try Data("# \(title)\n".utf8).write(to: u, options: .withoutOverwriting) }
        catch CocoaError.fileWriteFileExists { throw Failure(L("NameExists", name)) }
        return u
    }

    struct Failure: LocalizedError { let text: String; init(_ t: String) { text = t }; var errorDescription: String? { text } }

    /// The toolbar's two first buttons and a folder's right-click menu: asks the name (a free one offered) and makes the
    /// file, which opens at once, or the folder, where the next new file goes.
    func newItem(folder: Bool, in asked: URL?, doc: DocWindow?) {
        guard !Prefs.shared.treeLocked else { doc?.flash(L("NeedsUnlock")); return }
        let dir = targetFolder(asked, doc: doc)
        let a = NSAlert()
        a.messageText = L(folder ? "NewFolder" : "NewMarkdown")
        a.informativeText = L("NewItemName", dir.lastPathComponent)
        let suggested = folder ? FileOps.freeName(L("NewFolderDefault"), ext: "", in: dir) : FileOps.freeName(L("NewMarkdownDefault"), ext: ".md", in: dir)
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("Create"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        let stem = folder ? suggested : (suggested as NSString).deletingPathExtension
        DispatchQueue.main.async { field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length) }
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let u = try FileOps.createItem(in: dir, name: field.stringValue, folder: folder)
            generation += 1
            if folder { lastNewFolder = u } else { (NSApp.delegate as? AppDelegate)?.open(u, from: doc) }
        } catch {
            doc?.flash(L("NewItemFailed", error.localizedDescription))
        }
    }

    /// Windows that said "Don't ask again in this window": only for as long as they are open.
    private var noAsk = Set<ObjectIdentifier>()

    /// Right-click → Delete: to the Trash, where it can be restored, after a question (unless this window was told not
    /// to ask). A volume without a Trash (a network folder) asks again, always: there it is deleted for good. Its tabs
    /// close without saving (their text is in the Trash) and it leaves Favourites and Open recent. The open folders
    /// themselves are closed from their own menu, never deleted from here.
    func delete(_ url: URL, doc: DocWindow?) {
        let fm = FileManager.default
        guard !FileOps.isRoot(url) else { return }
        guard !Prefs.shared.treeLocked else { doc?.flash(L("NeedsUnlock")); return }
        var d: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &d) else { doc?.flash(L("ItemGone")); generation += 1; return }
        let isDir = d.boolValue, name = url.lastPathComponent
        let win = doc.map(ObjectIdentifier.init)
        if win == nil || !noAsk.contains(win!) {
            let a = NSAlert()
            a.messageText = L(isDir ? "DeleteAskFolder" : "DeleteAskFile", name)
            a.informativeText = L("DeleteToTrash")
            a.addButton(withTitle: L("Delete"))
            a.addButton(withTitle: L("Cancel"))
            a.showsSuppressionButton = win != nil
            a.suppressionButton?.title = L("DeleteNoAsk")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            if a.suppressionButton?.state == .on, let w = win { noAsk.insert(w) }
        }
        var forGood = false
        do { try deleteWithoutAsking(url, permanently: false) }
        catch {
            // no Trash on this volume: asked again, always, before deleting for good
            let a = NSAlert()
            a.messageText = L(isDir ? "DeleteAskFolderForGood" : "DeleteAskFileForGood", name)
            a.informativeText = error.localizedDescription
            a.alertStyle = .critical
            a.addButton(withTitle: L("Delete"))
            a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { generation += 1; return }
            do { try deleteWithoutAsking(url, permanently: true); forGood = true }
            catch { doc?.flash(L("DeleteFailed", name, error.localizedDescription)); generation += 1; return }
        }
        doc?.flash(L(forGood ? "DeletedForGood" : "Deleted", name))
    }

    /// Deletes without asking: closes its tabs, sends it to the Trash (or deletes it for good) and takes it out of the
    /// lists. Throws when macOS refuses; then nothing changed but the closed tabs. The self-test deletes for good, so
    /// its files never reach the user's Trash.
    func deleteWithoutAsking(_ url: URL, permanently: Bool) throws {
        let fm = FileManager.default
        var d: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &d) else { throw Failure(L("ItemGone")) }
        closeTabs(of: url, isDir: d.boolValue)
        if permanently || DocWindow.inSelfTest { try fm.removeItem(at: url) } else { try fm.trashItem(at: url, resultingItemURL: nil) }
        forget(url, isDir: d.boolValue)
    }

    private func affected(_ p: URL?, _ url: URL, _ isDir: Bool) -> Bool {
        guard let p else { return false }
        return p.standardizedFileURL.path == url.standardizedFileURL.path || (isDir && FileOps.isUnder(p, url))
    }

    /// The tabs of the file (or of the files inside the folder) close, without saving.
    private func closeTabs(of url: URL, isDir: Bool) {
        for x in DocWindow.all where affected(x.filePath, url, isDir) {
            x.model.dirty = false
            x.close()
        }
    }

    /// Out of Favourites, Open recent and the undo history; the trees read the disk again.
    private func forget(_ url: URL, isDir: Bool) {
        let prefs = Prefs.shared
        let gone: (String) -> Bool = { [self] in affected(URL(fileURLWithPath: $0), url, isDir) }
        if prefs.favorites.contains(where: gone) { prefs.favorites.removeAll(where: gone) }
        if prefs.recent.contains(where: gone) { prefs.recent.removeAll(where: gone) }
        if prefs.recentFolders.contains(where: gone) { prefs.recentFolders.removeAll(where: gone) }
        undoStack.removeAll { affected($0.to, url, isDir) || affected($0.from, url, isDir) }
        redoStack.removeAll { affected($0.to, url, isDir) || affected($0.from, url, isDir) }
        if affected(lastNewFolder, url, isDir) { lastNewFolder = nil }
        generation += 1
    }
}
