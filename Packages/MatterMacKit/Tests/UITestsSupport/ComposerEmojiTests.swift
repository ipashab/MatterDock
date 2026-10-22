import AppKit
import Testing
@testable import MatterMacUI

/// Эмодзи-кнопка композера: пикер открывается над полем, выбор вставляет
/// «:name: » в каретку одним undoable действием; без провайдера кнопка скрыта.
@MainActor
@Suite("Composer emoji button")
struct ComposerEmojiTests {
    @Test func emojiButtonFollowsTheProviderAndPicksInsertNames() throws {
        let h = ComposerHarness()
        defer { h.close() }
        // Без провайдера кнопки нет.
        #expect(h.controller.emojiButton.isHidden)
        #expect(!h.controller.isEmojiPickerShown)

        var shownPickers = 0
        h.controller.emojiPickerProvider = {
            shownPickers += 1
            return ReactionPickerViewController()
        }
        #expect(!h.controller.emojiButton.isHidden)

        h.controller.toggleEmojiPicker(nil)
        #expect(shownPickers == 1)
        #expect(h.controller.isEmojiPickerShown)

        // Повторный вызов закрывает, не собирая новый пикер.
        h.controller.toggleEmojiPicker(nil)
        #expect(!h.controller.isEmojiPickerShown)
        #expect(shownPickers == 1)

        h.type("hi ")
        endEvent(h)
        h.controller.toggleEmojiPicker(nil)
        #expect(h.controller.isEmojiPickerShown)
        let picker = try #require((h.controller.emojiPopoverForTesting?.contentViewController) as? ReactionPickerViewController)
        picker.pick(at: IndexPath(item: 1, section: 0))
        #expect(h.text == "hi :smile: ")
        #expect(!h.controller.isEmojiPickerShown, "после выбора пикер закрыт")
        endEvent(h)
        h.textView.undo(nil)
        #expect(h.text == "hi ", "вставка эмодзи — один шаг undo")
    }

    private func endEvent(_ h: ComposerHarness) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
