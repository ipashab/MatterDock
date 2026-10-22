import AppKit
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Composer Markdown formatting")
struct ComposerFormattingTests {
    /// Undo groups by event; let the run loop close each group as real events would.
    private func endEvent() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    @Test func wrapsTogglesAndUndoes() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("make this bold")
        endEvent()
        h.textView.setSelectedRange(NSRange(location: 10, length: 4))
        h.textView.applyMarkdown(.bold)
        endEvent()
        #expect(h.text == "make this **bold**", "\(h.text)")
        #expect(h.textView.selectedRange() == NSRange(location: 12, length: 4))
        // Applying again removes the markers.
        h.textView.applyMarkdown(.bold)
        #expect(h.text == "make this bold")
        endEvent()
        h.textView.undo(nil)
        #expect(h.text == "make this **bold**", "\(h.text)")
    }

    @Test func emptySelectionLinkQuoteAndCodeBlock() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.textView.applyMarkdown(.italic)
        #expect(h.text == "__")
        #expect(h.textView.selectedRange() == NSRange(location: 1, length: 0))
        h.textView.setSelectedRange(NSRange(location: 0, length: (h.text as NSString).length))
        h.type("docs")
        h.textView.setSelectedRange(NSRange(location: 0, length: 4))
        h.textView.applyMarkdown(.link)
        #expect(h.text == "[docs](url)")
        #expect(h.textView.selectedRange() == NSRange(location: 7, length: 3))
        h.textView.setSelectedRange(NSRange(location: 0, length: (h.text as NSString).length))
        h.type("a\nb")
        h.textView.setSelectedRange(NSRange(location: 0, length: 3))
        h.textView.applyMarkdown(.quote)
        #expect(h.text == "> a\n> b")
        h.textView.setSelectedRange(NSRange(location: 0, length: (h.text as NSString).length))
        h.type("x = 1\ny = 2")
        h.textView.setSelectedRange(NSRange(location: 0, length: 11))
        h.textView.applyMarkdown(.code)
        #expect(h.text == "```\nx = 1\ny = 2\n```")
    }

    @Test func keyEquivalentsMapToStyles() throws {
        func event(_ key: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        }
        #expect(ComposerTextView.markdownStyle(for: event("b", .command)) == .bold)
        #expect(ComposerTextView.markdownStyle(for: event("x", [.command, .shift])) == .strikethrough)
        #expect(ComposerTextView.markdownStyle(for: event("k", [.command, .option])) == .link)
        #expect(ComposerTextView.markdownStyle(for: event("k", .command)) == nil)
    }

    /// Маркеры-строки: заголовки включаются, меняют уровень и снимаются.
    @Test func headingMarkersToggleAndSwitchLevels() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("title\nplain")
        endEvent()
        h.textView.setSelectedRange(NSRange(location: 0, length: 5))
        h.textView.applyLineMarkers(.heading(1))
        endEvent()
        #expect(h.text == "# title\nplain")
        // Выделена строка заголовка: H2 меняет уровень, а не снимает.
        h.textView.setSelectedRange(NSRange(location: 0, length: 7))
        h.textView.applyLineMarkers(.heading(2))
        endEvent()
        #expect(h.text == "## title\nplain")
        h.textView.applyLineMarkers(.heading(2))
        endEvent()
        #expect(h.text == "title\nplain")
        h.textView.undo(nil)
        #expect(h.text == "## title\nplain", "снятие маркеров — один шаг undo")
    }

    /// Списки: нумерация целыми строками одной операцией, снятие повтором.
    @Test func listMarkersRenumberAndToggle() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("alpha\nbeta\ngamma")
        endEvent()
        h.textView.setSelectedRange(NSRange(location: 0, length: 17))
        h.textView.applyLineMarkers(.ordered)
        #expect(h.text == "1. alpha\n2. beta\n3. gamma")
        h.textView.applyLineMarkers(.ordered)
        #expect(h.text == "alpha\nbeta\ngamma")
        h.textView.applyLineMarkers(.bullet)
        #expect(h.text == "- alpha\n- beta\n- gamma")
        h.textView.applyLineMarkers(.bullet)
        #expect(h.text == "alpha\nbeta\ngamma")
        // Курсор без выделения — маркируется строка каретки.
        h.textView.setSelectedRange(NSRange(location: 6, length: 0))
        h.textView.applyLineMarkers(.bullet)
        #expect(h.text == "alpha\n- beta\ngamma")
    }

    /// Выделение выживает: маркеры накатываются на целые строки, курсор остаётся
    /// внутри размеченного куска.
    @Test func lineMarkersKeepSelectionOverWholeLines() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("one\ntwo three")
        h.textView.setSelectedRange(NSRange(location: 4, length: 3)) // «two»
        h.textView.applyLineMarkers(.ordered)
        #expect(h.text == "one\n1. two three")
        #expect(h.textView.selectedRange() == NSRange(location: 4, length: 12),
                "выделенными становятся целые строки")
    }
}
