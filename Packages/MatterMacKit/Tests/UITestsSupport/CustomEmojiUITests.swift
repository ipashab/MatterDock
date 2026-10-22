import AppKit
import Testing
import os
import MatterMacModels
import MatterMacCore
import MattermostAPI
@testable import MatterMacUI
import TestSupport

@MainActor
@Suite("Custom emoji layout and slash detection")
struct CustomEmojiUITests {
    @Test func slashIsOnlyAtStartAndKeepsArgumentSpaces() {
        func detect(_ text: String) -> CompletionContext? {
            CompletionQueryDetector.detect(in: text as NSString, selection: NSRange(location: (text as NSString).length, length: 0))
        }
        #expect(detect("/")?.trigger == .command)
        #expect(detect("/status a")?.query == "status a")
        #expect(detect(" /status") == nil)
        #expect(detect("hello /status") == nil)
        #expect(detect("/status\naway") == nil)
        #expect(detect("/" + String(repeating: "a", count: 513)) == nil)
    }

    @Test func attachmentGeometryIsStableAndDoesNotLeakToNewlines() throws {
        let renderer = MessageRenderer(emojiLookup: EmojiCatalog.system.glyph(for:))
        let document = MarkupParser.parse(":party_parrot:\n\nnext")
        let text = renderer.render(document, customEmoji: ["party_parrot": "aaaaaaaaaaaaaaaaaaaaaaaaaa"])
        let attachment = try #require(text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width > 0)
        #expect(attachment.bounds.width == attachment.bounds.height)
        #expect(attachment.image == nil)
        #expect(text.attribute(.matterMacCustomEmoji, at: 0, effectiveRange: nil) as? String == "aaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(text.attribute(.attachment, at: 1, effectiveRange: nil) == nil)
        let measurer = TextMeasurer()
        let initial = measurer.height(of: text, width: 180)
        (attachment.attachmentCell as? CustomEmojiAttachmentCell)?.image = NSImage(size: NSSize(width: 256, height: 256))
        #expect(measurer.height(of: text, width: 180) == initial)
    }

    @Test func pickerDeduplicatesPagesAndStopsWhenServerMakesNoProgress() async {
        let picker = ReactionPickerViewController()
        var requests: [Int] = []
        picker.customPage = { page, _ in
            requests.append(page)
            // First page contains duplicates; the next page adds 60 names; a
            // broken server then repeats that second page forever.
            return (0..<60).map { index in
                let number = page == 0 ? index / 2 : index + 30
                return CustomEmoji(id: String(repeating: "a", count: 26), name: "custom_\(number)")
            }
        }
        _ = picker.view
        await picker.customTask?.value
        #expect(requests == [0])
        #expect(picker.sections.last?.emoji.count == 30)
        picker.loadCustomPage()
        await picker.customTask?.value
        #expect(requests == [0, 1])
        #expect(picker.sections.last?.emoji.count == 90)
        picker.loadCustomPage()
        await picker.customTask?.value
        #expect(requests == [0, 1, 2])
        #expect(picker.sections.last?.emoji.count == 90)
        picker.loadCustomPage()
        #expect(picker.customTask == nil)
        #expect(requests == [0, 1, 2])
        picker.viewDidDisappear()
    }

    @MainActor @Test func cellReasksPipelineAfterRefusalAndShowsImage() async throws {
        // Отказы конвейера (rate limit) не должны оставлять ячейку «точками» до
        // перезахода в пикер: свой backoff-переспрос доводит картинку до показа.
        let service = FakeMattermostService(endpoint: CoreFixtures.endpoint, me: CoreFixtures.me)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        service.withState { state in
            state.imageHandler = { _, _ in
                let n = attempts.withLock { count in
                    count += 1
                    return count
                }
                if n <= 2 { throw APIError.rateLimited(retryAfterSeconds: nil) }
                return CoreFixtures.png(width: 64, height: 64)
            }
        }
        let pipeline = ImagePipeline(budget: .standard, diagnostics: DiagnosticRing(byteBudget: 1_024))
        let scope = AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id)
        let item = EmojiPickerItem()
        _ = item.view
        let entry = ReactionPickerViewController.Entry(
            CustomEmoji(id: String(repeating: "c", count: 26), name: "keanu_thanks"))
        item.configure(entry, imageLoader: { id in
            await pipeline.image(for: ImagePipeline.Key(scope: scope, resource: .customEmoji(id: id),
                                                       maxPixelSize: 64), using: service)
        })
        for _ in 0..<1600 where !item.showsCustomImage { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(item.showsCustomImage, "отказанная ячейка переспрашивает сама и догружается")
        item.cancelImage()
        #expect(!item.showsCustomImage)
    }

    @Test func pickerLoadsBoundedCustomPageAndSearch() async {
        let picker = ReactionPickerViewController()
        picker.customLimit = 2
        picker.customPage = { _, query in
            (0..<3).map { CustomEmoji(id: String(repeating: "a", count: 26), name: query.isEmpty ? "custom_\($0)" : query + "_\($0)") }
        }
        _ = picker.view
        for _ in 0..<30 where picker.sections.last?.title != "Custom" { await Task.yield() }
        #expect(picker.sections.last?.emoji.count == 2)
        picker.apply(query: "party")
        for _ in 0..<30 where picker.sections.last?.title != "Custom" { await Task.yield() }
        #expect(picker.sections.last?.emoji.first?.name == "party_0")
        picker.viewDidDisappear()
    }
}
