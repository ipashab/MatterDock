import AppKit
import Testing
@testable import MatterMacUI

/// Панель форматирования над полем: кнопки действуют на текст композера,
/// меню заголовка применяется по уровням, высота учтена в `preferredHeight`.
@MainActor
@Suite("Composer formatting toolbar")
struct ComposerToolbarTests {
    private func button(_ h: ComposerHarness, label: String) throws -> NSButton {
        let toolbar = try #require(h.controller.toolbar)
        return try #require(toolbar.arrangedSubviews.first {
            ($0 as? NSButton)?.accessibilityLabel() == label
        } as? NSButton)
    }

    @Test func toolbarSitsAboveTheInputAndCountsItsHeight() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.focus()
        h.controller.view.layoutSubtreeIfNeeded()
        let toolbar = try #require(h.controller.toolbar)
        #expect(!toolbar.isHidden)
        #expect(toolbar.frame.height == ComposerToolbarView.height)
        // Панель в общем стеке поля — строкой выше строки ввода.
        let stack = try #require(toolbar.superview as? NSStackView)
        let arranged = stack.arrangedSubviews
        let toolbarIndex = try #require(arranged.firstIndex(of: toolbar))
        let inputIndex = try #require(arranged.firstIndex {
            guard let row = $0 as? NSStackView else { return false }
            return row.arrangedSubviews.contains(h.controller.sendButton)
        })
        #expect(toolbarIndex < inputIndex, "панель выше строки ввода")
        #expect(arranged[toolbarIndex + 1] === arranged[inputIndex],
                "между панелью и строкой ввода нет скрытых строк")
    }

    @Test func buttonsFormatTheSelectionLikeKeyboardCommands() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("make holding bold")
        h.textView.setSelectedRange(NSRange(location: 13, length: 4))
        try button(h, label: "Bold").performClick(nil)
        #expect(h.text == "make holding **bold**")
        // Повторный клик — снять маркер (тот же форматтер, что и ⌘B).
        try button(h, label: "Bold").performClick(nil)
        #expect(h.text == "make holding bold")
    }

    @Test func listButtonsMarkWholeLines() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("first\nsecond")
        h.textView.setSelectedRange(NSRange(location: 0, length: 12))
        try button(h, label: "Bulleted List").performClick(nil)
        #expect(h.text == "- first\n- second")
        h.textView.setSelectedRange(NSRange(location: 0, length: 20))
        try button(h, label: "Numbered List").performClick(nil)
        #expect(h.text == "1. first\n2. second",
                "нумерованный список заменяет маркеры, а не складывает")
    }

    @Test func headingMenuAppliesLevelsH1ThroughH3() throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.type("chapter")
        let items = try #require(h.controller.toolbar).headingMenuItemsForTesting
        #expect(items.count == 3)
        h.textView.setSelectedRange(NSRange(location: 0, length: 7))
        let h2 = try #require(items.first { $0.tag == 2 })
        (h2.target as? NSObject)?.perform(h2.action, with: h2)
        #expect(h.text == "## chapter")
        let h1 = try #require(items.first { $0.tag == 1 })
        (h1.target as? NSObject)?.perform(h1.action, with: h1)
        #expect(h.text == "# chapter", "уровень меняется, а не складывается")
        let h3 = try #require(items.first { $0.tag == 3 })
        (h3.target as? NSObject)?.perform(h3.action, with: h3)
        #expect(h.text == "### chapter")
        // Повтор того же уровня — снять.
        (h3.target as? NSObject)?.perform(h3.action, with: h3)
        #expect(h.text == "chapter")
    }
}
