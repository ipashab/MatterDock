import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import TestSupport

/// Рельса папок сайдбара (ADR 0043): идентичность, фильтрация секций, элементы.
@Suite("Sidebar folders rail", .serialized)
struct SidebarFolderTests {
    private let workGroup = SidebarCategoryID(unchecked: "custom_work000000000000000")

    private func row(_ n: Int64, name: String, unread: Bool = false, mentions: Int = 0,
                     postAt: Int64 = 100) -> SidebarChannelRow {
        SidebarChannelRow(channelID: ChannelID(unchecked: "channel\(n)00000000000000000"), displayName: name,
                          type: .open, isUnread: unread, mentionCount: mentions, isArchived: false, isMuted: false,
                          partnerStatus: nil, lastPostAt: MattermostTimestamp(milliseconds: postAt))
    }

    private func snapshot(sections: [SidebarSection], folders: [SidebarFolderItem] = []) -> SidebarSnapshot {
        SidebarSnapshot(scope: AccountScope(server: ServerSlotID(1), user: UserID(unchecked: "user00000000000000000")),
                       generation: 1, teams: [], selectedTeam: nil, sections: sections, isTruncated: false,
                       folders: folders)
    }

    // MARK: - Идентичность

    @Test func identityRoundTripsThroughRawValue() {
        let all: [SidebarFolderID] = [.all, .threads, .drafts, .mentions, .unread, .group(workGroup)]
        for folder in all {
            #expect(SidebarFolderID(rawValue: folder.rawValue) == folder)
        }
    }

    @Test func identityRejectsUnknownValues() {
        // Пустая строка, чужой префикс, битый id категории и битые символы не проходят.
        for raw in ["", "bogus", "group", "group:", "group:UPPER", "group:bad!"] {
            #expect(SidebarFolderID(rawValue: raw) == nil, "raw \(raw) parsed")
        }
    }

    // MARK: - Секции второй колонки

    @Test func chatSectionsAllIsIdentity() {
        let sections = [SidebarSection(kind: .channels, rows: [row(1, name: "Channel 1")])]
        let snap = snapshot(sections: sections)
        #expect(snap.chatSections(for: .all) == sections)
    }

    @Test func chatSectionsGroupFiltersToItsCategoryOnly() {
        // Hoisting непрочитанных (секция без categoryID) в группу не попадает:
        // папка — фильтр, а не перестройка.
        let group = SidebarSection(kind: .custom, rows: [row(1, name: "Channel 1"), row(2, name: "Channel 2")],
                                   title: "Work", categoryID: workGroup)
        let read = row(3, name: "Channel 3")
        let snap = snapshot(sections: [
            SidebarSection(kind: .unreads, rows: [row(2, name: "Channel 2", unread: true)]),
            group,
            SidebarSection(kind: .channels, rows: [read]),
        ])
        #expect(snap.chatSections(for: .group(workGroup)) == [group])
    }

