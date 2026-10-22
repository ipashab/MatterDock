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
    /// Карточка «ответ на сообщение» (props.quote_post_id): полоса + автор + обрывок.
    var replyContext: CGRect?
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
    /// Аватарки участников треда у чипа «N ответов» (ADR 0045): кадры параллельны
    /// `PostPresentation.threadParticipants`, идут после текста чипа.
    var threadAvatars: [CGRect] = []
    /// Бабл «+N» за аватарками, когда участников больше показанного.
    var threadOverflow: CGRect?
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
    /// Аватарка участника треда у чипа «N ответов» (ADR 0045): круг 16 pt,
    /// шаг 12 pt (наложение кругов), старт через 8 pt после текста чипа.
    static let threadAvatarSize: CGFloat = 16
    static let threadAvatarStep: CGFloat = 12
    static let threadAvatarLeading: CGFloat = 8
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
        /// Отступ overlay-пилюли meta от правого и нижнего края пузыря (рендер 10/4).
        static let metaOverlayInset: CGFloat = 10
        static let metaOverlayBottomInset: CGFloat = 4
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

    /// Текст чипа треда под пузырём (рендер: «N ответов · Имя: обрывок…»).
    /// Один и тот же построитель — для измерения шириной и для ячейки, чтобы
    /// hug никогда не обрезал чип.
    func threadChipText(for post: PostPresentation) -> NSAttributedString {
        let title = post.threadPreview.map { TimelineStrings.threadChip(post.replyCount, preview: $0) }
            ?? TimelineStrings.replies(post.replyCount)
        return NSAttributedString(string: title, attributes: [.font: fonts.metaBold])
    }

    /// Кадры аватарок участников треда (ADR 0045): за текстом чипа (chipWidth),
    /// свежие первыми, последним — бабл «+N». Высота чипа не меняется.
    func threadAvatarFrames(for post: PostPresentation, chipX: CGFloat, chipWidth: CGFloat, y: CGFloat)
        -> (avatars: [CGRect], overflow: CGRect?, width: CGFloat) {
        var x = chipX + chipWidth + Self.threadAvatarLeading
        let avatarY = y + (Self.buttonHeight - Self.threadAvatarSize) / 2
        var frames: [CGRect] = []
        for _ in post.threadParticipants {
            frames.append(CGRect(x: x, y: avatarY, width: Self.threadAvatarSize, height: Self.threadAvatarSize))
            x += Self.threadAvatarStep
        }
        var overflow: CGRect? = nil
        if post.threadParticipantsOverflow > 0 {
            let text = NSAttributedString(string: "+\(post.threadParticipantsOverflow)",
                                          attributes: [.font: fonts.meta])
            let width = max(Self.threadAvatarSize, DrawnText.width(of: text) + 6)
            overflow = CGRect(x: x, y: avatarY, width: width, height: Self.threadAvatarSize)
            x += width
        }
        return (frames, overflow, x - chipX - chipWidth)
    }

    /// Ширина карточки «ответ на сообщение» во внутреннем пространстве пузыря:
    /// полоса (3 pt) + отступ (7 pt) + самая длинная из двух строк.
    func replyContextCardWidth(_ context: ReplyContext) -> CGFloat {
        let author = NSAttributedString(string: context.authorName, attributes: [.font: fonts.metaBold])
        let snippet = NSAttributedString(string: context.snippet, attributes: [.font: fonts.meta])
        return max(DrawnText.width(of: author), DrawnText.width(of: snippet)) + 10
    }

    /// Высота карточки: две строки meta и распорка между ними.
    var replyContextHeight: CGFloat { fonts.metaLineHeight * 2 + 4 }

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
        // Карточка «ответ на» держит пузырь не уже себя — hug не должен обрезать её.
        if let context = post.replyContext {
            inner = max(inner, min(replyContextCardWidth(context), innerMax))
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
        // Стороны классические: своё — колонка у правого края, чужое — у левого,
        // с аватаром слева и именем над пузырём (владелец вернул аватары влево).
        // Колонка контента ≤76% ширины строки: имя и полка — внутри колонки.
        let avatarRail: CGFloat = own ? 0 : Self.BubbleMetrics.avatarSize + Self.BubbleMetrics.avatarGap
        let columnWidth = innerMax + 2 * padding
        let columnLeft: CGFloat = own ? width - Self.horizontalInset - columnWidth
                                      : Self.horizontalInset + avatarRail
        let columnRight = columnLeft + columnWidth
        let bubbleX = own ? columnRight - bubbleWidth : columnLeft
        // Полка аксессуаров под пузырём живёт в границах колонки; прижим — по
        // стороне автора.
        let accessoryX = columnLeft
        let accessoryWidth = columnWidth
        var y: CGFloat = headerNeeded ? Self.headerTopPadding : Self.continuationTopPadding
        let rowTop = y

        if post.showsThreadContext {
            layout.threadContext = CGRect(x: columnLeft, y: y, width: columnWidth, height: fonts.metaLineHeight)
            y += fonts.metaLineHeight + 2
        }
        // Имя автора — над пузырём у головного поста чужих (у своего имени нет);
        // аватар стоит у каждого чужого поста, слева от колонки.
        if headerNeeded, !own {
            layout.header = CGRect(x: columnLeft, y: y, width: columnWidth, height: fonts.authorLineHeight)
            y += fonts.authorLineHeight + 2
        }
        if !own {
            layout.avatar = CGRect(x: Self.horizontalInset, y: rowTop + 3,
                                   width: Self.BubbleMetrics.avatarSize, height: Self.BubbleMetrics.avatarSize)
        }

        let bubbleTop = y
        var innerY = bubbleTop + Self.BubbleMetrics.verticalTopPadding
        // «Ответ на сообщение» (props.quote_post_id): полоса-карточка над телом,
        // внутри пузыря — как у Telegram.
        if post.replyContext != nil {
            layout.replyContext = CGRect(x: bubbleX + padding, y: innerY, width: inner,
                                          height: replyContextHeight)
            innerY += replyContextHeight + 4
        }
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
            let metaFrameWidth = min(metaWidth + 4, max(inner, metaWidth))
            if inlineMeta {
                // Однострочное тело: время в той же строке, прижат к правому краю.
                bubble.meta = CGRect(x: bubbleX + bubbleWidth - padding - metaFrameWidth,
                                     y: layout.body.maxY - fonts.metaLineHeight,
                                     width: metaFrameWidth, height: fonts.metaLineHeight)
            } else {
                // Многострочники и аттачменты: пилюля-оверлей в правом нижнем углу
                // пузыря (рендер: `.msg-meta { right:10px; bottom:4px }`), вне потока.
                bubble.meta = CGRect(
                    x: bubbleX + bubbleWidth - Self.BubbleMetrics.metaOverlayInset - metaFrameWidth,
                    y: bubbleTop + (innerY - bubbleTop) + Self.BubbleMetrics.verticalBottomPadding
                        - Self.BubbleMetrics.metaOverlayBottomInset - fonts.metaLineHeight,
                    width: metaFrameWidth, height: fonts.metaLineHeight)
            }
        }

        // Сторона автора держит хвост: своё — правый нижний угол, чужое — левый
        // (зеркально, как у мессенджеров); остальные углы — 14.
        bubble.frame = CGRect(x: bubbleX, y: bubbleTop, width: bubbleWidth,
                               height: innerY - bubbleTop + Self.BubbleMetrics.verticalBottomPadding)
        bubble.topLeft = Self.BubbleMetrics.cornerRadius
        bubble.topRight = Self.BubbleMetrics.cornerRadius
        bubble.bottomLeft = Self.BubbleMetrics.cornerRadius
        bubble.bottomRight = Self.BubbleMetrics.cornerRadius
        if own { bubble.bottomRight = Self.BubbleMetrics.tailCornerRadius }
        else { bubble.bottomLeft = Self.BubbleMetrics.tailCornerRadius }
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
            var chipLineMaxes: [CGFloat: CGFloat] = [:]
            for reaction in shown {
                let chipWidth = min(reactionChipWidth(reaction, renderer: renderer), accessoryWidth)
                if x > accessoryX, x + chipWidth > maxX {
                    x = accessoryX
                    lineY += chipHeight + Self.chipSpacing
                }
                layout.reactions.append(CGRect(x: x, y: lineY, width: chipWidth, height: chipHeight))
                chipLineMaxes[lineY.rounded()] = max(chipLineMaxes[lineY.rounded()] ?? accessoryX,
                                                     x + chipWidth)
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
                chipLineMaxes[lineY.rounded()] = max(chipLineMaxes[lineY.rounded()] ?? accessoryX,
                                                     x + overflowWidth)
            }
            // Реакции прижаты к краю колонки по стороне автора: своё — правым
            // краем, чужое — левым.
            let reactionShift: (CGFloat) -> CGFloat = own
                ? { lineMax in columnRight - lineMax }
                : { _ in 0 }
            for index in layout.reactions.indices {
                let key = layout.reactions[index].minY.rounded()
                if let lineMax = chipLineMaxes[key] {
                    layout.reactions[index].origin.x += reactionShift(lineMax)
                }
            }
            if let overflow = layout.reactionOverflow, let lineMax = chipLineMaxes[overflow.minY.rounded()] {
                layout.reactionOverflow!.origin.x += reactionShift(lineMax)
            }
            y = lineY + chipHeight
        }

        if post.replyCount > 0 {
            y += Self.componentSpacing
            // Чип треда с превью последнего ответа (рендер: «N ответов · Имя: …»),
            // hug-ширины, прижат к краю колонки по стороне автора; следом —
            // аватарки участников и бабл остатка (ADR 0045).
            let chipWidth = min(columnWidth, DrawnText.width(of: threadChipText(for: post)) + 20)
            let avatars = threadAvatarFrames(for: post, chipX: columnLeft, chipWidth: chipWidth, y: y)
            if chipWidth + avatars.width <= columnWidth {
                let runWidth = chipWidth + avatars.width
                let runX = own ? columnRight - runWidth : columnLeft
                layout.replies = CGRect(x: runX, y: y, width: chipWidth, height: Self.buttonHeight)
                let placed = threadAvatarFrames(for: post, chipX: runX, chipWidth: chipWidth, y: y)
                layout.threadAvatars = placed.avatars
                layout.threadOverflow = placed.overflow
            } else {
                let chipX = own ? columnRight - chipWidth : columnLeft
                layout.replies = CGRect(x: chipX, y: y, width: chipWidth, height: Self.buttonHeight)
            }
            y += Self.buttonHeight
        }

        if let state = post.sendState {
            y += Self.componentSpacing
            var pending = PendingLayout(status: .zero)
            // Pending-статус прижат к краю колонки по стороне автора, hug-ширины.
            let statusW = min(accessoryWidth, DrawnText.width(of: statusText(for: state)) + 4)
            let statusTextHeight = max(fonts.metaLineHeight, DrawnText.height(of: statusText(for: state), width: statusW))
            if Self.showsSpinner(state) {
                pending.spinner = CGRect(x: own ? columnRight - statusW - Self.spinnerSize - 6 : columnLeft,
                                        y: y + max(0, (fonts.metaLineHeight - Self.spinnerSize) / 2),
                                        width: Self.spinnerSize, height: Self.spinnerSize)
            }
            let statusX = own ? columnRight - statusW
                             : columnLeft + (Self.showsSpinner(state) ? Self.spinnerSize + 6 : 0)
            pending.status = CGRect(x: statusX, y: y, width: statusW, height: statusTextHeight)
            y += max(statusTextHeight, pending.spinner == nil ? 0 : Self.spinnerSize)
            if Self.offersRetry(state) || Self.offersUploadDiscard(state) {
                y += 4
                if Self.offersRetry(state), post.pendingID != nil {
                    pending.retry = CGRect(x: own ? columnRight : columnLeft, y: y, width: 0, height: Self.buttonHeight)
                }
                pending.discard = CGRect(x: own ? columnRight : columnLeft, y: y, width: 0, height: Self.buttonHeight)
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
        if post.replyContext != nil {
            layout.replyContext = CGRect(x: contentX, y: y, width: contentWidth, height: replyContextHeight)
            y += replyContextHeight + 2
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
            // Аватарки участников — сразу за видимым текстом чипа (ADR 0045);
            // не влезают в строку — не показываем, высота ряда не меняется.
            let textWidth = min(contentWidth, DrawnText.width(of: threadChipText(for: post)) + 20)
            if contentWidth - textWidth > Self.threadAvatarSize + Self.threadAvatarLeading {
                let placed = threadAvatarFrames(for: post, chipX: contentX, chipWidth: textWidth, y: y)
                let columnMaxX = contentX + contentWidth
                let inBounds = placed.avatars.allSatisfy { $0.maxX <= columnMaxX }
                    && (placed.overflow?.maxX ?? 0) <= columnMaxX
                if inBounds {
                    layout.threadAvatars = placed.avatars
                    layout.threadOverflow = placed.overflow
                }
            }
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
