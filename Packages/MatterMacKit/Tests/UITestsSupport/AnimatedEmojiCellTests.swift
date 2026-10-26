import AppKit
import ImageIO
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

/// Интеграционная проверка анимации в реальной иерархии с окном: ячейка
/// сообщения с GIF-эмодзи в тексте и в чипе реакции листает кадры тактовиком.
@MainActor
@Suite("Animated emoji in cell")
struct AnimatedEmojiCellTests {
    private final class AnimatedHost: TimelineCellHost {
        let renderer = MessageRenderer()
        let rowMetrics = TimelineRowMetrics(fonts: .forScale(1))
        var quickReactions: [String] { [] }
        var allowsQuoteReply: Bool { true }
        let emojiAnimator = EmojiFrameAnimator()
        var animation: ImagePipeline.Animation?
        var image: NSImage?
        func perform(_ action: TimelineAction) {}
        func performPrepared(_ action: TimelineAction) {}
        func image(for request: TimelineImageRequest) -> NSImage? { image }
        func animation(for request: TimelineImageRequest) -> ImagePipeline.Animation? { animation }
        func registerImageDemand(_ request: TimelineImageRequest) {}
        func unregisterImageDemand(_ request: TimelineImageRequest) {}
        func requestOlderFromGapButton() {}
        func requestNewerFromGapButton() {}
        func bodyTextViewReceivedMouseDown(_ textView: NSTextView) {}
        func copySelectedMessages() -> Bool { false }
        func canCopySelectedMessages() -> Bool { false }
        func handleReturnKey() -> Bool { false }
        func presentActionsMenu() -> Bool { false }
        func handleEscapeKey() -> Bool { false }
        func forwardKeyToTable(_ event: NSEvent) {}
        func contextMenu(for textView: NSTextView, event: NSEvent, link: URL?) -> NSMenu? { nil }
        func contextMenu(forRowContaining view: NSView, leadingItems: [NSMenuItem]) -> NSMenu? { nil }
        func handleSpaceKey() -> Bool { false }
    }

    private func twoFrameAnimation() throws -> ImagePipeline.Animation {
        let data = CoreFixtures.gif(frames: 2, delay: 0.05)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        var frames: [CGImage] = []
        for index in 0..<CGImageSourceGetCount(source) {
            frames.append(CGImageSourceCreateImageAtIndex(source, index, nil)!)
        }
        return ImagePipeline.Animation(frames: frames, delays: [0.05, 0.05], duration: 0.1)
    }

    @Test func freshArrivalAnimatesBodyAndChip() throws {
        let animation = try twoFrameAnimation()
        let host = AnimatedHost()
        // Картинка ещё не приехала: конфигурация ставит статику, анимация
        // приходит через imageDidBecomeAvailable → setEmojiImage.
        let document = MessageDocument(blocks: [.paragraph([.text("привет "), .emoji("gifka")])])
        let reaction = ReactionGroup(emojiName: "gifka", count: 1, includesCurrentUser: true,
                                     customEmojiID: "cid1")
        let post = PostPresentation(
            postID: PostID(unchecked: "p1"), pendingID: nil, channelID: CoreFixtures.channel(1).id, rootID: nil,
            author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob",
                                       isBot: false, isCurrentUser: false, avatarRevision: 0),
            createdAt: MattermostTimestamp(milliseconds: 1_700_000_000_000),
            isContinuation: false,
            body: .document(document, isCollapsed: false),
            isEdited: false, isPinned: false, files: [], reactions: [reaction], replyCount: 0,
            showsThreadContext: false, sendState: nil, actions: .none, permalink: nil, isLastInGroup: true)

        let renderer = MessageRenderer()
        let body = renderer.render(post.body, customEmoji: ["gifka": "cid1"])
        let cell = MessageCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let item = TimelineItem(id: TimelineItemID(.post(post.postID!)), revision: 1, content: .post(post))
        let layout = host.rowMetrics.messageLayout(for: post, width: 400, bodyHeight: 20, bodyUsedWidth: 60,
                                                   renderer: host.renderer, style: .bubble)
        cell.configure(item: item, post: post, layout: layout, body: body, host: host)

        let row = TimelineRowView(frame: NSRect(x: 0, y: 0, width: 400, height: layout.height))
        row.addSubview(cell)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        cell.layout()
        row.layoutSubtreeIfNeeded()

