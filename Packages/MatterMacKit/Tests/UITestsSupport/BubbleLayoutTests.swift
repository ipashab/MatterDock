import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

/// Геометрия пузырей (ADR 0041 M-4): сторона, hug, meta в хвосте, радиусы,
/// сервисные строки вне пузыря, реакции под пузырём.
@MainActor @Suite("Bubble row layout")
struct BubbleLayoutTests {
    private var metrics: TimelineRowMetrics {
        TimelineRowMetrics(fonts: .forScale(1))
    }

    private func author(own: Bool) -> AuthorPresentation {
        AuthorPresentation(userID: own ? CoreFixtures.me.id : CoreFixtures.bob.id,
                            displayName: own ? "Me" : "Bob", username: own ? "me" : "bob", isBot: false,
                            isCurrentUser: own, avatarRevision: 0)
    }

    private func post(own: Bool, continuation: Bool = false, last: Bool = true, edited: Bool = false,
                      body: MessageBody = .document(MessageDocument(blocks: [.paragraph([.text("hello")])]),
                                                    isCollapsed: false),
                      files: [FileInfo] = [], reactions: [ReactionGroup] = [], replyCount: Int = 0,
                      sendState: SendState? = nil, showsThreadContext: Bool = false) -> PostPresentation {
        let presentation = PostPresentation(
            postID: PostID(unchecked: "p1"), pendingID: nil, channelID: CoreFixtures.channel(1).id, rootID: nil,
            author: author(own: own), createdAt: MattermostTimestamp(milliseconds: 1_700_000_000_000),
            isContinuation: continuation, body: body, isEdited: edited, isPinned: false, files: files,
            reactions: reactions, replyCount: replyCount, showsThreadContext: showsThreadContext,
            sendState: sendState, actions: .none, permalink: nil, isLastInGroup: last)
        return presentation
    }

