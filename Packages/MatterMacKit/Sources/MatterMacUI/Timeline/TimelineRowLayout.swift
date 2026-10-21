import AppKit
import MatterMacModels
import MatterMacCore

/// Frames for every component of a row at one layout width. Computed once per
/// (item revision, width bucket, font scale) and used both for the row height and for
/// the cell's manual frame layout, so measured height and display always agree.
enum RowLayout {
    case message(MessageRowLayout)
    case separator(SeparatorRowLayout)

    var height: CGFloat {
        switch self {
        case .message(let layout): layout.height
        case .separator(let layout): layout.height
        }
    }

    var estimatedCost: Int {
        switch self {
        case .message(let layout):
            TimelineLayoutCaches.rowLayoutBaseCost
                + (layout.attachments.count + layout.reactions.count + (layout.linkPreview == nil ? 8 : 13))
                * TimelineLayoutCaches.rowLayoutFrameCost
        case .separator:
            TimelineLayoutCaches.rowLayoutBaseCost
        }
    }
}

struct PendingLayout: Equatable {
    var spinner: CGRect?
    var status: CGRect
    var retry: CGRect?
    var discard: CGRect?
}

/// Геометрия пузыря (ADR 0041): контейнер-фон с индивидуальными радиусами углов
/// и meta-строка (время ± «(edited)») внутри у хвоста.
struct BubbleLayout: Equatable {
    var frame: CGRect
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat
    /// Строка meta внутри пузыря; nil — не хвост группы (время покажет hover).
    var meta: CGRect?
}

struct MessageRowLayout: Equatable {
    var height: CGFloat = 0
    var avatar: CGRect?
    var threadContext: CGRect?
    var header: CGRect?
    var body: CGRect = .zero
    var showMore: CGRect?
    /// Server-provided link preview card (below the text, above attachments).
    var linkPreview: LinkPreviewLayout?
    /// One frame per displayed file (at most `maximumDisplayedFiles`).
    var attachments: [CGRect] = []
    var attachmentOverflow: CGRect?
    /// One frame per displayed reaction chip (at most `maximumDisplayedReactions`).
    var reactions: [CGRect] = []
    var reactionOverflow: CGRect?
    var replies: CGRect?
    var pending: PendingLayout?
    /// Пузырь (ADR 0041): nil — flat-сетка или сервисная строка.
    var bubble: BubbleLayout?
}

struct SeparatorRowLayout: Equatable {
    var height: CGFloat
    /// Wrapping explanatory text (failed gap, history start).
    var label: CGRect = .zero
    var button: CGRect?
    var spinner: CGRect?
}

/// Layout constants and computations for timeline rows at one font scale.
struct TimelineRowMetrics {
    let fonts: TimelineFonts

    static let horizontalInset: CGFloat = 16
    static let avatarSize = TimelineMetrics.avatarSize
    static let avatarGap: CGFloat = 10
    static let contentLeading = horizontalInset + avatarSize + avatarGap
    static let headerTopPadding: CGFloat = 8
    static let continuationTopPadding: CGFloat = 2
    static let bottomPadding: CGFloat = 4
    static let componentSpacing: CGFloat = 6
    static let buttonHeight: CGFloat = 22
    static let fileChipHeight: CGFloat = 44
    static let fileChipMaximumWidth: CGFloat = 320
    static let chipSpacing: CGFloat = 4
    static let spinnerSize: CGFloat = 16
    static let maximumDisplayedFiles = 10
    static let maximumDisplayedReactions = 40
    static let minimumContentWidth: CGFloat = 80
    static let minimumThumbnailEdge: CGFloat = 24
    static let unknownImageSize = CGSize(width: 240, height: 160)

    /// Tall enough for an Apple Color Emoji line (taller than the text line) plus insets.
    var reactionChipHeight: CGFloat { ceil(max(fonts.bodyLineHeight, fonts.emojiLineHeight) + 6) }

