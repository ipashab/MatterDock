import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor @Suite("Native Markdown rendering")
struct RenderingTests {
    @Test func tablesTasksAndAttachmentsKeepStructureAndMeasureLikeCells() throws {
        let document = MarkupParser.parse("# Heading\n\n> quote\n\n- [x] done\n- [ ] todo\n\n| **Left** | Right |\n| :--- | ---: |\n| value | 42 |\n\n```swift\nlet x = 1\n```\n\n---\n\n@alice #topic")
        let attachment = MarkupAttachment(accent: .good, author: "Build bot", title: "Build",
            titleLink: SafeLink("https://example.org"), fields: [
                .init(title: "Job", value: [.paragraph([.text("tests")])], isShort: true),
                .init(title: "Status", value: [.paragraph([.text("passed")])], isShort: true)],
            hasUnsupportedActions: true)
        var body = document
        body.blocks.append(.attachment(attachment))
        let renderer = MessageRenderer(currentUsername: "alice")
        let text = renderer.render(body)
        #expect(text.string.contains("☑"))
        #expect(text.string.contains("☐"))
        #expect(text.string.contains("Interactive buttons"))
        var tables = 0
        var mentions = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, _ in
            if let style = attrs[.paragraphStyle] as? NSParagraphStyle,
               style.textBlocks.contains(where: { $0 is NSTextTableBlock }) { tables += 1 }
            if attrs[.matterMacSelfMention] != nil { mentions += 1 }
        }
        #expect(tables > 0)
        #expect(TimelineLayoutCaches.renderCost(of: text) > text.length * TimelineLayoutCaches.renderBytesPerUTF16Unit)
        #expect(mentions > 0)
        let view = MessageBodyTextView(usingTextLayoutManager: false)
        view.configureForTimeline()
        let measurer = TextMeasurer()
        for width: CGFloat in [180, 420, 720] {
            view.setText(text, width: width)
            let container = try #require(view.textContainer)
            let manager = try #require(view.layoutManager)
            manager.ensureLayout(for: container)
            #expect(measurer.height(of: text, width: width) == ceil(manager.usedRect(for: container).maxY))
        }
    }

    @Test func tableLimitsAreVisibleAndGlobalBudgetStillApplies() {
        let table = MarkupTable(alignments: [.left], header: [[.text("Header")]],
            rows: Array(repeating: [[.text("value")]], count: 60))
        let renderer = MessageRenderer()
        let document = MessageDocument(blocks: [.table(table)])
        #expect(renderer.render(document).string.contains("10 more rows not shown"))
        #expect(renderer.render(document, characterLimit: 12).length <= 13)
    }

    /// Регрессия: у `NSTextBlock` ширина контента по умолчанию нулевая, и без явного
    /// растягивания TextKit выдаёт блоку нулевой прямоугольник — рамка кода, цитаты,
    /// разделителя и вложения не рисуется вообще. Прямоугольник рисования обязан
    /// занимать всю ширину контейнера.
    @Test func decoratedBlocksSpanTheFullContainerWidth() throws {
        let document = MarkupParser.parse("> quoted text\n\n```\ncoded text\n```\n\n---")
        let text = MessageRenderer().render(document)
        let view = MessageBodyTextView(usingTextLayoutManager: false)
        view.configureForTimeline()
        view.setText(text, width: 420)
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        manager.ensureLayout(for: container)

        let string = text.string as NSString
        for needle in ["quoted text", "coded text"] {
            let location = string.range(of: needle).location
            #expect(location != NSNotFound, "нет подстроки \(needle) в отрендеренном тексте")
            guard location != NSNotFound else { continue }
            let style = try #require(text.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                                    as? NSParagraphStyle)
            let block = try #require(style.textBlocks.first)
            let bounds = manager.boundsRect(for: block, at: manager.glyphIndexForCharacter(at: location),
                                           effectiveRange: nil)
            #expect(bounds.minX == 0, "блок \(needle) начинается не от левого края контейнера")
            #expect(bounds.width == 420, "блок \(needle) шире/уже контейнера: \(bounds.width)")
        }
    }

    /// ADR 0041 M-2: полная мера (высота + занятая ширина) для hug-ширины пузыря.
    @Test func measureReportsUsedWidthForBubbleHug() {
        let measurer = TextMeasurer()
        let renderer = MessageRenderer()
        let short = renderer.render(MarkupParser.parse("ok"))
        let long = renderer.render(MarkupParser.parse(String(repeating: "word ", count: 120)))
        let (h1, w1) = measurer.measure(of: short, width: 400)
        #expect(h1 > 0 && w1 > 0 && w1 < 400, "однострочник уже контейнера: \(w1)")
        let (h2, w2) = measurer.measure(of: long, width: 400)
        #expect(h2 > h1, "многострочник выше")
        #expect(w2 == 400, "перенос Claire занимает всю ширину, а не \(w2)")
    }

    /// ADR 0041 M-2: смена стиля строки — другие ключи; кэши не читают чужие записи.
    @Test func styleChangeBypassesLayoutAndRenderCaches() {
        let caches = TimelineLayoutCaches()
        let layouter = TimelineRowLayouter(caches: caches, budget: .standard)
        layouter.context = TimelineContextKey(
            scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
            target: .channel(CoreFixtures.channel(1).id))
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        let presentation = PostPresentation(
            postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
            author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob", isBot: false,
                                       isCurrentUser: false, avatarRevision: 0),
            createdAt: post.createAt, isContinuation: false, body: .document(MarkupParser.parse("hello"), isCollapsed: false),
            isEdited: false, isPinned: false, files: [], reactions: [], replyCount: 0, showsThreadContext: false,
            sendState: nil, actions: .none, permalink: nil)
        let item = TimelineItem(id: TimelineItemID(.post(post.id)), revision: 1, content: .post(presentation))

        // Первый проход по каждому ключу — измерения и рендер.
        _ = layouter.exactLayout(for: item, bucket: 50)
        _ = layouter.bodyText(for: item, post: presentation)
        #expect(layouter.counters.measurements == 1 && layouter.counters.renders == 1)
        // Повтор тех же ключей — только попадания в кэш.
        _ = layouter.exactLayout(for: item, bucket: 50)
        _ = layouter.bodyText(for: item, post: presentation)
        #expect(layouter.counters.measurements == 1 && layouter.counters.layoutCacheHits == 1)
        // exactLayout уже взял текст из кэша + один явный вызов: два хита рендера.
        #expect(layouter.counters.renders == 1 && layouter.counters.renderCacheHits == 2)
        // Другой стиль — другие ключи: снова работа, новых хитов нет.
        layouter.style = .bubble
        _ = layouter.exactLayout(for: item, bucket: 50)
        _ = layouter.bodyText(for: item, post: presentation)
        #expect(layouter.counters.measurements == 2 && layouter.counters.layoutCacheHits == 1)
        #expect(layouter.counters.renders == 2 && layouter.counters.renderCacheHits == 3)
        // Память: обе ветки лежат в кэше одновременно, пока не вымоет LRU.
        #expect(caches.rowLayoutCount == 2 && caches.renderCount == 2)
    }
}
