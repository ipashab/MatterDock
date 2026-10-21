import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

/// Папка «Черновики» (ADR 0043): вторая колонка сайдбара списком незавершённых
/// черновиков текущей сессии. Черновики session-only (SPEC §7) — список живёт только
/// на рендере, без логов и записи на диск. Клик продолжает писать: канал/тред
/// открывается, композер восстанавливает текст и каретка по ключу черновика.
struct DraftsFolderView: View {
    let app: AppModel
    @Bindable var session: SessionViewModel

    private var drafts: [DraftRecoveryItem] {
        app.environment.drafts.recoveryDrafts(for: session.scope)
    }

    var body: some View {
        if drafts.isEmpty {
            ContentUnavailableView("No drafts", systemImage: "square.and.pencil",
                                   description: Text("Unfinished messages wait here. Click one to continue writing; drafts stay only until you sign out or quit."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(drafts) { item in
                    DraftRow(item: item, session: session)
                        .contextMenu {
                            Button("Copy Text") { copy(item) }
                                .disabled(item.draft.text.isEmpty)
                            Divider()
                            Button("Discard…", role: .destructive) {
                                guard confirmDiscard() else { return }
                                discard(item)
                            }.disabled(!item.canDiscard)
                        }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("draftsFolderList")
        }
    }

    private func copy(_ item: DraftRecoveryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.draft.text, forType: .string)
    }

    private func discard(_ item: DraftRecoveryItem) {
        guard app.environment.drafts.discardRecoveryDraft(item) else { return }
        session.discardDraftEditingState(for: item.id)
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this draft?"
        alert.informativeText = "Its text and attachments will be removed from this session. This cannot undo anything already received by the server."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private struct DraftRow: View {
    let item: DraftRecoveryItem
    let session: SessionViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.draft.editingPost != nil ? "pencil.circle" : "square.and.pencil")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: channelName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if item.id.rootID != nil {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let kind {
                        Text(verbatim: kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                Text(verbatim: preview)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                if !item.draft.attachments.isEmpty {
                    Label(item.draft.attachments.count == 1 ? String(localized: "1 attachment")
                        : String(localized: "\(item.draft.attachments.count) attachments"),
                          systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { openChannel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Continue writing")
    }

    private var channelName: String {
        session.sidebar?.sections.lazy.flatMap(\.rows)
            .first { $0.channelID == item.id.channelID }?.displayName
            ?? String(localized: "Channel …") + item.id.channelID.rawValue.suffix(8)
    }

    private var kind: String? {
        item.id.forwardingPostID != nil ? String(localized: "Forwarding draft")
            : item.draft.editingPost != nil ? String(localized: "Edited message") : nil
    }

    private var preview: String {
        item.draft.text.isEmpty ? String(localized: "(no text)") : String(item.draft.text.prefix(280))
    }

    private var accessibilityText: String {
        var parts = [channelName, preview]
        if let kind { parts.append(kind) }
        return parts.joined(separator: ", ")
    }

    private func openChannel() {
        if item.id.forwardingPostID == nil, let root = item.id.rootID {
            session.select(channel: item.id.channelID, thread: root)
        } else {
            session.select(channel: item.id.channelID)
        }
    }
}