    // Пузыри (ADR 0041 §3). Константы рендера OpenDesign: скругление 14 pt
    // (хвост 4 pt), отступы 7/12/8, доля пузыря ≤76% строки, аватар входящего 38.
    enum BubbleMetrics {
        static let cornerRadius: CGFloat = 14
        static let tailCornerRadius: CGFloat = 4
        static let horizontalPadding: CGFloat = 12
        static let verticalTopPadding: CGFloat = 7
        static let verticalBottomPadding: CGFloat = 8
        /// Зазор между последним контентом пузыря и meta-строкой.
        static let metaSpacing: CGFloat = 2
        /// Зазор между однострочным телом и meta, уместившейся в ту же строку.
        static let inlineMetaGap: CGFloat = 10
        /// Минимальная ширина текста внутри пузыря: отдельно от широкого flat-минимума,
        /// чтобы короткие «ok»-пузыри оставались компактными.
        static let minimumInnerWidth: CGFloat = 44
        /// Аватар входящего в пузырном режиме (рендер: avatar-38); flat остаётся 32.
        static let avatarSize: CGFloat = 38
        static let avatarGap: CGFloat = 8
        /// Доля ширины пузыря от контентной ширины строки (рендер: max-width 76%).
        static let columnFraction: CGFloat = 0.76
    }

    /// Левый край пузыря входящего: горизонтальный отступ + аватар 38 + зазор.
    static var bubbleLeading: CGFloat { horizontalInset + BubbleMetrics.avatarSize + BubbleMetrics.avatarGap }

    /// Ширина текстового содержимого пузыря при полной развёртке: до 76% контентной
    /// ширины строки (рендер `.bubble-col`), своей и чужой стороны. Аватар и
    /// горизонтальные отступы учтены; текст измеряется ровно на этой ширине, поэтому
    /// hug никогда не перевёрстывает строки.
    func bubbleInnerWidth(for post: PostPresentation, layoutWidth: CGFloat) -> CGFloat {
        let rowContent = layoutWidth - 2 * Self.horizontalInset
        let fractionCap = max(Self.minimumContentWidth, rowContent * BubbleMetrics.columnFraction)
        let available = post.author.isCurrentUser
            ? rowContent
            : layoutWidth - Self.bubbleLeading - Self.horizontalInset
        return max(Self.minimumContentWidth, min(available, fractionCap) - 2 * BubbleMetrics.horizontalPadding)
    }

    /// Текст meta-строки в хвосте пузыря: время ± «(edited)» (ADR 0041 §4).
    /// Цвет ячейка подставляет по поверхности пузыря; измерению нужен шрифт.
    func bubbleMetaText(for post: PostPresentation) -> NSAttributedString {
        var text = TimelineStrings.time(post.createdAt)
        if post.isEdited { text += " " + TimelineStrings.edited }
        return NSAttributedString(string: text, attributes: [.font: fonts.meta])
    }

    static func contentWidth(forLayoutWidth width: CGFloat) -> CGFloat {
        max(minimumContentWidth, width - contentLeading - horizontalInset)
    }

    /// Thumbnail box for an image file, scaled to fit 360×240 and the content width.
    static func thumbnailSize(for file: FileInfo, contentWidth: CGFloat) -> CGSize {
        let maxWidth = min(TimelineMetrics.maximumThumbnailSize.width, contentWidth)
        let maxHeight = TimelineMetrics.maximumThumbnailSize.height
        guard let width = file.width, let height = file.height, width > 0, height > 0 else {
            let box = unknownImageSize
            let scale = min(1, maxWidth / box.width)
            return CGSize(width: floor(box.width * scale), height: floor(box.height * scale))
        }
        let scale = min(1, maxWidth / CGFloat(width), maxHeight / CGFloat(height))
        return CGSize(width: max(minimumThumbnailEdge, floor(CGFloat(width) * scale)),
                      height: max(minimumThumbnailEdge, floor(CGFloat(height) * scale)))
    }

    static func showsThumbnail(_ file: FileInfo) -> Bool { file.isImage }

    func reactionTitle(_ reaction: ReactionGroup, renderer: MessageRenderer) -> (emoji: String, count: String) {
        (renderer.emojiText(for: reaction.emojiName), "\(reaction.count)")
    }

