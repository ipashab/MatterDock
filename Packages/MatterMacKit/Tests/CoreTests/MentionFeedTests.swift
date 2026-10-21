import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

/// Фид папки «Упоминания и реакции» (ADR 0043): поиск `@username` и realtime-реакции
/// на мои резидентные посты.
@Suite("Mention feed", .serialized)
struct MentionFeedTests {
    /// Realtime-события обрабатываются асинхронно: ждём, пока очередь фейка
    /// опустеет, и даём одну итерацию рантайма (как в SessionTests).
    private func waitRealtimeDrained(_ h: SessionHarness) async {
        _ = await eventually { await h.realtime.queuedCount == 0 }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func searchFindsPostsThatMentionMe() async {
        let channelID = CoreFixtures.channel(1).id
        let mention = CoreFixtures.post(9, channel: channelID, message: "hey @alice review please")
        let h = await SessionHarness(configure: { state in
            state.posts[mention.id] = mention
        })
        await h.session.reloadMentionFeed()
        var items = await h.session.mentionFeedItems
        #expect(items.count == 1)
        #expect(items[0].kind == .mention)
        #expect(items[0].postID == mention.id)
        #expect(items[0].channelID == channelID)
        #expect(items[0].authorID == CoreFixtures.bob.id)
        #expect(items[0].preview.contains("@alice"))
        #expect(await h.session.mentionFeedHasMore == false)
        // Имя автора подгружается асинхронно; следующий показ папки его соберёт
        // (nameFormat по умолчанию — username).
        #expect(await eventually { await h.session.directory.peekUser(CoreFixtures.bob.id) != nil })
        await h.session.reloadMentionFeed()
        items = await h.session.mentionFeedItems
        #expect(items[0].authorName == "bob")
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func reactionToMyResidentPostBecomesARowAndLeavesOnRemoval() async {
        let mine = CoreFixtures.post(7, channel: CoreFixtures.channel(1).id, user: CoreFixtures.me.id,
                                     message: "my sweet post")
        let h = await SessionHarness(configure: { state in
            state.posts[mine.id] = mine
        })
        await h.openChannel()
        let reaction = Reaction(userID: CoreFixtures.bob.id, postID: mine.id, emojiName: "tada")
        await h.realtime.push(.reactionAdded(reaction))
        await waitRealtimeDrained(h)
        var items = await h.session.mentionFeedItems
        #expect(items.count == 1)
        #expect(items[0].kind == .reaction)
        #expect(items[0].postID == mine.id)
        #expect(items[0].reactionName == "tada")
        // Автор строки — реактор, не автор поста.
        #expect(items[0].authorID == CoreFixtures.bob.id)
        #expect(items[0].authorName == "bob")
        #expect(items[0].preview == "my sweet post")
        #expect(items[0].id == mine.id.rawValue + "|tada|" + CoreFixtures.bob.id.rawValue)
        // Реакцию сняли — строка ушла.
        await h.realtime.push(.reactionRemoved(reaction))
        await waitRealtimeDrained(h)
        items = await h.session.mentionFeedItems
        #expect(items.isEmpty)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func reactionToSomeoneElsesPostIsIgnored() async {
        // Посты 0–4 харнесса — от bob; реакция на чужой пост строкой не становится.
        let h = await SessionHarness()
        await h.openChannel()
        let theirs = CoreFixtures.post(3, channel: h.channel.id)
        let reaction = Reaction(userID: CoreFixtures.bob.id, postID: theirs.id, emojiName: "tada")
        await h.realtime.push(.reactionAdded(reaction))
        await waitRealtimeDrained(h)
        #expect(await h.session.mentionFeedItems.isEmpty)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func reactionsStayOnTopWhenMentionsReload() async {
        let channelID = CoreFixtures.channel(1).id
        let mention = CoreFixtures.post(9, channel: channelID, message: "hey @alice review please")
        let mine = CoreFixtures.post(7, channel: channelID, user: CoreFixtures.me.id, message: "my sweet post")
        let h = await SessionHarness(configure: { state in
            state.posts[mention.id] = mention
            state.posts[mine.id] = mine
        })
        await h.openChannel()
        await h.realtime.push(.reactionAdded(Reaction(userID: CoreFixtures.bob.id, postID: mine.id, emojiName: "tada")))
        await waitRealtimeDrained(h)
        await h.session.reloadMentionFeed()
        var items = await h.session.mentionFeedItems
        // Реакции — свежими первыми, за ними упоминания из поиска.
        #expect(items.count == 2)
        #expect(items.map(\.kind) == [.reaction, .mention])
        // Повторный поиск не теряет кольцо реакций.
        await h.session.reloadMentionFeed()
        items = await h.session.mentionFeedItems
        #expect(items.count == 2)
        #expect(items.map(\.kind) == [.reaction, .mention])
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
