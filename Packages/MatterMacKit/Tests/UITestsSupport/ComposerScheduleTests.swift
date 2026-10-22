import Foundation
import Testing
import AppKit
@testable import MatterMacUI
import MatterMacCore
import MatterMacModels

/// «Send later» в композере (ADR 0052): кнопка часов, меню пресетов и пикер
/// даты сводятся к одному входу — `requestSchedule(at:)`, который проходит те же
/// проверки, что и обычная отправка, и отдаёт текст хосту с датой срабатывания.
@Suite("Composer schedule")
struct ComposerScheduleTests {
    @Test @MainActor func requestScheduleDelegatesTheTextWithTheChosenDate() async throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.isSchedulingAvailable = true
        h.type("at dawn")
        await h.endEvent()
        let fire = Date().addingTimeInterval(900)
        h.controller.requestSchedule(at: fire)
        #expect(h.spy.schedules.count == 1)
        #expect(h.spy.schedules.first?.text == "at dawn")
        #expect(h.spy.schedules.first?.fireAt == fire)
        #expect(h.spy.sentTexts.isEmpty)
    }

    @Test @MainActor func emptyComposerDoesNotScheduleAndPastDateIsRefused() async throws {
        let h = ComposerHarness()
        defer { h.close() }
        h.controller.isSchedulingAvailable = true
        // Пустое поле — как у обычной отправки: делегат не вызывается.
        h.controller.requestSchedule(at: Date().addingTimeInterval(900))
        #expect(h.spy.schedules.isEmpty)
        h.type("later note")
        await h.endEvent()
        h.controller.requestSchedule(at: Date().addingTimeInterval(-10))
        #expect(h.spy.schedules.isEmpty)
        #expect(h.controller.notice == "Pick a time in the future.")
    }

    @Test @MainActor func clockButtonFollowsAvailabilityAndEditMode() async throws {
        let h = ComposerHarness()
        defer { h.close() }
        // По умолчанию расписание выключено хостом (пересылка и т.п.).
        #expect(h.controller.scheduleButton.isHidden)
        h.controller.isSchedulingAvailable = true
        #expect(!h.controller.scheduleButton.isHidden)
        #expect(h.controller.scheduleButton.isEnabled == false) // поле пустое
        // В режиме правки расписание не имеет смысла.
        h.controller.mode = .edit(postID: PostID(unchecked: "postpostpostpostpostpostpost"),
                                  original: "later note")
        #expect(h.controller.scheduleButton.isHidden)
        h.controller.mode = .compose
        #expect(!h.controller.scheduleButton.isHidden)
    }
}
