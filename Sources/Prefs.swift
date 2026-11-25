// Vigia: settings, text lookup and the theme colours.
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 10, 2026
// SPDX-License-Identifier: GPL-2.0-only
//
// The settings live in the app's preferences (io.github.gabriel-castiglia.vigia). The
// screenshot and self-test modes switch persistence off, so they never touch them.

import AppKit
import SwiftUI

final class Prefs: ObservableObject {
    static let shared = Prefs()

    @Published var lang = "en" { didSet { save() } }
    @Published var theme = "auto" { didSet { save(); applyAppearance() } }      // auto, light, dark
    @Published var accent = Accent.defaultKey { didSet { save(); applyDockIcon() } }
    @Published var mode = "visual" { didSet { save() } }                        // visual, source, preview
    @Published var spell = true { didSet { save() } }
    /// Spell check languages, all checked at once (Spell.swift); words added to the dictionary with the right click.
    @Published var spellLangs = Spell.defaultLanguages { didSet { save() } }
    @Published var spellWords: [String] = [] { didSet { save() } }
    /// File → Preview Tab for Files from the Panel (3.3.1, as Windows 3.3.0): a click in the panel shows the file in a
    /// passing tab that the next click reuses.
    @Published var previewTab = true { didSet { save() } }
    @Published var autoSave = true { didSet { save() } }                    // saves a moment after the typing stops
    @Published var readOnly = false { didSet { save() } }
    @Published var zoom = 1.0 { didSet { save() } }
    @Published var sidebar = true { didSet { save() } }                 // the panes shown at all (⇧⌘E)
    // The panes, as on Windows (Layout.swift): each one on or off, to the left or the right of the text; when both
    // share a side, one above the other ("rows") or side by side ("cols"), Files first unless outlineFirst.
    @Published var filesPanel = true { didSet { save() } }
    @Published var outlinePanel = true { didSet { save() } }
    @Published var filesSide = "left" { didSet { save() } }
    @Published var outlineSide = "left" { didSet { save() } }
    @Published var leftArrange = "rows" { didSet { save() } }
    @Published var rightArrange = "rows" { didSet { save() } }
    @Published var outlineFirst = false { didSet { save() } }
    // The width of each sidebar, by what it holds (Layouts.widthKey); set when its divider is let go.
    @Published var layoutWidths: [String: Double] = [:] { didSet { save() } }
    // The share that Contents takes when both panes share a side: of the height, or of the width side by side.
    @Published var outlineShare = 0.45 { didSet { save() } }
    @Published var outlineShareColumns = 0.45 { didSet { save() } }
    // View → Text width: the column of the Visual and GitHub views in points (980 = GitHub's), 0 = the whole window.
    @Published var textWidth = 980 { didSet { save() } }
    // The Files tree: locked, nothing is dragged; unlocked, files and folders are moved on disk by dragging them.
    @Published var treeLocked = true { didSet { save() } }
    // The search box above the tree: "name" (file names) or "content" (the text of the files).
    @Published var searchMode = "name" { didSet { save() } }
    @Published var recent: [String] = [] { didSet { save() } }
    @Published var recentFolders: [String] = [] { didSet { save() } }     // folders opened lately, newest first (6)
    @Published var favorites: [String] = [] { didSet { save() } }         // starred files and folders, in the user's order
    @Published var recentPanel = false { didSet { save() } }              // a RECENT block in the Files panel
    @Published var sampleHidden = false { didSet { save() } }              // the sample out of File → Open recent
    @Published var folders: [String] = [] { didSet { save() } }
    // The Files panel, as on Windows: pinned folders go first; the rest in the chosen order; each folder a colour.
    @Published var pinned: [String] = [] { didSet { save() } }
    @Published var startupFolders = "restore" { didSet { save() } }     // restore, clean, pinned
    @Published var folderSort = "opened" { didSet { save() } }          // opened, az, za, modified
    @Published var folderColors = "theme" { didSet { save() } }         // theme, multi, none
    @Published var folderColorMap: [String: Double] = [:] { didSet { save() } }   // hue chosen by hand
    @Published var sampleShown = false { didSet { save() } }
    // File → Reopen Tabs at Start (off by default): the files of the tabs, in order, and the one shown (Tabs.swift).
    @Published var restoreTabs = false { didSet { save() } }
    var openTabs: [String] = [] { didSet { save() } }
    var activeTab = 0 { didSet { save() } }
    @Published private(set) var dark = false

