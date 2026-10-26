import AppKit
import MatterMacModels
import MatterMacCore

/// Native system-emoji picker for "Add Reaction": a search field, a static
/// "Frequently Used" row (the account's recent reactions, then defaults), and the catalog grid by
/// category. The search field keeps focus: arrow keys move the grid selection,
/// Return picks the selected emoji (the first one by default), Escape cancels.
/// Custom emoji are loaded by page while browsing, or by the server autocomplete.
final class ReactionPickerViewController: NSViewController, NSSearchFieldDelegate, NSCollectionViewDataSource,
                                          NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    struct Entry: Equatable {
        let name: String
        let glyph: String
        let customID: String?
        init(_ emoji: SystemEmoji) { name = emoji.name; glyph = emoji.glyph; customID = nil }
        init(_ emoji: CustomEmoji) { name = emoji.name; glyph = ":"; customID = emoji.id }
    }
    struct Section: Equatable {
        let title: String
        let emoji: [Entry]
    }
    var customPage: ((Int, String) async -> [CustomEmoji])?
    var customImage: ((String) async -> ImagePipeline.Decoded?)?
    var customLimit = ResourceBudget.standard.customEmojiPickerEntries
    /// Тактовик GIF-эмодзи сетки: один таймер на видимые ячейки (ADR 0058).
    /// Сетка показывает десятки ячеек, лимит общий таймлайна здесь тесен.
    let emojiAnimator = EmojiFrameAnimator()
    private var customEntries: [Entry] = []
    private(set) var customTask: Task<Void, Never>?
    private var customGeneration = 0
    private var nextPage = 0
    private var hasMore = true
    private var currentQuery = ""


    static let itemSize = NSSize(width: 32, height: 32)
    static let columns = 9
    static let spacing: CGFloat = 2
    static let inset: CGFloat = 8
    static let headerHeight: CGFloat = 22
    /// Search results shown at most (the catalog bounds the work as well).
    static let maximumResults = 90
    static var preferredSize: NSSize {
        NSSize(width: inset * 2 + CGFloat(columns) * itemSize.width + CGFloat(columns - 1) * spacing, height: 360)
    }

    /// Called with the chosen emoji's short name (as sent to the server).
    var onPick: ((String) -> Void)?
    var onCancel: (() -> Void)?

    let catalog: EmojiCatalog
    let searchField = NSSearchField()
    let collectionView = EmojiGridView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No matching emoji"))
    /// Панель превью по удержанию (для тестов).
    let holdPreview = EmojiHoldPreview()
    private(set) var sections: [Section] = []
    private(set) var selection: IndexPath?
    /// Last VoiceOver announcement (the selected emoji's name), for tests.
    private(set) var lastAnnouncement: String?
    private let browseSections: [Section]

    /// `recent`: the user's reaction emoji, most recent first; the defaults fill the row.
    init(catalog: EmojiCatalog = .system, recent: [String] = []) {
        self.catalog = catalog
        var names: [String] = []
        for name in recent + EmojiCatalog.defaultQuickReactions where !names.contains(name) && names.count < 16 {
            names.append(name)
        }
        let frequent = names.compactMap(catalog.emoji(named:))
        browseSections = [Section(title: String(localized: "Frequently Used"), emoji: frequent.map(Entry.init))]
            + EmojiCategory.allCases.filter(\.isShownInPicker).map {
                Section(title: $0.displayName, emoji: catalog.pickerEmoji(in: $0).map(Entry.init))
            }
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var selectedEmoji: Entry? {
        guard let selection, sections.indices.contains(selection.section),
              sections[selection.section].emoji.indices.contains(selection.item) else { return nil }
        return sections[selection.section].emoji[selection.item]
    }

    override func loadView() {
        emojiAnimator.maximumTargets = 256
        let root = NSView(frame: NSRect(origin: .zero, size: Self.preferredSize))
        searchField.placeholderString = String(localized: "Search emoji")
        searchField.setAccessibilityLabel(String(localized: "Search emoji"))
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = NSEdgeInsets(top: 0, left: Self.inset, bottom: 6, right: Self.inset)
        layout.headerReferenceSize = NSSize(width: Self.preferredSize.width, height: Self.headerHeight)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(EmojiPickerItem.self, forItemWithIdentifier: EmojiPickerItem.identifier)
        collectionView.register(EmojiPickerHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: EmojiPickerHeader.identifier)
        collectionView.setAccessibilityLabel(String(localized: "Emoji"))

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        collectionView.picker = self
        holdPreview.isHidden = true
        root.addSubview(holdPreview)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.preferredSize.height),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        view = root
        preferredContentSize = Self.preferredSize
        apply(query: "")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Query and selection

    /// Shows the browse grid for an empty query, otherwise bounded search results.
    func apply(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sections = browseSections
        } else {
            // The server refuses reaction names over 64 characters (a few skin-tone
            // combinations are longer), so those are not offered.
            let results = catalog.search(trimmed, limit: Self.maximumResults).map(\.emoji)
                .filter { Reaction.isValidEmojiName($0.name) }
            sections = results.isEmpty ? [] : [Section(title: String(localized: "Search Results"), emoji: results.map(Entry.init))]
        }
        currentQuery = trimmed
        customGeneration += 1
        customTask?.cancel()
        customTask = nil
        customEntries = []
        nextPage = 0
        hasMore = true
        loadCustomPage()
        hideEmojiPreview()
        emptyLabel.isHidden = !sections.isEmpty
        collectionView.reloadData()
        select(sections.firstIndex { !$0.emoji.isEmpty }.map { IndexPath(item: 0, section: $0) }, announce: false)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        hideEmojiPreview()
        customGeneration += 1
        customTask?.cancel()
        customTask = nil
        for case let item as EmojiPickerItem in collectionView.visibleItems() { item.cancelImage() }
    }

    func loadCustomPage() {
        guard customTask == nil, hasMore, let customPage else { return }
        let generation = customGeneration, page = nextPage, query = currentQuery
        customTask = Task { [weak self] in
            let result = await customPage(page, query)
            guard !Task.isCancelled, let self, customGeneration == generation else { return }
            customTask = nil
            var known = Set(customEntries.map(\.name))
            let additions = result.filter { known.insert($0.name).inserted }.map(Entry.init)
            customEntries += additions
            customEntries = Array(customEntries.prefix(max(0, customLimit)))
            nextPage += 1
            hasMore = query.isEmpty && result.count == 60 && !additions.isEmpty && customEntries.count < customLimit
            sections.removeAll { $0.title == String(localized: "Custom") }
            if !customEntries.isEmpty { sections.append(Section(title: String(localized: "Custom"), emoji: customEntries)) }
            emptyLabel.isHidden = !sections.isEmpty
            collectionView.reloadData()
            if selection == nil { select(sections.firstIndex { !$0.emoji.isEmpty }.map { IndexPath(item: 0, section: $0) }, announce: false) }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if sections[indexPath.section].title == String(localized: "Custom"),
           indexPath.item >= customEntries.count - 18 { loadCustomPage() }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? EmojiPickerItem)?.cancelImage()
    }

    private func select(_ path: IndexPath?, announce: Bool = true) {
        selection = path
        // The highlight is drawn by the items; the collection view's own selection
        // stays empty so that every click (even on the highlighted item) reports.
        for case let item as EmojiPickerItem in collectionView.visibleItems() {
            item.isCurrent = collectionView.indexPath(for: item) == path
        }
        guard let path else { return }
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        if announce, let emoji = selectedEmoji {
            let text = Self.spokenName(emoji)
            lastAnnouncement = text
            NSAccessibility.post(element: searchField, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Moves by `delta` items in reading order across sections (Left/Right).
    func moveSelection(by delta: Int) {
        let flat = sections.indices.flatMap { section in sections[section].emoji.indices.map { IndexPath(item: $0, section: section) } }
        guard !flat.isEmpty else { return }
        let current = selection.flatMap(flat.firstIndex(of:)) ?? 0
        select(flat[min(max(0, current + delta), flat.count - 1)])
    }

    /// Moves one grid row up or down (Up/Down), across section boundaries.
    func moveSelectionRow(down: Bool) {
        guard let selection else { moveSelection(by: 0); return }
        let rowLength = columnCount
        let section = sections[selection.section].emoji.count
        let column = selection.item % rowLength
        if down {
            if selection.item + rowLength < section {
                select(IndexPath(item: selection.item + rowLength, section: selection.section))
            } else if selection.item / rowLength < (section - 1) / rowLength {
                select(IndexPath(item: section - 1, section: selection.section)) // shorter last row
            } else if let next = sections.indices.first(where: { $0 > selection.section && !sections[$0].emoji.isEmpty }) {
                select(IndexPath(item: min(column, sections[next].emoji.count - 1), section: next))
            }
        } else {
            if selection.item >= rowLength {
                select(IndexPath(item: selection.item - rowLength, section: selection.section))
            } else if let previous = sections.indices.last(where: { $0 < selection.section && !sections[$0].emoji.isEmpty }) {
                let count = sections[previous].emoji.count
                let lastRowStart = (count - 1) / rowLength * rowLength
                select(IndexPath(item: min(lastRowStart + column, count - 1), section: previous))
            }
        }
    }

    /// Items per grid row as laid out (a legacy scroller may take one column).
    var columnCount: Int {
        let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : Self.preferredSize.width
        let fitting = (width - Self.inset * 2 + Self.spacing) / (Self.itemSize.width + Self.spacing)
        return max(1, Int(fitting.rounded(.down)))
    }

    func pickSelection() {
        guard let emoji = selectedEmoji else { NSSound.beep(); return }
        onPick?(emoji.name)
    }

    /// Выбор ячейки: клик мыши (через `EmojiGridView`) и Enter сходятся здесь.
    func pick(at path: IndexPath) {
        guard sections.indices.contains(path.section),
              sections[path.section].emoji.indices.contains(path.item) else { return }
        collectionView.deselectItems(at: [path])
        selection = path
        onPick?(sections[path.section].emoji[path.item].name)
    }

    // MARK: - Превью по удержанию

    /// Крупный эмодзи над удерживаемой ячейкой (выбор при этом не совершается).
    func showEmojiPreview(at path: IndexPath) {
        guard sections.indices.contains(path.section),
              sections[path.section].emoji.indices.contains(path.item),
              let item = collectionView.item(at: path) as? EmojiPickerItem else { return }
        holdPreviewPath = path
        let entry = sections[path.section].emoji[path.item]
        holdPreview.show(glyph: entry.customID == nil ? item.previewGlyph : nil,
                         name: entry.name, image: item.previewImage,
                         animation: item.previewAnimation)
        let cell = collectionView.convert(item.view.frame, to: view)
        holdPreview.frame = Self.holdPreviewFrame(cell: cell, bounds: view.bounds, side: EmojiHoldPreview.side)
        holdPreview.isHidden = false
    }

    func hideEmojiPreview() {
        holdPreviewPath = nil
        holdPreview.isHidden = true
        // Таймер превью не должен тикать, пока превью скрыто.
        holdPreview.stopAnimation()
    }

    /// Ячейка, для которой сейчас превью (nil — скрыто).
    private(set) var holdPreviewPath: IndexPath?

    /// Превью над ячейкой по центру; у верхней границы — вниз, всё внутрь границ.
    static func holdPreviewFrame(cell: NSRect, bounds: NSRect, side: CGFloat) -> NSRect {
        let x = min(max(bounds.minX + 4, cell.midX - side / 2), max(bounds.minX + 4, bounds.maxX - side - 4))
        var y = cell.maxY + 6
        if y + side > bounds.maxY - 4 { y = cell.minY - side - 6 }
        return NSRect(x: x, y: max(bounds.minY + 4, y), width: side, height: side)
    }

    static func spokenName(_ emoji: Entry) -> String {
        emoji.name.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        apply(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveLeft(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveRight(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelectionRow(down: false)
        case #selector(NSResponder.moveDown(_:)): moveSelectionRow(down: true)
        case #selector(NSResponder.insertNewline(_:)): pickSelection()
        case #selector(NSResponder.cancelOperation(_:)): onCancel?()
        default: return false
        }
        return true
    }

    // MARK: - NSCollectionViewDataSource / Delegate

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].emoji.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: EmojiPickerItem.identifier, for: indexPath)
        if let item = item as? EmojiPickerItem {
            item.emojiAnimator = emojiAnimator
            item.configure(sections[indexPath.section].emoji[indexPath.item], imageLoader: customImage)
            item.isCurrent = indexPath == selection
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: EmojiPickerHeader.identifier, for: indexPath)
        (view as? EmojiPickerHeader)?.label.stringValue = sections[indexPath.section].title
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // Клавиатурный/программный выбор; клики обрабатывает `EmojiGridView`.
        guard let path = indexPaths.first else { return }
        collectionView.deselectItems(at: indexPaths)
        pick(at: path)
    }
}

/// Машина жеста «нажал — держишь — отпустил» в сетке пикера: по порогу
/// удержания показать превью; отпускание после превью НЕ выбирает эмодзи
/// («зажали — посмотрели»); без превью выбирает, если курсор не ушёл с ячейки.
/// Чистая логика — цикл событий в `EmojiGridView` только кормит её.
final class EmojiHoldGesture {
    private let threshold: TimeInterval
    private var pressedAt: Date?
    private var previewed = false
    private var inside = true

    init(threshold: TimeInterval) { self.threshold = threshold }

    func press() {
        pressedAt = Date()
        previewed = false
        inside = true
    }

    /// Наступило время превью? Однократно: true ровно один раз за нажатие.
    func tick(now: Date = Date()) -> Bool {
        guard let pressedAt, !previewed, now.timeIntervalSince(pressedAt) >= threshold else { return false }
        previewed = true
        return true
    }

    func dragged(inside: Bool) { self.inside = inside }

    /// Отпускание: true — выбрать ячейку (быстрый клик по месту).
    func release() -> Bool {
        pressedAt = nil
        return !previewed && inside
    }
}

/// Сетка пикера держит нажатие сама: короткий клик выбирает эмодзи, удержание
/// дольше `defaultHoldDelay` показывает крупный эмодзи и НЕ выбирает. Собственный
/// цикл отслеживания нужен потому, что стандартный трекинг NSCollectionView не
/// даёт показать превью до отпускания кнопки.
final class EmojiGridView: NSCollectionView {
    weak var picker: ReactionPickerViewController?
    static let defaultHoldDelay: TimeInterval = 0.35
    /// Порог удержания; тесты ставят 0 или большой интервал, чтобы пройти
    /// обе ветки цикла без реальных секунд.
    var holdDelay: TimeInterval = defaultHoldDelay

    override func mouseDown(with event: NSEvent) {
        guard let picker, let window, let path = hitPath(of: event) else {
            super.mouseDown(with: event)
            return
        }
        let gesture = EmojiHoldGesture(threshold: holdDelay)
        gesture.press()
        var previewed = false
        while true {
            if gesture.tick() {
                picker.showEmojiPreview(at: path)
                previewed = true
            }
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                              until: Date().addingTimeInterval(0.02),
                                              inMode: .default, dequeue: true) else { continue }
            switch next.type {
            case .leftMouseDragged:
                gesture.dragged(inside: hitPath(of: next) == path)
                if previewed, hitPath(of: next) != path { picker.hideEmojiPreview() }
            case .leftMouseUp:
                if previewed { picker.hideEmojiPreview() }
                else if gesture.release(), hitPath(of: next) == path { picker.pick(at: path) }
                return
            default:
                if previewed { picker.hideEmojiPreview() }
                return
            }
        }
    }

    private func hitPath(of event: NSEvent) -> IndexPath? {
        indexPathForItem(at: convert(event.locationInWindow, from: nil))
    }
}