        // Картинка с кадрами подоспела — ячейка переключает текст и чип на анимацию.
        host.animation = animation
        host.image = NSImage(cgImage: animation.frames[0], size: .zero)
        cell.imageDidBecomeAvailable(.customEmoji("cid1"))
        #expect(host.emojiAnimator.targetCountForTesting >= 2, "после прихода кадра обе цели зарегистрированы")
        var maxBodyIndex = 0
        var maxChipIndex = 0
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            maxBodyIndex = max(maxBodyIndex, cell.bodyEmojiAttachmentIndexForTesting() ?? 0)
            maxChipIndex = max(maxChipIndex, cell.reactionChipFrameIndexForTesting() ?? 0)
        }
        #expect(maxBodyIndex != 0, "вложение в тексте листает кадры после прихода картинки")
        #expect(maxChipIndex != 0, "чип реакции листает кадры после прихода картинки")
        window.orderOut(nil)
        host.emojiAnimator.removeAll()
    }

    @Test func cellBodyAndChipAdvanceInLiveHierarchy() throws {
        let animation = try twoFrameAnimation()
        let host = AnimatedHost()
        host.animation = animation
        host.image = NSImage(cgImage: animation.frames[0], size: .zero)

        // Сообщение с кастомным эмодзи в тексте и реакцией с тем же эмодзи.
        let document = MessageDocument(blocks: [.paragraph([.text("привет "), .emoji("gifka")])])
        let reaction = ReactionGroup(emojiName: "gifka", count: 1, includesCurrentUser: true,
                                     customEmojiID: "cid1")
        let post = PostPresentation(
            postID: PostID(unchecked: "p1"), pendingID: nil, channelID: CoreFixtures.channel(1).id, rootID: nil,
            author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob",
                                       isBot: false, isCurrentUser: false, avatarRevision: 0),
            createdAt: MattermostTimestamp(milliseconds: 1_700_000_000_000),
            isContinuation: false,
            body: .document(document, isCollapsed: false),
            isEdited: false, isPinned: false, files: [], reactions: [reaction], replyCount: 0,
            showsThreadContext: false, sendState: nil, actions: .none, permalink: nil, isLastInGroup: true)

        let renderer = MessageRenderer()
        let body = renderer.render(post.body, customEmoji: ["gifka": "cid1"])
        let cell = MessageCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let item = TimelineItem(id: TimelineItemID(.post(post.postID!)), revision: 1, content: .post(post))
        let layout = host.rowMetrics.messageLayout(for: post, width: 400, bodyHeight: 20, bodyUsedWidth: 60,
                                                   renderer: host.renderer, style: .bubble)
        cell.configure(item: item, post: post, layout: layout, body: body, host: host)

        // Иерархия с окном — как в приложении.
        let row = TimelineRowView(frame: NSRect(x: 0, y: 0, width: 400, height: layout.height))
        row.addSubview(cell)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        cell.layout()
        row.layoutSubtreeIfNeeded()

        // Ячейка зарегистрировала анимированные цели: текст и чип.
        if let storage = cell.bodyTextView.textStorage {
            print("DEBUG storage len=\(storage.length) string='\(storage.string)'")
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                if let attachment = attrs[.attachment] {
                    print("DEBUG range=\(range) cellClass=\(type(of: attachment)) emoji=\(attrs[.matterMacCustomEmoji] ?? "nil")")
                }
            }
        } else { print("DEBUG no storage") }
        print("DEBUG targets=\(host.emojiAnimator.targetCountForTesting) bodyIndex=\(String(describing: cell.bodyEmojiAttachmentIndexForTesting())) chipIndex=\(String(describing: cell.reactionChipFrameIndexForTesting()))")
        #expect(host.emojiAnimator.targetCountForTesting >= 2, "вложение в тексте и чип зарегистрированы")
        // Смотрим такты по живому таймеру в ранлупе; индексы зациклены, поэтому
        // фиксируем максимальный наблюдаемый индекс за окно наблюдения.
        var maxBodyIndex = 0
        var maxChipIndex = 0
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            maxBodyIndex = max(maxBodyIndex, cell.bodyEmojiAttachmentIndexForTesting() ?? 0)
            maxChipIndex = max(maxChipIndex, cell.reactionChipFrameIndexForTesting() ?? 0)
        }
        #expect(maxBodyIndex != 0, "вложение в тексте листает кадры")
        #expect(maxChipIndex != 0, "чип реакции листает кадры")
        window.orderOut(nil)
        host.emojiAnimator.removeAll()
    }
}
