import AppKit
import MatterMacModels
import MatterMacCore

/// Карточка «ответ на сообщение» (серверное `props.quote_post_id`): полоса у края,
/// имя автора цитаты и обрывок текста. Клик переносит к процитированному посту;
/// поверхность (свой/чужой пузырь, flat-сетка) задаёт цвета при настройке.
final class ReplyContextCardView: TimelinePressableView {
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 7

    private var authorText = NSAttributedString()
    private var snippetText = NSAttributedString()
    private var barColor = TimelinePalette.quoteBar
    private var lineHeight: CGFloat = 12

    /// Строки и цвета по поверхности (свой/чужой пузырь, flat-сетка); карточка
    /// flipped, рисуем от верхней грани: сперва автор, ниже — обрывок.
    func configure(context: ReplyContext, surface: RenderSurface, fonts: TimelineFonts) {
        let isOutgoing = surface == .outgoing
        let authorColor: NSColor = isOutgoing ? TimelinePalette.bubbleOutgoingLink : NSColor.linkColor
        let snippetColor: NSColor = isOutgoing ? TimelinePalette.bubbleOutgoingSecondary : NSColor.secondaryLabelColor
        barColor = isOutgoing ? TimelinePalette.bubbleOutgoingQuoteBar : TimelinePalette.quoteBar
        lineHeight = fonts.metaLineHeight
        authorText = NSAttributedString(string: context.authorName, attributes: [
            .font: fonts.metaBold, .foregroundColor: authorColor,
            .paragraphStyle: Self.truncating,
        ])
        snippetText = NSAttributedString(string: context.snippet, attributes: [
            .font: fonts.meta, .foregroundColor: snippetColor,
            .paragraphStyle: Self.truncating,
        ])
        setAccessibilityLabel(TimelineStrings.replyToAccessibility(context))
        needsDisplay = true
    }

    var displayedAuthor: String { authorText.string }
    var displayedSnippet: String { snippetText.string }

    func resetCard() {
        resetPressable()
        authorText = NSAttributedString()
        snippetText = NSAttributedString()
        barColor = TimelinePalette.quoteBar
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    override func draw(_ dirtyRect: NSRect) {
        drawAtPressedOpacity {
            guard !authorText.string.isEmpty else { return }
            let textX = Self.barWidth + Self.barGap
            let textWidth = max(0, bounds.width - textX)
            barColor.setFill()
            NSRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height).fill()
            let truncate: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading,
                                                     .truncatesLastVisibleLine]
            authorText.draw(with: CGRect(x: textX, y: 0, width: textWidth, height: lineHeight),
                            options: truncate, context: nil)
            snippetText.draw(with: CGRect(x: textX, y: lineHeight + 4, width: textWidth, height: lineHeight),
                             options: truncate, context: nil)
        }
    }
}