    var persist = true
    private var loading = false
    private let d = UserDefaults.standard

    func load() {
        guard persist else { return }
        loading = true
        defer { loading = false }
        lang = d.string(forKey: "Lang").map { Prefs.language($0) } ?? Prefs.macLanguage
        theme = d.string(forKey: "Theme") ?? "auto"
        accent = d.string(forKey: "Accent") ?? Accent.defaultKey
        mode = d.string(forKey: "Mode") ?? "visual"
        spell = d.object(forKey: "Spell") as? Bool ?? true
        spellLangs = (d.stringArray(forKey: "SpellLangs") ?? Spell.defaultLanguages).filter { !$0.isEmpty }
        spellWords = d.stringArray(forKey: "SpellWords") ?? []
        previewTab = d.object(forKey: "PreviewTab") as? Bool ?? true
        autoSave = d.object(forKey: "AutoSave") as? Bool ?? true
        readOnly = d.bool(forKey: "ReadOnly")
        zoom = max(0.5, min(3, d.object(forKey: "Zoom") as? Double ?? 1))
        sidebar = d.object(forKey: "Sidebar") as? Bool ?? true
        filesPanel = d.object(forKey: "FilesPanel") as? Bool ?? true
        outlinePanel = d.object(forKey: "OutlinePanel") as? Bool ?? true
        outlineShare = Prefs.clampShare(d.object(forKey: "OutlineShare") as? Double ?? 0.45)
        outlineShareColumns = Prefs.clampShare(d.object(forKey: "OutlineShareColumns") as? Double ?? 0.45)
        let l = Prefs.layoutValues(d)
        filesSide = l.filesSide; outlineSide = l.outlineSide; leftArrange = l.leftArrange; rightArrange = l.rightArrange
        outlineFirst = l.outlineFirst; layoutWidths = l.widths
        textWidth = [980, 1280, 1600, 0].contains(d.object(forKey: "TextWidth") as? Int ?? -1) ? d.integer(forKey: "TextWidth") : 980
        treeLocked = d.object(forKey: "TreeLocked") as? Bool ?? true
        searchMode = d.string(forKey: "SearchMode") == "content" ? "content" : "name"
        recent = d.stringArray(forKey: "Recent") ?? []
        recentFolders = d.stringArray(forKey: "RecentFolders") ?? []
        var seenFav = Set<String>()
        favorites = (d.stringArray(forKey: "Favorites") ?? []).filter { !$0.isEmpty && seenFav.insert($0.lowercased()).inserted }
        recentPanel = d.bool(forKey: "RecentPanel")
        sampleHidden = d.bool(forKey: "SampleHidden")
        folders = d.stringArray(forKey: "Folders") ?? []
        pinned = d.stringArray(forKey: "PinnedFolders") ?? []
        startupFolders = ["restore", "clean", "pinned"].contains(d.string(forKey: "StartupFolders") ?? "") ? d.string(forKey: "StartupFolders")! : "restore"
        folderSort = ["opened", "az", "za", "modified"].contains(d.string(forKey: "FolderSort") ?? "") ? d.string(forKey: "FolderSort")! : "opened"
        folderColors = ["theme", "multi", "none"].contains(d.string(forKey: "FolderColors") ?? "") ? d.string(forKey: "FolderColors")! : "theme"
        folderColorMap = (d.dictionary(forKey: "FolderColorMap") as? [String: Double]) ?? [:]
        sampleShown = d.bool(forKey: "SampleShown")
        restoreTabs = d.bool(forKey: "RestoreTabs")
        openTabs = (d.stringArray(forKey: "OpenTabs") ?? []).filter { !$0.isEmpty }
        activeTab = d.integer(forKey: "ActiveTab")
    }

    /// On quitting, the files of every tab, so that the new version opens them again after an update installs
    /// itself (SelfUpdate relaunches the app within ten minutes of the quit).
    func keepTabsForUpdate(_ files: [String]) {
        guard persist else { return }
        d.set(files, forKey: "UpdateTabs")
        d.set(appVersion, forKey: "UpdateTabsVersion")
        d.set(Date().timeIntervalSince1970, forKey: "UpdateTabsAt")
    }

