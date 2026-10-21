public import MatterMacModels

/// Идентичность папки сайдбара (Telegram-style folders rail, ADR 0043): пять
/// встроенных папок плюс пользовательские группы — серверные sidebar-категории.
/// `rawValue` — стабильная строка для локального хранения выбранной папки.
public enum SidebarFolderID: Hashable, Sendable {
    case all, threads, drafts, mentions, unread
    case group(SidebarCategoryID)

    public var rawValue: String {
        switch self {
        case .all: "all"
        case .threads: "threads"
        case .drafts: "drafts"
        case .mentions: "mentions"
        case .unread: "unread"
        case .group(let id): "group:\(id.rawValue)"
        }
    }

    /// Обратное чтение: неизвестная форма (чужой префикс, битый id) — `nil`.
    public init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "threads": self = .threads
        case "drafts": self = .drafts
        case "mentions": self = .mentions
        case "unread": self = .unread
        default:
            guard rawValue.hasPrefix("group:"),
                  let id = SidebarCategoryID(rawValue: String(rawValue.dropFirst(6))) else { return nil }
            self = .group(id)
        }
    }
}

/// Элемент рельсы папок: подпись, иконообраз (род определяет глиф в UI) и счётчики
/// для бейджа. Строится на сервере из уже собранных секций — нового I/O нет.
public struct SidebarFolderItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case all, group, threads, drafts, mentions, unread }

    public let folder: SidebarFolderID
    public let kind: Kind
    /// Встроенные — локализовано в Core; группы — `displayName` категории с сервера.
    public let caption: String
    public let categoryID: SidebarCategoryID?
    public let isMuted: Bool
    public let unreadCount: Int
    public let mentionCount: Int
    /// `false` только у `.threads`, когда на сервере выключены свёрнутые треды.
    public let isAvailable: Bool

    public var id: SidebarFolderID { folder }

    public init(folder: SidebarFolderID, kind: Kind, caption: String, categoryID: SidebarCategoryID? = nil,
                isMuted: Bool = false, unreadCount: Int = 0, mentionCount: Int = 0, isAvailable: Bool = true) {
        self.folder = folder
        self.kind = kind
        self.caption = caption
        self.categoryID = categoryID
        self.isMuted = isMuted
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.isAvailable = isAvailable
    }
}

extension SidebarSnapshot {
    /// Есть ли такая папка в текущем снапшоте (группу могли удалить на сервере).
    public func folderExists(_ folder: SidebarFolderID) -> Bool {
        folders.contains { $0.folder == folder }
    }

    /// Секции второй колонки для чат-папок (`.all`, `.group`, `.unread`).
    /// `.threads`/`.drafts`/`.mentions` колонку каналов не показывают — пусто.
    public func chatSections(for folder: SidebarFolderID) -> [SidebarSection] {
        switch folder {
        case .all:
            return sections
        case .group(let id):
            // Папка — фильтр, а не перестройка: без hoisting непрочитанных,
            // сортировка и collapsed — как сервер задал для категории.
            return sections.filter { $0.categoryID == id }
        case .unread:
            // Строки секций не пересекаются (размещение по категориям дедуплицировано
            // на сервере и в sidebarSections) — плоская склейка безопасна.
            let rows = sections.flatMap(\.rows).filter { $0.isUnread || $0.mentionCount > 0 }
                .sorted { lhs, rhs in
                    if (lhs.mentionCount > 0) != (rhs.mentionCount > 0) { return lhs.mentionCount > 0 }
                    if lhs.lastPostAt != rhs.lastPostAt { return lhs.lastPostAt > rhs.lastPostAt }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
            guard !rows.isEmpty else { return [] }
            return [SidebarSection(kind: .unreads, rows: rows, id: "folder-unread", sorting: .recent)]
        case .threads, .drafts, .mentions:
            return []
        }
    }
}