/// Крупный эмодзи по удержанию в пикере — только просмотр. Внешность общая с
/// `ReactionHoverPanel`: Liquid Glass на macOS 26+, ниже — материал меню.
final class EmojiHoldPreview: NSView {
    static let side: CGFloat = 88
    static let contentSide: CGFloat = 56
    private static let glyphFontSize: CGFloat = 44
    private static let nameFontSize: CGFloat = 13

    private let background: NSView
    private let content = NSView()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let emojiView = AnimatedImageView(frame: .zero)
    /// Собственный тактовик превью: цель одна, таймер живёт только пока
    /// превью показано.
    private let emojiAnimator = EmojiFrameAnimator()
    override init(frame frameRect: NSRect) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 12
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            background = effect
        }
        super.init(frame: frameRect)
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        addSubview(background)
        content.addSubview(glyphLabel)
        content.addSubview(emojiView)
        glyphLabel.alignment = .center
        glyphLabel.font = .systemFont(ofSize: Self.glyphFontSize)
        emojiView.imageScaling = .scaleProportionallyUpOrDown
        glyphLabel.isHidden = true
        emojiView.isHidden = true
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Глиф — для системного эмодзи; картинка — для кастомного (если подгружена);
    /// иначе — короткая подпись `:name:`.
    func show(glyph: String?, name: String, image: NSImage?, animation: ImagePipeline.Animation? = nil) {
        if let animation {
            emojiView.isHidden = false
            glyphLabel.isHidden = true
            emojiView.setAnimation(animation, animator: emojiAnimator)
        } else if let image {
            emojiView.setAnimation(nil, animator: nil)
            emojiView.image = image
            emojiView.isHidden = false
            glyphLabel.isHidden = true
        } else {
            emojiView.setAnimation(nil, animator: nil)
            emojiView.image = nil
            emojiView.isHidden = true
            let text = glyph ?? ":\(name):"
            glyphLabel.font = .systemFont(ofSize: text.count <= 2 ? Self.glyphFontSize : Self.nameFontSize,
                                          weight: text.count <= 2 ? .regular : .medium)
            glyphLabel.stringValue = text
            glyphLabel.isHidden = false
        }
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        content.frame = background.bounds
        let side = Self.contentSide
        let origin = NSPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        glyphLabel.frame = NSRect(origin: origin, size: NSSize(width: side, height: side))
        emojiView.frame = NSRect(origin: origin, size: NSSize(width: side, height: side))
    }

    /// Останавливает анимацию скрытого превью (таймер тактовика гаснет).
    func stopAnimation() {
        emojiView.setAnimation(nil, animator: nil)
        emojiView.image = nil
    }

    /// Только для тестов: что сейчас показано в превью.
    var displayedText: String { glyphLabel.isHidden ? "" : glyphLabel.stringValue }
    var displayedImage: NSImage? { emojiView.isHidden ? nil : emojiView.image }

    /// Нажатие держит цикл сетки; сюда клики не проваливаются.
    override func mouseDown(with event: NSEvent) {}
}