    /// The tabs kept by the quit before an update, once, if this start is that update's (another version, soon after).
    func takeUpdateTabs() -> [String] {
        guard persist else { return [] }
        defer { for k in ["UpdateTabs", "UpdateTabsVersion", "UpdateTabsAt"] { d.removeObject(forKey: k) } }
        guard let v = d.string(forKey: "UpdateTabsVersion"), v != appVersion,
              abs(Date().timeIntervalSince1970 - d.double(forKey: "UpdateTabsAt")) < 600 else { return [] }
        return d.stringArray(forKey: "UpdateTabs") ?? []
    }

    func save() {
        guard persist, !loading else { return }
        let values: [String: Any] = [
            "Lang": lang, "Theme": theme, "Accent": accent, "Mode": mode, "Spell": spell, "SpellLangs": spellLangs, "SpellWords": spellWords, "PreviewTab": previewTab, "AutoSave": autoSave, "ReadOnly": readOnly,
            "Zoom": zoom, "Sidebar": sidebar, "FilesPanel": filesPanel, "OutlinePanel": outlinePanel, "FilesSide": filesSide,
            "OutlineSide": outlineSide, "LeftArrange": leftArrange, "RightArrange": rightArrange, "OutlineFirst": outlineFirst,
            "LayoutWidths": layoutWidths, "OutlineShare": outlineShare, "OutlineShareColumns": outlineShareColumns, "TextWidth": textWidth, "TreeLocked": treeLocked, "SearchMode": searchMode, "Recent": recent, "RecentFolders": recentFolders, "SampleHidden": sampleHidden, "Folders": folders, "SampleShown": sampleShown,
            "PinnedFolders": pinned, "StartupFolders": startupFolders, "FolderSort": folderSort, "FolderColors": folderColors,
            "FolderColorMap": folderColorMap, "Favorites": favorites, "RecentPanel": recentPanel,
            "RestoreTabs": restoreTabs, "OpenTabs": openTabs, "ActiveTab": activeTab,
        ]
        for (k, v) in values { d.set(v, forKey: k) }
    }

    static let defaultSidebar = 260.0, defaultColumns = 520.0, defaultShare = 0.45   // a double click on a divider
    static let sidebarRange = 180.0...700.0
    static func clampWidth(_ w: Double) -> Double { min(max(w, sidebarRange.lowerBound), sidebarRange.upperBound) }

    /// Where the panes go, read from the settings. Up to 3.0 there were three layouts ("SideLayout": stacked,
    /// columns, right), each with its width: they are turned into the new values once, and the old keys removed.
    static func layoutValues(_ d: UserDefaults) -> (filesSide: String, outlineSide: String, leftArrange: String,
                                                    rightArrange: String, outlineFirst: Bool, widths: [String: Double]) {
        func side(_ k: String) -> String { d.string(forKey: k) == "right" ? "right" : "left" }
        func arrange(_ k: String) -> String { d.string(forKey: k) == "cols" ? "cols" : "rows" }
        if d.string(forKey: "FilesSide") != nil {
            return (side("FilesSide"), side("OutlineSide"), arrange("LeftArrange"), arrange("RightArrange"),
                    d.bool(forKey: "OutlineFirst"), (d.dictionary(forKey: "LayoutWidths") as? [String: Double]) ?? [:])
        }
        let old = d.string(forKey: "SideLayout") ?? "stacked"
        let outline = old == "right" ? "right" : "left", left = old == "columns" ? "cols" : "rows"
        var w: [String: Double] = [:]
        if let x = d.object(forKey: "SidebarWidth") as? Double { w["left:files+outline:rows"] = x; w["left:files"] = x }
        if let x = d.object(forKey: "SidebarWidthColumns") as? Double { w["left:files+outline:cols"] = x }
        if let x = d.object(forKey: "OutlineWidthRight") as? Double { w["right:outline"] = x }
        for (k, v) in ["FilesSide": "left", "OutlineSide": outline, "LeftArrange": left, "RightArrange": "rows"] { d.set(v, forKey: k) }
        d.set(w, forKey: "LayoutWidths")
        for k in ["SideLayout", "SidebarWidth", "SidebarWidthColumns", "OutlineWidthRight"] { d.removeObject(forKey: k) }
        return ("left", outline, left, "rows", false, w)
    }

    /// Whether any pane is shown.
    var panesShown: Bool { sidebar && (filesPanel || outlinePanel) }