    /// Same measurement the chip draws with (`ReactionChipMetrics`), so nothing clips.
    func reactionChipWidth(_ reaction: ReactionGroup, renderer: MessageRenderer) -> CGFloat {
        let title = reactionTitle(reaction, renderer: renderer)
        return ReactionChipMetrics(emoji: title.emoji, count: title.count, fonts: fonts, custom: reaction.customEmojiID != nil).width
    }

    func statusText(for state: SendState) -> NSAttributedString {
        let color: NSColor = switch state {
        case .failed: .systemRed
        case .outcomeUnknown: .systemOrange
        default: .secondaryLabelColor
        }
        return NSAttributedString(string: TimelineStrings.sendStateDescription(state), attributes: [
            .font: fonts.meta, .foregroundColor: color,
        ])
    }

    static func showsSpinner(_ state: SendState) -> Bool {
        switch state {
        case .queued, .uploading, .sending: true
        case .failed, .outcomeUnknown: false
        }
    }

    static func offersUploadDiscard(_ state: SendState) -> Bool {
        switch state { case .queued, .uploading: true; default: false }
    }

    static func offersRetry(_ state: SendState) -> Bool {
        switch state {
        case .failed, .outcomeUnknown: true
        default: false
        }
    }

    // MARK: - Message rows

    /// Header, avatar, attachments, reactions, and accessories around a body of the
    /// given height. Deterministic: same inputs produce identical frames.
    /// `style` переключает сетку (ADR 0041): `.flat` — прежняя плоская раскладка;
    /// `.bubble` — пузырь вокруг тела/превью/аттачментов с meta в хвосте.
    /// `bodyUsedWidth` — занятая текстом ширина (точная мера), для hug-ширины
    /// пузыря; 0 в оценочном проходе.
    func messageLayout(for post: PostPresentation, width: CGFloat, bodyHeight: CGFloat,
                       bodyUsedWidth: CGFloat = 0, renderer: MessageRenderer, exact: Bool = true,
                       style: RowStyle = .flat) -> MessageRowLayout {
        switch style {
        case .flat:
            return flatMessageLayout(for: post, width: width, bodyHeight: bodyHeight, renderer: renderer, exact: exact)
        case .bubble:
            return bubbleMessageLayout(for: post, width: width, bodyHeight: bodyHeight, bodyUsedWidth: bodyUsedWidth,
                                       renderer: renderer, exact: exact)
        }
    }

