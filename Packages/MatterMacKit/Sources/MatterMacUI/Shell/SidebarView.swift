import SwiftUI
import MatterMacModels
import MatterMacCore

/// The navigation column: an optional server/team rail at the leading edge, then the
/// selected team's channels in the server's sidebar categories.
struct SidebarView: View {
    let app: AppModel
    @Bindable var session: SessionViewModel
    @State private var columnWidth: CGFloat = 280

    var body: some View {
        let settings = app.environment.settings
        HStack(spacing: 0) {
            if settings.sidebarCollapsed {
                compactColumn
            } else {
                if WorkspaceRail.isShown(app: app, sidebar: session.sidebar) {
                    WorkspaceRail(app: app, session: session)
                }
                FolderRail(session: session)
                VStack(spacing: 0) {
                    chatColumn
                        .overlay(alignment: .bottom) {
                            VStack(spacing: 8) {
                                if session.connection != .connected {
                                    ConnectionFooter(session: session)
                                        .glassCapsule()
                                }
                                AccountBar(app: app, session: session)
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                        }
                }
                // The column may be narrower than the list's ideal width; never push the
                // rail out of the column.
                .frame(minWidth: 0, maxWidth: .infinity)
                .overlay {
                    // Рельса папок видна всегда — разделитель колонки тоже.
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: CGPoint(x: 0.5, y: geometry.size.height))
                            path.addLine(to: CGPoint(x: 0.5, y: 16))
                            path.addQuadCurve(to: CGPoint(x: 16, y: 0.5),
                                              control: CGPoint(x: 0.5, y: 0.5))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
                        }
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The window theme tints the sidebar material (nothing with the System theme).
        .background {
            ZStack { SidebarMaterial(); ThemedBackdrop(.sidebar) }
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            // Ручка растяжения (ADR 0060): вся высота колонки, у правого края.
            SidebarResizeHandle(settings: settings,
                                workspaceShown: WorkspaceRail.isShown(app: app, sidebar: session.sidebar))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .modifier(SidebarTitleToolbar(app: app, session: session, columnWidth: columnWidth,
                                      collapsed: settings.sidebarCollapsed))
        .sheet(item: $session.directorySheet) { sheet in
            DirectorySheetView(session: session, sheet: sheet)
        }
    }

    /// Свёрнутая колонка (ADR 0060): вертикальная лента аватарок каналов,
    /// поиск — одной иконкой; папки и рельсы скрыты, выбор папки не влияет
    /// на ленту (показывает все каналы).
    private var compactColumn: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { session.selectedChannel },
                set: { if let id = $0 { session.select(channel: id) } })) {
                Button { session.isQuickSwitcherVisible = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                .help("Search (⌘K)")
                .accessibilityLabel("Search")
                .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                .listRowBackground(Color.clear)
                ForEach(compactRows) { row in
                    SidebarAvatarRow(row: row, session: session)
                        .tag(row.channelID)
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            AccountBar(app: app, session: session, compact: true)
                .padding(.bottom, 8)
        }
    }

    private var compactRows: [SidebarChannelRow] {
        (session.sidebar?.chatSections(for: .all) ?? []).flatMap {
            $0.visibleRows(selected: session.selectedChannel)
        }
    }

    /// Контент второй колонки по выбранной папке (ADR 0043): чат-папки — список
    /// каналов, «Обсуждения» — лента тредов, «Черновики» — черновики,
    /// «Упоминания и реакции» — фид упоминаний.
    @ViewBuilder private var chatColumn: some View {
        switch session.selectedFolder {
        case .threads:
            ThreadsListView(session: session, context: .folder)
        case .drafts:
            DraftsFolderView(app: app, session: session)
        case .mentions:
            MentionsFolderView(session: session)
        default:
            channelList
        }
    }

    private var channelList: some View {
        // Drafts are read when the sidebar re-renders (selection or snapshot changes);
        // the composer saves them on every navigation.
        let drafts = Set(app.environment.drafts.nonEmptyKeys(for: session.scope).map(\.channelID))
        return List(selection: Binding(
            get: { session.selectedChannel },
            set: { if let id = $0 { session.select(channel: id) } })) {
            if let sidebar = session.sidebar {
                SidebarSearchRow { session.isQuickSwitcherVisible = true }
                ForEach(session.chatListSections) { section in
                    let rows = section.visibleRows(selected: session.selectedChannel)
                    if !rows.isEmpty || section.kind == .custom || section.kind == .channels || section.hiddenCount > 0 {
                        Section {
                            ForEach(rows) { row in
                                SidebarRow(row: row, session: session,
                                           hasDraft: drafts.contains(row.channelID) && row.channelID != session.selectedChannel,
                                           large: app.environment.settings.largeChatList)
                                    .tag(row.channelID)
                                    .contextMenu { rowMenu(row) }
                            }
                            if section.hiddenCount > 0 {
                                Button("More…") { session.directorySheet = .newMessage }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("\(section.hiddenCount) more conversations — start or find a direct message")
                            }
                        } header: {
                            SidebarSectionHeader(section: section, title: SidebarSectionHeader.title(for: section),
                                                 onToggle: section.categoryID == nil ? nil : {
                                                     session.setCategoryCollapsed(section, collapsed: !section.isCollapsed)
                                                 })
                        }
                    }
                }
                if session.chatListSections.isEmpty {
                    Text("No chats in this folder").foregroundStyle(.secondary)
                }
                if sidebar.isTruncated {
                    Button("More channels…") { session.isQuickSwitcherVisible = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("This session keeps a bounded channel list; find other channels with the quick switcher (⌘K).")
                }
                // The account pill floats over the list; the last row scrolls clear of it.
                Color.clear
                    .frame(height: session.connection == .connected ? 66 : 106)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .accessibilityHidden(true)
            } else if session.requiresAuthentication {
                Text("Sign in again to load channels.").foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading channels…").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Rows end at the list's top edge instead of scrolling on under the title
        // bar, where the scroll edge effect blurred them behind the traffic lights.
        .modifier(HiddenTopScrollEdgeEffect())
        .padding(.top, 6)
        .clipped()
    }

    @ViewBuilder private func rowMenu(_ row: SidebarChannelRow) -> some View {
        if row.isUnread || row.mentionCount > 0 {
            Button("Mark as Read") { session.markChannelsRead([row.channelID]) }
            Divider()
        }
        Button("Channel Info") {
            session.select(channel: row.channelID)
            session.isChannelInfoVisible = true
        }
        if (row.type == .open || row.type == .private) && !row.isArchived {
            Button("Add Members…") { session.directorySheet = .addMembers(row.channelID) }
        }
        Divider()
        Button(row.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            session.setFavorite(row.channelID, !row.isFavorite)
        }
        if !row.isArchived {
            Button(row.isMuted ? "Unmute" : "Mute") { session.setMuted(row.channelID, !row.isMuted) }
            Button("Notification Preferences…") { session.showNotificationPreferences(row.channelID) }
        }
        if row.type == .open || row.type == .private {
            Divider()
            Button("Leave Channel…") { session.leaveChannel(row.channelID, displayName: row.displayName) }
        }
    }
}

/// The team name in the sidebar column's part of the title bar, beside the traffic
/// lights. An `.automatic` item declared by the sidebar is placed just before the
/// sidebar toggle; its width fills the space back to the traffic lights so the name
/// starts there. (`.navigation` items start after the toggle, in the detail column,
/// and a plain overlay there would not receive clicks: the title bar view takes them.)
/// Строка поиска над списком чатов: клик открывает ⌘K-свитчер — по именам
/// каналов, людей из команды (в том числе без открытого чата) и каналам,
/// в которых пользователя ещё нет (ADR 0046).
private struct SidebarSearchRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Search")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(verbatim: "⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 20, minHeight: 17)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.07)))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .help("Search chats, team channels and people (⌘K)")
        .accessibilityLabel(Text("Search"))
        .accessibilityHint(Text("Opens the quick switcher: jump to a chat, team channel or person"))
    }
}

