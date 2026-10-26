import AppKit
import MatterMacCore

/// Панель «кто отреагировал» поверх таймлайна у чипа под курсором — как подсказка
/// реакторов в веб-клиенте, но мгновенно: нативный `toolTip` появляется только
/// после системной задержки. Одна на весь таймлайн, как `HoverActionBar`, —
/// heights строк не меняются. Внешность общая с `HoverActionBar`: Liquid Glass
/// на macOS 26+, ниже — материал меню.
final class ReactionHoverPanel: NSView {
    static let maxWidth: CGFloat = 320
    static let minWidth: CGFloat = 120
    static let inset: CGFloat = 9
    /// Квадрат крупного эмодзи слева от текста (как в веб-клиенте).
    static let emojiSize: CGFloat = 40
    static let emojiGap: CGFloat = 10

    /// Пост+эмодзи, для которых панель показана сейчас (повторная сборка
    /// текста под курсором не нужна).
    private(set) var itemID: TimelineItemID?
    private(set) var emojiName: String?

    private let background: NSView
    private let content = NSView()
    private let label = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
    private let emojiGlyph = NSTextField(labelWithString: "")
    private let emojiImage = AnimatedImageView(frame: .zero)
    /// Собственный тактовик панели: цель одна, таймер живёт, пока панель
    /// показывает GIF-эмодзи (ADR 0058).
    private let emojiAnimator = EmojiFrameAnimator()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 8
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 8
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            background = effect
        }
        super.init(frame: frameRect)
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        addSubview(background)
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return shadow
        }()
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = Self.maxWidth - 2 * Self.inset
        content.addSubview(label)
        // Крупный эмодзи: глиф для системного, картинка для кастомного.
        emojiGlyph.font = .systemFont(ofSize: Self.emojiSize * 0.78)
        emojiGlyph.alignment = .center
        emojiGlyph.isHidden = true
        content.addSubview(emojiGlyph)
        emojiImage.imageScaling = .scaleProportionallyUpOrDown
        emojiImage.isHidden = true
        content.addSubview(emojiImage)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Первая строка — кто отреагировал, вторая — подсказка про клик; слева —
    /// крупный эмодзи (глиф или подоспевшая картинка кастомного).
    func configure(item: TimelineItemID, emojiName: String, names: String, hint: String,
                   glyph: String, image: NSImage?, animation: ImagePipeline.Animation? = nil) {
        guard itemID != item || self.emojiName != emojiName else { return }
        itemID = item
        self.emojiName = emojiName
        let text = NSMutableAttributedString(string: names, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: "\n" + hint, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        label.attributedStringValue = text
        setAccessibilityLabel(names + ", " + hint)
        emojiGlyph.stringValue = glyph
        setEmojiImage(image, animation: animation)
        showsImage = image != nil || animation != nil
        emojiGlyph.isHidden = showsImage
        emojiImage.isHidden = !showsImage
        needsLayout = true
    }

    /// Картинка кастомного эмодзи подоспела после показа панели.
    func updateEmojiImage(_ image: NSImage?, animation: ImagePipeline.Animation? = nil) {
        guard itemID != nil, image != nil || animation != nil, !showsImage else { return }
        setEmojiImage(image, animation: animation)
        showsImage = true
        emojiGlyph.isHidden = true
        emojiImage.isHidden = false
        needsLayout = true
    }

    /// Один путь для глифа/статики/анимации: анимация сильнее статичной
    /// картинки, её снимает тактовик панели.
    private func setEmojiImage(_ image: NSImage?, animation: ImagePipeline.Animation?) {
        if let animation {
            emojiImage.setAnimation(animation, animator: emojiAnimator)
        } else {
            emojiImage.setAnimation(nil, animator: nil)
            emojiImage.image = image
        }
    }

    private var showsImage = false

    /// Только для тестов: что сейчас в квадрате крупного эмодзи.
    var displayedGlyph: String { emojiGlyph.isHidden ? "" : emojiGlyph.stringValue }
    var displayedImage: NSImage? { emojiImage.isHidden ? nil : emojiImage.image }

    func reset() {
        itemID = nil
        emojiName = nil
        emojiGlyph.stringValue = ""
        emojiImage.setAnimation(nil, animator: nil)
        emojiImage.image = nil
        showsImage = false
        isHidden = true
    }

    /// Размер панели под текущий текст (ширина — до `maxWidth`).
    var preferredSize: CGSize {
        let emojiWidth = Self.emojiSize + Self.emojiGap
        label.preferredMaxLayoutWidth = Self.maxWidth - 2 * Self.inset - emojiWidth
        let text = label.fittingSize
        let width = min(Self.maxWidth, max(Self.minWidth, text.width + emojiWidth)) + 2 * Self.inset
        return CGSize(width: width, height: max(text.height, Self.emojiSize) + 2 * Self.inset)
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        content.frame = background.bounds
        let emojiFrame = NSRect(x: Self.inset, y: (bounds.height - Self.emojiSize) / 2,
                                width: Self.emojiSize, height: Self.emojiSize)
        emojiGlyph.frame = emojiFrame
        emojiImage.frame = emojiFrame
        let textX = Self.inset + Self.emojiSize + Self.emojiGap
        label.frame = NSRect(x: textX, y: Self.inset,
                             width: max(1, bounds.width - textX - Self.inset),
                             height: max(1, bounds.height - 2 * Self.inset))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let effect = background as? NSVisualEffectView {
            effect.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Клики по панели не проваливаются в таймлайн под ней.
    override func mouseDown(with event: NSEvent) {}
}