    /// ⇧⌘E and the toolbar button: hides the panes, or shows them (both, if both had been turned off).
    func togglePanes() {
        if panesShown { sidebar = false } else { showPanes() }
    }

    func showPanes() {
        sidebar = true
        if !filesPanel && !outlinePanel { filesPanel = true; outlinePanel = true }
    }

    /// What needs the Files panel (a folder opened, the search box) shows it.
    func showFiles() { sidebar = true; filesPanel = true }

    /// The layout panel's switches: one pane on or off.
    func togglePane(_ p: Pane) {
        let on = sidebar && (p == .files ? filesPanel : outlinePanel)
        if !sidebar { sidebar = true; filesPanel = false; outlinePanel = false }
        if p == .files { filesPanel = !on } else { outlinePanel = !on }
    }
    static func clampShare(_ s: Double) -> Double { min(max(s, 0.1), 0.9) }
    static let columnsRange = 360.0...1000.0       // the sidebar with Files and Contents side by side
    static func clampColumns(_ w: Double) -> Double { min(max(w, columnsRange.lowerBound), columnsRange.upperBound) }

    /// The first time, Spanish or Japanese if the Mac speaks it, English otherwise.
    static var macLanguage: String {
        let first = Locale.preferredLanguages.first ?? ""
        return first.hasPrefix("es") ? "es" : first.hasPrefix("ja") ? "ja" : "en"
    }

    /// What the panel opens with at start: the folders of the last session (pinned ones included), none, or
    /// only the pinned ones. Pinned folders stay pinned when they are not opened.
    func applyStartupFolders() {
        pinned.removeAll { $0.isEmpty }
        switch startupFolders {
        case "clean": folders = []
        case "pinned": folders = pinned
        default: for p in pinned where !folders.contains(p) { folders.append(p) }
        }
    }

    func isPinned(_ dir: String) -> Bool { pinned.contains(dir) }

    func togglePin(_ dir: String) {
        if isPinned(dir) { pinned.removeAll { $0 == dir } } else { pinned.append(dir) }
    }

    /// Closing a folder also unpins it and forgets its colour (as on Windows).
    func closeFolder(_ dir: String) {
        folders.removeAll { $0 == dir }
        pinned.removeAll { $0 == dir }
        folderColorMap[dir] = nil
    }

    /// Swaps a folder with its neighbour in the opening order; the order goes back to "order opened".
    func moveFolder(_ dir: String, by delta: Int) {
        guard let i = folders.firstIndex(of: dir), folders.indices.contains(i + delta) else { return }
        folders.swapAt(i, i + delta)
        folderSort = "opened"
    }

    /// Pinned folders first, in the order they were pinned, then the rest by the chosen order.
    var orderedFolders: [String] {
        let top = pinned.filter { folders.contains($0) }
        let rest = folders.filter { !top.contains($0) }
        let name = { (p: String) in (p as NSString).lastPathComponent }
        let sorted: [String]
        switch folderSort {
        case "az": sorted = rest.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case "za": sorted = rest.sorted { name($0).localizedStandardCompare(name($1)) == .orderedDescending }
        case "modified":
            let date = { (p: String) in ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast }
            sorted = rest.sorted { date($0) > date($1) }
        default: sorted = rest
        }
        return top + sorted
    }

    /// The colour of an open folder: chosen by hand, or tones of the theme colour, or spread around the colour
    /// wheel (multicolour), as on Windows. Its place in the opening order keeps it the same when the order changes.
    /// nil when folders have no colour.
    func folderTint(_ dir: String) -> (fill: Color, edge: Color)? {
        guard folderColors != "none" else { return nil }
        let i = max(0, folders.firstIndex(of: dir) ?? 0)
        let (ah, asat, _) = Prefs.hsl(Accent.get(accent).light)
        var grey = false
        let hue: Double
        if let manual = folderColorMap[dir] { hue = manual }
        else if folderColors == "multi" { hue = (ah + Double(i) * 137.508).truncatingRemainder(dividingBy: 360) }
        else {
            grey = asat < 0.15        // black and white themes: shades of grey
            let steps: [Double] = [0, 22, -22, 44, -44, 66, -66, 11, -11, 33, -33]
            hue = (ah + steps[i % steps.count] + 360).truncatingRemainder(dividingBy: 360)
        }
        let s = grey ? 0.0 : 1.0
        let fill = dark ? Prefs.color(hue, 0.30 * s, grey ? 0.17 + Double(i % 4) * 0.025 : 0.20)
                        : Prefs.color(hue, 0.65 * s, grey ? 0.95 - Double(i % 4) * 0.02 : 0.94)
        let edge = dark ? Prefs.color(hue, 0.55 * s, grey ? 0.55 : 0.62) : Prefs.color(hue, 0.55 * s, grey ? 0.55 : 0.58)
        return (fill, edge)
    }

