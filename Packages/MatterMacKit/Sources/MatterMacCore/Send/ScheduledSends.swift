public import Foundation
public import MatterMacModels

/// Отложенная отправка (кнопка «Send later»). API расписания на сервере 7.8 нет
/// (зонд `/users/me/scheduled_posts` отдаёт 404), а SPEC §7 запрещает клиентскую
/// персистентность — поэтому очередь живёт только в памяти процесса: при выходе из
/// приложения записи исчезают, и подпись в таймлайне честно об этом предупреждает.
public struct ScheduledSend: Sendable, Hashable {
    public let scheduledID: PendingPostID
    public let channelID: ChannelID
    public let rootID: PostID?
    public let message: String
    public let attachments: [PendingSend.Attachment]
    /// Момент, когда запись должна стать обычной pending-отправкой.
    public let fireAt: MattermostTimestamp
    let reservation: UnsentWorkLedger.Reservation

    public init(scheduledID: PendingPostID, channelID: ChannelID, rootID: PostID?, message: String,
                attachments: [PendingSend.Attachment], fireAt: MattermostTimestamp,
                reservation: UnsentWorkLedger.Reservation) {
        self.scheduledID = scheduledID
        self.channelID = channelID
        self.rootID = rootID
        self.message = message
        self.attachments = attachments
        self.fireAt = fireAt
        self.reservation = reservation
    }

    public var target: TimelineTarget {
        if let rootID { .thread(root: rootID, channel: channelID) } else { .channel(channelID) }
    }
}

/// Отложенные отправки одной сессии. Бюджет unsent-байтов удерживается резервацией,
/// пока запись не уйдёт в pending-очередь или не будет отменена: отложенный текст —
/// это всё ещё не отправленный текст (SPEC §11, «never evict»).
public struct ScheduledSendQueue: Sendable {
    public private(set) var items: [ScheduledSend] = []
    private var lastIssuedMilliseconds: Int64 = 0

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// Идентификатор в том же пространстве, что и pending-отправки (Ms-схема
    /// официального клиента); коллизия поднимает миллисекунду.
    public mutating func makeID(user: UserID, now: MattermostTimestamp) -> PendingPostID {
        let ms = max(now.milliseconds, lastIssuedMilliseconds + 1)
        lastIssuedMilliseconds = ms
        return PendingPostID(user: user, milliseconds: ms)
    }

    public mutating func append(_ send: ScheduledSend) { items.append(send) }

    public func item(_ id: PendingPostID) -> ScheduledSend? { items.first { $0.scheduledID == id } }

    public func items(for target: TimelineTarget) -> [ScheduledSend] { items.filter { $0.target == target } }

    public var earliestFireAt: MattermostTimestamp? { items.map(\.fireAt).min() }

    /// Записи, срок которых уже наступил (по возрастанию времени отправки).
    public func due(now: MattermostTimestamp) -> [ScheduledSend] {
        items.filter { $0.fireAt <= now }.sorted { $0.fireAt < $1.fireAt }
    }

    @discardableResult
    public mutating func remove(_ id: PendingPostID) -> ScheduledSend? {
        guard let index = items.firstIndex(where: { $0.scheduledID == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func removeAll() -> [ScheduledSend] {
        let removed = items
        items.removeAll()
        return removed
    }
}

/// Пресеты меню «Send later», как в веб-клиенте: 15 минут, 30 минут, час,
/// завтра 09:00 и произвольный момент (его выбирает пикер в композере).
public enum SendSchedulePreset: String, CaseIterable, Sendable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case tomorrowMorning

    public var title: String {
        switch self {
        case .fifteenMinutes: String(localized: "In 15 minutes")
        case .thirtyMinutes: String(localized: "In 30 minutes")
        case .oneHour: String(localized: "In 1 hour")
        case .tomorrowMorning: String(localized: "Tomorrow at 9:00 AM")
        }
    }

    /// Чистая функция для тестов: календарь передаётся явно, чтобы не зависеть от
    /// локальной зоны процесса.
    public func fireDate(after now: Date, calendar: Calendar) -> Date {
        switch self {
        case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .tomorrowMorning:
            var morning = calendar.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
            // 09:00 локального времени следующего дня.
            morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: morning) ?? morning
            return morning
        }
    }
}