    @Test func sidesAndCorners() {
        let width: CGFloat = 400
        let incoming = metrics.messageLayout(for: post(own: false), width: width, bodyHeight: 20,
                                             renderer: MessageRenderer(), style: .bubble)
        let bubble = incoming.bubble!
        // Стороны классические: чужое — слева с аватаром 38 у края, пузырь сразу
        // за ним; имя автора — над пузырём.
        let rail = TimelineRowMetrics.horizontalInset + TimelineRowMetrics.BubbleMetrics.avatarSize
        #expect(abs(bubble.frame.minX - (rail + TimelineRowMetrics.BubbleMetrics.avatarGap)) < 1,
                "чужой пузырь сразу за аватаром слева")
        #expect(abs(incoming.avatar!.minX - TimelineRowMetrics.horizontalInset) < 1 && incoming.avatar!.width == 38)
        #expect(incoming.header != nil, "у головного чужого поста есть имя автора")
        let own = metrics.messageLayout(for: post(own: true), width: width, bodyHeight: 20,
                                        renderer: MessageRenderer(), style: .bubble).bubble!
        #expect(own.frame.maxX == width - TimelineRowMetrics.horizontalInset)
        #expect(own.frame.minY < bubble.frame.minY, "свой пост без имени — пузырь начинается выше")
        // Радиусы: 14 везде, хвост — у нижнего угла на стороне автора (зеркально).
        #expect(bubble.topLeft == 14 && bubble.topRight == 14 && bubble.bottomRight == 14 && bubble.bottomLeft == 4)
        #expect(own.topLeft == 14 && own.topRight == 14 && own.bottomLeft == 14 && own.bottomRight == 4)
        // Continuation внутри группы: та же колонка, meta нет.
        let continued = metrics.messageLayout(for: post(own: true, continuation: true, last: false), width: width,
                                               bodyHeight: 20, renderer: MessageRenderer(), style: .bubble).bubble!
        #expect(continued.topRight == 14 && continued.bottomRight == 4)
        #expect(continued.meta == nil, "время покажет hover, meta только у хвоста")
    }

    @Test func bubbleWidthCappedAtColumnFraction() {
        // Рендер: `.bubble-col { max-width: 76% }` — и своей, и чужой стороны.
        let wide: CGFloat = 2000
        let ownInner = metrics.bubbleInnerWidth(for: post(own: true), layoutWidth: wide)
        let incomingInner = metrics.bubbleInnerWidth(for: post(own: false), layoutWidth: wide)
        let rowContent = wide - 2 * TimelineRowMetrics.horizontalInset
        let expected = rowContent * TimelineRowMetrics.BubbleMetrics.columnFraction
            - 2 * TimelineRowMetrics.BubbleMetrics.horizontalPadding
        #expect(abs(ownInner - expected) < 1, "свой пузырь ≤76% строки")
        #expect(abs(incomingInner - expected) < 1, "чужой пузырь ≤76% строки")
        let ownBubble = metrics.messageLayout(for: post(own: true), width: wide, bodyHeight: 200,
                                              bodyUsedWidth: 1900, renderer: MessageRenderer(), style: .bubble).bubble!
        #expect(ownBubble.frame.width <= rowContent * TimelineRowMetrics.BubbleMetrics.columnFraction + 0.5,
                "широкий текст не раздувает пузырь за долю колонки")
    }

    @Test func hugShrinksShortTextAndFullWidthKept() {
        let layout = metrics.messageLayout(for: post(own: true), width: 400, bodyHeight: 20,
                                           bodyUsedWidth: 30, renderer: MessageRenderer(), style: .bubble)
        let full = metrics.messageLayout(for: post(own: true, body: .document(
            MessageDocument(blocks: [.paragraph([.text(String(repeating: "word ", count: 120))])]),
            isCollapsed: false)), width: 400, bodyHeight: 160, bodyUsedWidth: 368 - 20, renderer: MessageRenderer(), style: .bubble)
        #expect(layout.bubble!.frame.width < full.bubble!.frame.width, "короткий текст сжимает пузырь")
        #expect(layout.body.width >= TimelineRowMetrics.BubbleMetrics.minimumInnerWidth
                && layout.body.width < full.body.width, "тело не Уже минимальной ширины пузыря")
        // Без точной меры (оценка) пузырь не сжимается.
        let estimate = metrics.messageLayout(for: post(own: true), width: 400, bodyHeight: 20,
                                             renderer: MessageRenderer(), exact: false, style: .bubble)
        #expect(estimate.bubble!.frame.width > layout.bubble!.frame.width, "оценка не сжимает")
    }

    @Test func singleLineMetaSharesBodyLine() {
        // Рендер: у однострочного тела время садится в ту же строку («ok · 12:34»).
        let fonts = metrics.fonts
        let layout = metrics.messageLayout(for: post(own: true), width: 400, bodyHeight: fonts.bodyLineHeight,
                                           bodyUsedWidth: 30, renderer: MessageRenderer(), style: .bubble)
        let meta = layout.bubble!.meta
        #expect(meta != nil, "хвост группы несёт meta")
        #expect(abs(meta!.maxY - layout.body.maxY) < 1, "meta прижат к низу однострочного тела")
        #expect(meta!.maxX <= layout.bubble!.frame.maxX - TimelineRowMetrics.BubbleMetrics.horizontalPadding)
        let expectedHeight = TimelineRowMetrics.BubbleMetrics.verticalTopPadding + fonts.bodyLineHeight
            + TimelineRowMetrics.BubbleMetrics.verticalBottomPadding
        #expect(abs(layout.bubble!.frame.height - expectedHeight) < 1,
                "одна строка с inline meta без отдельной meta-строки")
    }

    @Test func multiLineMetaOverlaysLastLine() {
        // Многострочный пузырь: meta-пилюля — оверлей в правом нижнем углу
        // (рендер `.msg-meta { right:10px; bottom:4px }`), может накрывать текст.
        let layout = metrics.messageLayout(for: post(own: true), width: 400, bodyHeight: 3 * metrics.fonts.bodyLineHeight,
                                           bodyUsedWidth: 200, renderer: MessageRenderer(), style: .bubble)
        let meta = layout.bubble!.meta!
        let bubble = layout.bubble!.frame
        #expect(abs((bubble.maxX - meta.maxX) - TimelineRowMetrics.BubbleMetrics.metaOverlayInset) < 1,
                "пилюля на 10 pt правее края")
        #expect(abs((bubble.maxY - meta.maxY) - TimelineRowMetrics.BubbleMetrics.metaOverlayBottomInset) < 1,
                "пилюля на 4 pt выше дна")
        #expect(meta.minY >= bubble.minY, "пилюля внутри пузыря")
    }

    @Test func lastInGroupGetsMetaInsideBubble() {
        let last = metrics.messageLayout(for: post(own: true, edited: true), width: 400, bodyHeight: 20,
                                         bodyUsedWidth: 30, renderer: MessageRenderer(), style: .bubble)
        #expect(last.bubble!.meta != nil, "хвост группы несёт meta")
        #expect(abs((last.bubble!.frame.maxX - last.bubble!.meta!.maxX)
            - TimelineRowMetrics.BubbleMetrics.metaOverlayInset) < 1)
        // У текста meta есть "(edited)" и время — проверяем строку.
        let text = metrics.bubbleMetaText(for: post(own: true, edited: true))
        #expect(text.string.contains(TimelineStrings.edited))
        let notLast = metrics.messageLayout(for: post(own: true, last: false), width: 400, bodyHeight: 20,
                                            bodyUsedWidth: 30, renderer: MessageRenderer(), style: .bubble)
        #expect(notLast.bubble!.meta == nil, "продолжение группы без meta")
    }

    @Test func serviceRowsAreFlat() {
        let width: CGFloat = 400
        let system = metrics.messageLayout(for: post(own: true, body: .system("joined the channel")),
                                           width: width, bodyHeight: 20, renderer: MessageRenderer(), style: .bubble)
        #expect(system.bubble == nil, "сервисная строка без пузыря")
        let deleted = metrics.messageLayout(for: post(own: true, body: .deleted), width: width,
                                             bodyHeight: 20, renderer: MessageRenderer(), style: .bubble)
        #expect(deleted.bubble == nil)
        let flat = metrics.messageLayout(for: post(own: true), width: width, bodyHeight: 20,
                                          renderer: MessageRenderer(), style: .flat)
        #expect(flat.bubble == nil, "flat-стиль не рисует пузырь")
    }

    @Test func contentWrapsInsideAndReactionsBelow() throws {
        let file = FileInfo(id: FileID(unchecked: "f1"), name: "report.pdf")
        let reaction = ReactionGroup(emojiName: "tada", count: 2, includesCurrentUser: true)
        let post = post(own: false, files: [file], reactions: [reaction], replyCount: 3)
        let layout = metrics.messageLayout(for: post, width: 400, bodyHeight: 20, bodyUsedWidth: 30,
                                            renderer: MessageRenderer(), style: .bubble)
        let bubble = layout.bubble!
        let attachment = try #require(layout.attachments.first)
        #expect(bubble.frame.contains(attachment), "аттачмент внутри пузыря")
        #expect(layout.reactions.first!.minY >= bubble.frame.maxY, "реакции под пузырём")
        let replies = try #require(layout.replies)
        #expect(replies.minY >= layout.reactions.first!.maxY, "чип треда под реакциями")
        // Имя автора — над пузырём входящего.
        let header = try #require(layout.header)
        #expect(header.maxY <= bubble.frame.minY, "заголовок над пузырём")
    }

    @Test func pendingSitsOnOwnSide() {
        let pending = PostPresentation(
            postID: nil, pendingID: PendingPostID(rawValue: "me:1"), channelID: CoreFixtures.channel(1).id, rootID: nil,
            author: author(own: true), createdAt: MattermostTimestamp(milliseconds: 1_700_000_000_000),
            isContinuation: false, body: .document(MessageDocument(blocks: [.paragraph([.text("sending")])]),
                                                    isCollapsed: false),
            isEdited: false, isPinned: false, files: [], reactions: [], replyCount: 0, showsThreadContext: false,
            sendState: .sending, actions: .none, permalink: nil, isLastInGroup: true)
        let layout = metrics.messageLayout(for: pending, width: 400, bodyHeight: 20, bodyUsedWidth: 40,
                                           renderer: MessageRenderer(), style: .bubble)
        #expect(layout.bubble!.frame.maxX == 400 - TimelineRowMetrics.horizontalInset, "pending — справа")
        #expect(layout.pending != nil, "статус отправки на месте")
    }

    @Test func chatColumnCentersAtCap() {
        // Рендер: `.chat-inner { max-width: 860px; margin: 0 auto }`.
        let wide = CGRect(x: 0, y: 0, width: 1200, height: 700)
        let capped = TimelineViewController.chatColumnFrame(in: wide, capped: true)
        #expect(capped.width == TimelineViewController.chatColumnMaxWidth)
        #expect(abs(capped.midX - wide.midX) < 1, "колонка по центру контейнера")
        let narrow = TimelineViewController.chatColumnFrame(in: CGRect(x: 0, y: 0, width: 700, height: 700),
                                                            capped: true)
        #expect(narrow.width == 700, "узкий контейнер не центрируется")
        #expect(TimelineViewController.chatColumnFrame(in: wide, capped: false) == wide,
                "flat-режим занимает всю ширину")
    }

    @Test func estimateMatchesExactDirection() {
        let layouter = TimelineRowLayouter(caches: TimelineLayoutCaches(), budget: .standard)
        layouter.context = TimelineContextKey(
            scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
            target: .channel(CoreFixtures.channel(1).id))
        layouter.style = .bubble
        let presentation = post(own: true)
        let item = TimelineItem(id: TimelineItemID(.post(presentation.postID!)), revision: 1,
                                content: .post(presentation))
        let estimated = layouter.estimatedHeight(for: item, bucket: 50)
        let exact = layouter.exactLayout(for: item, bucket: 50)
        #expect(estimated > 0 && exact.height > 0)
        #expect(abs(estimated - exact.height) < exact.height * 0.9, "оценка не обязана быть точной, но в ту сторону")
    }

    @Test func bubblePathFollowsFrameAndRadii() {
        let bubble = BubbleLayout(frame: CGRect(x: 100, y: 0, width: 200, height: 60),
                                  topLeft: 12, topRight: 4, bottomLeft: 12, bottomRight: 4, meta: nil)
        let path = MessageCellView.bubblePath(bubble)
        #expect(path.bounds == bubble.frame, "контур точно в рамке пузыря")
    }

    /// ADR 0041 M-6: переключение стиля контроллером переводит layouter и
    /// сбрасывает измерения (тот же путь, что смена размера текста).
    @MainActor @Test func controllerSwitchesRowStyle() {
        let controller = TimelineViewController()
        #expect(controller.layouter.style == .flat, "default off")
        controller.usesBubbleStyle = true
        #expect(controller.layouter.style == .bubble)
        controller.usesBubbleStyle = false
        #expect(controller.layouter.style == .flat)
        // Повторная установка того же значения не дёргает сброс.
        controller.usesBubbleStyle = false
        #expect(!controller.isViewLoaded)
    }

    /// ADR 0041 M-7: hover-бар у края пузыря, в flat — у края строки.
    @Test func hoverBarAnchorsToBubbleEdge() {
        let clip = CGRect(x: 0, y: 0, width: 800, height: 600)
        let flat = TimelineViewController.hoverBarX(rowMaxX: 795, bubbleMaxX: nil, barWidth: 120, clip: clip)
        #expect(flat == 659, "flat: у края строки")
        // Входящий пузырь: бар правым краем у пузыря.
        let incoming = TimelineViewController.hoverBarX(rowMaxX: 795, bubbleMaxX: 300, barWidth: 120, clip: clip)
        #expect(incoming == 172, "пузырь: у края пузыря")
        // Не уезжает за левый край видимой области.
        let clamped = TimelineViewController.hoverBarX(rowMaxX: 795, bubbleMaxX: 100, barWidth: 120, clip: clip)
        #expect(clamped == clip.minX + 4)
    }
}

