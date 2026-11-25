// Vigia: writing a file so that it is never left empty or cut in half, without breaking what it is.
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 25, 2026
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Data.write(.atomic) already wrote a temporary file and renamed it over the old one, but measured on 25-nov-2026 it
/// also replaced a symbolic link with a plain file (the file it pointed to kept the old text) and dropped the
/// extended attributes (Finder tags and comments, where the file came from). Here the new text goes to a temporary
/// file next to the real one, reaches the disk, and takes its place with FileManager.replaceItemAt, which keeps the
/// old file's permissions and extended attributes; a link stays a link and its file is the one written.
enum AtomicFile {
    struct ReadOnly: LocalizedError {
        let path: String
        var errorDescription: String? { L("FileReadOnly", (path as NSString).lastPathComponent) }
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dest = url.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: dest.path) else { try data.write(to: dest, options: .atomic); return }
        guard fm.isWritableFile(atPath: dest.path) else { throw ReadOnly(path: dest.path) }
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString.prefix(8).lowercased()).tmp")
        do {
            try data.write(to: tmp, options: .withoutOverwriting)
            let h = try FileHandle(forWritingTo: tmp)
            try h.synchronize()   // on the disk before it takes the place of the old file
            try h.close()
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// A temporary file of a write in one step (".a.md.1a2b3c4d.tmp").
    static func isTemporary(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".tmp") && name.range(of: #"^\..+\.[0-9a-f]{8}\.tmp$"#, options: .regularExpression) != nil
    }
}