    /// The twelve colours of the Colour menu: hue every 30 degrees.
    static let folderHues: [(hue: Double, en: String, es: String, ja: String)] = [
        (0, "Red", "Rojo", "赤"), (30, "Orange", "Naranja", "オレンジ"), (60, "Yellow", "Amarillo", "黄"),
        (90, "Lime", "Lima", "ライム"), (120, "Green", "Verde", "緑"), (150, "Mint", "Menta", "ミント"),
        (180, "Cyan", "Cian", "シアン"), (210, "Sky", "Celeste", "スカイブルー"), (240, "Blue", "Azul", "青"),
        (270, "Violet", "Violeta", "バイオレット"), (300, "Purple", "Morado", "紫"), (330, "Pink", "Rosa", "ピンク"),
    ]

    /// The text of the app's language among the three versions.
    static func pick(_ en: String, _ es: String, _ ja: String) -> String {
        switch shared.lang { case "es": return es; case "ja": return ja; default: return en }
    }

    /// The languages of the interface, in the order of the Language menu.
    static let languages = [("en", "English"), ("es", "Español"), ("ja", "日本語")]

    /// A language code the app knows ("en", "es" or "ja"); anything else is English.
    static func language(_ code: String?) -> String { ["es", "ja"].contains(code ?? "") ? code! : "en" }

    static func hsl(_ rgb: UInt32) -> (h: Double, s: Double, l: Double) {
        let r = Double(rgb >> 16 & 0xFF) / 255, g = Double(rgb >> 8 & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
        guard d > 1e-9 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
        h *= 60
        return (h, s, l)
    }

    static func color(_ h: Double, _ s: Double, _ l: Double) -> Color {
        let c = (1 - abs(2 * l - 1)) * s, hp = h / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return Color(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: 1)
    }

    func addRecent(_ path: String) {
        var r = recent.filter { $0 != path }
        r.insert(path, at: 0)
        recent = Array(r.prefix(12))
    }

    /// File → Open recent and the recent folders follow a rename or a move from the Files panel (FileOps).
    func follow(from: String, to: String, isDir: Bool) {
        func map(_ p: String) -> String {
            if p.lowercased() == from.lowercased() { return to }
            if isDir, p.lowercased().hasPrefix(from.lowercased() + "/") { return to + p.dropFirst(from.count) }
            return p
        }
        func dedup(_ a: [String]) -> [String] { var seen = Set<String>(); return a.filter { seen.insert($0.lowercased()).inserted } }
        let r = dedup(recent.map(map)), f = dedup(recentFolders.map(map)), fav = dedup(favorites.map(map))
        if r != recent { recent = r }
        if f != recentFolders { recentFolders = f }
        if fav != favorites { favorites = fav }
    }

    // MARK: favourites (one list for every folder of the panel, shown as its first block)

    func isFavorite(_ path: String) -> Bool { favorites.contains { $0.lowercased() == path.lowercased() } }

    func toggleFavorite(_ path: String) {
        if isFavorite(path) { favorites.removeAll { $0.lowercased() == path.lowercased() } } else { favorites.append(path) }
    }

    /// A favourite is a folder when it is one on disk, or when it is gone and its name has no Markdown extension.
    static func favIsDir(_ path: String) -> Bool {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &dir) { return dir.boolValue }
        return !["md", "markdown", "mdown", "mkd", "txt"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// As shown: folders first, then files, each in the list's order.
    var favoritesShown: [String] { favorites.filter(Prefs.favIsDir) + favorites.filter { !Prefs.favIsDir($0) } }

    /// Up or down among the favourites of the same kind.
    func moveFavorite(_ path: String, by delta: Int) {
        var shown = favoritesShown
        guard let i = shown.firstIndex(where: { $0.lowercased() == path.lowercased() }) else { return }
        let j = i + delta
        guard shown.indices.contains(j), Prefs.favIsDir(shown[i]) == Prefs.favIsDir(shown[j]) else { return }
        shown.swapAt(i, j)
        favorites = shown
    }

    /// A favourite dragged onto another one takes its place.
    func moveFavorite(_ path: String, onto target: String) {
        var shown = favoritesShown
        guard let from = shown.firstIndex(where: { $0.lowercased() == path.lowercased() }),
              let to = shown.firstIndex(where: { $0.lowercased() == target.lowercased() }), from != to else { return }
        let item = shown.remove(at: from)
        shown.insert(item, at: to)
        favorites = shown
    }

    func sortFavorites() {
        favorites = favoritesShown.sorted {
            let a = Prefs.favIsDir($0), b = Prefs.favIsDir($1)
            if a != b { return a }
            return URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1).lastPathComponent) == .orderedAscending
        }
    }

