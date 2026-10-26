import Foundation
import Testing
import os
import MatterMacModels
import MattermostAPI
@testable import MatterMacCore
import TestSupport

@Suite("Image ownership and bounds")
struct ImagePipelineTests {
    let scope = AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id)

    @MainActor @Test func pastedBytesFollowLastOwnerAfterDraftAndPendingRelease() throws {
        let data = CoreFixtures.png()
        var budget = ResourceBudget.standard
        budget.pastedImageBytes = data.count
        let ledger = UnsentWorkLedger(budget: budget)
        let store = DraftStore(ledger: ledger)
        let key = DraftKey(scope: scope, channelID: CoreFixtures.channel(1).id, rootID: nil)
        var source: UploadSource? = try ledger.pastedImage(data, typeIdentifier: "public.png")
        try store.save(Draft(text: "", attachments: [source!]), for: key)
        source = nil
        var activeUpload = store.draft(for: key)?.attachments.first
        let pending = try store.takeForSending(key)
        store.finishSending(key, reservation: pending, accepted: true)
        ledger.release(pending)
        #expect(ledger.usage.totalBytes == 0)
        #expect(ledger.usage.imageBytes == data.count)
        #expect(throws: UnsentWorkLedger.Refusal.imageBudgetExceeded(limitBytes: data.count)) {
            _ = try ledger.pastedImage(data, typeIdentifier: "public.png")
        }
        #expect(activeUpload?.memoryBytes == data.count)
        activeUpload = nil
        #expect(ledger.usage.imageBytes == 0)
        #expect(throws: APIError.self) {
            _ = try ledger.pastedImage(Data([1, 2]), typeIdentifier: "public.png")
        }
        #expect(ledger.usage.imageBytes == 0)
    }

    @Test func visibleImageRemainsChargedAfterCachePurge() async throws {
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let data = CoreFixtures.png(width: 128, height: 64)
        service.withState { $0.imageHandler = { _, _ in data } }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let key = ImagePipeline.Key(scope: scope, resource: .profileImage(CoreFixtures.me.id, revision: 0), maxPixelSize: 32)
        var visible = await pipeline.image(for: key, using: service)
        #expect(visible?.image.width == 32)
        #expect(visible?.image.height == 16)
        let cost = try #require(visible?.byteCost)
        var cached = await pipeline.image(for: key, using: service)
        #expect(service.calls.filter { $0 == "imageData" }.count == 1)
        #expect(cached === visible)
        await pipeline.purge(scope: scope)
        #expect(await pipeline.decodedCount == 0)
        #expect(await pipeline.decodedBytes == cost)
        visible = nil
        // The second visible owner also keeps its charge.
        #expect(await pipeline.decodedBytes == cost)
        cached = nil
        #expect(await pipeline.decodedBytes == 0)
    }

    @Test func transientFailureKeepsKeyAlivePermanentOneBurnsIt() async {
        // Всплеск параллельных загрузок (пикер) даёт лимитку/сетевой сбой: ключ не
        // должен сгорать — следующая попытка обязана дойти. 404 — наоборот, вечен.
        let data = CoreFixtures.png()
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        service.withState { state in
            state.imageHandler = { _, _ in
                let n = attempts.withLock { count in
                    count += 1
                    return count
                }
                if n == 1 { throw APIError.rateLimited(retryAfterSeconds: nil) }
                return data
            }
        }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let key = ImagePipeline.Key(scope: scope, resource: .customEmoji(id: "emoji"), maxPixelSize: 32)
        #expect(await pipeline.image(for: key, using: service) == nil)
        #expect(await pipeline.image(for: key, using: service) != nil,
                "rate limit не должен вычёркивать картинку навсегда")
        let gone = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        gone.withState { state in
            state.imageHandler = { _, _ in
                throw APIError.notFound(ServerErrorInfo(id: "", statusCode: 404, requestID: nil))
            }
        }
        let missing = ImagePipeline.Key(scope: scope, resource: .customEmoji(id: "gone"), maxPixelSize: 32)
        #expect(await pipeline.image(for: missing, using: gone) == nil)
        #expect(await pipeline.image(for: missing, using: gone) == nil)
        #expect(gone.calls.filter { $0 == "imageData" }.count == 1, "отсутствующую картинку не переспрашиваем")
    }

    @Test func boundsAndCancelledLateResponsesCannotPopulateCache() async {
        let data = CoreFixtures.png()
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let gate = Gate()
        service.withState { $0.imageHandler = { _, _ in await gate.wait(); return data } }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let key = ImagePipeline.Key(scope: scope, resource: .profileImage(CoreFixtures.me.id, revision: 0), maxPixelSize: 32)
        let task = Task { await pipeline.image(for: key, using: service) }
        #expect(await eventually { service.calls.contains("imageData") })
        await pipeline.purge(scope: scope)
        await gate.open()
        #expect(await task.value == nil)
        #expect(await pipeline.decodedBytes == 0)
        #expect(await pipeline.decodedCount == 0)
        #expect(await pipeline.inflightCount == 0)
        var budget = ResourceBudget.standard
        budget.maximumSourceImagePixels = 100
        let bounded = ImagePipeline(budget: budget, diagnostics: DiagnosticRing(byteBudget: 1_024))
        #expect(await bounded.image(for: key, using: service) == nil)
        #expect(await bounded.decodedBytes == 0)
        budget.compressedImagePerObjectBytes = data.count - 1
        let compressed = ImagePipeline(budget: budget, diagnostics: DiagnosticRing(byteBudget: 1_024))
        #expect(await compressed.image(for: key, using: service) == nil)
        #expect(await compressed.decodedBytes == 0)
    }

    @Test func reservationComesFromSourceMetadataAndOutputIsNeverUpscaled() async throws {
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let wide = CoreFixtures.png(width: 1_600, height: 800)
        let small = CoreFixtures.png(width: 64, height: 32)
        service.withState { state in
            state.imageHandler = { resource, _ in resource == .filePreview(FileID(unchecked: "small")) ? small : wide }
        }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let preview = ImageResource.filePreview(FileID(unchecked: "wide"))
        // A Retina timeline thumbnail (360 pt × 2) is sharper than the old 512 px cap.
        let thumbnail = try #require(await pipeline.image(for: ImagePipeline.Key(scope: scope, resource: preview, maxPixelSize: 720),
                                                          using: service))
        #expect(thumbnail.image.width == 720 && thumbnail.image.height == 360)
        let plan = try #require(ImagePipeline.decodePlan(wide, maxPixelSize: 720, maximumSourcePixels: 50_000_000))
        #expect(thumbnail.byteCost <= plan.reservedBytes)
        #expect(await pipeline.decodedBytes == thumbnail.byteCost)
        // The viewer size is capped by the source, not upscaled.
        let viewer = try #require(await pipeline.image(for: ImagePipeline.Key(scope: scope, resource: preview, maxPixelSize: 2_048),
                                                       using: service))
        #expect(viewer.image.width == 1_600 && viewer.image.height == 800)
        let tiny = try #require(await pipeline.image(
            for: ImagePipeline.Key(scope: scope, resource: .filePreview(FileID(unchecked: "small")), maxPixelSize: 2_048),
            using: service))
        #expect(tiny.image.width == 64 && tiny.image.height == 32)
        #expect(await pipeline.decodedBytes == thumbnail.byteCost + viewer.byteCost + tiny.byteCost)
        #expect(await pipeline.decodedBytes <= ResourceBudget.standard.decodedImageBytes)
    }

    @Test func imageLargerThanTheDecodedBudgetIsRefusedBeforeDecoding() async throws {
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let data = CoreFixtures.png(width: 1_024, height: 1_024)
        service.withState { $0.imageHandler = { _, _ in data } }
        var budget = ResourceBudget.standard
        budget.maximumDecodedImageBytes = 1 * .mebibyte
        let pipeline = ImagePipeline(budget: budget, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let resource = ImageResource.filePreview(FileID(unchecked: "big"))
        #expect(await pipeline.image(for: ImagePipeline.Key(scope: scope, resource: resource, maxPixelSize: 1_024),
                                     using: service) == nil)
        #expect(await pipeline.decodedBytes == 0)
        // A smaller rendition of the same source fits.
        let fitting = await pipeline.image(for: ImagePipeline.Key(scope: scope, resource: resource, maxPixelSize: 256),
                                           using: service)
        #expect(fitting?.image.width == 256)
    }

    @Test func cancelledQueuedDecodeReleasesItsWaiterWithoutAFreeSlot() async {
        let gate = AsyncGate(limit: 1, maximumWaiters: 1)
        #expect(await gate.enter())
        let queued = Task { await gate.enter() }
        #expect(await eventually { await gate.waitingCount == 1 })
        #expect(await gate.enter() == false)
        queued.cancel()
        #expect(await eventually { await gate.waitingCount == 0 })
        #expect(await queued.value == false)
        #expect(await gate.activeCount == 1)
        await gate.leave()
        #expect(await gate.activeCount == 0)
    }

    @Test func animatedGIFDecodesAllFramesWithDelaysAndLoopIndex() async throws {
        // GIF-эмодзи (ADR 0058): план знает число кадров, декод отдаёт все кадры
        // с задержками, счётчик памяти учитывает сумму кадров, индекс циклится.
        let data = CoreFixtures.gif(frames: 2, delay: 0.2)
        let plan = try #require(ImagePipeline.decodePlan(data, maxPixelSize: 32, maximumSourcePixels: 50_000_000))
        #expect(plan.frameCount == 2)
        let animation = try #require(await ImagePipeline.downsampleFrames(
            data, frameCount: plan.frameCount, maxPixelSize: plan.maxPixelSize, maximumSourcePixels: 50_000_000))
        #expect(animation.frames.count == 2)
        #expect(animation.delays.allSatisfy { abs($0 - 0.2) < 0.01 })
        #expect(abs(animation.duration - 0.4) < 0.05)
        #expect(animation.frameIndex(at: 0) == 0)
        #expect(animation.frameIndex(at: 0.25) == 1)
        #expect(animation.frameIndex(at: 0.45) == 0, "цикл замыкается на первый кадр")
        // Статичная картинка кадры не приносит.
        let still = try #require(ImagePipeline.decodePlan(CoreFixtures.png(), maxPixelSize: 32, maximumSourcePixels: 50_000_000))
        #expect(still.frameCount == 1)

        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        service.withState { $0.imageHandler = { _, _ in data } }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let key = ImagePipeline.Key(scope: scope, resource: .customEmoji(id: "gif"), maxPixelSize: 32)
        var decoded: ImagePipeline.Decoded?
        decoded = await pipeline.image(for: key, using: service)
        let frames = try #require(decoded?.animation)
        #expect(decoded?.image === frames.frames[0])
        #expect(decoded?.byteCost == frames.byteCost)
        #expect(await pipeline.decodedBytes == frames.byteCost)
        await pipeline.purge(scope: scope)
        #expect(await pipeline.decodedBytes == frames.byteCost,
                "кадры держит живая ссылка — высвобождение только после неё")
        decoded = nil
        #expect(await pipeline.decodedBytes == 0)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return await condition()
    }
}
