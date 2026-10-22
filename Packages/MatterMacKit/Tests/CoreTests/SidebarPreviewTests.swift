import Foundation
import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI
import MattermostRealtime
import TestSupport

/// Превью строки чата в сайдбаре: последнее сообщение самого канала — то есть
/// последний **корень**; ответы треда в список чатов не всплывают (ADR 0047).
@Suite("Sidebar previews", .serialized)
struct SidebarPreviewTests {
    private func harness() async -> SidebarHarness {
        await SidebarHarness(configure: { state in
            var channel = CoreFixtures.channel(1)
            channel.lastPostAt = MattermostTimestamp(milliseconds: 1_700_000_010_000)
            state.channels[channel.id] = channel
        })
    }

    private func ready(_ h: SidebarHarness) async {
        _ = await eventually {
            await h.session.quickSwitcherResults(query: "").contains { $0.title == "Channel 1" }
        }
    }

    @Test func backfillPreviewsTheLatestRootNotTheThreadReply() async throws {
        let h = await harness()
        await ready(h)
        let channel = CoreFixtures.channel(1)
        h.service.withState { state in
            let root = CoreFixtures.post(1, channel: channel.id, message: "корень треда",
                                         createAt: 1_700_000_000_000)
            let reply = CoreFixtures.post(2, channel: channel.id, message: "ответ в треде",
                                          createAt: 1_700_000_005_000, rootID: root.id)
            state.posts[root.id] = root
            state.posts[reply.id] = reply
        }
        await h.session.backfillSidebarPreviews()
        _ = await eventually { await h.session.channelPreviews[channel.id] != nil }
        #expect(await h.session.channelPreviews[channel.id]?.text == "корень треда",
                "превью — последнее сообщение канала, не треда")
        #expect(await h.session.channelPreviewStamp[channel.id] == CoreFixtures.post(1, channel: channel.id).id)
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func realtimeReplyNeverOverwritesTheChannelPreview() async throws {
        let h = await harness()
        await ready(h)
        let channel = CoreFixtures.channel(1)
        let root = CoreFixtures.post(1, channel: channel.id, message: "первый корень",
                                     createAt: 1_700_000_000_000)
        let reply = CoreFixtures.post(2, channel: channel.id, message: "ответ в треде",
                                      createAt: 1_700_000_005_000, rootID: root.id)
        let newerRoot = CoreFixtures.post(3, channel: channel.id, message: "новый корень",
                                          createAt: 1_700_000_006_000)
        func push(_ post: Post) async {
            await h.realtime.push(.posted(PostedEvent(post: post, channelType: .open, teamID: CoreFixtures.team.id,
                                                      mentionsCurrentUser: false, setOnline: true)))
        }
        func channelState() async -> (Int64, String?) {
            await (h.session.directory.channels[channel.id]?.totalMessageCount ?? 0,
                   h.session.channelPreviews[channel.id]?.text)
        }
        await push(root)
        _ = await eventually {
            let state = await channelState()
            return state.0 == 1 && state.1 == "первый корень"
        }
        await push(reply)
        _ = await eventually {
            let state = await channelState()
            return state.0 == 2
        }
        #expect(await channelState().1 == "первый корень", "ответ треда не меняет превью чата")
        #expect(await h.session.channelPreviewStamp[channel.id] == root.id)
        await push(newerRoot)
        _ = await eventually {
            let state = await channelState()
            return state.0 == 3 && state.1 == "новый корень"
        }
        _ = await h.session.shutdown(revokeServerSession: false)
    }

    @Test func latestRootSearchContinuesPastReplyOnlyPages() async throws {
        let h = await harness()
        await ready(h)
        let channel = CoreFixtures.channel(1)
        h.service.withState { state in
            for n in 1...ServerSession.sidebarPreviewPageSize {
                let reply = CoreFixtures.post(n, channel: channel.id, message: "ответ \(n)",
                                              createAt: 1_700_000_000_000 + Int64(n),
                                              rootID: CoreFixtures.post(999, channel: channel.id).id)
                state.posts[reply.id] = reply
            }
            let root = CoreFixtures.post(200, channel: channel.id, message: "старый корень",
                                         createAt: 1_700_000_000_000)
            state.posts[root.id] = root
        }
        let root = try await h.session.latestRootPost(in: channel.id)
        #expect(root?.message == "старый корень", "корень находится за пределами первой страницы ответов")
        _ = await h.session.shutdown(revokeServerSession: false)
    }
}
