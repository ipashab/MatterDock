import SwiftUI
import MatterMacModels
import MatterMacCore

/// Папка «Упоминания и реакции» (ADR 0043): вторая колонка сайдбара — фид постов,
/// где меня упомянули (поиск `@username`, как в официальном клиенте), и realtime-строк
/// реакций на мои сообщения. Полной истории реакций сервер не даёт — строки-реакции
/// видны, пока папка собирает их в этой сессии.
struct MentionsFolderView: View {
    @Bindable var session: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch session.mentionFeed?.state {
            case .failed(let error):
                ContentUnavailableView {
                    Label("Mentions Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(UserFacingErrorText.describe(error))
                } actions: {
                    Button("Try Again") { session.reloadMentionFeed() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .searching, .idle, .none:
                if items.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            case .ready:
                if items.isEmpty {
                    ContentUnavailableView("No Mentions",
                                           systemImage: "at",
                                           description: Text("Messages that mention you and reactions to your messages appear here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
        // Каждое появление папки — свежий поиск; реакции копятся поверх.
        .task(id: session.scope) { session.reloadMentionFeed() }
    }

    private var items: [MentionFeedItem] { session.mentionFeed?.items ?? [] }

    private var list: some View {
        List {
            ForEach(items) { item in
                MentionRow(item: item, session: session)
                    .onTapGesture { open(item) }
            }
            if session.mentionFeed?.canLoadMore == true {
                Button("Load More Mentions") { session.loadMoreMentionFeed() }
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("mentionsFolderList")
    }

    /// Строка ведёт к посту: тредовые открываются тредом, остальные — каналом с фокусом.
    private func open(_ item: MentionFeedItem) {
        if let root = item.rootID {
            session.select(channel: item.channelID, thread: root)
        } else {
            session.select(channel: item.channelID, focusing: item.postID)
        }
    }
}

private struct MentionRow: View {
    let item: MentionFeedItem
    let session: SessionViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProfileAvatar(session: session, userID: item.authorID, revision: item.authorAvatarRevision,
                          name: item.authorName, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: item.authorName.isEmpty ? String(localized: "Unknown") : item.authorName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if item.kind == .reaction, let emoji = item.reactionName {
                        Text(verbatim: EmojiText.display(emoji))
                    }
                    Text(verbatim: item.channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.createdAt.date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(verbatim: item.preview.isEmpty ? String(localized: "(no text)") : item.preview)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(item.kind == .reaction ? "Open the message that was reacted to" : "Open the message that mentioned you")
    }

    private var accessibilityText: String {
        var parts = [item.authorName, item.channelName, item.preview]
        if item.kind == .reaction { parts.append(String(localized: "reaction")) }
        return parts.joined(separator: ", ")
    }
}
