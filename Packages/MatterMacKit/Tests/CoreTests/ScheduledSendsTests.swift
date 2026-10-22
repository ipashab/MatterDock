import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import TestSupport

@Suite("Send schedule presets")
struct SendSchedulePresetTests {
    /// Фиксированный GMT-календарь: пресеты не зависят от зоны процесса.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func offsetsAreExactAndTomorrowStartsAtNine() {
        let now = Date(timeIntervalSince1970: 1_700_000_500) // 03:15 GMT, 14.11.2023
        #expect(SendSchedulePreset.fifteenMinutes.fireDate(after: now, calendar: calendar)
                == now.addingTimeInterval(900))
        #expect(SendSchedulePreset.thirtyMinutes.fireDate(after: now, calendar: calendar)
                == now.addingTimeInterval(1_800))
        #expect(SendSchedulePreset.oneHour.fireDate(after: now, calendar: calendar)
                == now.addingTimeInterval(3_600))
        let tomorrow = SendSchedulePreset.tomorrowMorning.fireDate(after: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: tomorrow)
        #expect(components == DateComponents(year: 2023, month: 11, day: 15, hour: 9, minute: 0))
    }

    @Test func queueReturnsDueItemsInFireOrderAndCancelsByID() {
        var queue = ScheduledSendQueue()
        let me = CoreFixtures.me.id
        let stamp = MattermostTimestamp(milliseconds: 1_700_000_000_000)
        let first = queue.makeID(user: me, now: stamp)
        let second = queue.makeID(user: me, now: stamp)
        #expect(first != second)
        let reservation = UnsentWorkLedger.Reservation(id: 1, bytes: 1)
        let channel = CoreFixtures.channel(1).id
        queue.append(makeSend(id: first, channel: channel, fireInMilliseconds: 120_000, reservation: reservation))
        queue.append(makeSend(id: second, channel: channel, fireInMilliseconds: 60_000, reservation: reservation))
        // Срок ещё не наступил.
        #expect(queue.due(now: stamp).isEmpty)
        #expect(queue.earliestFireAt?.milliseconds == stamp.milliseconds + 60_000)
        // Через минуту наступил только второй; порядок — по времени срабатывания.
        let due = queue.due(now: MattermostTimestamp(milliseconds: stamp.milliseconds + 60_000))
        #expect(due.map(\.scheduledID) == [second])
        // id 하나 режет только свою запись.
        #expect(queue.remove(first)?.scheduledID == first)
        #expect(queue.item(first) == nil)
        #expect(queue.items(for: .channel(channel)).count == 1)
        _ = queue.remove(second)
        #expect(queue.isEmpty && queue.removeAll().isEmpty)
    }

    private func makeSend(id: PendingPostID, channel: ChannelID, fireInMilliseconds: Int64,
                          reservation: UnsentWorkLedger.Reservation) -> ScheduledSend {
        ScheduledSend(scheduledID: id, channelID: channel, rootID: nil, message: "hello",
                      attachments: [], fireAt: MattermostTimestamp(milliseconds: 1_700_000_000_000 + fireInMilliseconds),
                      reservation: reservation)
    }
}

@Suite("Session schedules", .serialized)
struct ScheduledSessionTests {
    private func reserve(_ h: SessionHarness, _ bytes: Int) throws -> UnsentWorkLedger.Reservation {
        try h.unsent.convertDraftToPending(nil, bytes: bytes)
    }