private struct SidebarTitleToolbar: ViewModifier {
    /// Traffic lights, the sidebar toggle, and toolbar margins.
    static let reservedWidth: CGFloat = 154
    let app: AppModel
    let session: SessionViewModel
    let columnWidth: CGFloat
    /// Свёрнутый сайдбар (ADR 0060): места нет, шапка не ставится совсем —
    /// остаются только кнопки-«светофоры» окна.
    var collapsed = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if !collapsed {
            if #available(macOS 26.0, *) {
                content.toolbar {
                    ToolbarItem(placement: .automatic) { header }
                        .sharedBackgroundVisibility(.hidden)
                }
            } else {
                content.toolbar {
                    ToolbarItem(placement: .automatic) { header }
                }
            }
        } else {
            content
        }
    }

    private var header: some View {
        SidebarHeader(app: app, session: session)
            .frame(width: max(40, columnWidth - Self.reservedWidth), alignment: .leading)
    }
}

/// Team (and, with several servers, server) name; a menu for browsing, creating and
/// messaging.
struct SidebarHeader: View {
    let app: AppModel
    let session: SessionViewModel

    var body: some View {
        Menu {
            Button("Browse Channels…") { session.directorySheet = .browseChannels }
            Button("New Channel…") { session.directorySheet = .createChannel }
            Button("New Direct Message…") { session.directorySheet = .newMessage }
            Divider()
            Button("Mark All as Read") { session.markChannelsRead(nil) }
            Divider()
            Toggle("Group Unread Channels Separately", isOn: Binding(
                get: { session.sidebar?.groupsUnreads ?? false },
                set: { session.setGroupsUnreads($0) }))
            if app.canAddServer {
                Divider()
                Button("Add Server…") { app.showAddServer() }
            }
        } label: {
            HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: teamName)
                        .font(.headline)
                    if app.slots.count > 1 {
                        Text(verbatim: serverName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(session.requiresAuthentication)
        .help("\(teamName) — browse or create channels and messages")
        .accessibilityLabel("\(teamName), channels and messages")
        .accessibilityIdentifier("sidebarAddMenu")
    }

    private var teamName: String {
        guard let sidebar = session.sidebar, let team = sidebar.teams.first(where: { $0.id == sidebar.selectedTeam })
        else { return serverName }
        return team.displayName.isEmpty ? team.name : team.displayName
    }

    private var serverName: String {
        session.slot.siteName.isEmpty ? session.slot.endpoint.host : session.slot.siteName
    }
}

/// A category title with a disclosure control. Collapsing writes the category's
/// `collapsed` flag on the server, so the user's other clients follow.
struct SidebarSectionHeader: View {
    let section: SidebarSection
    let title: String
    let onToggle: (() -> Void)?

    static func title(for section: SidebarSection) -> String {
        switch section.kind {
        case .unreads: String(localized: "Unreads")
        case .favorites: String(localized: "Favorites")
        case .channels: String(localized: "Channels")
        case .directMessages: String(localized: "Direct Messages")
        case .custom: section.title.isEmpty ? String(localized: "Category") : section.title
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                            .frame(width: 10)
                        Text(verbatim: title).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.isCollapsed ? "Expand \(title)" : "Collapse \(title)")
            } else {
                Text(verbatim: title).lineLimit(1)
            }
            if section.isMuted {
                Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.tertiary)
                    .help("Muted category")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(onToggle == nil ? [.isHeader] : [.isHeader, .isButton])
        .accessibilityAction { onToggle?() }
    }

    private var accessibilityText: String {
        var parts = [title]
        if onToggle != nil { parts.append(section.isCollapsed ? String(localized: "collapsed") : String(localized: "expanded")) }
        if section.isMuted { parts.append(String(localized: "muted")) }
        return parts.joined(separator: ", ")
    }
}

struct SidebarRow: View {
    let row: SidebarChannelRow
    let session: SessionViewModel
    var hasDraft = false
    /// Крупная строка рендера OpenDesign: аватар 38, имя с временем и превью
    /// последнего сообщения; компактный режим — прежняя однострочная.
    var large = false

