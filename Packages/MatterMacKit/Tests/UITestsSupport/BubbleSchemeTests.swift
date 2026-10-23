import AppKit
import Foundation
import Testing
@testable import MatterMacUI

/// Пресеты цветовой схемы пузырей (ADR 0056). Цвета схем — чистые значения
/// (isDark × highContrast), поэтому пары проверяются компонентами sRGB и
/// контрастом WCAG; динамическая палитра — резолвом под drawing appearance.
/// Хранилище выбранной схемы глобальное, поэтому каждая схема-тест
/// восстанавливает `classic`.
@Suite("Bubble color schemes", .serialized)
struct BubbleSchemeTests {
    private func srgb(_ color: NSColor) throws -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let resolved = try #require(color.usingColorSpace(.sRGB))
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
    }

    private func channel(_ value: CGFloat) -> CGFloat {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Контраст WCAG двух светимостей.
    private func contrast(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Наложение полупрозрачного переднего плана на непрозрачный фон схем.
    private func composite(_ fg: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat),
                           over bg: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        let a = fg.a + bg.a * (1 - fg.a)
        let r = fg.r * fg.a + bg.r * bg.a * (1 - fg.a)
        let g = fg.g * fg.a + bg.g * bg.a * (1 - fg.a)
        let b = fg.b * fg.a + bg.b * bg.a * (1 - fg.a)
        return (r / a, g / a, b / a)
    }

    @Test func classicAnchorsMatchPrototypeTokens() throws {
        // Регрессионный якорь ADR 0041/0042: классическая пара не меняется
        // с появлением пресетов.
        let background = try srgb(BubbleScheme.classic.outgoingBackground(isDark: false, highContrast: false))
        #expect(abs(background.r - 214 / 255) < 0.002 && abs(background.g - 232 / 255) < 0.002
                && abs(background.b - 247 / 255) < 0.002)
        let darkBackground = try srgb(BubbleScheme.classic.outgoingBackground(isDark: true, highContrast: false))
        #expect(abs(darkBackground.r - 43 / 255) < 0.002 && abs(darkBackground.g - 82 / 255) < 0.002
                && abs(darkBackground.b - 120 / 255) < 0.002)
        let text = try srgb(BubbleScheme.classic.outgoingText(isDark: false))
        #expect(abs(text.r - 30 / 255) < 0.002 && abs(text.g - 55 / 255) < 0.002
                && abs(text.b - 80 / 255) < 0.002)
        let link = try srgb(BubbleScheme.classic.outgoingLink(isDark: false))
        #expect(abs(link.r - 47 / 255) < 0.002 && abs(link.g - 127 / 255) < 0.002
                && abs(link.b - 193 / 255) < 0.002)
    }

    @Test func everySchemeKeepsReadablePairs() throws {
        // Тело/фон — WCAG AA для обычного текста; meta и ссылки — мягче,
        // но заметно дальше от фона, чем случайный выбор.
        for scheme in BubbleScheme.allCases {
            for isDark in [false, true] {
                for highContrast in [false, true] {
                    let background = try srgb(scheme.outgoingBackground(isDark: isDark, highContrast: highContrast))
                    let backgroundLuminance = luminance(background.r, background.g, background.b)
                    let text = composite(try srgb(scheme.outgoingText(isDark: isDark)), over: background)
                    let textRatio = contrast(luminance(text.0, text.1, text.2), backgroundLuminance)
                    #expect(textRatio >= 4.5, "\(scheme.rawValue) тело \(isDark) hc=\(highContrast): \(textRatio)")
                    let secondary = composite(try srgb(scheme.outgoingSecondary(isDark: isDark)), over: background)
                    let secondaryRatio = contrast(luminance(secondary.0, secondary.1, secondary.2), backgroundLuminance)
                    #expect(secondaryRatio >= 2.7, "\(scheme.rawValue) meta \(isDark): \(secondaryRatio)")
                }
                let background = try srgb(scheme.outgoingBackground(isDark: isDark, highContrast: false))
                let link = try srgb(scheme.outgoingLink(isDark: isDark))
                let linkRatio = contrast(luminance(link.r, link.g, link.b),
                                         luminance(background.r, background.g, background.b))
                #expect(linkRatio >= 3.0, "\(scheme.rawValue) ссылка \(isDark): \(linkRatio)")
            }
        }
    }

    @Test func softBlueIsLighterAndCalmerThanClassicOnLightTheme() throws {
        // Репорт 2026-10-23: на белой теме голубой пузырь «слишком яркий» —
        // soft светлее классики, насыщеннее белого не становится.
        let soft = try srgb(BubbleScheme.softBlue.outgoingBackground(isDark: false, highContrast: false))
        let classic = try srgb(BubbleScheme.classic.outgoingBackground(isDark: false, highContrast: false))
        #expect(luminance(soft.r, soft.g, soft.b) > luminance(classic.r, classic.g, classic.b),
                "soft светлее классики")
        #expect(max(soft.r, soft.g, soft.b) - min(soft.r, soft.g, soft.b)
                < max(classic.r, classic.g, classic.b) - min(classic.r, classic.g, classic.b),
                "soft менее насыщена")
        #expect(soft.r < 250.0 / 255 && soft.g < 250.0 / 255 && soft.b < 250.0 / 255, "soft — не белая")
    }

    @Test func paletteProvidersReadSelectedScheme() throws {
        // Динамические токены палитры читают хранилище при резолве: выбор схемы
        // меняет компоненты уже существующих токенов (поэтому кэш рендера схему
        // не различает, а смена применяется живьём).
        defer { BubbleScheme.select(.classic) }
        let aqua = try #require(NSAppearance(named: .aqua))
        func resolvedBackground() -> (CGFloat, CGFloat, CGFloat) {
            var out: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
            aqua.performAsCurrentDrawingAppearance {
                if let color = TimelinePalette.bubbleOutgoingBackground.usingColorSpace(.sRGB) {
                    out = (color.redComponent, color.greenComponent, color.blueComponent)
                }
            }
            return out
        }
        BubbleScheme.select(.classic)
        let classic = resolvedBackground()
        #expect(abs(classic.0 - 214 / 255) < 0.01 && abs(classic.1 - 232 / 255) < 0.01
                && abs(classic.2 - 247 / 255) < 0.01, "light-резолв классики — прототип")
        BubbleScheme.select(.graphite)
        let graphite = resolvedBackground()
        #expect(abs(graphite.0 - classic.0) > 0.01 || abs(graphite.1 - classic.1) > 0.01
                || abs(graphite.2 - classic.2) > 0.01, "резолв сменился вместе со схемой")
    }
}
