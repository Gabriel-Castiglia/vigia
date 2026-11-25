// Vigia: spell check, several languages at once (3.3.1, as Windows 3.3.0): the page marks the words the app reports.
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 25, 2026
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

/// A word is right when any chosen language knows it, so a text that mixes languages is checked as a whole. The
/// checking is the Mac's own (NSSpellChecker), language by language: WebKit's checker follows one language at a time
/// and has no ignore list, so it is off in the page (app.js) and the page asks here instead. Windows uses Hunspell
/// dictionaries for the same thing (SpellChecker.cs); the languages here are the ones macOS has, plus:
/// - "es-UY", the Spanish of Uruguay: the Mac's Spanish marks every verb of the voseo ("tenés", "mirá"), so a word it
///   does not know is tried as the vosotros form the voseo comes from (tenéis, mirad; decíselo = decid + se + lo).
/// - "ja": there is no Japanese spelling dictionary; Japanese text is never marked.
@MainActor
enum Spell {
    private static let checker = NSSpellChecker.shared
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()
    /// Ignore: until Vigía closes, in every tab.
    static var session = Set<String>()
    /// What each language said of a word: the same words come back from every tab and every redraw.
    private static var known: [String: [String: Bool]] = [:]

    nonisolated static let defaultLanguages = ["en", "es", "es-UY", "ja"]

    /// Every language that can be chosen: the chosen ones first (in their order), then the Mac's, then Japanese.
    static func available(chosen: [String]) -> [String] {
        var out = ["en", "es", "es-UY"]
        for l in checker.availableLanguages where !out.contains(l) { out.append(l) }
        out.append("ja")
        return chosen.filter(out.contains) + out.filter { !chosen.contains($0) }
    }

    /// The name of a language in the interface's language.
    static func name(_ code: String) -> String {
        switch code {
        case "en": return L("SpellLangen")
        case "es": return L("SpellLanges")
        case "es-UY": return L("SpellLanges-UY")
        case "ja": return L("SpellLangja")
        default:
            let ui = Locale(identifier: Prefs.shared.lang)
            return ui.localizedString(forIdentifier: code)?.capitalized(with: ui) ?? code
        }
    }

    /// Words in Japanese (or Chinese) script, numbers and single letters are never marked.
    static func skip(_ w: String) -> Bool {
        w.count < 2 || w.contains(where: \.isNumber) || w.unicodeScalars.contains {
            (0x3000 ... 0x9FFF).contains($0.value) || (0xF900 ... 0xFAFF).contains($0.value) || (0xFF00 ... 0xFFEF).contains($0.value)
        }
    }