    @Test func scheduleHoldsBytesUntilCanceledOrFired() async throws {
        let h = await SessionHarness(clock: ContinuousClock())
        await h.openChannel()
        let fireAt = h.wallClock.now().addingTimeInterval(60)
        let reservation = try reserve(h, "план на вечер".utf8.count)
        let id = try await h.session.enqueueSchedule(text: "план на вечер", channel: h.channel.id, rootID: nil,
                                                      attachments: [], fireAt: fireAt, reservation: reservation)
        // Байты удерживаются, пока запись в расписании.
        #expect(h.unsent.usage.pendingBytes == "план на вечер".utf8.count)
        let scheduledCount = await h.session.scheduledSends(for: .channel(h.channel.id)).count
        #expect(scheduledCount == 1)

        // Отмена возвращает текст и освобождает бюджет.
        let before = await h.windowIDs().count
        let canceledText = await h.session.cancelSchedule(id)
        #expect(canceledText == "план на вечер")
        #expect(h.unsent.usage.totalBytes == 0)
        let afterCount = await h.session.scheduledSends(for: .channel(h.channel.id)).count
        #expect(afterCount == 0)
        let after = await h.windowIDs().count
        #expect(after == before)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func firedScheduleBecomesAOrdinarySendAndPosts() async throws {
        let h = await SessionHarness(clock: ContinuousClock())
        await h.openChannel()
        let reservation = try reserve(h, 10)
        let fireAt = h.wallClock.now().addingTimeInterval(0.2)
        try await h.session.enqueueSchedule(text: "later hello", channel: h.channel.id, rootID: nil,
                                             attachments: [], fireAt: fireAt, reservation: reservation)
        // Переводим фиксированные часы за срок; планировщик просыпается тиком ≤250 мс.
        h.wallClock.advance(milliseconds: 500)
        let fired = await eventually {
            let noSchedule = await h.session.scheduledSends(for: .channel(h.channel.id)).isEmpty
            let noPending = await h.session.pending.isEmpty
            return noSchedule && noPending
        }
        #expect(fired)
        #expect(h.service.withState { $0.createdPosts.map(\.message) } == ["later hello"])
        // Отправлено и подтверждено — бюджет полностью освобождён.
        #expect(await eventually { h.unsent.usage.totalBytes == 0 })
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func fireDateInThePastIsRefusedWithoutSideEffects() async throws {
        let h = await SessionHarness()
        await h.openChannel()
        let reservation = try reserve(h, 10)
        await #expect(throws: ServerSession.SendRejection.fireDatePast) {
            _ = try await h.session.enqueueSchedule(text: "too late", channel: h.channel.id, rootID: nil,
                                                    attachments: [], fireAt: h.wallClock.now().addingTimeInterval(-1),
                                                    reservation: reservation)
        }
        let noneQueued = await h.session.scheduledSends(for: .channel(h.channel.id)).isEmpty
        #expect(noneQueued)
        // Разрезервирование — обязанность вызвавшего (композер возвращает текст в черновик).
        h.unsent.release(reservation)
        #expect(h.unsent.usage.totalBytes == 0)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func revokedChannelParksSchedulesAsFailedPendingRows() async throws {
        let h = await SessionHarness(clock: ContinuousClock())
        await h.openChannel()
        let reservation = try reserve(h, 10)
        let id = try await h.session.enqueueSchedule(text: "дальновидный план", channel: h.channel.id, rootID: nil,
                                                     attachments: [], fireAt: h.wallClock.now().addingTimeInterval(600),
                                                     reservation: reservation)
        await h.session.purgeChannel(h.channel.id, reason: nil)
        // Текст не потерян: запись остаётся в pending как сбойная отправка.
        let remaining = await h.session.scheduledSends(for: .channel(h.channel.id)).count
        #expect(remaining == 0)
        let message = await h.session.pending.item(id)?.message
        #expect(message == "дальновидный план")
        let state = await h.session.pending.item(id)?.presentationState
        if case .failed(.permissionDenied)? = state {} else {
            Issue.record("состояние переноса должно быть failed(permissionDenied), получено \(String(describing: state))")
        }
        // Бюджет удерживается сбойной строкой — как у всякой несбыточной отправки.
        #expect(h.unsent.usage.pendingBytes == 10)
        _ = await h.session.shutdown(revokeServerSession: false)
        #expect(h.unsent.usage.totalBytes == 0)
    }
}