    @Test func chatSectionsUnreadFlattensMentionsFirst() {
        let snap = snapshot(sections: [
            SidebarSection(kind: .channels, rows: [
                row(1, name: "Old unread", unread: true, postAt: 100),
                row(2, name: "Quiet"),
                row(3, name: "Noisy", unread: true, mentions: 4, postAt: 50),
            ]),
            SidebarSection(kind: .directMessages, rows: [
                row(4, name: "Fresh unread", unread: true, postAt: 900),
            ]),
        ])
        let rows = snap.chatSections(for: .unread)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .unreads)
        // С упоминанием — первым; далее свежесть по убыванию; прочитанные исключены.
        #expect(rows[0].rows.map(\.displayName) == ["Noisy", "Fresh unread", "Old unread"])
    }

    @Test func chatSectionsUnreadEmptyWhenEverythingIsRead() {
        let snap = snapshot(sections: [SidebarSection(kind: .channels, rows: [row(1, name: "Channel 1")])])
        #expect(snap.chatSections(for: .unread).isEmpty)
    }

    @Test func serviceFolderSectionsAreEmpty() {
        // Обсуждения/черновики/упоминания колонку каналов не показывают (фазы 2–4).
        let snap = snapshot(sections: [SidebarSection(kind: .channels, rows: [row(1, name: "Channel 1")])])
        for folder in [SidebarFolderID.threads, .drafts, .mentions] {
            #expect(snap.chatSections(for: folder).isEmpty)
        }
    }

    @Test func folderExistsReflectsTheRailContents() {
        let snap = snapshot(sections: [], folders: [
            SidebarFolderItem(folder: .all, kind: .all, caption: "All"),
            SidebarFolderItem(folder: .group(workGroup), kind: .group, caption: "Work"),
        ])
        #expect(snap.folderExists(.all))
        #expect(snap.folderExists(.group(workGroup)))
        #expect(!snap.folderExists(.unread))
        #expect(!snap.folderExists(.group(SidebarCategoryID(unchecked: "custom_gone0000000000000"))))
    }

    // MARK: - Элементы рельсы (сервер)

    @Test func railItemsFollowServerOrderAndCarryCounts() async {
        let work = SidebarCategoryID(unchecked: CoreFixtures.id("work", 1))
        let alpha = SidebarCategoryID(unchecked: CoreFixtures.id("work", 2))
        let h = await SidebarHarness(configure: { state in
            // Канал 1: два упоминания — единственный непрочитанный.
            state.memberships[CoreFixtures.channel(1).id]?.mentionCount = 2
            state.memberships[CoreFixtures.channel(1).id]?.mentionCountRoot = 2
        }, directory: { directory in
            let me = CoreFixtures.me.id
            let team = CoreFixtures.team.id
            func id(_ kind: String) -> SidebarCategoryID { SidebarCategoryID(unchecked: kind + "_" + me.rawValue + "_" + team.rawValue) }
            directory.categories[team] = [
                SidebarCategory(id: work, userID: me, teamID: team, kind: .custom, displayName: "Work",
                                channelIDs: [.fixture(1), .fixture(2)]),
                SidebarCategory(id: alpha, userID: me, teamID: team, kind: .custom, displayName: "Alpha",
                                channelIDs: [.fixture(3)]),
                SidebarCategory(id: id("favorites"), userID: me, teamID: team, kind: .favorites, displayName: "Favorites"),
                SidebarCategory(id: id("channels"), userID: me, teamID: team, kind: .channels, displayName: "Channels"),
                SidebarCategory(id: id("direct_messages"), userID: me, teamID: team, kind: .directMessages,
                                displayName: "Direct Messages"),
            ]
        })
        await h.waitForCategories()
        let sections = await h.session.sidebarSections(collapsedThreads: false)
        let items = await h.session.folderItems(collapsedThreads: false, sections: sections)
        // Порядок: «Все» → группы в серверном порядке → «Обсуждения» → «Непрочитанные».
        #expect(items.map(\.folder) == [.all, .group(work), .group(alpha), .threads, .unread])
        #expect(items.map(\.caption) == ["All", "Work", "Alpha", "Threads", "Unreads"])
        let all = items[0]
        #expect(all.unreadCount == 1)
        #expect(all.mentionCount == 2)
        let workItem = items[1]
        #expect(workItem.categoryID == work)
        #expect(workItem.unreadCount == 1)
        #expect(workItem.mentionCount == 2)
        let alphaItem = items[2]
        #expect(alphaItem.unreadCount == 0)
        #expect(alphaItem.mentionCount == 0)
        let unread = items[4]
        #expect(unread.unreadCount == 1)
        #expect(unread.mentionCount == 2)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func threadsFolderCarriesTheLastPublishedTotals() async {
        let h = await SidebarHarness()
        let sections = await h.session.sidebarSections(collapsedThreads: false)
        // До первой тредовой активности бейдж «Обсуждений» пуст.
        var item = await h.session.folderItems(collapsedThreads: false, sections: sections)
            .first { $0.kind == .threads }
        #expect(item?.unreadCount == 0 && item?.mentionCount == 0)
        // Публикация тоталов тредов наполняет бейдж; доступность — флаг CRT.
        await h.session.publishThreadActivity(unreadThreads: 4, unreadMentions: 2)
        item = await h.session.folderItems(collapsedThreads: false, sections: sections)
            .first { $0.kind == .threads }
        #expect(item?.unreadCount == 4 && item?.mentionCount == 2)
        #expect(item?.isAvailable == true)
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
