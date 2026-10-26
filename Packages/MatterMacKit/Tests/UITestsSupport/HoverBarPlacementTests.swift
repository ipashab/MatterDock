import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// ADR 0062: hover-бар сообщений висит над верхней кромкой пузыря, заходя
/// только в его верхнюю набивку, — текст наведённого сообщения не
/// перекрывается (репорт «панель с реакциями накладывается на сообщение»).
@MainActor
@Suite("Hover bar placement")
struct HoverBarPlacementTests {

    @MainActor
    private func item(_ post: Post, text: String, author: UserID = CoreFixtures.bob.id,
                      continuation: Bool = false) -> TimelineItem {
        TimelineItem(id: TimelineItemID(.post(post.id)), revision: 1, content: .post(
            PostPresentation(postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
                author: AuthorPresentation(userID: author, displayName: "Bob", username: "bob",
                                           isBot: false, isCurrentUser: author == CoreFixtures.me.id,
                                           avatarRevision: 0),
                createdAt: post.createAt, isContinuation: continuation,
                body: .document(MarkupParser.parse(text), isCollapsed: false), isEdited: false,
                isPinned: false, files: [], reactions: [], replyCount: 0, showsThreadContext: false,
                sendState: nil,
                actions: PostActionHints(canReply: true, canReact: true, canEdit: true, canDelete: true,
                                         canCopyLink: true, canPin: true, canSave: true, canMarkUnread: true,
                                         canForward: true),
                permalink: nil)))
    }

    @Test func hoverBarStaysAboveTheBubbleAndOffTheText() throws {
        let c = TimelineViewController()
        c.usesBubbleStyle = true
        c.emojiLookup = { EmojiCatalog.system.glyph(for: $0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        let ch = CoreFixtures.channel(1).id
        let p1 = CoreFixtures.post(1, channel: ch)
        let p2 = CoreFixtures.post(2, channel: ch)
        c.apply(TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                                 target: .channel(ch), generation: 1,
                                 items: [item(p1, text: "Первое сообщение группы с длинным текстом, переносящимся на несколько строк, чтобы бар точно нашёл чем перекрыть текст, окажись он слишком низко."),
                                         item(p2, text: "Продолжение группы — короткая строка, у которой бар висит над пузырём.", continuation: true)],
                                 isAtLiveEdge: true, isStale: false, scrollRequest: nil))
        window.orderFrontRegardless()
        defer { c.removeAllContent(); window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let rowRect0 = c.view.convert(c.tableView.rect(ofRow: 1), from: c.tableView)
        c.hoverPointerLocation = window.convertPoint(fromScreen: window.convertToScreen(
            NSRect(origin: NSPoint(x: rowRect0.midX, y: rowRect0.midY), size: .zero)).origin)
        c.updateHover()
        #expect(!c.hoverBar.isHidden)
        let bar = c.hoverBar.frame
        let cell = try #require(c.tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) as? MessageCellView)
        let bubble = c.view.convert(try #require(cell.rowLayout.bubble).frame, from: cell)
        let body = c.view.convert(cell.rowLayout.body, from: cell)
        // Заход в пузырь — только верхняя набивка (7 pt).
        let intrusion = c.view.isFlipped ? bar.maxY - bubble.minY : bubble.maxY - bar.minY
        #expect(abs(intrusion - TimelineRowMetrics.BubbleMetrics.verticalTopPadding) < 1.5)
        // Глифы тела наведённого сообщения не перекрываются: кромки могут
        // касаться (низ бара = верх рамки текста), но заход в неё ≤ 1 pt.
        let covered = bar.intersection(body)
        #expect(covered.isNull || covered.height <= 1)
    }
}