    /// Telegram-style пузырь (ADR 0041): контейнер обнимает тело, превью ссылки и
    /// аттачменты; meta — отдельной строкой в хвосте; реакции, чип треда, кнопки и
    /// pending-статус — под пузырём. Своё — справа без аватара, чужое — слева с
    /// аватаром и именем над пузырём. Сервисные строки (system/deleted/unsupported)
    /// не заворачиваются — остаются плоской сеткой.
    private func bubbleMessageLayout(for post: PostPresentation, width: CGFloat, bodyHeight: CGFloat,
                                     bodyUsedWidth: CGFloat, renderer: MessageRenderer, exact: Bool) -> MessageRowLayout {
        switch post.body {
        case .document: break
        default:
            return flatMessageLayout(for: post, width: width, bodyHeight: bodyHeight, renderer: renderer, exact: exact)
        }
        var layout = MessageRowLayout()
        let own = post.author.isCurrentUser
        let headerNeeded = !post.isContinuation
        let innerMax = bubbleInnerWidth(for: post, layoutWidth: width)

        // Meta в хвосте: у однострочного тела время садится в ту же строку
        // («ok · 12:34»); многострочники и аттачменты держат meta ниже тела.
        let metaText: NSAttributedString? = post.isLastInGroup ? bubbleMetaText(for: post) : nil
        let metaWidth = metaText.map { DrawnText.width(of: $0) } ?? 0

        // Hug: в точном проходе короткий текст сжимает пузырь. Большие сущности
        // (превью, файлы) и оценочный проход используют полную ширину.
        var inner = innerMax
        if exact, post.linkPreview == nil, post.files.isEmpty {
            inner = max(min(bodyUsedWidth, innerMax), Self.BubbleMetrics.minimumInnerWidth)
        }
        let inlineMeta = exact && metaText != nil && post.linkPreview == nil && post.files.isEmpty
            && bodyUsedWidth > 0 && bodyHeight <= ceil(fonts.bodyLineHeight) + 0.5
            && bodyUsedWidth + Self.BubbleMetrics.inlineMetaGap + metaWidth <= innerMax
        if post.isLastInGroup {
            if inlineMeta {
                inner = min(max(inner, bodyUsedWidth + Self.BubbleMetrics.inlineMetaGap + metaWidth), innerMax)
            } else {
                inner = max(inner, min(metaWidth, innerMax))
            }
        }

        let padding = Self.BubbleMetrics.horizontalPadding
        let bubbleWidth = inner + 2 * padding
        let bubbleX: CGFloat = own ? width - Self.horizontalInset - bubbleWidth : Self.bubbleLeading
        // Полка аксессуаров под пузырём: от Leading edge содержимого пузыря.
        let accessoryX = bubbleX + padding
        let accessoryWidth = max(Self.minimumContentWidth,
                                 min(innerMax, width - Self.horizontalInset - accessoryX))
        var y: CGFloat = headerNeeded ? Self.headerTopPadding : Self.continuationTopPadding

        if post.showsThreadContext {
            layout.threadContext = CGRect(x: bubbleX, y: y, width: accessoryWidth, height: fonts.metaLineHeight)
            y += fonts.metaLineHeight + 2
        }
        // Имя автора — над пузырём входящего; у своего имени нет.
        if headerNeeded, !own {
            layout.avatar = CGRect(x: Self.horizontalInset, y: y,
                                    width: Self.BubbleMetrics.avatarSize, height: Self.BubbleMetrics.avatarSize)
            layout.header = CGRect(x: bubbleX, y: y, width: accessoryWidth, height: fonts.authorLineHeight)
            y += fonts.authorLineHeight + 2
        }

        let bubbleTop = y
        var innerY = bubbleTop + Self.BubbleMetrics.verticalTopPadding
        layout.body = CGRect(x: bubbleX + padding, y: innerY, width: inner, height: bodyHeight)
        innerY += bodyHeight

        if let preview = post.linkPreview {
            innerY += Self.componentSpacing
            let card = linkPreviewLayout(preview, origin: CGPoint(x: bubbleX + padding, y: innerY),
                                         contentWidth: inner, exact: exact)
            layout.linkPreview = card
            innerY += card.frame.height
        }

        let files = post.files.prefix(Self.maximumDisplayedFiles)
        for file in files {
            innerY += Self.componentSpacing
            if Self.showsThumbnail(file) {
                let size = Self.thumbnailSize(for: file, contentWidth: inner)
                layout.attachments.append(CGRect(x: bubbleX + padding, y: innerY, width: size.width, height: size.height))
                innerY += size.height
            } else {
                let chipWidth = min(inner, Self.fileChipMaximumWidth)
                layout.attachments.append(CGRect(x: bubbleX + padding, y: innerY, width: chipWidth, height: Self.fileChipHeight))
                innerY += Self.fileChipHeight
            }
        }
        if post.files.count > files.count {
            innerY += Self.componentSpacing
            layout.attachmentOverflow = CGRect(x: bubbleX + padding, y: innerY, width: inner, height: fonts.metaLineHeight)
            innerY += fonts.metaLineHeight
        }

        var bubble = BubbleLayout(frame: .zero, topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0, meta: nil)
        if metaText != nil {
            let metaFrameWidth = min(metaWidth + 4, inner)
            if inlineMeta {
                // Время в строке тела: прижато к низу однострочного тела.
                bubble.meta = CGRect(x: bubbleX + bubbleWidth - padding - metaFrameWidth,
                                     y: layout.body.maxY - fonts.metaLineHeight,
                                     width: metaFrameWidth, height: fonts.metaLineHeight)
            } else {
                innerY += Self.BubbleMetrics.metaSpacing
                bubble.meta = CGRect(x: bubbleX + bubbleWidth - padding - metaFrameWidth, y: innerY,
                                     width: metaFrameWidth, height: fonts.metaLineHeight)
                innerY += fonts.metaLineHeight
            }
        }

        let radius = Self.BubbleMetrics.cornerRadius
        let tail = Self.BubbleMetrics.tailCornerRadius
        bubble.frame = CGRect(x: bubbleX, y: bubbleTop, width: bubbleWidth,
                               height: innerY - bubbleTop + Self.BubbleMetrics.verticalBottomPadding)
        bubble.topLeft = post.isContinuation && !own ? tail : radius
        bubble.topRight = post.isContinuation && own ? tail : radius
        bubble.bottomLeft = post.isLastInGroup && !own ? tail : radius
        bubble.bottomRight = post.isLastInGroup && own ? tail : radius
        layout.bubble = bubble
        y = bubble.frame.maxY

        // Полка под пузырём: «Показать полностью», реакции, чип треда, pending.
        if case .document(_, true) = post.body {
            y += Self.componentSpacing
            layout.showMore = CGRect(x: accessoryX, y: y, width: accessoryWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }

        if !post.reactions.isEmpty {
            y += Self.componentSpacing
            let chipHeight = reactionChipHeight
            var x = accessoryX
            var lineY = y
            let maxX = accessoryX + accessoryWidth
            let shown = post.reactions.prefix(Self.maximumDisplayedReactions)
            for reaction in shown {
                let chipWidth = min(reactionChipWidth(reaction, renderer: renderer), accessoryWidth)
                if x > accessoryX, x + chipWidth > maxX {
                    x = accessoryX
                    lineY += chipHeight + Self.chipSpacing
                }
                layout.reactions.append(CGRect(x: x, y: lineY, width: chipWidth, height: chipHeight))
                x += chipWidth + Self.chipSpacing
            }
            if post.reactions.count > shown.count {
                let text = NSAttributedString(string: TimelineStrings.moreReactions(post.reactions.count - shown.count),
                                              attributes: [.font: fonts.meta])
                let overflowWidth = DrawnText.width(of: text) + 8
                if x > accessoryX, x + overflowWidth > maxX {
                    x = accessoryX
                    lineY += chipHeight + Self.chipSpacing
                }
                layout.reactionOverflow = CGRect(x: x, y: lineY, width: overflowWidth, height: chipHeight)
            }
            y = lineY + chipHeight
        }

        if post.replyCount > 0 {
            y += Self.componentSpacing
            layout.replies = CGRect(x: accessoryX, y: y, width: accessoryWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }

        if let state = post.sendState {
            y += Self.componentSpacing
            var pending = PendingLayout(status: .zero)
            var textX = accessoryX
            if Self.showsSpinner(state) {
                pending.spinner = CGRect(x: accessoryX, y: y + max(0, (fonts.metaLineHeight - Self.spinnerSize) / 2),
                                          width: Self.spinnerSize, height: Self.spinnerSize)
                textX += Self.spinnerSize + 6
            }
            let textWidth = max(Self.minimumContentWidth, accessoryX + accessoryWidth - textX)
            let textHeight = max(fonts.metaLineHeight, DrawnText.height(of: statusText(for: state), width: textWidth))
            pending.status = CGRect(x: textX, y: y, width: textWidth, height: textHeight)
            y += max(textHeight, pending.spinner == nil ? 0 : Self.spinnerSize)
            if Self.offersRetry(state) || Self.offersUploadDiscard(state) {
                y += 4
                if Self.offersRetry(state), post.pendingID != nil {
                    pending.retry = CGRect(x: accessoryX, y: y, width: 0, height: Self.buttonHeight)
                }
                pending.discard = CGRect(x: accessoryX, y: y, width: 0, height: Self.buttonHeight)
                y += Self.buttonHeight
            }
            layout.pending = pending
        }

        y += Self.bottomPadding
        if let avatar = layout.avatar { y = max(y, avatar.maxY + Self.bottomPadding) }
        layout.height = ceil(y)
        return layout
    }

    private func flatMessageLayout(for post: PostPresentation, width: CGFloat, bodyHeight: CGFloat,
                                   renderer: MessageRenderer, exact: Bool) -> MessageRowLayout {
        var layout = MessageRowLayout()
        let isSystem: Bool
        if case .system = post.body { isSystem = true } else { isSystem = false }
        let showsHeader = !post.isContinuation && !isSystem
        let contentX = Self.contentLeading
        let contentWidth = Self.contentWidth(forLayoutWidth: width)
        var y = showsHeader ? Self.headerTopPadding : Self.continuationTopPadding

        if post.showsThreadContext {
            layout.threadContext = CGRect(x: contentX, y: y, width: contentWidth, height: fonts.metaLineHeight)
            y += fonts.metaLineHeight + 2
        }
        if showsHeader {
            layout.avatar = CGRect(x: Self.horizontalInset, y: y, width: Self.avatarSize, height: Self.avatarSize)
            layout.header = CGRect(x: contentX, y: y, width: contentWidth, height: fonts.authorLineHeight)
            y += fonts.authorLineHeight + 2
        }
        layout.body = CGRect(x: contentX, y: y, width: contentWidth, height: bodyHeight)
        y += bodyHeight

        if case .document(_, true) = post.body {
            y += Self.componentSpacing
            layout.showMore = CGRect(x: contentX, y: y, width: contentWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }

        if let preview = post.linkPreview {
            y += Self.componentSpacing
            let card = linkPreviewLayout(preview, origin: CGPoint(x: contentX, y: y), contentWidth: contentWidth, exact: exact)
            layout.linkPreview = card
            y += card.frame.height
        }

        let files = post.files.prefix(Self.maximumDisplayedFiles)
        for file in files {
            y += Self.componentSpacing
            if Self.showsThumbnail(file) {
                let size = Self.thumbnailSize(for: file, contentWidth: contentWidth)
                layout.attachments.append(CGRect(x: contentX, y: y, width: size.width, height: size.height))
                y += size.height
            } else {
                let chipWidth = min(contentWidth, Self.fileChipMaximumWidth)
                layout.attachments.append(CGRect(x: contentX, y: y, width: chipWidth, height: Self.fileChipHeight))
                y += Self.fileChipHeight
            }
        }
        if post.files.count > files.count {
            y += Self.componentSpacing
            layout.attachmentOverflow = CGRect(x: contentX, y: y, width: contentWidth, height: fonts.metaLineHeight)
            y += fonts.metaLineHeight
        }

        if !post.reactions.isEmpty {
            y += Self.componentSpacing
            let chipHeight = reactionChipHeight
            var x = contentX
            var lineY = y
            let maxX = contentX + contentWidth
            let shown = post.reactions.prefix(Self.maximumDisplayedReactions)
            for reaction in shown {
                let chipWidth = min(reactionChipWidth(reaction, renderer: renderer), contentWidth)
                if x > contentX, x + chipWidth > maxX {
                    x = contentX
                    lineY += chipHeight + Self.chipSpacing
                }
                layout.reactions.append(CGRect(x: x, y: lineY, width: chipWidth, height: chipHeight))
                x += chipWidth + Self.chipSpacing
            }
            if post.reactions.count > shown.count {
                let text = NSAttributedString(string: TimelineStrings.moreReactions(post.reactions.count - shown.count),
                                              attributes: [.font: fonts.meta])
                let overflowWidth = DrawnText.width(of: text) + 8
                if x > contentX, x + overflowWidth > maxX {
                    x = contentX
                    lineY += chipHeight + Self.chipSpacing
                }
                layout.reactionOverflow = CGRect(x: x, y: lineY, width: overflowWidth, height: chipHeight)
            }
            y = lineY + chipHeight
        }

        if post.replyCount > 0 {
            y += Self.componentSpacing
            layout.replies = CGRect(x: contentX, y: y, width: contentWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }

        if let state = post.sendState {
            y += Self.componentSpacing
            var pending = PendingLayout(status: .zero)
            var textX = contentX
            if Self.showsSpinner(state) {
                pending.spinner = CGRect(x: contentX, y: y + max(0, (fonts.metaLineHeight - Self.spinnerSize) / 2),
                                         width: Self.spinnerSize, height: Self.spinnerSize)
                textX += Self.spinnerSize + 6
            }
            let textWidth = max(Self.minimumContentWidth, contentX + contentWidth - textX)
            let textHeight = max(fonts.metaLineHeight, DrawnText.height(of: statusText(for: state), width: textWidth))
            pending.status = CGRect(x: textX, y: y, width: textWidth, height: textHeight)
            y += max(textHeight, pending.spinner == nil ? 0 : Self.spinnerSize)
            if Self.offersRetry(state) || Self.offersUploadDiscard(state) {
                y += 4
                if Self.offersRetry(state), post.pendingID != nil {
                    pending.retry = CGRect(x: contentX, y: y, width: 0, height: Self.buttonHeight)
                }
                pending.discard = CGRect(x: contentX, y: y, width: 0, height: Self.buttonHeight)
                y += Self.buttonHeight
            }
            layout.pending = pending
        }

        y += Self.bottomPadding
        if let avatar = layout.avatar { y = max(y, avatar.maxY + Self.bottomPadding) }
        layout.height = ceil(y)
        return layout
    }

    // MARK: - Separator rows

    func dateSeparatorLayout(width: CGFloat) -> SeparatorRowLayout {
        let height = ceil(fonts.metaLineHeight + 20)
        return SeparatorRowLayout(height: height,
                                  label: CGRect(x: Self.horizontalInset, y: 10, width: max(0, width - 2 * Self.horizontalInset),
                                                height: fonts.metaLineHeight))
    }

    func unreadBoundaryLayout(width: CGFloat) -> SeparatorRowLayout {
        let height = ceil(fonts.metaLineHeight + 12)
        return SeparatorRowLayout(height: height,
                                  label: CGRect(x: Self.horizontalInset, y: 6, width: max(0, width - 2 * Self.horizontalInset),
                                                height: fonts.metaLineHeight))
    }

    func gapText(_ gap: GapPresentation) -> NSAttributedString? {
        let text: String
        switch gap.state {
        case .idle: return nil
        case .loading: text = gap.direction == .older ? TimelineStrings.loadingOlder : TimelineStrings.loadingNewer
        case .failed(let error): text = TimelineStrings.loadFailed(gap.direction, error)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: fonts.meta, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
    }

    func gapLayout(_ gap: GapPresentation, width: CGFloat) -> SeparatorRowLayout {
        let textWidth = max(Self.minimumContentWidth, width - 2 * Self.horizontalInset)
        var layout = SeparatorRowLayout(height: 0)
        var y: CGFloat = 10
        switch gap.state {
        case .idle:
            layout.button = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        case .loading:
            let textHeight = gapText(gap).map { DrawnText.height(of: $0, width: textWidth) } ?? 0
            layout.spinner = CGRect(x: Self.horizontalInset, y: y, width: Self.spinnerSize, height: Self.spinnerSize)
            layout.label = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: max(textHeight, Self.spinnerSize))
            y += max(textHeight, Self.spinnerSize)
        case .failed:
            let textHeight = gapText(gap).map { DrawnText.height(of: $0, width: textWidth) } ?? 0
            layout.label = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: textHeight)
            y += textHeight + 6
            layout.button = CGRect(x: Self.horizontalInset, y: y, width: textWidth, height: Self.buttonHeight)
            y += Self.buttonHeight
        }
        layout.height = ceil(y + 10)
        return layout
    }

    func historyStartText(_ name: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: TimelineStrings.historyStart(name), attributes: [
            .font: fonts.font(size: fonts.bodySize, bold: true, italic: false, mono: false),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
    }

    func historyStartLayout(channelName: String, width: CGFloat) -> SeparatorRowLayout {
        let textWidth = max(Self.minimumContentWidth, width - 2 * Self.horizontalInset)
        let textHeight = DrawnText.height(of: historyStartText(channelName), width: textWidth)
        return SeparatorRowLayout(height: ceil(textHeight + 32),
                                  label: CGRect(x: Self.horizontalInset, y: 16, width: textWidth, height: textHeight))
    }

    // MARK: - Estimates

    /// Cheap estimate for a body that has not been measured: counts characters per
    /// block without building attributed text. Linear in document size.
    func estimatedBodyHeight(_ body: MessageBody, contentWidth: CGFloat, budget: ResourceBudget) -> CGFloat {
        let bodyCharsPerLine = max(8, contentWidth / (fonts.bodySize * 0.52))
        let monoCharsPerLine = max(8, contentWidth / max(fonts.monoAdvance, 1))
        var lines: CGFloat = 0
        var extra: CGFloat = 0
        func textLines(_ length: Int, perLine: CGFloat) -> CGFloat { max(1, ceil(CGFloat(length) / perLine)) }

        switch body {
        case .document(let document, let collapsed):
            var remaining = collapsed ? budget.collapsedMessageCharacters : budget.maximumRenderedCharacters
            estimate(document.blocks, bodyPerLine: bodyCharsPerLine, monoPerLine: monoCharsPerLine,
                     lines: &lines, extra: &extra, remaining: &remaining, depth: 0)
            if document.blocks.count > 1 { extra += CGFloat(document.blocks.count - 1) * (fonts.bodyLineHeight * 0.5) }
        case .system(let text):
            lines = textLines(text.utf16.count, perLine: bodyCharsPerLine)
        case .deleted:
            lines = 1
        case .unsupported(let summary, let fallback):
            lines = textLines(summary.utf16.count, perLine: bodyCharsPerLine)
                + (fallback.isEmpty ? 0 : textLines(fallback.utf16.count, perLine: bodyCharsPerLine))
        }
        return ceil(max(1, lines) * fonts.bodyLineHeight + extra)
    }

    private func estimate(_ blocks: [MarkupBlock], bodyPerLine: CGFloat, monoPerLine: CGFloat, lines: inout CGFloat,
                          extra: inout CGFloat, remaining: inout Int, depth: Int) {
        for block in blocks {
            if remaining <= 0 { return }
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines):
                var length = 0
                var breaks = 0
                Self.count(inlines, length: &length, breaks: &breaks, depth: 0)
                remaining -= length
                lines += max(1, ceil(CGFloat(length) / bodyPerLine)) + CGFloat(breaks)
                if case .heading = block { extra += fonts.bodyLineHeight }
            case .codeBlock(_, let code):
                var codeLines: CGFloat = 0
                var lineLength = 0
                for unit in code.utf16 {
                    if unit == 0x0A {
                        codeLines += max(1, ceil(CGFloat(lineLength) / monoPerLine))
                        lineLength = 0
                    } else {
                        lineLength += 1
                    }
                }
                codeLines += max(1, ceil(CGFloat(lineLength) / monoPerLine))
                remaining -= code.utf16.count
                lines += codeLines
                extra += 12
            case .blockQuote(let children):
                if depth < MessageRenderer.maximumBlockDepth {
                    estimate(children, bodyPerLine: bodyPerLine * 0.95, monoPerLine: monoPerLine, lines: &lines,
                             extra: &extra, remaining: &remaining, depth: depth + 1)
                } else {
                    lines += 1
                }
            case .list(let list):
                for entry in list.items {
                    let item = entry.blocks
                    estimate(item, bodyPerLine: bodyPerLine * 0.92, monoPerLine: monoPerLine, lines: &lines,
                             extra: &extra, remaining: &remaining, depth: depth + 1)
                    if item.isEmpty { lines += 1 }
                }
            case .table(let table):
                lines += CGFloat(min(table.rows.count, MessageRenderer.maximumTableRows) + 2)
            case .attachment(let attachment):
                let length = MessageDocument(blocks: [.attachment(attachment)]).plainText.utf16.count
                remaining -= length
                lines += max(1, ceil(CGFloat(length) / bodyPerLine))
            case .thematicBreak:
                lines += 1
            case .plainFallback(let text):
                remaining -= text.utf16.count
                lines += max(1, ceil(CGFloat(text.utf16.count) / monoPerLine))
            }
        }
    }

    private static func count(_ inlines: [MarkupInline], length: inout Int, breaks: inout Int, depth: Int) {
        for inline in inlines {
            switch inline {
            case .text(let text), .code(let text): length += text.utf16.count
            case .emphasis(let children), .strong(let children), .strikethrough(let children),
                 .link(_, let children):
                if depth < MessageRenderer.maximumInlineDepth {
                    count(children, length: &length, breaks: &breaks, depth: depth + 1)
                }
            case .mention(let name), .channelMention(let name), .hashtag(let name): length += name.utf16.count + 1
            case .emoji: length += 2
            case .lineBreak, .softBreak: breaks += 1
            }
        }
    }
}