/// Хост-стаб для прямой конфигурации MessageCellView без окна и контроллера.
@MainActor
private final class StubCellHost: TimelineCellHost {
    let renderer = MessageRenderer()
    let rowMetrics = TimelineRowMetrics(fonts: .forScale(1))
    var quickReactions: [String] { [] }
    func perform(_ action: TimelineAction) {}
    func performPrepared(_ action: TimelineAction) {}
    func image(for request: TimelineImageRequest) -> NSImage? { nil }
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

/// Ячейка с пузырём (ADR 0041 M-5): meta-строка, gutter hover-времени,
/// сброс при переиспользовании.
@MainActor @Suite("Bubble cell view")
struct BubbleCellTests {
    private let metrics = TimelineRowMetrics(fonts: .forScale(1))
    private let host = StubCellHost()

    private func layout(for post: PostPresentation, width: CGFloat = 400) -> MessageRowLayout {
        metrics.messageLayout(for: post, width: width, bodyHeight: 20, bodyUsedWidth: 60,
                              renderer: host.renderer, style: .bubble)
    }

    private func makePost(own: Bool, continuation: Bool = false, last: Bool = true,
                          edited: Bool = false) -> PostPresentation {
        PostPresentation(
            postID: PostID(unchecked: "p1"), pendingID: nil, channelID: CoreFixtures.channel(1).id, rootID: nil,
            author: AuthorPresentation(userID: own ? CoreFixtures.me.id : CoreFixtures.bob.id,
                                        displayName: own ? "Me" : "Bob", username: own ? "me" : "bob", isBot: false,
                                        isCurrentUser: own, avatarRevision: 0),
            createdAt: MattermostTimestamp(milliseconds: 1_700_000_000_000),
            isContinuation: continuation,
            body: .document(MessageDocument(blocks: [.paragraph([.text("hello")])]), isCollapsed: false),
            isEdited: edited, isPinned: false, files: [], reactions: [], replyCount: 0, showsThreadContext: false,
            sendState: nil, actions: .none, permalink: nil, isLastInGroup: last)
    }

