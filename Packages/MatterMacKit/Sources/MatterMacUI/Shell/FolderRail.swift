import SwiftUI
import MatterMacModels
import MatterMacCore

/// Рельса папок сайдбара (ADR 0043): узкая колонка между workspace rail и списком
/// чатов. Элемент — глиф и подпись группы под ним; выбор меняет вторую колонку,
/// не трогая открытый канал.
struct FolderRail: View {
    static let width: CGFloat = 64
    @Bindable var session: SessionViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(session.sidebar?.folders ?? []) { item in
                    FolderRailButton(item: item, session: session)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat folders")
        .accessibilityIdentifier("sidebarFolders")
    }
}

private struct FolderRailButton: View {
    let item: SidebarFolderItem
    @Bindable var session: SessionViewModel
    /// Показ эмодзи-пикера иконки группы (контекстное меню, ADR 0043).
    @State private var isIconPickerShown = false

    private var isSelected: Bool { session.selectedFolder == item.folder }

    var body: some View {
        Button { session.selectFolder(item.folder) } label: {
            VStack(spacing: 3) {
                glyph
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(item.isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
                    )
                    .overlay(alignment: .topTrailing) { badge }
                Text(verbatim: item.caption)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 3)
            }
            .frame(width: FolderRail.width, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isAvailable)
        .opacity(item.isMuted ? 0.7 : 1)
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: 22)
                    .offset(x: 2)
            }
        }
        .help(item.caption)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebarFolder-\(item.folder.rawValue)")
        .contextMenu { iconMenu }
        .popover(isPresented: $isIconPickerShown, arrowEdge: .trailing) {
            if item.kind == .group, let categoryID = item.categoryID {
                EmojiIconPicker { name in
                    isIconPickerShown = false
                    session.setGroupIcon(categoryID: categoryID.rawValue, emoji: name)
                } cancel: {
                    isIconPickerShown = false
                }
                .frame(width: ReactionPickerViewController.preferredSize.width,
                       height: ReactionPickerViewController.preferredSize.height)
            }
        }
    }

    /// Меню иконки — только у групп: выбор эмодзи (системный каталог) и сброс.
    @ViewBuilder private var iconMenu: some View {
        if item.kind == .group, let categoryID = item.categoryID {
            Button("Choose Icon…") { isIconPickerShown = true }
            if session.groupIcon(categoryID: categoryID.rawValue) != nil {
                Divider()
                Button("Reset Icon") { session.setGroupIcon(categoryID: categoryID.rawValue, emoji: nil) }
            }
        }
    }

    /// Дефолтные глифы — по контракту ADR 0043; группа — выбранное эмодзи или папка.
    @ViewBuilder private var glyph: some View {
        switch item.kind {
        case .all: Image(systemName: "list.bullet")
        case .group:
            if let emoji = item.categoryID.flatMap({ session.groupIcon(categoryID: $0.rawValue) }) {
                Text(verbatim: EmojiText.display(emoji)).font(.system(size: 16))
            } else {
                Image(systemName: "folder")
            }
        case .threads: Image(systemName: "bubble.left.and.text.bubble.right")
        case .drafts: Image(systemName: "square.and.pencil")
        case .mentions: Image(systemName: "at")
        case .unread: Image(systemName: "bell.badge")
        }
    }

    /// Красная капсула — упоминания (у «Черновиков» — живое число черновиков из
    /// вью-модели: хранилище черновиков в UI); точка — просто непрочитанное.
    private var badgeCount: Int {
        item.kind == .drafts ? session.draftsFolderCount : item.mentionCount
    }

    @ViewBuilder private var badge: some View {
        if badgeCount > 0 {
            Text(verbatim: badgeCount > 99 ? "99+" : "\(badgeCount)")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.red))
                .foregroundStyle(.white)
                .offset(x: 8, y: -6)
        } else if item.kind != .drafts, item.unreadCount > 0 {
            Circle()
                .fill(Color.primary)
                .frame(width: 6, height: 6)
                .offset(x: 4, y: -2)
        }
    }

    private var accessibilityText: String {
        var parts = [item.caption]
        if item.kind == .drafts {
            if session.draftsFolderCount > 0 {
                parts.append(session.draftsFolderCount == 1 ? String(localized: "1 draft")
                                                            : String(localized: "\(session.draftsFolderCount) drafts"))
            }
        } else if item.mentionCount > 0 { parts.append(String(localized: "\(item.mentionCount) mentions")) }
        else if item.unreadCount > 0 { parts.append(String(localized: "unread")) }
        return parts.joined(separator: ", ")
    }
}

/// Эмодзи-пикер для иконки группы: системный каталог из реакций без custom-страниц
/// (custom-эмодзи сервера не рисуются рельсой — нет загрузчика, честно не предлагаем).
private struct EmojiIconPicker: NSViewControllerRepresentable {
    let pick: (String) -> Void
    let cancel: () -> Void

    func makeNSViewController(context: Context) -> ReactionPickerViewController {
        let picker = ReactionPickerViewController()
        picker.onPick = pick
        picker.onCancel = cancel
        return picker
    }

    func updateNSViewController(_ picker: ReactionPickerViewController, context: Context) {}
}