    func removeMissingFavorites() { favorites = favorites.filter { FileManager.default.fileExists(atPath: $0) } }

    // MARK: appearance

    func applyAppearance() {
        switch theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        refreshDark()
    }

    func refreshDark() {
        let isDark = theme == "dark" || (theme == "auto" &&
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if isDark != dark { dark = isDark }
    }

    func applyDockIcon() {
        if let img = Accent.get(accent).icon { NSApp.applicationIconImage = img }
    }

    var highlight: Color { Accent.get(accent).color(dark: dark) }
}

/// The text for `key` in the app's language; {0}, {1}… are replaced by `args`.
func L(_ key: String, _ args: CustomStringConvertible...) -> String {
    let row = STRINGS[key] ?? [key, key, key]
    let lang = Prefs.shared.lang
    var s = lang == "es" ? row[1] : lang == "ja" && row.count > 2 ? row[2] : row[0]
    for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: a.description) }
    return s
}

/// The twelve theme colours of the Windows version: the icon background (icono/accents/<key>.png,
/// made by tools/make_icons.py) and the highlight for the light and the dark chrome.
struct Accent {
    let key, en, es, ja: String
    let light, dark: UInt32

    var name: String { Prefs.pick(en, es, ja) }

    func color(dark isDark: Bool) -> Color {
        let v = isDark ? dark : light
        return Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    var icon: NSImage? {
        guard let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "accents") else { return nil }
        return NSImage(contentsOf: url)
    }

    static let all: [Accent] = [
        Accent(key: "gold", en: "Gold", es: "Dorado", ja: "ゴールド", light: 0x9A6F00, dark: 0xE2B84C),
        Accent(key: "purple", en: "Purple", es: "Morado", ja: "紫", light: 0x5B2A86, dark: 0xB392E0),
        Accent(key: "sky", en: "Sky blue", es: "Celeste", ja: "スカイブルー", light: 0x1A8CD8, dark: 0x5CB8F0),
        Accent(key: "ember", en: "Orange", es: "Naranja", ja: "オレンジ", light: 0xD9652F, dark: 0xF08A5D),
        Accent(key: "red", en: "Red", es: "Rojo", ja: "赤", light: 0xC8102E, dark: 0xF2545B),
        Accent(key: "yellow", en: "Yellow", es: "Amarillo", ja: "黄", light: 0xB88A00, dark: 0xF5C842),
        Accent(key: "green", en: "Green", es: "Verde", ja: "緑", light: 0x1E8A43, dark: 0x4CC27A),
        Accent(key: "teal", en: "Teal", es: "Verde azulado", ja: "ティール", light: 0x00796B, dark: 0x4DB6AC),
        Accent(key: "blue", en: "Blue", es: "Azul", ja: "青", light: 0x1F5FD1, dark: 0x6E9BFF),
        Accent(key: "pink", en: "Pink", es: "Rosa", ja: "ピンク", light: 0xC2185B, dark: 0xF06292),
        Accent(key: "black", en: "Black", es: "Negro", ja: "黒", light: 0x1D1D1F, dark: 0xC7C7CC),
        Accent(key: "white", en: "White", es: "Blanco", ja: "白", light: 0x8E8E93, dark: 0xF5F5F7),
    ]

    static let defaultKey = "sky"     // the lighthouse against the sky (3.1.0; gold before)
    static func get(_ key: String) -> Accent { all.first { $0.key == key } ?? all.first { $0.key == defaultKey }! }
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
let appRepo = "Gabriel-Castiglia/vigia"