/// One emoji cell: the glyph as a large label; VoiceOver reads the short name.
final class EmojiPickerItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("EmojiPickerItem")
    /// Конвейер переполнен — отказ это норма, а не ошибка. Ячейка не остаётся
    /// точками до перезахода в пикер: она переспрашивает с нарастающей паузой.
    private static let imageRetryDelays: [Duration] = [.milliseconds(400), .milliseconds(900),
                                                       .seconds(2), .seconds(4), .seconds(8)]
    private let glyphLabel = NSTextField(labelWithString: "")
    private let customImageView = AnimatedImageView(frame: .zero)
    /// Тактовик пикера (общий на все ячейки), задаётся при конфигурации.
    var emojiAnimator: EmojiFrameAnimator?
    private var imageTask: Task<Void, Never>?
    private var decodedImage: ImagePipeline.Decoded?
    private var imageID: String?
    /// Для тестов: картинка показана (не «точки»).
    private(set) var showsCustomImage = false

    /// Контент превью по удержанию: глиф и подгруженная картинка кастомного.
    var previewGlyph: String { glyphLabel.stringValue }
    var previewImage: NSImage? { showsCustomImage ? customImageView.image : nil }
    var previewAnimation: ImagePipeline.Animation? { showsCustomImage ? customImageView.animation : nil }


    override func loadView() {
        let cell = EmojiCellView(frame: NSRect(origin: .zero, size: ReactionPickerViewController.itemSize))
        glyphLabel.font = .systemFont(ofSize: 22)
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        glyphLabel.setAccessibilityElement(false)
        customImageView.frame = NSRect(x: 5, y: 5, width: 22, height: 22)
        customImageView.imageScaling = .scaleProportionallyUpOrDown
        customImageView.setAccessibilityElement(false)
        cell.addSubview(customImageView)
        cell.addSubview(glyphLabel)
        NSLayoutConstraint.activate([
            glyphLabel.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            glyphLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.button)
        view = cell
    }

    func cancelImage() {
        imageTask?.cancel()
        imageTask = nil
        imageID = nil
        customImageView.setAnimation(nil, animator: nil)
        customImageView.image = nil
        decodedImage = nil
        showsCustomImage = false
    }

    override func prepareForReuse() { super.prepareForReuse(); cancelImage() }

    func configure(_ emoji: ReactionPickerViewController.Entry,
                   imageLoader: ((String) async -> ImagePipeline.Decoded?)?) {
        _ = view
        cancelImage()
        glyphLabel.isHidden = false
        glyphLabel.stringValue = emoji.glyph
        if let id = emoji.customID, let imageLoader {
            imageID = id
            imageTask = Task { [weak self] in
                // Отказ конвейера (переполнение, сеть) — не ошибка картинки: просим
                // заново с паузой, пока не приедет или не выдохнемся.
                for attempt in 0...Self.imageRetryDelays.count {
                    if attempt > 0 {
                        try? await Task.sleep(for: Self.imageRetryDelays[attempt - 1])
                        if Task.isCancelled { return }
                    }
                    guard !Task.isCancelled, let self, imageID == id else { return }
                    if let decoded = await imageLoader(id) {
                        decodedImage = decoded
                        if let animation = decoded.animation {
                            customImageView.setAnimation(animation, animator: emojiAnimator)
                        } else {
                            customImageView.image = NSImage(cgImage: decoded.image, size: .zero)
                        }
                        glyphLabel.isHidden = true
                        showsCustomImage = true
                        imageTask = nil
                        return
                    }
                    // Отказ — переспросим с паузой ниже.
                }
            }
        }
        view.toolTip = ":" + emoji.name + ":"
        view.setAccessibilityLabel(ReactionPickerViewController.spokenName(emoji))
        view.setAccessibilityHelp(":" + emoji.name + ":")
    }

    /// The keyboard selection (drawn here; see `ReactionPickerViewController.select`).
    var isCurrent = false {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        (view as? EmojiCellView)?.isHighlighted = isCurrent
        view.setAccessibilitySelected(isCurrent)
    }
}

