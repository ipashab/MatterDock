import AppKit
import MatterMacModels
import MatterMacCore

/// Produces rendered body text and row layouts for timeline items using the shared
/// bounded caches and one reusable TextKit 1 measuring stack. Main-actor only.
final class TimelineRowLayouter {
    struct Counters: Equatable {
        var renders = 0
        var renderCacheHits = 0
        var measurements = 0
        var layoutCacheHits = 0
        var estimates = 0
    }

    let caches: TimelineLayoutCaches
    let budget: ResourceBudget
    private let measurer = TextMeasurer()
    private(set) var renderer: MessageRenderer
    private(set) var metrics: TimelineRowMetrics
    var context: TimelineContextKey?
    var appearance: RenderAppearance = .light
    /// Стиль строк (ADR 0041); входит в кэш-ключи и в messageLayout.
    var style: RowStyle = .flat
    var counters = Counters()

    init(caches: TimelineLayoutCaches, budget: ResourceBudget) {
        self.caches = caches
        self.budget = budget
        let renderer = MessageRenderer()
        self.renderer = renderer
        self.metrics = TimelineRowMetrics(fonts: renderer.fonts)
    }

    var fontScaleKey: Int { metrics.fonts.scaleKey }

    func updateRenderer(fontScale: CGFloat, currentUsername: String?, emojiLookup: TimelineEmojiLookup?) {
        renderer = MessageRenderer(fontScale: fontScale, currentUsername: currentUsername, emojiLookup: emojiLookup)
        metrics = TimelineRowMetrics(fonts: renderer.fonts)
    }

    // MARK: - Body text

    func bodyText(for item: TimelineItem, post: PostPresentation) -> NSAttributedString {
        guard let context else {
            counters.renders += 1
            return rendered(post)
        }
        let key = RenderCacheKey(context: context, item: item.id, revision: item.revision, appearance: appearance,
                                 fontScaleKey: fontScaleKey, style: style)
        if let cached = caches.renderedText(for: key) {
            counters.renderCacheHits += 1
            return cached
        }
        counters.renders += 1
        let text = rendered(post)
        caches.storeRenderedText(text, for: key)
        return text
    }

    /// Body text plus the trailing "(edited)" marker for edited messages, so it is shown
    /// on continuation rows too and measured with the text it follows. На пузырях
    /// (ADR 0041) маркер не приклеивается к телу — он переезжает в meta внутри
    /// пузыря (рисуется ячейкой поверх surface-текста).
    private func rendered(_ post: PostPresentation) -> NSAttributedString {
        let surface: RenderSurface
        if style == .bubble, case .document = post.body {
            surface = post.author.isCurrentUser ? .outgoing : .incoming
        } else {
            surface = .plain
        }
        let text = renderer.render(post.body, budget: budget, customEmoji: post.customEmoji, surface: surface)
        guard post.isEdited, surface == .plain, case .document(let document, _) = post.body else { return text }
        return renderer.appendingEditedMarker(to: text, inlineAfterParagraph: document.blocks.last.map {
            if case .paragraph = $0 { return true }
            return false
        } ?? true)
    }

    // MARK: - Layout

    static func layoutWidth(forBucket bucket: Int) -> CGFloat {
        CGFloat(max(bucket, 1)) * TimelineMetrics.widthBucket
    }

    private func key(for item: TimelineItem, bucket: Int) -> RowLayoutKey? {
        guard let context else { return nil }
        return RowLayoutKey(context: context, item: item.id, revision: item.revision, widthBucket: bucket,
                            fontScaleKey: fontScaleKey, style: style)
    }

    /// Cached exact layout, without measuring.
    func cachedLayout(for item: TimelineItem, bucket: Int) -> RowLayout? {
        guard let key = key(for: item, bucket: bucket) else { return nil }
        return caches.peekRowLayout(for: key)
    }

    /// Exact layout: from the cache, or rendered and measured with TextKit 1.
    func exactLayout(for item: TimelineItem, bucket: Int) -> RowLayout {
        let key = key(for: item, bucket: bucket)
        if let key, let cached = caches.rowLayout(for: key) {
            counters.layoutCacheHits += 1
            return cached
        }
        let width = Self.layoutWidth(forBucket: bucket)
        let layout: RowLayout
        switch item.content {
        case .post(let post):
            counters.measurements += 1
            let text = bodyText(for: item, post: post)
            var bodyHeight: CGFloat
            var bodyUsedWidth: CGFloat = 0
            var bubbled = false
            if style == .bubble, case .document = post.body { bubbled = true }
            if bubbled {
                // Пузырь (ADR 0041): текст измеряется на своей территории —
                // hug не перевёрстывает строки.
                let measured = measurer.measure(of: text, width: metrics.bubbleInnerWidth(for: post, layoutWidth: width))
                bodyHeight = measured.height
                bodyUsedWidth = measured.usedWidth
            } else {
                bodyHeight = measurer.height(of: text, width: TimelineRowMetrics.contentWidth(forLayoutWidth: width))
            }
            layout = .message(metrics.messageLayout(for: post, width: width, bodyHeight: bodyHeight,
                                                    bodyUsedWidth: bodyUsedWidth, renderer: renderer, style: style))
        default:
            layout = .separator(separatorLayout(for: item, width: width))
        }
        if let key { caches.storeRowLayout(layout, for: key) }
        return layout
    }

    /// Whether an item's exact layout is cheap enough to compute without deferring
    /// (separator rows: no attributed body text).
    func isCheap(_ item: TimelineItem) -> Bool {
        if case .post = item.content { return false }
        return true
    }

    /// Estimated height for an unmeasured post row; exact for separators.
    func estimatedHeight(for item: TimelineItem, bucket: Int) -> CGFloat {
        let width = Self.layoutWidth(forBucket: bucket)
        switch item.content {
        case .post(let post):
            counters.estimates += 1
            // Оценка на территории пузыря, если стиль включён (ADR 0041); точный
            // проход сразу вслед перезапишет высоту.
            let measureWidth = style == .bubble ? metrics.bubbleInnerWidth(for: post, layoutWidth: width)
                                                : TimelineRowMetrics.contentWidth(forLayoutWidth: width)
            let bodyHeight = metrics.estimatedBodyHeight(post.body, contentWidth: measureWidth, budget: budget)
            return metrics.messageLayout(for: post, width: width, bodyHeight: bodyHeight, renderer: renderer,
                                         exact: false, style: style).height
        default:
            return separatorLayout(for: item, width: width).height
        }
    }

    func separatorLayout(for item: TimelineItem, width: CGFloat) -> SeparatorRowLayout {
        switch item.content {
        case .post: SeparatorRowLayout(height: 0)
        case .dateSeparator: metrics.dateSeparatorLayout(width: width)
        case .unreadBoundary: metrics.unreadBoundaryLayout(width: width)
        case .gap(let gap): metrics.gapLayout(gap, width: width)
        case .historyStart(let name): metrics.historyStartLayout(channelName: name, width: width)
        }
    }
}
