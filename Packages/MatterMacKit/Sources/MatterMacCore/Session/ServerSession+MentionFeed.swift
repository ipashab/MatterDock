import Foundation
import MatterMacModels
import MattermostAPI

// Фид папки «Упоминания и реакции» (ADR 0043). Упоминания — серверный поиск
// `@username`, как в официальном клиенте; страницы по 25, общий лимит — бюджет
// поиска (`searchResults`). Реакции на мои сообщения сервер не ищет вовсе:
// строки-реакции накапливаются только из realtime на резидентные посты —
// честное ограничение, полной истории реакций не будет.
extension ServerSession {
    /// Страница поиска упоминаний.
    public static let mentionFeedPageSize = 25

    /// Полная перезагрузка: свежий поиск упоминаний с первой страницы. Строки-реакции
    /// сохраняются — серверного списка у них нет, терять кольцо нельзя.
    public func reloadMentionFeed() async {
        guard isActiveSessionAlive, let team = selectedTeam else { return }
        let generation = mentionFeedRevision &+ 1
        mentionFeedRevision = generation
        let epoch = self.epoch
        publishMentionFeed(.searching)
        do throws(APIError) {
            let page = try await service.searchPosts(
                SearchQuery(team: team, terms: "@" + me.username, isOrSearch: true,
                            timeZoneOffsetSeconds: Int(deps.timeZone().secondsFromGMT()),
                            page: 0, perPage: Self.mentionFeedPageSize))
            guard epochStable(epoch, generation) else { return }
            ingestMentionPosts(page.posts)
            let reactions = mentionFeedItems.filter { $0.kind == .reaction }
            mentionFeedItems = mergeMentionFeed(reactions: reactions, mentions: listMentionItems(posts: page.posts))
            releaseDroppedMentionPosts()
            mentionFeedPage = 0
            mentionFeedHasMore = page.posts.count >= Self.mentionFeedPageSize
                && mentionFeedItems.count < budget.searchResults.count
            publishMentionFeed(.ready)
        } catch {
            guard epochStable(epoch, generation) else { return }
            handleAuthenticationFailureIfNeeded(error)
            publishMentionFeed(.failed(Self.userFacing(error)))
        }
    }

    /// Следующая страница поиска упоминаний («Ещё» под списком).
    public func loadMoreMentionFeed() async {
        guard isActiveSessionAlive, let team = selectedTeam, mentionFeedHasMore else { return }
        let generation = mentionFeedRevision
        let epoch = self.epoch
        run(.mentionFeedPage) { session in
            let page = session.mentionFeedPage + 1
            do {
                let result = try await session.service.searchPosts(
                    SearchQuery(team: team, terms: "@" + session.me.username, isOrSearch: true,
                                timeZoneOffsetSeconds: Int(session.deps.timeZone().secondsFromGMT()),
                                page: page, perPage: Self.mentionFeedPageSize))
                guard session.epochStable(epoch, generation) else { return }
                session.ingestMentionPosts(result.posts)
                let reactions = session.mentionFeedItems.filter { $0.kind == .reaction }
                let mentions = session.mentionFeedItems.filter { $0.kind == .mention }
                session.mentionFeedItems = session.mergeMentionFeed(reactions: reactions,
                                                                    mentions: mentions + session.listMentionItems(posts: result.posts))
                session.releaseDroppedMentionPosts()
                session.mentionFeedPage = page
                session.mentionFeedHasMore = result.posts.count >= Self.mentionFeedPageSize
                    && session.mentionFeedItems.count < session.budget.searchResults.count
                session.publishMentionFeed(.ready)
            } catch {
                guard session.epochStable(epoch, generation) else { return }
                session.handleAuthenticationFailureIfNeeded(error)
                session.publishMentionFeed(.failed(Self.userFacing(error)))
            }
        }
    }

    /// Realtime: реакция на мой резидентный пост становится строкой фида; повторная
    /// (сняли и снова поставили) поднимает строку наверх.
    func mentionFeedReactionAdded(_ reaction: Reaction) {
        guard let post = store.post(reaction.postID), !post.isDeleted, post.userID == me.id,
              let channel = directory.channels[post.channelID] else { return }
        if reaction.userID != me.id, directory.peekUser(reaction.userID) == nil {
            missingUsers.insert(reaction.userID)
            scheduleUserFetch()
        }
        let rowID = Self.reactionRowID(post: reaction.postID, reactionName: reaction.emojiName,
                                       reactor: reaction.userID)
        if let index = mentionFeedItems.firstIndex(where: { $0.id == rowID }) {
            mentionFeedItems.remove(at: index)
        }
        mentionFeedItems.insert(reactionItem(post: post, channel: channel, reaction: reaction), at: 0)
        if mentionFeedItems.count > budget.searchResults.count {
            mentionFeedItems = Array(mentionFeedItems.prefix(budget.searchResults.count))
        }
        publishMentionFeed(.ready)
    }