    private func configureCell(_ post: PostPresentation) -> MessageCellView {
        let cell = MessageCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let body = host.renderer.render(post.body)
        let item = TimelineItem(id: TimelineItemID(.post(post.postID!)), revision: 1, content: .post(post))
        cell.configure(item: item, post: post, layout: layout(for: post), body: body, host: host)
        return cell
    }

    @Test func metaLabelAtGroupTailWithEdited() throws {
        let cell = configureCell(makePost(own: true, edited: true))
        let meta = try #require(cell.bubbleMetaLabel)
        #expect(!meta.isHidden)
        let bubble = try #require(cell.rowLayout.bubble)
        #expect(meta.frame == bubble.meta, "meta в рамке из layout")
        #expect(meta.attributedText.string.contains(TimelineStrings.edited), "«(edited)» в meta")
        #expect(meta.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                === TimelinePalette.bubbleOutgoingSecondary, "исходящий meta — светлый токен")
    }

    @Test func continuationHasNoMetaAndHoverTimeOnOwnSide() throws {
        let cell = configureCell(makePost(own: true, continuation: true, last: false))
        #expect(cell.bubbleMetaLabel?.isHidden != false, "у продолжения группы нет meta")
        cell.setHovered(true)
        cell.layout()
        let label = try #require(cell.hoverTimeLabel)
        #expect(!label.isHidden, "hover-время у строки без meta")
        let bubble = try #require(cell.rowLayout.bubble)
        #expect(label.frame.maxX < bubble.frame.minX, "gutter hover-времени — слева от своего пузыря")
        // Хвост группы с meta не дублирует время в gutter.
        let tail = configureCell(makePost(own: true, edited: true))
        tail.setHovered(true)
        tail.layout()
        #expect(tail.hoverTimeLabel?.isHidden != false, "meta уже в пузыре — gutter не нужен")
    }

