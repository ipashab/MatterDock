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
        stepCount += 1
        targets.removeAll { $0.target == nil }
        for target in targets { target.target?.advanceAnimation(to: time) }
    }

    /// Только для тестов: сколько раз тикал тактовик.
    private(set) var stepCount = 0
    /// Только для тестов: сколько живых целей сейчас зарегистрировано.
    var targetCountForTesting: Int {
        targets.compactMap { $0.target }.count
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

/// View с кадрами GIF-эмодзи (ADR 0058): рисует текущий кадр сам — как чип
/// реакции — и листает их по тактовику. `NSImageView.animates` не подходит:
/// представления из CGImage не несут длительности кадра, и AppKit их не листает.
@MainActor
final class AnimatedImageView: NSView, EmojiAnimationTarget {
    /// Статичная картинка (первый кадр), показывается пока анимации нет.
    var image: NSImage? { didSet { needsDisplay = true } }
    private(set) var animation: ImagePipeline.Animation?
    private weak var animator: EmojiFrameAnimator?
    private var animationStartedAt: Double = 0
    private var animationFrameIndex = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let cgImage: CGImage?
        if let animation {
            cgImage = animation.frames[min(animationFrameIndex, animation.frames.count - 1)]
        } else {
            cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let cgImage else { return }
        // Пропорционально вписываем квадрат эмодзи в границы view.
        let boundsSize = bounds.size
        let source = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = min(boundsSize.width / source.width, boundsSize.height / source.height)
        let target = CGSize(width: source.width * scale, height: source.height * scale)
        let rect = NSRect(x: (boundsSize.width - target.width) / 2, y: (boundsSize.height - target.height) / 2,
                          width: target.width, height: target.height)
        NSImage(cgImage: cgImage, size: .zero).draw(in: rect, from: .zero,
                                                    operation: .sourceOver, fraction: 1,
                                                    respectFlipped: true, hints: nil)
    }

    func advanceAnimation(to time: Double) {
        guard let animation else { return }
        let index = animation.frameIndex(at: time - animationStartedAt)
        guard index != animationFrameIndex else { return }
        animationFrameIndex = index
        needsDisplay = true
    }

    /// Только для тестов.
    var animationFrameIndexForTesting: Int { animationFrameIndex }
}