    /// Realtime: реакцию сняли — строка фида уходит вместе с ней.
    func mentionFeedReactionRemoved(_ reaction: Reaction) {
        let rowID = Self.reactionRowID(post: reaction.postID, reactionName: reaction.emojiName,
                                       reactor: reaction.userID)
        guard let index = mentionFeedItems.firstIndex(where: { $0.id == rowID }) else { return }
        mentionFeedItems.remove(at: index)
        publishMentionFeed(.ready)
    }

    // MARK: - Внутреннее

    /// Посты поиска становятся резидентными (как в обычном поиске): имена авторов
    /// дозапрашиваются, строки можно пересобрать после загрузки.
    private func ingestMentionPosts(_ posts: [Post]) {
        for post in posts where !post.isDeleted {
            store.upsert(post)
            if mentionFeedRetainedPosts.insert(post.id).inserted { store.retain(post.id) }
        }
        scheduleUserFetch()
        enforceRetention()
    }

    /// Удержание чистим для постов, выпавших из фида после перезагрузки.
    private func releaseDroppedMentionPosts() {
        let present = Set(mentionFeedItems.compactMap { $0.kind == .mention ? $0.postID : nil })
        mentionFeedRetainedPosts = mentionFeedRetainedPosts.filter { id in
            if present.contains(id) { return true }
            store.release(id)
            return false
        }
    }

    private static func reactionRowID(post: PostID, reactionName: String, reactor: UserID) -> String {
        post.rawValue + "|" + reactionName + "|" + reactor.rawValue
    }

    /// Реакция — на мой пост; автор строки (и её аватар) — тот, кто поставил реакцию.
    private func reactionItem(post: Post, channel: Channel, reaction: Reaction) -> MentionFeedItem {
        let reactor = directory.peekUser(reaction.userID)
        let preview = String(deps.documents.document(for: post).plainText.prefix(280))
        return MentionFeedItem(
            id: Self.reactionRowID(post: post.id, reactionName: reaction.emojiName, reactor: reaction.userID),
            kind: .reaction, postID: post.id, channelID: post.channelID, rootID: post.rootID,
            channelName: displayName(of: channel),
            authorID: reaction.userID,
            authorName: reaction.userID == me.id
                ? String(localized: "You") : (reactor.map { directory.nameFormat.displayName(for: $0) } ?? ""),
            authorAvatarRevision: reactor?.lastPictureUpdate.milliseconds ?? 0,
            preview: preview, createdAt: post.createAt,
            reactionName: reaction.emojiName)
    }

    /// Строки-упоминания из постов поиска; имена недостающих пользователей
    /// дозапросятся, строка не отбрасывается (как в фиде тредов).
    private func listMentionItems(posts: [Post]) -> [MentionFeedItem] {
        var missing = Set<UserID>()
        var items: [MentionFeedItem] = []
        for post in posts where !post.isDeleted {
            guard let channel = directory.channels[post.channelID] else { continue }
            let author = peekUserForMentions(post.userID)
            if author == nil, post.userID != me.id { missing.insert(post.userID) }
            let preview = String(deps.documents.document(for: post).plainText.prefix(280))
            items.append(MentionFeedItem(
                id: post.id.rawValue, kind: .mention, postID: post.id, channelID: post.channelID,
                rootID: post.rootID, channelName: displayName(of: channel),
                authorID: post.userID,
                authorName: post.props.overrideUsername
                    ?? author.map { directory.nameFormat.displayName(for: $0) } ?? "",
                authorAvatarRevision: author?.lastPictureUpdate.milliseconds ?? 0,
                preview: preview, createdAt: post.createAt, reactionName: nil))
        }
        if !missing.isEmpty {
            missingUsers.formUnion(missing)
            scheduleUserFetch()
        }
        return items
    }

    private func peekUserForMentions(_ id: UserID) -> User? {
        id == me.id ? me : directory.peekUser(id)
    }

    private func epochStable(_ epoch: UInt64, _ generation: UInt64) -> Bool {
        self.epoch == epoch && mentionFeedRevision == generation && isActiveSessionAlive && !Task.isCancelled
    }

    /// Реакции — свежими первыми (кольцо), за ними упоминания (порядок поиска,
    /// новее выше); дубликаты по id и общий лимит бюджета поиска.
    private func mergeMentionFeed(reactions: [MentionFeedItem], mentions: [MentionFeedItem]) -> [MentionFeedItem] {
        var seen = Set<String>()
        var items: [MentionFeedItem] = []
        for item in reactions + mentions {
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
            if items.count >= budget.searchResults.count { break }
        }
        return items
    }

    private func publishMentionFeed(_ state: MentionFeedSnapshot.State) {
        mentionFeedUpdatesContinuation.yield(MentionFeedSnapshot(
            scope: scope, revision: mentionFeedRevision, state: state,
            items: mentionFeedItems, canLoadMore: mentionFeedHasMore))
    }
}
