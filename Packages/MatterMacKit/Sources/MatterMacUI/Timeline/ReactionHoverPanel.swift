import AppKit
import MatterMacCore

/// Панель «кто отреагировал» поверх таймлайна у чипа под курсором — как подсказка
/// реакторов в веб-клиенте, но мгновенно: нативный `toolTip` появляется только
/// после системной задержки. Одна на весь таймлайн, как `HoverActionBar`, —
/// heights строк не меняются. Внешность общая с `HoverActionBar`: Liquid Glass
/// на macOS 26+, ниже — материал меню.
final class ReactionHoverPanel: NSView {
    static let maxWidth: CGFloat = 300
    static let minWidth: CGFloat = 90
    static let inset: CGFloat = 9

    /// Пост+эмодзи, для которых панель показана сейчас (повторная сборка
    /// текста под курсором не нужна).
    private(set) var itemID: TimelineItemID?
    private(set) var emojiName: String?

    private let background: NSView
    private let content = NSView()
    private let label = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))

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
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Первая строка — кто отреагировал, вторая — подсказка про клик.
    func configure(item: TimelineItemID, emojiName: String, names: String, hint: String) {
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
        needsLayout = true
    }

    func reset() {
        itemID = nil
        emojiName = nil
        isHidden = true
    }

    /// Размер панели под текущий текст (ширина — до `maxWidth`).
    var preferredSize: CGSize {
        label.preferredMaxLayoutWidth = Self.maxWidth - 2 * Self.inset
        let text = label.fittingSize
        let width = min(Self.maxWidth, max(Self.minWidth, text.width)) + 2 * Self.inset
        return CGSize(width: width, height: text.height + 2 * Self.inset)
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        content.frame = background.bounds
        label.frame = NSRect(x: Self.inset, y: Self.inset,
                             width: max(1, bounds.width - 2 * Self.inset),
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
