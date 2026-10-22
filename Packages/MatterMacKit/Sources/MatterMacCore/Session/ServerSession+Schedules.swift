public import Foundation
public import MatterMacModels
public import MattermostAPI

// Отложенная отправка (ADR 0052). Очередь только в памяти: сервер 7.8 не имеет
// API расписания, а SPEC §7 запрещает персистентность. Текст остаётся в бюджете
// unsent до отправки или отмены; при выходе из приложения записи пропадают —
// об этом честно сообщает подпись в таймлайне и меню композера.
extension ServerSession {
    /// Ставит сообщение в отложенную очередь. `reservation` уже удерживает байты
    /// черновика (как при обычной отправке); reservation переживает перенос в
    /// pending-очередь в момент срабатывания.
    @discardableResult
    public func enqueueSchedule(text: String, channel: ChannelID, rootID: PostID?, attachments: [UploadSource],
                                fireAt: Date, reservation: UnsentWorkLedger.Reservation) throws(SendRejection) -> PendingPostID {
        guard isActiveSessionAlive else { throw .sessionClosed }
        try validateSend(text: text, channel: channel, attachments: attachments)
        let fireTimestamp = MattermostTimestamp(date: fireAt)
        guard fireTimestamp > now() else { throw SendRejection.fireDatePast }
        let scheduledID = scheduled.makeID(user: me.id, now: now())
        scheduled.append(ScheduledSend(
            scheduledID: scheduledID, channelID: channel, rootID: rootID, message: text,
            attachments: attachments.enumerated().map { index, source in
                PendingSend.Attachment(clientID: "\(scheduledID.rawValue)-\(index)", source: source)
            },
            fireAt: fireTimestamp, reservation: reservation))
        deps.diagnostics.record(.send, .info, "send scheduled")
        markDirty(rootID == nil ? .timeline : [.thread, .timeline])
        processSchedules()
        return scheduledID
    }

    /// Отменяет отложенную отправку; возвращает текст (как `discardSend`).
    @discardableResult
    public func cancelSchedule(_ id: PendingPostID) -> String? {
        guard let item = scheduled.remove(id) else { return nil }
        deps.unsent.release(item.reservation)
        deps.diagnostics.record(.send, .info, "schedule canceled")
        markDirty(item.rootID == nil ? .timeline : [.thread, .timeline])
        return item.message
    }

    /// Отложенные записи для показа в таймлайне (в будущем порядке срабатывания).
    public func scheduledSends(for target: TimelineTarget) -> [ScheduledSend] {
        scheduled.items(for: target).sorted { $0.fireAt < $1.fireAt }
    }

    /// Планировщик: одна задача на сессию, пока очередь не опустеет. Тик короткий,
    /// чтобы тесты (и ранние сроки) не ждали лишнего; пустая очередь завершает цикл.
    func processSchedules() {
        guard isActiveSessionAlive, !scheduled.isEmpty, !isRunning(.scheduledSweeper) else { return }
        run(.scheduledSweeper) { session in
            while session.isActiveSessionAlive, !Task.isCancelled, !session.scheduled.isEmpty {
                let due = session.scheduled.due(now: session.now())
                if due.isEmpty {
                    try? await session.deps.clock.sleep(for: .milliseconds(250))
                    continue
                }
                for item in due {
                    _ = session.scheduled.remove(item.scheduledID)
                    session.fire(item)
                }
            }
        }
    }

    /// Перенос сработавшей записи в pending-очередь с уже зарезервированными байтами.
    /// Если за время ожидания канал стал недоступен, текст не теряется: запись
    /// становится сбойной pending-отправкой, как и всякая отправка в отозванный канал.
    private func fire(_ item: ScheduledSend) {
        do {
            try enqueueSend(text: item.message, channel: item.channelID, rootID: item.rootID,
                            attachments: item.attachments.map(\.source), reservation: item.reservation)
            processSendQueue()
        } catch {
            var failed = PendingSend(
                pendingID: item.scheduledID, channelID: item.channelID, rootID: item.rootID,
                message: item.message, attachments: item.attachments, createdAt: item.fireAt,
                reservation: item.reservation)
            failed.state = .failed(Self.failureFace(of: error))
            pending.append(failed)
            deps.diagnostics.record(.send, .warning, "schedule fired into an unavailable channel")
            markDirty(item.rootID == nil ? .timeline : [.thread, .timeline])
        }
    }

    /// Локальный отказ переноса в face-ошибку для сбойной строки. Запись уже
    /// прошла `validateSend` при постановке — реалистичны только канальные отказы.
    private static func failureFace(of rejection: SendRejection) -> UserFacingError {
        switch rejection {
        case .channelUnavailable, .channelArchived: .permissionDenied
        case .attachmentsDisabled, .attachmentsUnavailable: .unsupportedCapability("attach")
        case .tooLong(let limit): .messageTooLong(limitCharacters: limit)
        case .budget(let refusal):
            switch refusal {
            case .textBudgetExceeded: .budgetExceeded(.unsentText)
            case .tooManyPendingOperations: .budgetExceeded(.pendingOperations)
            case .imageBudgetExceeded: .budgetExceeded(.pastedImages)
            case .draftBeingSubmitted: .budgetExceeded(.unsentText)
            }
        default: .permissionDenied
        }
    }
}
