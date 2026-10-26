import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// ADR 0061: попап реакций не наезжает на сообщение и в тесной геометрии —
/// когда с обеих сторон не хватает места под полный попап, презентер усекает
/// его высоту до доступного места вместо того, чтобы позволить AppKit
/// прижать попап к экрану прямо поверх строки.
@MainActor
@Suite("Reaction popover fit", .serialized)
struct ReactionPopoverFitTests {

    /// Таймлайн с сообщением в реальном окне; окно занимает заданный кадр.
    private func makeTimeline(postText: String, windowFrame: NSRect) throws
        -> (timeline: TimelineViewController, window: NSWindow) {
        let c = TimelineViewController()
        let window = NSWindow(contentRect: windowFrame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        c.emojiLookup = { EmojiCatalog.system.glyph(for: $0) }
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        c.apply(TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                                 target: .channel(CoreFixtures.channel(1).id), generation: 1,
                                 items: [item(post, text: postText)], isAtLiveEdge: true, isStale: false,
                                 scrollRequest: nil))
        window.contentView?.layoutSubtreeIfNeeded()
        return (c, window)
    }

    /// Панель поповера и строка сообщения на экране; пересечение между ними.
    private func overlap(popover: NSPopover, timeline: TimelineViewController, window: NSWindow) -> Bool {
        guard let panel = popover.contentViewController?.view.window,
              let row = timeline.anchorRect(for: CoreFixtures.post(1, channel: CoreFixtures.channel(1).id).id),
              let content = window.contentView else { return false }
        let rowScreen = window.convertToScreen(content.convert(row, to: nil))
        return panel.frame.intersects(rowScreen)
    }

    @Test func popoverStaysOffTheBubbleWhenSpaceIsTight() throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        // Высокое сообщение в окне посреди экрана: с обеих сторон места мало,
        // полный попап (388 + стрелка) не помещается ни сверху, ни снизу.
        let windowFrame = NSRect(x: visible.minX + 200,
                                 y: visible.midY - 300,
                                 width: 900, height: 600)
        let text = Array(repeating: "строка сообщения поп длиннее", count: 60).joined(separator: "\n")
        let (timeline, window) = try makeTimeline(postText: text, windowFrame: windowFrame)
        window.orderFrontRegardless()
        defer { window.close() }
        window.displayIfNeeded()
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        let row = try #require(timeline.anchorRect(for: post.id))
        // Ожидание самосогласовано с экраном тестовой машины: высота попапа
        // равна тому, что вмещает выбранная сторона.
        let spaces = try #require(ReactionPickerPresenter.screenSpaces(bubble: row, in: timeline.view))
        let placement = ReactionPickerPresenter.anchorPlacement(
            bubble: row, in: timeline.view,
            popoverHeight: ReactionPickerViewController.preferredSize.height)
        let wanted = ReactionPickerPresenter.fittedHeight(spaceAbove: spaces.above,
                                                           spaceBelow: spaces.below,
                                                           above: placement.above)
        let popover = ReactionPickerPresenter.present(for: post.id, in: timeline,
                                                      channel: post.channelID) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(abs(popover.contentSize.height - wanted) < 1.01)
        let available = placement.above ? spaces.above : spaces.below
        // Усечение обязано поместить панель в отведённое место, когда минимума
        // хватает; если и минимум не влезает — попап усыхает до минимума.
        if wanted > ReactionPickerViewController.minimumHeight
            || available - 14 >= ReactionPickerViewController.minimumHeight {
            #expect(!overlap(popover: popover, timeline: timeline, window: window))
        }
        popover.performClose(nil)
    }

    @Test func popoverLeavesTheBubbleAloneWithPlentyOfSpace() throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        // Окно у нижнего края экрана: строка в верхней части окна, снизу
        // полно места — попап открывается снизу полным размером.
        let windowFrame = NSRect(x: visible.minX + 200, y: visible.minY + 10,
                                 width: 900, height: 600)
        let (timeline, window) = try makeTimeline(postText: "Короткое сообщение",
                                                  windowFrame: windowFrame)
        window.orderFrontRegardless()
        defer { window.close() }
        window.displayIfNeeded()
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        let popover = ReactionPickerPresenter.present(for: post.id, in: timeline,
                                                      channel: post.channelID) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!overlap(popover: popover, timeline: timeline, window: window))
        popover.performClose(nil)
    }
}

@MainActor
private func item(_ post: Post, text: String) -> TimelineItem {
    TimelineItem(id: TimelineItemID(.post(post.id)), revision: 1, content: .post(
        PostPresentation(postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
            author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob",
                                       isBot: false, isCurrentUser: false, avatarRevision: 0),
            createdAt: post.createAt, isContinuation: false,
            body: .document(MarkupParser.parse(text), isCollapsed: false), isEdited: false,
            isPinned: false, files: [], reactions: [], replyCount: 0, showsThreadContext: false,
            sendState: nil, actions: .none, permalink: nil)))
}
