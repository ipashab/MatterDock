import AppKit

/// Markdown formatting commands for the composer (⌘B, ⌘I, ⇧⌘X, ⌥⌘C, ⌥⌘K and the
/// Format menu). Edits go through `insertText(_:replacementRange:)`, so the draft
/// budget, undo history and input-method rules apply exactly as for typing.
extension ComposerTextView {
    enum MarkdownStyle: CaseIterable {
        case bold, italic, strikethrough, code, link, quote

        var marker: String {
            switch self {
            case .bold: "**"
            case .italic: "_"
            case .strikethrough: "~~"
            case .code: "`"
            case .link, .quote: ""
            }
        }
    }

    @objc func formatBold(_ sender: Any?) { applyMarkdown(.bold) }
    @objc func formatItalic(_ sender: Any?) { applyMarkdown(.italic) }
    @objc func formatStrikethrough(_ sender: Any?) { applyMarkdown(.strikethrough) }
    @objc func formatCode(_ sender: Any?) { applyMarkdown(.code) }
    @objc func formatLink(_ sender: Any?) { applyMarkdown(.link) }
    @objc func formatQuote(_ sender: Any?) { applyMarkdown(.quote) }

    /// Line-prefix formatting (headings, lists). Adds the marker to every line of
    /// the selection (the caret's line when nothing is selected) or removes it when
    /// every line already carries the family's marker.
    enum LineMarkerStyle {
        case heading(Int)
        case ordered
        case bullet

        /// Префикс строки с номером строчки (с нуля) — нумерованный список считает заново.
        func prefix(index: Int) -> String {
            switch self {
            case .heading(let level): String(repeating: "#", count: level) + " "
            case .ordered: "\(index + 1). "
            case .bullet: "- "
            }
        }

        /// Строка уже помечена этим точным маркером (снятие — только точное
        /// совпадение; другой уровень заголовка переключает, а не снимает).
        func isPresent(in line: String) -> Bool {
            switch self {
            case .heading(let level): line.hasPrefix(String(repeating: "#", count: level) + " ")
            case .ordered: line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            case .bullet: line.hasPrefix("- ")
            }
        }

        /// Строка без маркеров этого семейства: заголовки снимаются любым
        /// уровнем, списки — взаимозаменяемы (нумерация и «- » соседи).
        func stripped(line: String) -> String {
            var rest = line
            switch self {
            case .heading:
                if let range = rest.range(of: #"^#{1,6} "#, options: .regularExpression) {
                    rest = String(rest[range.upperBound...])
                }
            case .ordered, .bullet:
                if let range = rest.range(of: #"^\d+\. "#, options: .regularExpression) {
                    rest = String(rest[range.upperBound...])
                }
                if rest.hasPrefix("- ") { rest = String(rest.dropFirst(2)) }
            }
            return rest
        }
    }

    /// Toggle line markers over the whole lines touched by the selection.
    func applyLineMarkers(_ style: LineMarkerStyle) {
        guard isEditable, !hasMarkedText() else { NSSound.beep(); return }
        breakUndoCoalescing()
        defer { breakUndoCoalescing() }
        let selected = selectedRange()
        let text = string as NSString
        guard selected.location != NSNotFound, NSMaxRange(selected) <= text.length else { return }
        // Расширенный диапазон — целые строки от начала первой до конца последней.
        var start = selected.location
        while start > 0, text.character(at: start - 1) != 0x0A { start -= 1 }
        var end = NSMaxRange(selected)
        while end < text.length, text.character(at: end) != 0x0A { end += 1 }
        let linesRange = NSRange(location: start, length: end - start)
        let lines = text.substring(with: linesRange).components(separatedBy: "\n")
        let remove = !lines.isEmpty && lines.allSatisfy { style.isPresent(in: $0) }
        let transformed = lines.enumerated().map { index, line -> String in
            guard !line.isEmpty else { return line }
            if remove { return style.stripped(line: line) }
            return style.prefix(index: index) + style.stripped(line: line)
        }
        let replacement = transformed.joined(separator: "\n")
        let before = string
        insertText(replacement, replacementRange: linesRange)
        if string != before {
            setSelectedRange(NSRange(location: start, length: (replacement as NSString).length))
        }
    }

    /// Maps a key equivalent to a style (only plain Command/Shift/Option chords).
    static func markdownStyle(for event: NSEvent) -> MarkdownStyle? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch (modifiers, key) {
        case (.command, "b"): return .bold
        case (.command, "i"): return .italic
        case ([.command, .shift], "x"): return .strikethrough
        case ([.command, .option], "c"), ([.command, .option], "ç"): return .code
        case ([.command, .option], "k"), ([.command, .option], "˚"): return .link
        default: return nil
        }
    }

    /// Wraps the selection (or toggles an existing wrap). With no selection, inserts
    /// the markers and places the caret between them.
    func applyMarkdown(_ style: MarkdownStyle) {
        guard isEditable, !hasMarkedText() else { NSSound.beep(); return }
        // Each formatting command is its own undo step.
        breakUndoCoalescing()
        defer { breakUndoCoalescing() }
        let range = selectedRange()
        let text = string as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return }
        let selected = text.substring(with: range)
        let replacement: String
        let newSelection: NSRange
        let before = string

        switch style {
        case .bold, .italic, .strikethrough, .code:
            var marker = style.marker
            if style == .code, selected.contains("\n") {
                marker = "```"
                let body = "\n" + selected + (selected.hasSuffix("\n") ? "" : "\n")
                replacement = marker + body + marker
                newSelection = NSRange(location: range.location + 4, length: (selected as NSString).length)
                break
            }
            let length = (marker as NSString).length
            // Toggle off when the selection is already wrapped by the markers.
            if range.location >= length, NSMaxRange(range) + length <= text.length,
               text.substring(with: NSRange(location: range.location - length, length: length)) == marker,
               text.substring(with: NSRange(location: NSMaxRange(range), length: length)) == marker {
                let outer = NSRange(location: range.location - length, length: range.length + 2 * length)
                insertText(selected, replacementRange: outer)
                if string != before { setSelectedRange(NSRange(location: outer.location, length: range.length)) }
                return
            }
            replacement = marker + selected + marker
            newSelection = NSRange(location: range.location + length, length: range.length)
        case .link:
            let label = selected.isEmpty ? String(localized: "text") : selected
            replacement = "[" + label + "](url)"
            let urlStart = range.location + 1 + (label as NSString).length + 2
            newSelection = NSRange(location: urlStart, length: 3)
        case .quote:
            let lines = selected.isEmpty ? [""] : selected.components(separatedBy: "\n")
            replacement = lines.map { "> " + $0 }.joined(separator: "\n")
            newSelection = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        }
        insertText(replacement, replacementRange: range)
        // A refused edit (draft budget) leaves the text unchanged; keep the selection.
        if string != before { setSelectedRange(newSelection) }
    }
}