    var body: some View {
        if large {
            largeBody
        } else {
            compactBody
        }
    }

    // MARK: - Крупная строка (рендер OpenDesign)

    private var largeBody: some View {
        HStack(spacing: 10) {
            largeAvatar
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.displayName)
                        .font(.system(size: 14, weight: row.isUnread ? .semibold : .medium))
                        .foregroundStyle(row.isArchived ? .secondary : .primary)
                        .lineLimit(1)
                        .help(row.partnerUsername.map { "@" + $0 } ?? row.displayName)
                    Spacer(minLength: 4)
                    Text(listTime)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    previewText
                    if hasDraft {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Unsent draft")
                    }
                    if row.mentionCount > 0 {
                        Text(row.mentionCount > 99 ? "99+" : "\(row.mentionCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 20)
                            .background(Capsule().fill(.tint))
                            .foregroundStyle(.white)
                    } else if row.isUnread {
                        Circle().fill(.tint).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .opacity(row.isMuted && row.mentionCount == 0 ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(session.selectedChannel == row.channelID ? .isSelected : [])
        .accessibilityAction { session.select(channel: row.channelID) }
    }

    /// Аватар 38 (рендер: avatar-38, радиус 27%) — общий со свёрнутым
    /// режимом `SidebarChannelAvatar`.
    private var largeAvatar: some View {
        SidebarChannelAvatar(row: row, session: session, size: 38)
    }

    private var previewText: some View {
        Group {
            if let preview = row.lastPostPreview {
                if let author = preview.authorName {
                    (Text("\(author): ").fontWeight(.medium) + Text(preview.text))
                } else {
                    Text(preview.text)
                }
            } else if row.lastPostAt == MattermostTimestamp.zero {
                Text("No messages yet").italic()
            } else {
                Text(verbatim: "")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// Время последнего сообщения в строке: часы-минуты сегодня, иначе день и месяц.
    private var listTime: String {
        let date = Date(timeIntervalSince1970: Double(row.lastPostAt.milliseconds) / 1000)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.day().month())
    }

    // MARK: - Компактная строка (прежняя)

    private var compactBody: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: row.partnerID == nil ? 16 : 20)
            Text(row.displayName)
                .fontWeight(row.isUnread ? .semibold : .regular)
                .foregroundStyle(row.isArchived ? .secondary : .primary)
                .lineLimit(1)
                .help(row.partnerUsername.map { "@" + $0 } ?? row.displayName)
            Spacer(minLength: 4)
            if hasDraft {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Unsent draft")
            }
            if row.mentionCount > 0 {
                Text(row.mentionCount > 99 ? "99+" : "\(row.mentionCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.tint))
                    .foregroundStyle(.white)
            } else if row.isUnread {
                Circle().fill(.tint).frame(width: 7, height: 7)
            }
        }
        // Muted channels are dimmed; mentions still stand out through the badge.
        .opacity(row.isMuted && row.mentionCount == 0 ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(session.selectedChannel == row.channelID ? .isSelected : [])
        .accessibilityAction { session.select(channel: row.channelID) }
    }

    @ViewBuilder private var icon: some View {
        switch row.type {
        case .direct:
            if let partner = row.partnerID {
                ProfileAvatar(session: session, userID: partner, revision: row.partnerAvatarRevision,
                              name: row.displayName, size: 20, status: row.partnerStatus ?? .offline)
            } else {
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
        case .group:
            Image(systemName: "person.2").foregroundStyle(.secondary)
        case .private:
            Image(systemName: row.isArchived ? "archivebox" : "lock").foregroundStyle(.secondary)
        default:
            Image(systemName: row.isArchived ? "archivebox" : "number").foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch row.partnerStatus {
        case .online: .green
        case .away: .yellow
        case .doNotDisturb, .outOfOffice: .red
        default: .secondary.opacity(0.5)
        }
    }

    private var accessibilityText: String {
        var parts = [row.displayName]
        if row.mentionCount > 0 { parts.append(String(localized: "\(row.mentionCount) mentions")) }
        else if row.isUnread { parts.append(String(localized: "unread")) }
        if hasDraft { parts.append(String(localized: "draft")) }
        if row.isArchived { parts.append(String(localized: "archived")) }
        if row.isMuted { parts.append(String(localized: "muted")) }
        return parts.joined(separator: ", ")
    }
}

/// Leading rail: signed-in servers (circles) above the active server's teams
/// (rounded squares), with unread and mention indicators. ⌘1…⌘9 select teams.
/// Аватар строки списка чатов: у личных — фото с точкой статуса, у каналов и
/// групп — тонированная плашка с глифом (рендер OpenDesign: радиус 27%).
/// Один и тот же для крупной строки и свёрнутого сайдбара (ADR 0060).
struct SidebarChannelAvatar: View {
    let row: SidebarChannelRow
    let session: SessionViewModel
    let size: Double

    var body: some View {
        switch row.type {
        case .direct:
            if let partner = row.partnerID {
                ProfileAvatar(session: session, userID: partner, revision: row.partnerAvatarRevision,
                              name: row.displayName, size: size, status: row.partnerStatus ?? .offline)
            } else {
                ZStack {
                    Circle().fill(.quaternary)
                    Circle().fill(Self.presenceColor(row.partnerStatus)).frame(width: size / 3.8, height: size / 3.8)
                }
                .frame(width: size, height: size)
            }
        case .group:
            glyph("person.2")
        case .private:
            glyph(row.isArchived ? "archivebox" : "lock")
        default:
            glyph(row.isArchived ? "archivebox" : "number")
        }
    }

    private func glyph(_ systemImage: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color(nsColor: TimelinePalette.avatarTint(for: row.channelID.rawValue)).opacity(0.28))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(Color(nsColor: TimelinePalette.avatarTint(for: row.channelID.rawValue)))
        }
        .frame(width: size, height: size)
    }

    /// Цвет точки присутствия — общий для строк списка и свёрнутого режима.
    static func presenceColor(_ status: PresenceStatus?) -> Color {
        switch status {
        case .online: .green
        case .away: .yellow
        case .doNotDisturb, .outOfOffice: .red
        default: .secondary.opacity(0.5)
        }
    }
}

/// Строка свёрнутого сайдбара (ADR 0060): аватар канала и индикатор внимания —
/// бейдж числа упоминаний или точка непрочитанного; имя вынесено в подсказку
/// и доступно VoiceOver.
private struct SidebarAvatarRow: View {
    let row: SidebarChannelRow
    let session: SessionViewModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SidebarChannelAvatar(row: row, session: session, size: 36)
            indicator
        }
        .frame(width: 44, height: 44)
        .opacity(row.isMuted && row.mentionCount == 0 ? 0.55 : 1)
        .help(row.partnerUsername.map { "@" + $0 } ?? row.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(session.selectedChannel == row.channelID ? .isSelected : [])
    }

    @ViewBuilder private var indicator: some View {
        if row.mentionCount > 0 {
            Text(row.mentionCount > 99 ? "99+" : "\(row.mentionCount)")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minHeight: 16)
                .background(Capsule().fill(.tint))
                .foregroundStyle(.white)
                .offset(x: 4, y: 4)
        } else if row.isUnread {
            Circle().fill(.tint).frame(width: 9, height: 9)
                .offset(x: 4, y: 4)
        }
    }

    private var accessibilityText: String {
        var parts = [row.displayName]
        if row.mentionCount > 0 { parts.append(String(localized: "\(row.mentionCount) mentions")) }
        if row.isUnread { parts.append(String(localized: "unread")) }
        if row.isArchived { parts.append(String(localized: "archived")) }
        if row.isMuted { parts.append(String(localized: "muted")) }
        return parts.joined(separator: ", ")
    }
}

/// Геометрия сайдбара (ADR 0060): перетаскиваемая ширина и сворачивание
/// колонки чатов до одних аватарок.
enum SidebarMetrics {
    static let workspaceRailWidth: Double = 52
    static let folderRailWidth: Double = 64
    /// Ширина свёрнутой колонки чатов.
    static let collapsedWidth: Double = 64
    /// Границы чат-колонки в раскрытом сайдбаре (рельсы не в счёт).
    static let expandedChatMin: Double = 180
    static let expandedChatMax: Double = 520
    /// Ниже этой чат-колонки ручка сворачивает сайдбар.
    static let collapseChatBelow: Double = 140
    /// Разворот из свёрнутого состояния: настолько пикселей тяги хватит.
    static let expandDragMinimum: Double = 16
    /// Диапазон сохранённой ширины всей колонки (валидация при загрузке).
    static var storageRange: ClosedRange<Double> { 100...720 }

    /// Суммарная ширина рельс раскрытого сайдбара.
    static func railWidth(workspaceShown: Bool) -> Double {
        (workspaceShown ? workspaceRailWidth : 0) + folderRailWidth
    }

    /// Итоговая ширина колонки для NavigationSplitView: сохранённое значение
    /// каждый раз поджимается к текущим рельсам.
    static func columnWidth(collapsed: Bool, stored: Double, workspaceShown: Bool) -> Double {
        guard !collapsed else { return collapsedWidth }
        let rails = railWidth(workspaceShown: workspaceShown)
        return min(max(stored, rails + expandedChatMin), rails + expandedChatMax)
    }
}

/// Логика перетаскивания ручки (ADR 0060), вынесена в чистый тип: один
/// источник для жеста и тестов. Пишет прямо в `LocalSettings`.
@MainActor
struct SidebarWidthController {
    private enum Drag {
        case none
        case expandedFrom(Double)
        case collapsedFrom
    }

    let settings: LocalSettings
    let workspaceShown: Bool
    private var drag: Drag = .none

    /// Горизонтальная тяга: смещение жеста от старта в pt (плюс — вправо).
    mutating func dragChanged(_ translation: Double) {
        let rails = SidebarMetrics.railWidth(workspaceShown: workspaceShown)
        switch drag {
        case .none:
            // Первый кадр жеста фиксирует точку старта — и сразу применяется.
            drag = settings.sidebarCollapsed ? .collapsedFrom
                : .expandedFrom(SidebarMetrics.columnWidth(collapsed: false, stored: settings.sidebarWidth,
                                                           workspaceShown: workspaceShown))
            dragChanged(translation)
        case .collapsedFrom:
            // Направления асимметричны: разворот — уже небольшим движением
            // вправо, чтобы не тянуть через весь порог сворачивания.
            if translation >= SidebarMetrics.expandDragMinimum {
                settings.sidebarCollapsed = false
                settings.sidebarWidth = rails + SidebarMetrics.expandedChatMin
            }
        case .expandedFrom(let origin):
            let proposal = origin + translation
            if proposal <= rails + SidebarMetrics.collapseChatBelow {
                settings.sidebarCollapsed = true
            } else {
                settings.sidebarWidth = min(max(proposal, rails + SidebarMetrics.expandedChatMin),
                                            rails + SidebarMetrics.expandedChatMax)
            }
        }
    }

    /// Жест окончен.
    mutating func dragEnded() { drag = .none }

    /// Двойной клик по ручке — переключение свёрнуто/раскрыто.
    mutating func doubleClicked() { settings.sidebarCollapsed.toggle() }
}

/// Ручка растяжения сайдбара (ADR 0060): тянется в границах `SidebarMetrics`;
/// ниже порога сворачивает колонку в аватарки, из свёрнутого — небольшой тягой
/// вправо разворачивает обратно. Двойной клик — переключение той же пары.
private struct SidebarResizeHandle: View {
    @State private var controller: SidebarWidthController

    init(settings: LocalSettings, workspaceShown: Bool) {
        // Контроллер замыкается на тот же экземпляр настроек и держит
        // состояние жеста между кадрами перетаскивания.
        _controller = State(initialValue: SidebarWidthController(settings: settings, workspaceShown: workspaceShown))
    }

    var body: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture(count: 2) { controller.doubleClicked() }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { controller.dragChanged(Double($0.translation.width)) }
                .onEnded { _ in controller.dragEnded() })
    }
}

struct WorkspaceRail: View {
    let app: AppModel
    let session: SessionViewModel
    static let width: CGFloat = 52

