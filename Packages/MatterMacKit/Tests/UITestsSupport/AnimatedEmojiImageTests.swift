import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

/// NSImageView с кадрами GIF-эмодзи (ADR 0058): тактовик меняет показанный
/// кадр по задержкам; представления из CGImage длительность не несут, поэтому
/// `NSImageView.animates` здесь не участвует.
@MainActor
@Suite("Animated emoji views")
struct AnimatedEmojiImageTests {
    private func twoFrameAnimation() async throws -> ImagePipeline.Animation {
        let data = CoreFixtures.png()
        let image = try #require(await ImagePipeline.downsample(data, maxPixelSize: 32, maximumSourcePixels: 50_000_000))
        return ImagePipeline.Animation(frames: [image, image], delays: [0.1, 0.2], duration: 0.3)
    }

    @Test func imageViewStepsThroughFramesAndStopsWhenCleared() async throws {
        let animation = try await twoFrameAnimation()
        let animator = EmojiFrameAnimator()
        let view = AnimatedImageView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        func shownFrameID() -> ObjectIdentifier? {
            guard let cgImage = view.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return ObjectIdentifier(cgImage)
        }

        view.setAnimation(animation, animator: animator)
        #expect(shownFrameID() == ObjectIdentifier(animation.frames[0]))
        animator.step(at: 0)
        #expect(shownFrameID() == ObjectIdentifier(animation.frames[0]), "до конца первого кадра картинка не меняется")
        animator.step(at: 0.25)
        #expect(shownFrameID() == ObjectIdentifier(animation.frames[1]), "на втором кадре картинка сменена")
        animator.step(at: 0.65) // 0.65 mod 0.3 = 0.05 — снова первый кадр
        #expect(shownFrameID() == ObjectIdentifier(animation.frames[0]), "цикл замкнулся на первый кадр")
        view.setAnimation(nil, animator: nil)
        animator.step(at: 1.0)
        #expect(view.animation == nil)
    }

    @Test func animatorStopsWhenLastTargetUnregisters() async throws {
        let animation = try await twoFrameAnimation()
        let animator = EmojiFrameAnimator()
        let view = AnimatedImageView(frame: .zero)
        view.setAnimation(animation, animator: animator)
        var probe: AnimatedImageView? = AnimatedImageView(frame: .zero)
        probe?.setAnimation(animation, animator: animator)
        animator.step(at: 0)
        probe = nil // слабая цель исчезла — тактовик не должен остановиться на живой ячейке
        animator.step(at: 0.15)
        #expect(view.animation != nil)
        view.setAnimation(nil, animator: nil)
    }
}
