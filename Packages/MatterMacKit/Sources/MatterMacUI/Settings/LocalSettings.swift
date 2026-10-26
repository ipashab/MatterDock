public import AppKit
public import Observation
public import MatterMacPlatform

/// Where "On This Mac" settings are saved between launches. The app passes
/// `UserDefaults.standard`; tests and `-MatterMacUITesting` pass nothing (memory
/// only) or a private in-memory store.
public protocol LocalSettingsStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: LocalSettingsStorage {}

/// MatterMac's own presentation and attention settings (Settings › "On This Mac").
/// At the user's request (2026-09-25, decision 0032) they are saved on this Mac in
/// the injected storage under `MatterMac.*` keys: small typed values only, validated
/// on load (anything unknown falls back to the default). Nothing here is sent to the
/// server, and no message content, draft or account data is ever stored here.
@MainActor
@Observable
public final class LocalSettings {
    public enum TextSize: String, CaseIterable, Identifiable, Sendable {
        case small, standard, large, extraLarge
        public var id: String { rawValue }
        /// Timeline font scale (applied to the system body font).
        public var scale: CGFloat {
            switch self {
            case .small: 0.9
            case .standard: 1
            case .large: 1.15
            case .extraLarge: 1.3
            }
        }
    }

    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
    }

    /// Язык интерфейса (MatterDock, decision 0040). `system` — как в macOS;
    /// явный выбор пишется дополнительно в `AppleLanguages`, откуда
    /// `Bundle.main` берёт локализацию на следующем запуске.
    public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
        case system, english, russian
        public var id: String { rawValue }

        /// Значение `AppleLanguages` для этого выбора (`nil` — системное).
        public var appleLanguages: [String]? {
            switch self {
            case .system: nil
            case .english: ["en"]
            case .russian: ["ru"]
            }
        }
    }

    /// Storage keys (namespaced; values are `Bool` or a known `String`).
    enum Key: String, CaseIterable {
        case sendBehavior = "MatterMac.sendBehavior"
        case textSize = "MatterMac.textSize"
        case appearance = "MatterMac.appearance"
        case language = "MatterMac.language"
        case bubbleTimeline = "MatterMac.bubbleTimeline"
        case bubbleScheme = "MatterMac.bubbleScheme"
        case largeChatList = "MatterMac.largeChatList"
        case notificationsEnabled = "MatterMac.notificationsEnabled"
        case showMessagePreview = "MatterMac.showMessagePreview"
        case playSound = "MatterMac.playSound"
        case soundName = "MatterMac.soundName"
        case bounceDockIcon = "MatterMac.bounceDockIcon"
        case checksForUpdates = "MatterMac.checksForUpdates"
        case updateChannel = "MatterMac.updateChannel"
        /// Versioned JSON `Data` (`AppTheme`), at most `AppTheme.maximumStoredBytes`.
        case theme = "MatterMac.theme"
        /// Выбранная папка рельсы сайдбара (ADR 0043): `SidebarFolderID.rawValue`,
        /// одна на приложение (не по аккаунту — идентификаторы аккаунтов здесь
        /// не хранятся).
        case selectedSidebarFolder = "MatterMac.selectedSidebarFolder"
        /// JSON `Data` `[categoryID: emojiName]` — иконки пользовательских групп
        /// (ADR 0043); не больше 100 записей, строки до 64 байт.
        case sidebarGroupIcons = "MatterMac.sidebarGroupIcons"
        /// Ширина колонки чатов в pt (ADR 0060): сохраняется между запусками,
        /// вне допустимого диапазона — сбрасывается к умолчанию.
        case sidebarWidth = "MatterMac.sidebarWidth"
        /// Сайдбар свёрнут до аватарок (ADR 0060).
        case sidebarCollapsed = "MatterMac.sidebarCollapsed"
    }

    /// Window theme (Settings › Appearance). Applies live to every window; invalid
    /// saved data loads as `.system` (decision 0035).
    public var theme: AppTheme = .system {
        didSet {
            guard oldValue != theme, isLoaded, let data = theme.storageData() else { return }
            storage?.set(data, forKey: Key.theme.rawValue)
        }
    }

    /// Return vs ⌘Return in the composer.
    public var sendBehavior: AppEnvironment.SendBehaviorSetting = .returnSends {
        didSet { save(.sendBehavior, sendBehavior.rawValue) }
    }
    public var textSize: TextSize = .standard {
        didSet { save(.textSize, textSize.rawValue) }
    }
    /// Сообщения из рендера OpenDesign (ADR 0042): интерфейс 1:1 — пузыри
    /// включены по умолчанию, альтернативного вида больше нет. Переключение
    /// прогоняет сброс высот, как смена размера текста.
    public var bubbleTimeline = true {
        didSet { save(.bubbleTimeline, bubbleTimeline) }
    }
    /// Цветовая схема пузырей (ADR 0056): пресеты от `classic` до `green`,
    /// свободного выбора цвета нет — текст, ссылки и код подогнаны под пару
    /// фон/передний план каждой схемы. Применяется живьём: смена через
    /// `ConversationSettingsBinding` перерисовывает видимые строки.
    /// Неизвестное сохранённое значение загружается как `classic`.
    public var bubbleScheme: BubbleScheme = .classic {
        didSet {
            guard oldValue != bubbleScheme, isLoaded else { return }
            save(.bubbleScheme, bubbleScheme.rawValue)
        }
    }
    /// Крупные строки списка чатов (рендер OpenDesign: аватары, время и превью
    /// последнего сообщения); мелкий режим — прежняя компактная строка.
    public var largeChatList = true {
        didSet { save(.largeChatList, largeChatList) }
    }
    /// Ширина всей колонки сайдбара в pt (ADR 0060): рельсы плюс чат-колонка.
    /// Значение вне `SidebarMetrics.storageRange` при загрузке отбрасывается.
    public var sidebarWidth: Double = 344 {
        didSet {
            guard oldValue != sidebarWidth, isLoaded else { return }
            storage?.set(sidebarWidth, forKey: Key.sidebarWidth.rawValue)
        }
    }
    /// Сайдбар свёрнут до колонки аватарок (ADR 0060).
    public var sidebarCollapsed = false {
        didSet { save(.sidebarCollapsed, sidebarCollapsed) }
    }
    public var appearance: Appearance = .system {
        didSet {
            if oldValue != appearance { applyAppearance() }
            save(.appearance, appearance.rawValue)
        }
    }
    /// Язык интерфейса; смена применяется после перезапуска приложения.
    public var language: AppLanguage = .system {
        didSet {
            guard oldValue != language, isLoaded else { return }
            save(.language, language.rawValue)
            // `AppleLanguages` читается системой на старте; `nil` возвращает
            // выбор системному языку.
            storage?.set(language.appleLanguages, forKey: "AppleLanguages")
        }
    }
    /// The user's Notification Center choice (on by default). Delivery also needs
    /// macOS authorization; see `AppModel.notificationsEnabled`.
    public var notificationsEnabled = true {
        didSet { save(.notificationsEnabled, notificationsEnabled) }
    }
    /// Include up to 100 characters of message text in Notification Center alerts.
    /// On by default (user request 2026-09-25).
    public var showMessagePreview = true {
        didSet { save(.showMessagePreview, showMessagePreview) }
    }
    /// Plays `soundName` for incoming alerts (with or without Notification Center).
    public var playSound = true {
        didSet { save(.playSound, playSound) }
    }
    public var soundName: String = SystemSounds.defaultName {
        didSet { save(.soundName, soundName) }
    }
    /// Bounce the Dock icon once for mentions and direct messages while inactive.
    public var bounceDockIcon = true {
        didSet { save(.bounceDockIcon, bounceDockIcon) }
    }

    /// Check GitHub for new releases and download them in the background.
    public var checksForUpdates = false {
        didSet { save(.checksForUpdates, checksForUpdates) }
    }
    /// `nil`: follow the running build (nightly builds follow nightlies).
    public var updateChannel: UpdateChannel? {
        didSet { if let updateChannel { save(.updateChannel, updateChannel.rawValue) } }
    }

    /// Выбранная папка рельсы сайдбара, `SidebarFolderID.rawValue` (ADR 0043).
    /// Неизвестное значение при загрузке становится «все».
    public var selectedSidebarFolder: String = "all" {
        didSet {
            guard oldValue != selectedSidebarFolder, isLoaded else { return }
            storage?.set(selectedSidebarFolder, forKey: Key.selectedSidebarFolder.rawValue)
        }
    }

    /// Иконки пользовательских групп: `categoryID → emojiName` (ADR 0043).
    public var sidebarGroupIcons: [String: String] = [:] {
        didSet {
            guard oldValue != sidebarGroupIcons, isLoaded,
                  let data = try? JSONEncoder().encode(sidebarGroupIcons) else { return }
            storage?.set(data, forKey: Key.sidebarGroupIcons.rawValue)
        }
    }

    @ObservationIgnored private let storage: (any LocalSettingsStorage)?
    /// Set after loading so restoring values does not write them straight back.
    @ObservationIgnored private var isLoaded = false

    /// `storage == nil` keeps every setting in memory for this run only.
    public init(storage: (any LocalSettingsStorage)? = nil) {
        self.storage = storage
        if let storage {
            let read = Reader(storage: storage)
            sendBehavior = read.value(.sendBehavior) ?? sendBehavior
            textSize = read.value(.textSize) ?? textSize
            bubbleTimeline = read.bool(.bubbleTimeline) ?? bubbleTimeline
            bubbleScheme = read.value(.bubbleScheme) ?? bubbleScheme
            largeChatList = read.bool(.largeChatList) ?? largeChatList
            appearance = read.value(.appearance) ?? appearance
            language = read.value(.language) ?? language
            notificationsEnabled = read.bool(.notificationsEnabled) ?? notificationsEnabled
            showMessagePreview = read.bool(.showMessagePreview) ?? showMessagePreview
            playSound = read.bool(.playSound) ?? playSound
            soundName = read.string(.soundName).flatMap { SystemSounds.names.contains($0) ? $0 : nil } ?? soundName
            bounceDockIcon = read.bool(.bounceDockIcon) ?? bounceDockIcon
            checksForUpdates = read.bool(.checksForUpdates) ?? checksForUpdates
            updateChannel = read.value(.updateChannel)
            theme = read.data(.theme).flatMap(AppTheme.init(storageData:)) ?? theme
            selectedSidebarFolder = read.folder(.selectedSidebarFolder) ?? selectedSidebarFolder
            sidebarGroupIcons = read.iconMap(.sidebarGroupIcons)
            sidebarWidth = read.double(.sidebarWidth, in: SidebarMetrics.storageRange) ?? sidebarWidth
            sidebarCollapsed = read.bool(.sidebarCollapsed) ?? sidebarCollapsed
        }
        // Сеем схему до первой отрисовки: палитра читает её в провайдерах
        // динамических цветов; дальше значение держат биндинги панелей.
        BubbleScheme.select(bubbleScheme)
        isLoaded = true
        if appearance != .system { applyAppearance() }
    }

    public var fontScale: CGFloat { textSize.scale }

    /// Overrides the app's appearance (not the system's).
    func applyAppearance() {
        let app = NSApplication.shared
        switch appearance {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func save(_ key: Key, _ value: Bool) {
        guard isLoaded else { return }
        storage?.set(value, forKey: key.rawValue)
    }

    private func save(_ key: Key, _ value: String) {
        guard isLoaded else { return }
        storage?.set(value, forKey: key.rawValue)
    }

    /// Typed, validated reads: a wrong type or unknown value yields `nil`.
    private struct Reader {
        let storage: any LocalSettingsStorage

        func bool(_ key: Key) -> Bool? {
            // Only a real boolean (`NSNumber` 0/1 or `Bool`); strings like "YES" are ignored.
            guard let number = storage.object(forKey: key.rawValue) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }

        func string(_ key: Key) -> String? {
            guard let text = storage.object(forKey: key.rawValue) as? String, text.utf8.count <= 64 else { return nil }
            return text
        }

        /// Число из интервала `range`: сырое значение вне диапазона — `nil`,
        /// загружается умолчание (защита от мусора в хранилище).
        func double(_ key: Key, in range: ClosedRange<Double>) -> Double? {
            guard let number = storage.object(forKey: key.rawValue) as? Double,
                  range.contains(number) else { return nil }
            return number
        }

        func data(_ key: Key) -> Data? {
            storage.object(forKey: key.rawValue) as? Data
        }

        /// Сырое значение папки: `group:<categoryID>` длиннее обычных строк (до 102
        /// байт); корректность проверяет `SidebarFolderID(rawValue:)` в VM.
        func folder(_ key: Key) -> String? {
            guard let text = storage.object(forKey: key.rawValue) as? String, text.utf8.count <= 128 else { return nil }
            return text
        }

        /// Карта иконок групп: JSON-словарь, записи длиннее 64 байт и всё сверх
        /// 100 записей отбрасываются.
        func iconMap(_ key: Key) -> [String: String] {
            guard let data = data(key),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            let kept = map.filter { $0.key.utf8.count <= 64 && $0.value.utf8.count <= 64 }
                .sorted { $0.key < $1.key }
                .prefix(100)
            var result: [String: String] = [:]
            for pair in kept { result[pair.key] = pair.value }
            return result
        }

        func value<Value: RawRepresentable<String>>(_ key: Key) -> Value? {
            guard let text = string(key) else { return nil }
            return Value(rawValue: text)
        }
    }
}