    static func isShown(app: AppModel, sidebar: SidebarSnapshot?) -> Bool {
        app.slots.count > 1 || (sidebar?.teams.count ?? 0) > 1
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                if app.slots.count > 1 {
                    ForEach(app.slots) { slot in
                        ServerRailButton(app: app, slot: slot)
                    }
                    if app.canAddServer {
                        Button { app.showAddServer() } label: {
                            Image(systemName: "plus")
                                .frame(width: 30, height: 30)
                                .background(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Add a server")
                        .accessibilityLabel("Add a server")
                    }
                    if let teams = session.sidebar?.teams, teams.count > 1 {
                        Divider().frame(width: 26).padding(.vertical, 4)
                    }
                }
                if let sidebar = session.sidebar, sidebar.teams.count > 1 {
                    ForEach(Array(sidebar.teams.enumerated()), id: \.element.id) { index, team in
                        TeamRailButton(session: session, team: team, index: index,
                                       isSelected: team.id == sidebar.selectedTeam)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Servers and teams")
        .accessibilityIdentifier("workspaceRail")
    }
}

struct TeamRailButton: View {
    let session: SessionViewModel
    let team: TeamSummary
    let index: Int
    let isSelected: Bool

    var body: some View {
        Button { session.selectTeam(team.id) } label: {
            TeamIconView(session: session, team: team, size: 32)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
                        .padding(-3)
                }
                .overlay(alignment: .topTrailing) {
                    if team.mentionCount > 0 {
                        Text(team.mentionCount > 99 ? "99+" : "\(team.mentionCount)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .foregroundStyle(.white)
                            .offset(x: 7, y: -6)
                    }
                }
                .frame(width: WorkspaceRail.width, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            // Selected: a tall bar; unread elsewhere: a short one (as in the official client).
            if isSelected || team.hasUnread {
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: isSelected ? 22 : 8)
                    .offset(x: -1)
            }
        }
        .help(index < 9 ? "\(team.displayName) (⌘\(index + 1))" : team.displayName)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("team-\(team.name)")
    }

    private var accessibilityText: String {
        var parts = [team.displayName]
        if team.mentionCount > 0 { parts.append(String(localized: "\(team.mentionCount) mentions")) }
        else if team.hasUnread { parts.append(String(localized: "unread")) }
        return parts.joined(separator: ", ")
    }
}

/// The team's icon (`GET /teams/{id}/image` through the bounded image pipeline)
/// when it has one, else its initials on a stable tint.
struct TeamIconView: View {
    let session: SessionViewModel
    let team: TeamSummary
    let size: CGFloat
    @State private var image: NSImage?
    @State private var lease: ImagePipeline.Decoded?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: TimelinePalette.avatarTint(for: team.id.rawValue)).opacity(0.85))
                    .overlay(Text(verbatim: Self.initials(team.displayName.isEmpty ? team.name : team.displayName))
                        .font(.system(size: floor(size * 0.4), weight: .semibold))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: "\(team.id.rawValue)#\(team.iconRevision)") { await load() }
        .onDisappear {
            image = nil
            lease = nil
        }
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    private func load() async {
        image = nil
        lease = nil
        guard team.iconRevision > 0, let pipeline = session.app?.images, !session.isDetached else { return }
        let pixels = Int((size * max(1, displayScale)).rounded(.up))
        guard let decoded = await session.session.teamIcon(team.id, revision: team.iconRevision, maxPixelSize: pixels,
                                                           pipeline: pipeline),
              !Task.isCancelled, !session.isDetached else { return }
        lease = decoded
        image = NSImage(cgImage: decoded.image, size: .zero)
    }
}

struct ServerRailButton: View {
    let app: AppModel
    let slot: SessionRegistry.Slot

    var body: some View {
        let isActive = slot.id == app.activeSlotID
        Button { app.activate(slot.id) } label: {
            Text(verbatim: TeamIconView.initials(name))
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.25))))
                .foregroundStyle(isActive ? .white : .primary)
                .frame(width: WorkspaceRail.width, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(name) — @\(slot.user.username)")
        .accessibilityLabel("\(name), signed in as \(slot.user.username)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var name: String { slot.siteName.isEmpty ? slot.endpoint.host : slot.siteName }
}

/// The signed-in account: picture, presence, custom status, and session actions.
/// Changing the status is an explicit server change visible to other users.
struct AccountBar: View {
    let app: AppModel
    let session: SessionViewModel
    /// Свёрнутый сайдбар (ADR 0060): только аватар и меню-шестерёнка,
    /// без имени и статуса.
    var compact = false
    @State private var isProfileVisible = false
    @State private var isCustomStatusVisible = false

    var body: some View {
        let user = session.slot.user
        let status = session.sidebar?.myStatus
        HStack(spacing: 8) {
            Button { isProfileVisible = true } label: {
                ProfileAvatar(session: session, userID: user.id, revision: session.sidebar?.myPictureRevision ?? user.lastPictureUpdate.milliseconds,
                              name: user.username, size: 30, status: status)
            }
            .buttonStyle(.plain)
            .help("View your profile")
            .accessibilityLabel("Your profile")
            .popover(isPresented: $isProfileVisible) {
                UserProfileCard(session: session, lookup: .id(user.id)) { isProfileVisible = false }
            }
            if !compact {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "@" + user.username).font(.callout.weight(.medium)).lineLimit(1)
                    if let custom = session.sidebar?.myCustomStatus, custom.isVisible(at: .now) {
                        Text(verbatim: [custom.emoji.isEmpty ? "" : EmojiText.display(custom.emoji), custom.text]
                            .filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let status {
                        Text(status.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            Menu {
                Section("Status") {
                    ForEach(PresenceStatus.selectable, id: \.self) { option in
                        Toggle(option.label, isOn: Binding(get: { status == option },
                                                            set: { if $0 { session.setStatus(option) } }))
                    }
                    Button("Set Custom Status…") { isCustomStatusVisible = true }
                }
                Section("Notifications") {
                    Toggle("Show Notifications", isOn: Binding(get: { app.environment.settings.notificationsEnabled },
                                                               set: { value in Task { await app.setNotificationsEnabled(value) } }))
                    Toggle("Play Sound", isOn: Binding(get: { app.notificationSounds }, set: { app.notificationSounds = $0 }))
                }
                Divider()
                Button("Edit Profile…") { ProfileEditSheet.present(session: session) }
                Button("Review Unsent Work…") { session.isUnsentRecoveryVisible = true }
                Button("Copy Unsent Text") { session.copyUnsentText() }
                    .disabled(session.isCopyingUnsentText)
                Divider()
                Button("About MatterMac") { app.isCompatibilityVisible = true }
                Button("Sign Out…") { Task { await app.signOut(session.slot.id) } }
            } label: {
                Image(systemName: "gearshape.fill")
                    .frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Status and session")
            .accessibilityLabel("Status and session")
            .sheet(isPresented: $isCustomStatusVisible) {
                CustomStatusView(session: session, current: session.sidebar?.myCustomStatus)
            }
        }
        .padding(.horizontal, compact ? 0 : 10)
        .padding(.vertical, 8)
        .glassCapsule()
    }
}

struct ConnectionFooter: View {
    let session: SessionViewModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            if !session.requiresAuthentication, showsRetry {
                Button("Reconnect") { session.reconnect() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
    }

    private var showsRetry: Bool {
        switch session.connection {
        case .backingOff, .offline, .disconnected: true
        default: false
        }
    }

    private var color: Color {
        switch session.connection {
        case .connected: .green
        case .connecting, .authenticating, .synchronizing: .yellow
        case .backingOff, .offline, .disconnected: .orange
        case .authenticationRequired: .red
        }
    }

    private var text: String {
        switch session.connection {
        case .connected: String(localized: "Connected as @\(session.slot.user.username)")
        case .connecting: String(localized: "Connecting…")
        case .authenticating: String(localized: "Authenticating…")
        case .synchronizing: String(localized: "Syncing…")
        case .backingOff(let seconds): String(localized: "Disconnected. Retrying in \(seconds)s")
        case .offline: String(localized: "Offline — showing messages already loaded")
        case .disconnected: String(localized: "Disconnected")
        case .authenticationRequired: String(localized: "Signed out by the server — sign in again")
        }
    }
}

private struct HiddenTopScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
