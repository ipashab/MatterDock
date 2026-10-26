import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

/// Проверки реального жизненного цикла: таймер тактовика тикает в ранлупе,
/// ячейка-вложение перерисовывается через controlView из draw.
@MainActor
@Suite("Animated emoji lifecycle")
struct AnimatedEmojiLifecycleTests {
    /// Два кадра из настоящего GIF-фикстура — синхронно, без пайплайна.
    private func animation() throws -> ImagePipeline.Animation {
        let data = CoreFixtures.gif(frames: 2, delay: 0.05)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<CGImageSourceGetCount(source) {
            frames.append(CGImageSourceCreateImageAtIndex(source, index, nil)!)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append(gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1)
        }
        return ImagePipeline.Animation(frames: frames, delays: delays, duration: delays.reduce(0, +))
    }

    @Test func timerTicksInRunLoopAndAdvancesImageView() throws {
        let animation = try animation()
        let animator = EmojiFrameAnimator()
        let view = AnimatedImageView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        view.setAnimation(animation, animator: animator)
        var maxObservedFrameIndex = 0
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            maxObservedFrameIndex = max(maxObservedFrameIndex, view.animationFrameIndexForTesting)
        }
        #expect(animator.stepCount > 0, "таймер должен тикать в ранлупе")
        #expect(maxObservedFrameIndex != 0, "такты должны листать кадры")
        view.setAnimation(nil, animator: nil)
    }

    @Test func attachmentCellUsesControlViewFromDraw() throws {
        let animation = try animation()
        print("DEBUG animation frames=\(animation.frames.count) delays=\(animation.delays) duration=\(animation.duration)")
        let animator = EmojiFrameAnimator()
        let cell = AnimatedEmojiAttachmentCell(bounds: NSRect(x: 0, y: 0, width: 22, height: 22), animation: animation)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        // Ячейка отрисована текстовым view — как это делает TextKit.
        cell.draw(withFrame: NSRect(x: 10, y: 10, width: 22, height: 22), in: textView)
        print("DEBUG cell lastIndex=\(cell.lastIndexForTesting) lastFrame=\(String(describing: cell.lastFrameForTesting))")
        animator.register(cell)
        animator.step(at: CACurrentMediaTime() + 0.07) // 0.07 mod 0.1 — второй кадр
        print("DEBUG after step: stepCount=\(animator.stepCount) didInvalidate=\(cell.didInvalidateForTesting) index=\(cell.lastIndexForTesting)")
        #expect(cell.didInvalidateForTesting, "advance обязан перерисовать ячейку через controlView из draw")
        animator.unregister(cell)
    }
}
