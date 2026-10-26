import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

/// View с кадрами GIF-эмодзи (ADR 0058): тактовик листает кадры по задержкам;
/// представления из CGImage длительность не несут, поэтому `NSImageView.animates`
/// здесь не участвует.
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
        view.setAnimation(animation, animator: animator)
        let start = CACurrentMediaTime()
        #expect(view.animationFrameIndexForTesting == 0)
        animator.step(at: start + 0.05)
        #expect(view.animationFrameIndexForTesting == 0, "до конца первого кадра кадр не меняется")
        animator.step(at: start + 0.25)
        #expect(view.animationFrameIndexForTesting == 1, "на втором кадре индекс сменён")
        animator.step(at: start + 0.65) // 0.65 mod 0.3 = 0.05 — снова первый кадр
        #expect(view.animationFrameIndexForTesting == 0, "цикл замкнулся на первый кадр")
        view.setAnimation(nil, animator: nil)
        animator.step(at: start + 1.0)
        #expect(view.animation == nil)
    }

    @Test func animatorStopsWhenLastTargetUnregisters() async throws {
        let animation = try await twoFrameAnimation()
        let animator = EmojiFrameAnimator()
        let view = AnimatedImageView(frame: .zero)
        view.setAnimation(animation, animator: animator)
        var probe: AnimatedImageView? = AnimatedImageView(frame: .zero)
        probe?.setAnimation(animation, animator: animator)
        let start = CACurrentMediaTime()
        animator.step(at: start)
        probe = nil // слабая цель исчезла — тактовик не должен остановиться на живой ячейке
        animator.step(at: start + 0.15)
        #expect(view.animation != nil)
        view.setAnimation(nil, animator: nil)
    }
}
