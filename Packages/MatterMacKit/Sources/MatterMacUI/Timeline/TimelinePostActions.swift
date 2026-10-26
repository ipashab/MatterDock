import AppKit
import MatterMacModels
import MatterMacCore

/// The message actions offered for a post, shared by the context menu, the hover action
/// bar's "More" menu and the row's accessibility custom actions, so all three always
/// agree. `nil` entries are separators.
enum TimelinePostActions {
    struct Entry: Equatable {
        let title: String
        let action: TimelineAction
        /// SF Symbol shown in menus.
        let symbol: String?
    }

    /// Reactions offered directly on the hover bar (static, like the official client's
    /// defaults when there is no recent-emoji history).
    static let quickReactions = ["+1", "white_check_mark", "heart"]

    /// Three quick reactions: the user's most recent, then the defaults.
    static func quickReactions(recent: [String]) -> [String] {
        var result: [String] = []
        for name in recent + quickReactions where !result.contains(name) && result.count < 3 { result.append(name) }
        return result
    }

    /// Данные для ответа-цитаты (ADR 0057): идентификатор, автор и обрывок
    /// сообщения снимаются с его же презентации — баннеру композера и меню
    /// ничего доносить не нужно.
    static func quoteTarget(for post: PostPresentation) -> ReplyContext? {
        guard let id = post.postID else { return nil }
        let excerpt: String
        switch post.body {
        case .document(let document, _): excerpt = TimelineBuilder.quoteSnippet(document.plainText)
        case .system(let text): excerpt = TimelineBuilder.quoteSnippet(text)
        case .unsupported(_, let fallbackText): excerpt = TimelineBuilder.quoteSnippet(fallbackText)
        case .deleted: return nil
        }
        return ReplyContext(postID: id, authorName: post.author.displayName, snippet: excerpt)
    }

    static func entries(for post: PostPresentation, allowsQuoteReply: Bool = true) -> [Entry?] {
        guard let id = post.postID else { return [] }
        var sections: [[Entry]] = []
        var first: [Entry] = []
        if post.actions.canReply {
            // «Ответить» — ответ-цитата в том же канале (как в веб-клиенте
            // сервера); открытие треда — отдельным пунктом. В панели треда
            // цитаты нет: там и так ответ в тред.
            if allowsQuoteReply, let quote = quoteTarget(for: post) {
                first.append(Entry(title: TimelineStrings.actionReply, action: .quoteReply(quote),
                                   symbol: "arrowshape.turn.up.left"))
            }
            first.append(Entry(title: TimelineStrings.actionReplyInThread, action: .reply(post.rootID ?? id),
                               symbol: "arrowshape.turn.up.left"))
        }
        if post.actions.canReact {
            first.append(Entry(title: TimelineStrings.actionAddReaction, action: .addReaction(id), symbol: "face.smiling"))
        }
        if post.actions.canForward {
            first.append(Entry(title: TimelineStrings.actionForward, action: .forward(id), symbol: "arrowshape.turn.up.right"))
        }
        sections.append(first)
        var state: [Entry] = []
        if post.actions.canMarkUnread {
            state.append(Entry(title: TimelineStrings.actionMarkUnread, action: .markUnread(id), symbol: "envelope.badge"))
        }
        if post.actions.canSave {
            state.append(post.isSaved
                ? Entry(title: TimelineStrings.actionUnsave, action: .setSaved(id, false), symbol: "bookmark.slash")
                : Entry(title: TimelineStrings.actionSave, action: .setSaved(id, true), symbol: "bookmark"))
        }
        if post.actions.canPin {
            state.append(post.isPinned
                ? Entry(title: TimelineStrings.actionUnpin, action: .setPinned(id, false), symbol: "pin.slash")
                : Entry(title: TimelineStrings.actionPin, action: .setPinned(id, true), symbol: "pin"))
        }
        sections.append(state)
        var copy: [Entry] = []
        if post.actions.canCopyLink, let url = post.permalink {
            copy.append(Entry(title: TimelineStrings.actionCopyLink, action: .copyLink(url), symbol: "link"))
        }
        copy.append(Entry(title: TimelineStrings.actionCopyText, action: .copyText(id), symbol: "doc.on.doc"))
        sections.append(copy)
        var modify: [Entry] = []
        if post.actions.canEdit { modify.append(Entry(title: TimelineStrings.actionEdit, action: .edit(id), symbol: "pencil")) }
        if post.actions.canDelete {
            modify.append(Entry(title: TimelineStrings.actionDelete, action: .delete(id), symbol: "trash"))
        }
        sections.append(modify)
        sections.append([Entry(title: TimelineStrings.actionViewProfile(post.author.displayName),
                               action: .showProfile(post.author.userID), symbol: "person.crop.circle")])
        var result: [Entry?] = []
        for section in sections where !section.isEmpty {
            if !result.isEmpty { result.append(nil) }
            result.append(contentsOf: section.map { Optional($0) })
        }
        return result
    }

    /// Accessibility custom actions: quick reactions first, then every menu entry.
    static func accessibilityEntries(for post: PostPresentation, allowsQuoteReply: Bool = true,
                                     quickReactions: [String] = quickReactions) -> [Entry] {
        guard let id = post.postID else { return [] }
        var result: [Entry] = []
        if post.actions.canReact {
            for name in quickReactions {
                result.append(Entry(title: TimelineStrings.quickReaction(name), action: .toggleReaction(id, emojiName: name),
                                    symbol: nil))
            }
        }
        result.append(contentsOf: entries(for: post, allowsQuoteReply: allowsQuoteReply).compactMap { $0 })
        return result
    }

    /// Writes clipboard content the timeline owns before the delegate sees the action.
    @MainActor static func prepare(_ action: TimelineAction) {
        if case .copyLink(let url) = action {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}
