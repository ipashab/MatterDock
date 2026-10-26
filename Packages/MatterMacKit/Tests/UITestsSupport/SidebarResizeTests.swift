import AppKit
import SwiftUI
import Testing
import MatterMacModels
import MatterMacCore
import MattermostAPI
import MattermostRealtime
import TestSupport
@testable import MatterMacUI

/// Перетаскиваемая ширина сайдбара и сворачивание в аватарки (ADR 0060):
/// чистые расчёты `SidebarMetrics`, контракт ручки `SidebarWidthController`,
/// живая интеграция настроек с настоящим окном и пиксельная проверка того,
/// что свёрнутая колонка действительно закрашивает аватары.
@MainActor
@Suite("Sidebar resize and collapse", .serialized)
struct SidebarResizeTests {
    @Test func metricsClampStoredWidthToCurrentRails() {
        // Рельсы вычитаются из сохранённого: 344 → чат-колонка 228.
        #expect(SidebarMetrics.columnWidth(collapsed: false, stored: 344, workspaceShown: true) == 344)
        // Слишком узко и слишком широко поджимается к границам чат-колонки.
        #expect(SidebarMetrics.columnWidth(collapsed: false, stored: 40, workspaceShown: true) == 296)
        #expect(SidebarMetrics.columnWidth(collapsed: false, stored: 999, workspaceShown: true) == 636)
        #expect(SidebarMetrics.columnWidth(collapsed: false, stored: 40, workspaceShown: false) == 244)
        // Свёрнуто — фиксированная колонка аватарок, рельсы скрыты.
        #expect(SidebarMetrics.columnWidth(collapsed: true, stored: 999, workspaceShown: true)
            == SidebarMetrics.collapsedWidth)
        #expect(SidebarMetrics.railWidth(workspaceShown: true)
            == SidebarMetrics.workspaceRailWidth + SidebarMetrics.folderRailWidth)
        #expect(SidebarMetrics.railWidth(workspaceShown: false) == SidebarMetrics.folderRailWidth)
    }

    @Test func compactColumnFitsItsOwnWidth() {
        // Репорт 2026-10-26: колонка аватарок — ровно «аватар-строка + отступ
        // слева» с двух сторон; всё содержимое габаритно внутри.
        #expect(SidebarMetrics.compactAvatarSize <= SidebarMetrics.compactRowSize)
        #expect(SidebarMetrics.collapsedWidth
            == SidebarMetrics.compactRowSize + SidebarMetrics.compactRowInset * 2)
        // Компактный AccountBar (аватар 30 + интервал 8 + шестерёнка 24)
        // помещается в колонку без обрезки.
        #expect(30 + 8 + 24 <= SidebarMetrics.collapsedWidth)
    }

    @Test func handleDragFollowsTheContract() {
        let settings = LocalSettings()
        var handle = SidebarWidthController(settings: settings, workspaceShown: true)
        let rails = SidebarMetrics.railWidth(workspaceShown: true)

        // Из раскрытого (344): тяга влево уменьшает, но не ниже минимума
        // чат-колонки; вправо — не дальше верхней границы.
        handle.dragChanged(-20)
        #expect(settings.sidebarCollapsed == false && settings.sidebarWidth == 324)
        handle.dragChanged(-80)
        #expect(settings.sidebarWidth == rails + SidebarMetrics.expandedChatMin)
        handle.dragChanged(500)
        #expect(settings.sidebarWidth == rails + SidebarMetrics.expandedChatMax)

        // Ниже порога — сворачивание; ширина при этом не портится.
        handle.dragEnded()
        handle.dragChanged(-800)
        #expect(settings.sidebarCollapsed == true)
        #expect(settings.sidebarWidth == rails + SidebarMetrics.expandedChatMax)

        // Из свёрнутого: небольшая тяга вправо разворачивает сразу
        // к минимальной раскрытой ширине.
        handle.dragEnded()
        handle.dragChanged(20)
        #expect(settings.sidebarCollapsed == false)
        #expect(settings.sidebarWidth == rails + SidebarMetrics.expandedChatMin)

        // Двойной клик переключает свёрнутость, ширина хранится отдельно.
        handle.doubleClicked()
        #expect(settings.sidebarCollapsed == true)
        handle.doubleClicked()
        #expect(settings.sidebarCollapsed == false)
        #expect(settings.sidebarWidth == rails + SidebarMetrics.expandedChatMin)
    }

    @Test func persistedWidthAndCollapseDriveTheLiveColumn() async throws {
        let storage = MemorySettingsStorage()
        let (app, model, window) = try await makeLiveAppAndWindow(storage: storage)
        defer { window.close() }
        try await settleUntil { model.sidebar != nil && model.selectedChannel != nil }

        // Начальная ширина — дефолт настроек (344), без workspace-рельсы.
        try await settleUntil(column(width: 344, in: window))
        // Сохранённая ширина применяется колонкой.
        app.environment.settings.sidebarWidth = 456
        try await settleUntil(column(width: 456, in: window))
        // Сворачивание — фиксированная колонка аватарок.
        app.environment.settings.sidebarCollapsed = true
        try await settleUntil(column(width: SidebarMetrics.collapsedWidth, in: window))
        // Обратный разворот возвращает сохранённую ширину.
        app.environment.settings.sidebarCollapsed = false
        try await settleUntil(column(width: 456, in: window))
        #expect(storage.values["MatterMac.sidebarWidth"] as? Double == 456)
        #expect(storage.values["MatterMac.sidebarCollapsed"] as? Bool == false)
    }

    /// Репорт 2026-10-26 («в свёрнутом виде не отображаются аватарки»):
    /// пиксельная проверка обеих дорожек. Старт свёрнутым и сворачивание
    /// в рантайме обязаны закрашивать аватары в колонке.
    @Test func collapsedColumnPaintsAvatars() async throws {
        let (app, model, window) = try await makeLiveAppAndWindow(
            storage: MemorySettingsStorage(["MatterMac.sidebarCollapsed": true]),
            channels: 2, withContact: true)
        defer { window.close() }
        try await settleUntil { model.sidebar != nil && model.selectedChannel != nil }
        try await settleUntil(column(width: SidebarMetrics.collapsedWidth, in: window))
        try await paintAndSettle(window)

        // Свёрнутый старт: аватары закрашены (тонированные плашки каналов
        // и инициалы контакта проходят цветовой порог; пустая колонка
        // стабильно даёт ~0).
        let fraction = try coloredFraction(ofAvatarStrip: window)
        #expect(fraction > 0.08, "аватары закрашены при старте свёрнутым")

        // Рантайм-свёртка (драг/двойной клик/меню) — та же колонка.
        app.environment.settings.sidebarCollapsed = false
        try await settleUntil(column(width: 456, in: window, tolerance: 6))
        app.environment.settings.sidebarCollapsed = true
        try await settleUntil(column(width: SidebarMetrics.collapsedWidth, in: window))
        try await paintAndSettle(window)
        #expect(try coloredFraction(ofAvatarStrip: window) > 0.08, "аватары закрашены после рантайм-свёртки")
    }

    // MARK: - Живое приложение в тестовом окне

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
    }

    private func makeLiveAppAndWindow(storage: (any LocalSettingsStorage)? = MemorySettingsStorage(),
                                      channels: Int = 1, withContact: Bool = false) async throws
        -> (AppModel, SessionViewModel, NSWindow) {
        _ = NSApplication.shared
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let team = CoreFixtures.team.id
        let me = CoreFixtures.me.id
        service.withState { state in
            state.teams = [CoreFixtures.team]
            state.users[CoreFixtures.bob.id] = CoreFixtures.bob
            for n in 1...max(1, channels) {
                var channel = CoreFixtures.channel(n)
                channel.displayName = "Channel \(n)"
                state.channels[channel.id] = channel
                state.memberships[channel.id] = ChannelMembership(channelID: channel.id, userID: me)
            }
            if withContact {
                // Контакт (личный чат): аватар — ProfileAvatar с инициалами.
                let dm = Channel(id: ChannelID(unchecked: CoreFixtures.id("dm", 1)), teamID: nil, type: .direct,
                                 name: [me.rawValue, CoreFixtures.bob.id.rawValue].sorted().joined(separator: "__"),
                                 displayName: "")
                state.channels[dm.id] = dm
                state.memberships[dm.id] = ChannelMembership(channelID: dm.id, userID: me)
            }
        }
        service.withDirectory { directory in
            var categoryIDs = (1...max(1, channels)).map { CoreFixtures.channel($0).id }
            if withContact { categoryIDs.append(ChannelID(unchecked: CoreFixtures.id("dm", 1))) }
            directory.categories[team] = [
                SidebarCategory(id: SidebarCategoryID(unchecked: "channels_" + me.rawValue + "_" + team.rawValue),
                               userID: me, teamID: team, kind: .channels, displayName: "Channels",
                               channelIDs: categoryIDs),
            ]
        }
        let app = AppModel(environment: AppEnvironment(settingsStorage: storage, serviceFactory: Factory(fake: service),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
        let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities())
        let model = SessionViewModel(slot: slot, app: app)
        await slot.session.start()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let host = NSHostingController(rootView: MainWindowView(app: app, session: model).frame(minWidth: 760, minHeight: 500))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.orderFrontRegardless()
        return (app, model, window)
    }

    private func settleUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Ширина сайдбар-колонки NavigationSplitView: ищем NSSplitView в иерархии
    /// окна и берём ширину его первой секции (сверху вниз иерархия SwiftUI
    /// не даёт адресоваться, split — настоящий AppKit).
    private func column(width expected: Double, in window: NSWindow, tolerance: Double = 2) -> () -> Bool {
        { sidebarColumnWidth(in: window).map { abs($0 - expected) <= tolerance } ?? false }
    }

    @discardableResult
    private func sidebarColumnWidth(in window: NSWindow) -> Double? {
        guard let contentView = window.contentView else { return nil }
        var found: Double?
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView, split.isVertical, found == nil,
               let firstCap = split.arrangedSubviews.first {
                found = Double(firstCap.bounds.width)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(contentView)
        return found
    }

    // MARK: - Пиксели

    /// Даёт окну отрисоваться и снимает его в битмап.
    private func paintAndSettle(_ window: NSWindow, wait: Duration = .milliseconds(300)) async throws {
        try await Task.sleep(for: wait)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Доля окрашенных пикселей в полосе колонки аватарок (порог насыщенности
    /// отсеивает серый материал сайдбара): аватары — тонированные плашки
    /// каналов, инициалы контактов и бейджи.
    private func coloredFraction(ofAvatarStrip window: NSWindow) throws -> Double {
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return 0 }
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, content.bounds.width)
        var colored = 0, total = 0
        // Полоса под строкой поиска, над AccountBar (pt), с пересчётом в пиксели.
        for yPoint in stride(from: 110.0, to: 400.0, by: 2) {
            for xPoint in stride(from: 10.0, to: 54.0, by: 1) {
                let x = Int(xPoint * scale), y = Int(yPoint * scale)
                guard x < rep.pixelsWide, y < rep.pixelsHigh,
                      let color = rep.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                    - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) > 0.15 { colored += 1 }
            }
        }
        return total > 0 ? Double(colored) / Double(total) : 0
    }

}