    private static func knows(_ w: String, _ lang: String) -> Bool {
        if let k = known[lang]?[w] { return k }
        let k: Bool
        if lang == "es-UY" { k = knows(w, "es") || voseo(w).contains { knows($0, "es") } }
        else {
            k = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: tag,
                                      wordCount: nil).location == NSNotFound
        }
        known[lang, default: [:]][w] = k
        return k
    }

    /// The vosotros forms a word of the voseo comes from: present (tenés → tenéis, hablás → habláis, sos → sois) and
    /// imperative (mirá → mirad, poné → poned, decí → decid), also with pronouns after it (decíselo → decid, mirala →
    /// mirad, contame → contad). Measured with the Mac's Spanish on 25-nov-2026: every one of those is then right, and
    /// "cafe" or "xqzwrt" are still marked.
    nonisolated static func voseo(_ w: String) -> [String] {
        let l = w.lowercased()
        var out: [String] = []
        for (end, vos) in [("ás", "áis"), ("és", "éis")] where l.hasSuffix(end) && l.count > 3 { out.append(String(l.dropLast(2)) + vos) }
        if l == "sos" { out.append("sois") }
        func imperative(_ s: String, accent: Bool) -> String? {
            let ends = accent ? [("á", "ad"), ("é", "ed"), ("í", "id")] : [("a", "ad"), ("e", "ed"), ("i", "id")]
            for (end, vos) in ends where s.hasSuffix(end) && s.count > 2 { return String(s.dropLast()) + vos }
            return nil
        }
        if let i = imperative(l, accent: true) { out.append(i) }
        let pronouns = ["selo", "sela", "selos", "selas", "melo", "mela", "melos", "melas", "telo", "tela", "noslo", "nosla",
                        "lo", "la", "los", "las", "le", "les", "me", "te", "se", "nos"]
        for p in pronouns where l.count > p.count + 2 && l.hasSuffix(p) {
            let stem = String(l.dropLast(p.count))
            if let i = imperative(stem, accent: true) ?? imperative(stem, accent: false) { out.append(i) }
        }
        return out
    }

    static func check(_ w: String, _ langs: [String], own: Set<String>) -> Bool {
        if skip(w) || own.contains(w) || session.contains(w) { return true }
        var any = false
        for l in langs where l != "ja" {
            any = true
            if knows(w, l) { return true }
        }
        return !any   // no language to check with: nothing is marked
    }

    /// The words no chosen language knows. The Mac's checker answers in ~0.12 ms a word and wants the main thread,
    /// so a long list is done in parts and the window keeps answering meanwhile.
    static func misspelled(_ words: [String], _ langs: [String], own: Set<String>) async -> [String] {
        var bad: [String] = [], seen = Set<String>()
        for (i, w) in words.enumerated() {
            if seen.insert(w).inserted, !check(w, langs, own: own) { bad.append(w) }
            if i % 300 == 299 { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        return bad
    }

    /// Suggestions from every chosen language, the best of each first, at most eight.
    static func suggest(_ w: String, _ langs: [String]) -> [String] {
        let range = NSRange(location: 0, length: (w as NSString).length)
        let per = langs.filter { $0 != "ja" }.map { l -> [String] in
            let lang = l == "es-UY" ? "es" : l
            return Array((checker.guesses(forWordRange: range, in: w, language: lang, inSpellDocumentWithTag: tag) ?? []).prefix(5))
        }
        var r: [String] = []
        for i in 0 ..< 5 where r.count < 8 { for s in per where i < s.count && !r.contains(s[i]) { r.append(s[i]) } }
        return Array(r.prefix(8))
    }

    /// Languages or the dictionary changed: every page asks for its words again.
    static func resetAll() {
        known.removeAll()
        for d in DocWindow.all { Task { await d.web.call("mdApp.spellReset()") } }
    }

    /// Ignore (until Vigía closes, in every tab) or Add to dictionary (kept in the settings of this Vigía).
    static func accept(_ word: String, permanent: Bool) {
        guard !word.isEmpty else { return }
        let prefs = Prefs.shared
        if permanent {
            if !prefs.spellWords.contains(word) {
                prefs.spellWords = (prefs.spellWords + [word]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
        } else { session.insert(word) }
        for d in DocWindow.all { Task { await d.web.call("mdApp.spellAccept(w)", ["w": word]) } }
    }

    /// On or off in every open tab (their text and undo history stay).
    static func setOn(_ on: Bool) {
        Prefs.shared.spell = on
        for d in DocWindow.all { Task { await d.applySpell() } }
    }

    /// The right-click menu of a marked word, where the pointer is: suggestions, Ignore, Add to dictionary.
    static func showMenu(for word: String, in doc: DocWindow) {
        let menu = NSMenu()
        let sug = suggest(word, Prefs.shared.spellLangs)
        for s in sug {
            let i = ClosureItem(s) { Task { await doc.web.call("mdApp.spellReplace(t)", ["t": s]) } }
            i.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            menu.addItem(i)
        }
        if sug.isEmpty { let i = NSMenuItem(title: L("SpellNoSuggestions"), action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        menu.addItem(.separator())
        menu.addItem(ClosureItem(L("SpellIgnore")) { accept(word, permanent: false) })
        menu.addItem(ClosureItem(L("SpellAdd")) { accept(word, permanent: true) })
        menu.addItem(.separator())
        menu.addItem(ClosureItem(L("SpellLangs")) { showDialog(in: doc.window) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Edit → Spell Check Languages and Dictionary…: on/off, the languages (several at once), and the words added to
    /// the dictionary (untick one to take it out).
    static func showDialog(in window: NSWindow?) {
        let prefs = Prefs.shared
        let a = NSAlert()
        a.messageText = L("SpellTitle")
        a.addButton(withTitle: L("SpellClose"))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let width: CGFloat = 400
        func wrap(_ s: String) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: s)
            t.preferredMaxLayoutWidth = width
            t.widthAnchor.constraint(equalToConstant: width).isActive = true
            return t
        }
        stack.addArrangedSubview(ClosureCheck(title: L("SpellOn"), on: prefs.spell) { setOn($0) })
        stack.addArrangedSubview(wrap(L("SpellLangsHint")))
        let langs = NSStackView()
        langs.orientation = .vertical
        langs.alignment = .leading
        for code in available(chosen: prefs.spellLangs) {
            langs.addArrangedSubview(ClosureCheck(title: name(code), on: prefs.spellLangs.contains(code)) { on in
                var l = prefs.spellLangs.filter { $0 != code }
                if on { l.append(code) }
                prefs.spellLangs = l
                resetAll()
            })
        }
        stack.addArrangedSubview(scroll(langs, width: width, height: 170))
        stack.addArrangedSubview(wrap(L("SpellWordsHintMac")))
        let words = NSStackView()
        words.orientation = .vertical
        words.alignment = .leading
        for w in prefs.spellWords {
            words.addArrangedSubview(ClosureCheck(title: w, on: true) { on in
                prefs.spellWords = on ? (prefs.spellWords + [w]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                                      : prefs.spellWords.filter { $0 != w }
                resetAll()
            })
        }
        if prefs.spellWords.isEmpty { words.addArrangedSubview(NSTextField(labelWithString: L("SpellNoWords"))) }
        stack.addArrangedSubview(scroll(words, width: width, height: 110))
        stack.frame.size = stack.fittingSize
        a.accessoryView = stack
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    private static func scroll(_ content: NSView, width: CGFloat, height: CGFloat) -> NSScrollView {
        let s = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        s.hasVerticalScroller = true
        s.borderType = .bezelBorder
        s.drawsBackground = false
        let flipped = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 6),
            content.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4),
        ])
        let size = content.fittingSize
        flipped.frame = NSRect(x: 0, y: 0, width: width - 20, height: max(height - 4, size.height + 8))
        s.documentView = flipped
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        s.heightAnchor.constraint(equalToConstant: height).isActive = true
        return s
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A check box that runs a closure with its new state.
final class ClosureCheck: NSButton {
    private let run: (Bool) -> Void
    init(title: String, on: Bool, _ run: @escaping (Bool) -> Void) {
        self.run = run
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = on ? .on : .off
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run(state == .on) }
}
