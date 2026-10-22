import AppKit

/// Панель форматирования над полем ввода — как в веб-клиенте: полужирный,
/// курсив, зачёркнутый, заголовок (меню H1–H3), ссылка, код, нумерованный и
/// маркированный списки, цитата. Кнопки действуют на общий текстовый вид
/// композера через те же форматтеры, что и клавиатурные команды (⌘B и др.),
/// поэтому бюджет драфта и undo работают как при вводе с клавиатуры.
final class ComposerToolbarView: NSStackView {
    static let height: CGFloat = 22
    private weak var textView: ComposerTextView?

    init(textView: ComposerTextView) {
        self.textView = textView
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false

        addToolbarButton(symbol: "bold", label: String(localized: "Bold")) { $0.formatBold(nil) }
        addToolbarButton(symbol: "italic", label: String(localized: "Italic")) { $0.formatItalic(nil) }
        addToolbarButton(symbol: "strikethrough", label: String(localized: "Strikethrough")) { $0.formatStrikethrough(nil) }
        addHeadingButton()
        addToolbarButton(symbol: "link", label: String(localized: "Link")) { $0.formatLink(nil) }
        addToolbarButton(symbol: "chevron.left.forwardslash.chevron.right",
                         label: String(localized: "Code")) { $0.formatCode(nil) }
        addToolbarButton(symbol: "list.number", label: String(localized: "Numbered List")) {
            $0.applyLineMarkers(.ordered)
        }
        addToolbarButton(symbol: "list.bullet", label: String(localized: "Bulleted List")) {
            $0.applyLineMarkers(.bullet)
        }
        addToolbarButton(symbol: "text.quote", label: String(localized: "Quote")) { $0.formatQuote(nil) }

        // Без required-hug: горизонтали даём сжиматься и растягиваться самой
        // строке ввода, иначе битая ширина панели транзитом уходит в колонку.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func addToolbarButton(symbol: String, label: String,
                                  action: @escaping (ComposerTextView) -> Void) {
        let button = ToolbarFormatButton(label: label, symbol: symbol, action: action)
        button.target = self
        button.action = #selector(performFormatting(_:))
        addArrangedSubview(button)
    }

    /// Кнопка заголовка: клик раскрывает меню уровней (как «H▾» в веб-клиенте).
    private func addHeadingButton() {
        let menu = NSMenu()
        for level in 1...3 {
            let item = NSMenuItem(title: String(localized: "Heading \(level)"), action: nil, keyEquivalent: "")
            item.tag = level
            item.target = self
            item.action = #selector(applyHeading(_:))
            menu.items.append(item)
        }
        let button = ToolbarFormatButton(label: String(localized: "Heading"), symbol: "textformat.size") { _ in }
        button.headingMenu = menu
        button.target = self
        button.action = #selector(performFormatting(_:))
        addArrangedSubview(button)
    }

    /// Только для тестов: пункты меню уровней заголовка (H1–H3).
    var headingMenuItemsForTesting: [NSMenuItem] {
        for case let button as ToolbarFormatButton in arrangedSubviews where button.headingMenu != nil {
            return button.headingMenu?.items ?? []
        }
        return []
    }

    @objc private func performFormatting(_ sender: NSButton) {
        guard let button = sender as? ToolbarFormatButton, let textView else { return }
        window?.makeFirstResponder(textView)
        if let menu = button.headingMenu {
            // Меню уровней свисает с кнопки вниз, на поле ввода.
            let point = NSPoint(x: button.frame.minX - 4, y: -2)
            menu.popUp(positioning: nil, at: point, in: self)
        } else {
            button.perform(textView)
        }
    }

    @objc private func applyHeading(_ item: NSMenuItem) {
        textView?.applyLineMarkers(.heading(item.tag))
    }
}

/// Кнопка-иконка панели: хранит действие форматирования (target-action NSButton
/// не хранит замыканий). `headingMenu` отличает кнопку заголовка — её клик
/// раскрывает меню, а не форматирует напрямую. Internal для тестов.
final class ToolbarFormatButton: NSButton {
    private let format: (ComposerTextView) -> Void
    var headingMenu: NSMenu?

    init(label: String, symbol: String, action: @escaping (ComposerTextView) -> Void) {
        self.format = action
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(label)
        toolTip = label
        translatesAutoresizingMaskIntoConstraints = false
        // Ширина сжимаемая: required-ширина девяти кнопок задирала бы
        // минимальную ширину всего композера, и колонка разговора получала
        // фиксированный узкий кусок вместо гибкого остатка. В реальных ширинах
        // (>400 пт) кнопки всегда получают полные 22 пт.
        let width = widthAnchor.constraint(equalToConstant: ComposerToolbarView.height)
        width.priority = .defaultHigh
        width.isActive = true
        heightAnchor.constraint(equalToConstant: ComposerToolbarView.height).isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func perform(_ textView: ComposerTextView) { format(textView) }
}
