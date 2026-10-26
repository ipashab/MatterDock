import AppKit
import MatterMacCore

/// Анимируемая единица: по времени сама решает, какой кадр показать, и помечает
/// свои пиксели грязными. Реализации — вложение эмодзи в тексте и чип реакции.
@MainActor
protocol EmojiAnimationTarget: AnyObject {
    func advanceAnimation(to time: Double)
}

/// Общий тактовщик анимированных эмодзи одного таймлайна: один таймер на все
/// видимые GIF-ячейки вместо таймера на каждую (бюджет SPEC §15). Цели слабые.
/// Превышение лимита целей деградирует в статичный первый кадр — как до
/// загрузки анимации. Режим `.common`: анимация не замирает при скролле.
@MainActor
final class EmojiFrameAnimator {
    private struct WeakTarget {
        weak var target: (any EmojiAnimationTarget)?
    }

    /// Период такта: эмодзи не нужны 60 кадров в секунду.
    static let frameInterval: TimeInterval = 1.0 / 15.0

    /// Верхняя граница одновременно анимируемых единиц.
    var maximumTargets = 64

    private var targets: [WeakTarget] = []
    private var timer: Timer?

    func register(_ target: any EmojiAnimationTarget) {
        guard !targets.contains(where: { $0.target === target }), targets.count < maximumTargets else { return }
        targets.append(WeakTarget(target: target))
        ensureTimer()
    }

    func unregister(_ target: any EmojiAnimationTarget) {
        targets.removeAll { $0.target === target }
        if targets.isEmpty { stopTimer() }
    }

    func removeAll() {
        targets.removeAll()
        stopTimer()
    }

    /// Для тестов: один такт по явному времени, без ожидания таймера.
    func step(at time: Double) {
        targets.removeAll { $0.target == nil }
        for target in targets { target.target?.advanceAnimation(to: time) }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step(at: CACurrentMediaTime())
                if self.targets.isEmpty { self.stopTimer() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// NSImageView с кадрами GIF-эмодзи (ADR 0058): представления из CGImage не
/// несут длительности кадра, поэтому `NSImageView.animates` их не листает —
/// перебор ведёт общий `EmojiFrameAnimator`, меняя показанный кадр.
@MainActor
final class AnimatedImageView: NSImageView, EmojiAnimationTarget {
    private(set) var animation: ImagePipeline.Animation?
    private weak var animator: EmojiFrameAnimator?
    private var animationStartedAt: Double = 0
    private var animationFrameIndex = 0

    /// Переключает источник: анимация — кадры по тактовику, `nil` — статичная
    /// картинка (или пусто, если и `image` не задана).
    func setAnimation(_ animation: ImagePipeline.Animation?, animator: EmojiFrameAnimator?) {
        self.animator?.unregister(self)
        self.animator = animator
        self.animation = animation
        animationFrameIndex = 0
        animationStartedAt = CACurrentMediaTime()
        if let animation {
            image = NSImage(cgImage: animation.frames[0], size: .zero)
            animator?.register(self)
        }
    }

    func advanceAnimation(to time: Double) {
        guard let animation else { return }
        let index = animation.frameIndex(at: time - animationStartedAt)
        guard index != animationFrameIndex else { return }
        animationFrameIndex = index
        image = NSImage(cgImage: animation.frames[index], size: .zero)
    }
}
