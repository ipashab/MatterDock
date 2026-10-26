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
/// чистые расчёты `SidebarMetrics`, контракт ручки `SidebarWidthController`
/// и живая интеграция настроек с настоящим окном.
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
        _ = NSApplication.shared
        let storage = MemorySettingsStorage()
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let team = CoreFixtures.team.id
        let me = CoreFixtures.me.id
        service.withState { state in
            state.channels[CoreFixtures.channel(1).id] = CoreFixtures.channel(1)
            state.memberships[CoreFixtures.channel(1).id] = ChannelMembership(channelID: CoreFixtures.channel(1).id, userID: me)
        }
        service.withDirectory { directory in
            directory.categories[team] = [
                SidebarCategory(id: SidebarCategoryID(unchecked: "channels_" + me.rawValue + "_" + team.rawValue),
                               userID: me, teamID: team, kind: .channels, displayName: "Channels",
                               channelIDs: [CoreFixtures.channel(1).id]),
            ]
        }
        let app = AppModel(environment: AppEnvironment(settingsStorage: storage, serviceFactory: Factory(fake: service),
            makeRealtime: { _, _, _ in FakeRealtimeConnection() }, markupParse: { text, _ in MarkupParser.parse(text) }))
        let slot = try app.registry.add(endpoint: CoreFixtures.endpoint,
            login: LoginResult(credential: BearerCredential(token: "fixture-token", kind: .session)!, user: CoreFixtures.me),
            capabilities: ServerCapabilities())
        let model = SessionViewModel(slot: slot, app: app)
        await slot.session.start()
        try await settleUntil { model.sidebar != nil && model.selectedChannel != nil }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let host = NSHostingController(rootView: MainWindowView(app: app, session: model).frame(minWidth: 760, minHeight: 500))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.orderFrontRegardless()
        defer { window.close() }

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

    // MARK: - Helpers

    private struct Factory: MattermostServiceFactory {
        let fake: FakeMattermostService
        func discovery(for endpoint: ServerEndpoint) -> any MattermostDiscoveryService { fatalError("No discovery in this fixture") }
        func service(for endpoint: ServerEndpoint, credential: BearerCredential) -> any MattermostService { fake }
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
}