    @Test func incomingMetaAlsoUsesOutgoingToken() throws {
        // Рендер OpenDesign: все пузыри одного цвета — meta везде исходящий токен.
        let cell = configureCell(makePost(own: false))
        let meta = try #require(cell.bubbleMetaLabel)
        #expect(meta.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                === TimelinePalette.bubbleOutgoingSecondary, "чужой meta — светлый токен исходящего")
        #expect(!cell.nameLabel.isHidden, "имя автора над чужим пузырём")
        #expect(cell.metaLabel.isHidden, "время уходит в meta-пилюлю, в строке автора его нет")
    }

    @Test func resetClearsBubbleMetaOnReuse() throws {
        let cell = configureCell(makePost(own: true, edited: true))
        #expect(cell.bubbleMetaLabel != nil && !(cell.bubbleMetaLabel?.isHidden ?? true))
        cell.resetContent()
        #expect(cell.bubbleMetaLabel?.isHidden == true, "переиспользование прячет meta")
    }

    /// ADR 0041 M-7: hover-тит живёт в пузыре, row view не красит всю строку;
    /// flat-строка подсвечивается по-старому.
    @Test func rowHoverRoutesThroughBubble() {
        let bubbled = configureCell(makePost(own: true))
        #expect(bubbled.isBubbled)
        let row = TimelineRowView(frame: NSRect(x: 0, y: 0, width: 400, height: bubbled.rowLayout.height))
        row.addSubview(bubbled)
        row.isHovered = true
        #expect(bubbled.isRowHovered, "row view передал hover ячейке")
        row.isHovered = false
        #expect(!bubbled.isRowHovered)
        // Flat: флаг доходит до ячейки, но она не пузырная — полнострочная
        // подсветка остаётся на row view.
        let flatCell = configureCell(makePost(own: true))
        flatCell.resetContent()
        #expect(!flatCell.isBubbled, "после сброса ячейка снова не пузырная")
        let flatRow = TimelineRowView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        flatRow.addSubview(flatCell)
        flatRow.isHovered = true
        #expect(flatCell.isRowHovered && !flatCell.isBubbled, "флаг передаётся, тит — на row view")
        flatRow.isHovered = false
        #expect(!flatCell.isRowHovered)
    }
}