/// Layer-backed cell background; `updateLayer` resolves the dynamic color for the
/// current appearance.
final class EmojiCellView: NSView {
    var isHighlighted = false {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = isHighlighted ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
    }
}

final class EmojiPickerHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("EmojiPickerHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ReactionPickerViewController.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

extension EmojiCategory {
    var displayName: String {
        switch self {
        case .smileysEmotion: String(localized: "Smileys & Emotion")
        case .peopleBody: String(localized: "People & Body")
        case .animalsNature: String(localized: "Animals & Nature")
        case .foodDrink: String(localized: "Food & Drink")
        case .activities: String(localized: "Activities")
        case .travelPlaces: String(localized: "Travel & Places")
        case .objects: String(localized: "Objects")
        case .symbols: String(localized: "Symbols")
        case .flags: String(localized: "Flags")
        case .component: String(localized: "Components")
        }
    }
}

// MARK: - Presentation

/// Shows the picker in a transient popover anchored to the message row (or the
/// timeline when the row is not on screen) and hands the chosen name back.
enum ReactionPickerPresenter {
    @discardableResult
    static func present(for post: PostID, in timeline: TimelineViewController,
                        model: SessionViewModel? = nil, channel: ChannelID? = nil,
                        pick: @escaping (String) -> Void) -> NSPopover {
        let picker = ReactionPickerViewController(recent: timeline.snapshot?.recentReactions ?? [])
        if let model, let channel {
            picker.customLimit = model.app?.environment.budget.customEmojiPickerEntries ?? ResourceBudget.standard.customEmojiPickerEntries
            picker.customPage = { [weak model] page, query in
                guard let model, !model.isDetached else { return [] }
                return await model.session.customEmojiPage(page: page, query: query)
            }
            picker.customImage = { [weak model] id in
                guard let model, !model.isDetached, let pipeline = model.app?.images else { return nil }
                return await model.session.timelineImage(.customEmoji(id: id), channel: channel,
                                                         maxPixelSize: 64, pipeline: pipeline)
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.contentSize = ReactionPickerViewController.preferredSize
        picker.onPick = { [weak popover] name in
            popover?.performClose(nil)
            pick(name)
        }
        picker.onCancel = { [weak popover] in popover?.performClose(nil) }
        let bounds = timeline.view.bounds
        let anchor: NSRect
        let edge: NSRectEdge
        if let row = timeline.anchorRect(for: post) {
            let placement = Self.anchorPlacement(bubble: row, in: timeline.view,
                                                 popoverHeight: ReactionPickerViewController.preferredSize.height)
            anchor = placement.anchor
            edge = placement.edge
        } else {
            anchor = NSRect(x: bounds.midX, y: bounds.minY + 8, width: 1, height: 1)
            edge = .maxY
        }
        popover.show(relativeTo: anchor, of: timeline.view, preferredEdge: edge)
        return popover
    }

    /// Выбор стороны и якорной полосы (ADR 0058): попап пристыковывается к
    /// полосе высотой 1 pt у верхнего или нижнего края пузыря, поэтому не
    /// перекрывает сообщение даже когда AppKit подравнивает его к экрану.
    /// Сторона — где до видимой границы экрана больше места: поповер может
    /// выходить за пределы окна, но не за экран. Якорь по центру пузыря
    /// горизонтально; стрелка указывает на край сообщения.
    static func anchorPlacement(bubble: NSRect, in view: NSView, popoverHeight: CGFloat)
        -> (anchor: NSRect, edge: NSRectEdge) {
        guard let window = view.window else {
            return stripAndEdge(above: true, flipped: view.isFlipped, bubble: bubble)
        }
        let bubbleOnScreen = window.convertToScreen(view.convert(bubble, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? bubbleOnScreen
        let above = isAbovePreferred(spaceAbove: visible.maxY - bubbleOnScreen.maxY,
                                     spaceBelow: bubbleOnScreen.minY - visible.minY,
                                     popoverHeight: popoverHeight)
        return stripAndEdge(above: above, flipped: view.isFlipped, bubble: bubble)
    }

    /// Где места больше: над пузырём? Сторона, куда попап целиком помещается
    /// до края экрана, приоритетна; при равенстве — верх (там нет композера).
    static func isAbovePreferred(spaceAbove: CGFloat, spaceBelow: CGFloat, popoverHeight: CGFloat) -> Bool {
        let needed = popoverHeight + 14 // стрелка и зазор
        if spaceAbove >= needed, spaceAbove >= spaceBelow { return true }
        if spaceBelow >= needed { return false }
        return spaceAbove >= spaceBelow
    }

    /// Полоса у выбранного края пузыря и соответствующий ей край попапа.
    /// В перевёрнутых координатах верх пузыря — это minY, в обычных — maxY.
    static func stripAndEdge(above: Bool, flipped: Bool, bubble: NSRect) -> (anchor: NSRect, edge: NSRectEdge) {
        let stripY = above == flipped ? bubble.minY : bubble.maxY - 1
        let anchor = NSRect(x: bubble.midX - 1, y: stripY, width: 2, height: 1)
        let edge: NSRectEdge = above == flipped ? .minY : .maxY
        return (anchor, edge)
    }
}

extension TimelineViewController {
    /// The visible part of a post's row in `view` coordinates, or `nil` when the
    /// row is not in the timeline or scrolled out of view.
    func anchorRect(for post: PostID) -> NSRect? {
        guard isViewLoaded, let row = rowIndex[TimelineItemID(.post(post))], row < tableView.numberOfRows else { return nil }
        let visible = tableView.rect(ofRow: row).intersection(tableView.visibleRect)
        guard !visible.isEmpty else { return nil }
        return view.convert(visible, from: tableView)
    }
}
