import AppKit
import os

/// Цветовая схема пузырей (Settings ▸ Appearance, ADR 0056). Выбор хранится в
/// `LocalSettings` и сеется в `BubbleScheme.selected` при старте; цвета
/// разрешаются в провайдерах динамических `NSColor` при каждой отрисовке,
/// поэтому смена схемы не требует перерендера — как переключение темы.
/// `classic` — точные цвета ADR 0041/0042; остальные — готовые пресеты,
/// подобранные по контрасту к своему фону (свободного выбора цвета нет
/// намеренно: текст, ссылки и цитаты подогнаны к паре фон/передний план).
nonisolated public enum BubbleScheme: String, CaseIterable, Identifiable, Sendable {
    /// Текущая сине-белая палитра прототипа.
    case classic
    /// Светлый, но не белый: приглушённый голубой мягче яркого `classic`
    /// (репорт 2026-10-23).
    case softBlue
    /// Нейтральный графит без синевы.
    case graphite
    /// Зелёный («мох»).
    case green

    public var id: String { rawValue }

    /// Текущая схема процесса. Мьютекс нужен из-за strict concurrency:
    /// читают провайдеры цветов, пишет — настройка (после применения — со
    /// следующего перерендера кэшированных запусков, поэтому в UI есть
    /// пометка о перезапуске).
    private static let lock = OSAllocatedUnfairLock(initialState: BubbleScheme.classic)
    static var selected: BubbleScheme { lock.withLock { $0 } }
    static func select(_ scheme: BubbleScheme) { lock.withLock { $0 = scheme } }

    // MARK: - Цвета исходящей поверхности (свои пузыри, карточки и цитаты)

    func outgoingBackground(isDark: Bool, highContrast: Bool) -> NSColor {
        switch self {
        case .classic:
            if isDark { return Self.color(43, 82, 120) }
            return Self.color(highContrast ? 199 : 214, highContrast ? 221 : 232, highContrast ? 242 : 247)
        case .softBlue:
            if isDark { return Self.color(highContrast ? 70 : 52, highContrast ? 88 : 68, highContrast ? 106 : 84) }
            return Self.color(highContrast ? 208 : 226, highContrast ? 220 : 235, highContrast ? 231 : 243)
        case .graphite:
            if isDark { return Self.color(highContrast ? 86 : 62, highContrast ? 92 : 67, highContrast ? 102 : 76) }
            return Self.color(highContrast ? 213 : 228, highContrast ? 216 : 230, highContrast ? 220 : 233)
        case .green:
            if isDark { return Self.color(highContrast ? 38 : 28, highContrast ? 94 : 68, highContrast ? 62 : 46) }
            return Self.color(highContrast ? 202 : 222, highContrast ? 226 : 238, highContrast ? 203 : 222)
        }
    }

    func outgoingText(isDark: Bool) -> NSColor {
        switch self {
        case .classic: isDark ? .white.withAlphaComponent(0.96) : Self.color(30, 55, 80)
        case .softBlue: isDark ? .white.withAlphaComponent(0.95) : Self.color(45, 62, 78)
        case .graphite: isDark ? .white.withAlphaComponent(0.95) : Self.color(38, 42, 48)
        case .green: isDark ? .white.withAlphaComponent(0.96) : Self.color(30, 58, 38)
        }
    }

    /// Время/«изм.» в пузыре.
    func outgoingSecondary(isDark: Bool) -> NSColor {
        switch self {
        case .classic: isDark ? .white.withAlphaComponent(0.6) : Self.color(30, 55, 80, alpha: 0.65)
        case .softBlue: isDark ? .white.withAlphaComponent(0.6) : Self.color(45, 62, 78, alpha: 0.62)
        case .graphite: isDark ? .white.withAlphaComponent(0.6) : Self.color(38, 42, 48, alpha: 0.6)
        case .green: isDark ? .white.withAlphaComponent(0.6) : Self.color(30, 58, 38, alpha: 0.62)
        }
    }

    func outgoingLink(isDark: Bool) -> NSColor {
        switch self {
        case .classic: isDark ? Self.color(100, 181, 239) : Self.color(47, 127, 193)
        case .softBlue: isDark ? Self.color(140, 180, 214) : Self.color(58, 110, 155)
        case .graphite: isDark ? Self.color(159, 182, 212) : Self.color(64, 90, 130)
        case .green: isDark ? Self.color(134, 209, 154) : Self.color(46, 125, 50)
        }
    }

    func outgoingCodeBackground(isDark: Bool, highContrast: Bool) -> NSColor {
        // На светлых схемах код-блок светлеет пузыря, на тёмных — светлеет
        // белёсой вуалью (как в `classic`).
        switch self {
        case .classic:
            isDark ? .white.withAlphaComponent(highContrast ? 0.22 : 0.14)
                   : .white.withAlphaComponent(highContrast ? 0.85 : 0.75)
        case .softBlue, .graphite, .green:
            isDark ? .white.withAlphaComponent(highContrast ? 0.20 : 0.12)
                   : .white.withAlphaComponent(highContrast ? 0.90 : 0.80)
        }
    }

    func outgoingCodeBorder(isDark: Bool) -> NSColor {
        switch self {
        case .classic: isDark ? .white.withAlphaComponent(0.30) : Self.color(30, 55, 80, alpha: 0.22)
        case .softBlue: isDark ? .white.withAlphaComponent(0.26) : Self.color(45, 62, 78, alpha: 0.18)
        case .graphite: isDark ? .white.withAlphaComponent(0.26) : Self.color(38, 42, 48, alpha: 0.18)
        case .green: isDark ? .white.withAlphaComponent(0.30) : Self.color(30, 58, 38, alpha: 0.18)
        }
    }

    func outgoingQuoteBar(isDark: Bool) -> NSColor {
        switch self {
        case .classic: isDark ? .white.withAlphaComponent(0.45) : Self.color(30, 55, 80, alpha: 0.35)
        case .softBlue: isDark ? .white.withAlphaComponent(0.42) : Self.color(45, 62, 78, alpha: 0.30)
        case .graphite: isDark ? .white.withAlphaComponent(0.42) : Self.color(38, 42, 48, alpha: 0.30)
        case .green: isDark ? .white.withAlphaComponent(0.45) : Self.color(30, 58, 38, alpha: 0.30)
        }
    }

    private static func color(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }
}
