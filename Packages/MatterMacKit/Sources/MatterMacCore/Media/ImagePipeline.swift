public import CoreGraphics
public import Foundation
import ImageIO
import os
public import MatterMacModels
public import MattermostAPI

/// Process-wide bounded image pipeline (SPEC §14 Image pipeline, §15).
///
/// - Fetches server thumbnails/previews/avatars with a per-object compressed-size
///   limit; never fetches third-party URLs. With a `ContentCache`, the compressed
///   bytes of immutable resources (keyed by file ID or picture/icon revision) are
///   kept on disk and read before the network; proxied link-preview images are not.
/// - Checks source pixel dimensions from metadata *before* decoding, reserves the
///   downsampled output's conservative size against the decoded budget, and
///   downsamples with Image I/O to the requested display pixel size (orientation
///   applied; never upscaled).
/// - Retains decoded images in a strict cost-tracked LRU (cost = bytesPerRow × height)
///   and never keeps compressed bytes after decoding.
/// - At most `imageDecodesGlobal` decodes run at once and at most
///   `outstandingImageRequests` requests are in flight; beyond that, new requests
///   are refused (the cell shows its placeholder and may ask again later).
public actor ImagePipeline {
    public struct Key: Hashable, Sendable {
        public let scope: AccountScope
        public let resource: ImageResource
        /// Longest edge in device pixels.
        public let maxPixelSize: Int

        public init(scope: AccountScope, resource: ImageResource, maxPixelSize: Int) {
            self.scope = scope
            self.resource = resource
            self.maxPixelSize = maxPixelSize
        }
    }

    /// Cache entries, returned task results and displayed rows share this ownership.
    /// Evicting the cache cannot uncharge an image still held by a visible cell.
    public final class Decoded: Sendable {
        public let image: CGImage
        /// Кадры анимированного источника (GIF/APNG): `nil` у статичных картинок.
        /// Первый кадр — тот же `image`; счётчик памяти учитывает все кадры.
        public let animation: Animation?
        public let byteCost: Int
        private let release: @Sendable () -> Void
        init(_ image: CGImage, animation: Animation? = nil, release: @escaping @Sendable () -> Void) {
            self.image = image
            self.animation = animation
            byteCost = animation?.byteCost ?? image.bytesPerRow * image.height
            self.release = release
        }
        deinit { release() }
    }

    /// Кадры анимированного эмодзи с задержками (секунды). Задержки выровнены
    /// вниз до минимального шага анимации: слишком короткие кадры (0 с) показываются
    /// как 0,1 с, как это делают браузеры.
    public struct Animation: Sendable {
        public let frames: [CGImage]
        /// Задержка каждого кадра, секунды; `frames.count == delays.count`.
        public let delays: [Double]
        /// Сумма задержек — длительность полного цикла.
        public let duration: Double

        public init(frames: [CGImage], delays: [Double], duration: Double) {
            self.frames = frames
            self.delays = delays
            self.duration = duration
        }

        /// Кадр, видимый через `elapsed` секунд от начала цикла (зациклено).
        public func frameIndex(at elapsed: Double) -> Int {
            guard frames.count > 1, duration > 0 else { return 0 }
            var position = elapsed.truncatingRemainder(dividingBy: duration)
            if position < 0 { position += duration }
            var accumulated = 0.0
            for (index, delay) in delays.enumerated() {
                accumulated += delay
                if position < accumulated { return index }
            }
            return frames.count - 1
        }

        var byteCost: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
    }
    private struct Flight {
        let task: Task<Decoded?, Never>
        var waiters: Set<UUID>
    }
    private var decoded: CostLRU<Key, Decoded>
    private var failures: CostLRU<Key, Bool>
    private var inflight: [Key: Flight] = [:]
    private let budget: ResourceBudget
    private let decodeGate: AsyncGate
    private let retainedBytes = OSAllocatedUnfairLock(initialState: 0)
    private let diagnostics: DiagnosticRing
    private let disk: ContentCache?

    public init(budget: ResourceBudget, diagnostics: DiagnosticRing, cache: ContentCache? = nil) {
        self.budget = budget
        self.disk = cache
        self.decoded = CostLRU(countLimit: budget.decodedImageEntries, costLimit: budget.decodedImageBytes)
        self.failures = CostLRU(countLimit: budget.imageFailureEntries, costLimit: budget.imageFailureEntries)
        self.decodeGate = AsyncGate(limit: max(1, min(budget.imageDecodesGlobal,
            budget.compressedImageBytes / max(1, budget.compressedImagePerObjectBytes))),
            maximumWaiters: budget.outstandingImageRequests)
        self.diagnostics = diagnostics
    }

    public func cached(_ key: Key) -> Decoded? { decoded.value(for: key) }
    public var decodedBytes: Int { retainedBytes.withLock { $0 } }
    public var decodedCount: Int { decoded.count }
    public var inflightCount: Int { inflight.count }

    public func image(for key: Key, using service: any MattermostService) async -> Decoded? {
        guard !Task.isCancelled else { return nil }
        if let hit = decoded.value(for: key) { return hit }
        if failures.contains(key) { return nil }
        let waiter = UUID()
        let task: Task<Decoded?, Never>
        if var flight = inflight[key] {
            guard !flight.task.isCancelled, flight.waiters.count < budget.outstandingImageRequests else { return nil }
            task = flight.task
            flight.waiters.insert(waiter)
            inflight[key] = flight
        } else {
            guard inflight.count < budget.outstandingImageRequests else { return nil }
            task = Task { await fetch(key, using: service) }
            inflight[key] = Flight(task: task, waiters: [waiter])
        }
        let image = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { await self.cancelWaiter(waiter, key: key) }
        }
        if var flight = inflight[key] {
            flight.waiters.remove(waiter)
            inflight[key] = flight.waiters.isEmpty ? nil : flight
        }
        guard !Task.isCancelled, !task.isCancelled else { return nil }
        if let image { decoded.set(image, for: key, cost: image.byteCost) }
        return image
    }

    private func cancelWaiter(_ waiter: UUID, key: Key) {
        guard var flight = inflight[key] else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty { flight.task.cancel() }
        inflight[key] = flight
    }

    private func fetch(_ key: Key, using service: any MattermostService) async -> Decoded? {
        guard await decodeGate.enter() else { return nil }
        let result = await fetchAdmitted(key, using: service)
        await decodeGate.leave()
        return result
    }

    private func fetchAdmitted(_ key: Key, using service: any MattermostService) async -> Decoded? {
        guard !Task.isCancelled else { return nil }
        let maximumBytes = min(budget.compressedImagePerObjectBytes, budget.compressedImageBytes)
        let diskName = Self.diskName(key.resource)
        var cached: Data?
        if let disk, let diskName { cached = await disk.data(.image, diskName, scope: key.scope) }
        let data: Data
        var fromDisk = false
        if let cached, cached.count <= maximumBytes {
            data = cached
            fromDisk = true
        } else {
            do {
                let fetched = try await service.imageData(key.resource, maximumBytes: maximumBytes)
                guard fetched.count <= maximumBytes else { failures.set(true, for: key, cost: 1); return nil }
                data = fetched
            } catch {
                // В память идёт только собственная проблема ресурса (нет, запрещён, не
                // декодируется). Сеть, лимиты запросов и 5xx преходящи: картинка будет
                // запрошена заново, иначе всплеск параллельных загрузок в пикере
                // навсегда превращает часть эмодзи в точки.
                let permanent: Bool
                switch error {
                case .unauthorized, .forbidden, .notFound, .badRequest, .payloadTooLarge,
                     .responseTooLarge, .malformedResponse, .notImplemented, .redirectRefused:
                    permanent = true
                default: permanent = false
                }
                if !Task.isCancelled, permanent { failures.set(true, for: key, cost: 1) }
                return nil
            }
        }
        // Source metadata is read before anything is decoded; the reservation is the
        // conservative size of the downsampled output, never the source.
        let edge = min(key.maxPixelSize, budget.maximumImagePixelDimension)
        guard let plan = Self.decodePlan(data, maxPixelSize: edge, maximumSourcePixels: budget.maximumSourceImagePixels),
              plan.reservedBytes <= min(budget.maximumDecodedImageBytes, budget.decodedImageBytes) else {
            if fromDisk, let disk, let diskName { await disk.remove(.image, diskName, scope: key.scope) }
            failures.set(true, for: key, cost: 1)
            return nil
        }
        let reservation = plan.reservedBytes
        // Keep displayed images charged while evicting unused cache entries to make room.
        while retainedBytes.withLock({ $0 + reservation > budget.decodedImageBytes }), !decoded.isEmpty {
            _ = decoded.removeLeastRecentlyUsed()
        }
        let admitted = retainedBytes.withLock { bytes in
            guard bytes + reservation <= budget.decodedImageBytes else { return false }
            bytes += reservation
            return true
        }
        guard admitted else { return nil } // Saturation is not a permanent failed resource.
        if plan.frameCount > 1 {
            let decodedFrames = await Self.downsampleFrames(data, frameCount: plan.frameCount,
                                                            maxPixelSize: plan.maxPixelSize,
                                                            maximumSourcePixels: budget.maximumSourceImagePixels)
            let frameBytes = decodedFrames?.byteCost ?? 0
            guard let animated = decodedFrames, !Task.isCancelled, frameBytes <= reservation else {
                retainedBytes.withLock { $0 -= reservation }
                if !Task.isCancelled { failures.set(true, for: key, cost: 1) }
                return nil
            }
            let cost = animated.byteCost
            retainedBytes.withLock { $0 -= reservation - cost }
            if !fromDisk, let disk, let diskName { await disk.store(data, .image, diskName, scope: key.scope) }
            let counter = retainedBytes
            return Decoded(animated.frames[0], animation: animated) { counter.withLock { $0 -= cost } }
        }
        guard let image = await Self.downsample(data, maxPixelSize: plan.maxPixelSize,
                                                maximumSourcePixels: budget.maximumSourceImagePixels),
              !Task.isCancelled, image.bytesPerRow * image.height <= reservation else {
            retainedBytes.withLock { $0 -= reservation }
            if !Task.isCancelled { failures.set(true, for: key, cost: 1) }
            return nil
        }
        let cost = image.bytesPerRow * image.height
        retainedBytes.withLock { $0 -= reservation - cost }
        // Only bytes that decoded are kept on disk.
        if !fromDisk, let disk, let diskName { await disk.store(data, .image, diskName, scope: key.scope) }
        let counter = retainedBytes
        return Decoded(image) { counter.withLock { $0 -= cost } }
    }

    /// The on-disk name of a resource whose bytes never change under that name, or
    /// `nil` when it must not be kept (proxied external images).
    static func diskName(_ resource: ImageResource) -> String? {
        switch resource {
        case .profileImage(let user, let revision): "profile/\(user.rawValue)/\(revision)"
        case .teamIcon(let team, let revision): "team/\(team.rawValue)/\(revision)"
        case .fileThumbnail(let file): "thumbnail/\(file.rawValue)"
        case .filePreview(let file): "preview/\(file.rawValue)"
        case .customEmoji(let id): "emoji/\(id)"
        case .proxiedImage: nil
        }
    }

    /// In-flight cancellation prevents late responses from repopulating the cache.
    public func purge(scope: AccountScope) {
        decoded.removeAll { key, _ in key.scope == scope }
        failures.removeAll { key, _ in key.scope == scope }
        for (key, flight) in inflight where key.scope == scope { flight.task.cancel() }
    }

    /// Memory pressure: discard decoded images first (SPEC §15 pressure policy).
    public func trim(toFraction fraction: Double) {
        decoded.trim(toCost: Int(Double(budget.decodedImageBytes) * max(0, min(1, fraction))))
    }

    /// What decoding `data` at `maxPixelSize` will produce, from source metadata only.
    public struct DecodePlan: Equatable, Sendable {
        /// Longest edge requested from Image I/O (never above the source's longest edge).
        public let maxPixelSize: Int
        /// Upper bound of the decoded bitmap: output pixels (plus one pixel of rounding
        /// per edge) at 4 bytes (8-bit sources) or 8 bytes (deeper sources) each, plus
        /// 64 bytes of row alignment per row.
        public let reservedBytes: Int
        /// Число кадров анимированного источника (GIF/APNG), ограниченное
        /// `maximumAnimationFrames`; статичные источники — 1.
        public let frameCount: Int

        fileprivate init(maxPixelSize: Int, reservedBytes: Int, frameCount: Int = 1) {
            self.maxPixelSize = maxPixelSize
            self.reservedBytes = reservedBytes
            self.frameCount = frameCount
        }
    }

    /// Верхняя граница кадров анимации на ресурс: декод идёт в ожидании эмодзи
    /// (мелкие картинки), длинные циклы обрезаются и зацикливаются по своей части.
    public static let maximumAnimationFrames = 16

    /// Reads only the source properties. `nil` for undecodable data, missing
    /// dimensions, or sources above `maximumSourcePixels`.
    public static func decodePlan(_ data: Data, maxPixelSize: Int, maximumSourcePixels: Int) -> DecodePlan? {
        guard maxPixelSize > 0, maximumSourcePixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow,
              width * height <= maximumSourcePixels
        else { return nil }
        let longest = max(width, height)
        let edge = min(maxPixelSize, longest)
        let scale = Double(edge) / Double(longest)
        let outWidth = Int((Double(width) * scale).rounded(.up)) + 1
        let outHeight = Int((Double(height) * scale).rounded(.up)) + 1
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let bytesPerPixel = depth > 8 ? 8 : 4
        // Orientation may swap the edges; alignment is charged for the longer one.
        let rows = max(outWidth, outHeight)
        let frameBytes = outWidth * outHeight * bytesPerPixel + rows * 64
        let frameCount = min(CGImageSourceGetCount(source), maximumAnimationFrames)
        return DecodePlan(maxPixelSize: edge, reservedBytes: frameBytes * frameCount, frameCount: frameCount)
    }

    /// Downsamples encoded image data to at most `maxPixelSize` on the longest edge,
    /// refusing sources larger than `maximumSourcePixels` before decoding.
    @concurrent
    public static func downsample(_ data: Data, maxPixelSize: Int, maximumSourcePixels: Int) async -> CGImage? {
        guard maxPixelSize > 0, maximumSourcePixels > 0 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow,
              width * height <= maximumSourcePixels
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        // Animated images: only the first frame is decoded here; animated emoji go
        // through `downsampleFrames`.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// Декодирует все кадры анимированного источника (GIF/APNG) в одном размере.
    /// Задержки читаются из метаданных кадра; нулевые и отрицательные выравниваются
    /// до 0,1 с (как в браузерах), иначе цикл схлопывается в один кадр.
    @concurrent
    static func downsampleFrames(_ data: Data, frameCount: Int, maxPixelSize: Int,
                                 maximumSourcePixels: Int) async -> Animation? {
        guard maxPixelSize > 0, maximumSourcePixels > 0, frameCount > 1 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) >= frameCount else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<frameCount {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let raw = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
                ?? png?[kCGImagePropertyAPNGDelayTime] as? Double
                ?? 0
            frames.append(frame)
            delays.append(raw > 0 ? raw : 0.1)
        }
        return Animation(frames: frames, delays: delays, duration: delays.reduce(0, +))
    }
}

/// A counting gate with a bounded waiter queue. `enter()` returns `false` instead of
/// queueing when `maximumWaiters` are already waiting.
public actor AsyncGate {
    private let limit: Int
    private let maximumWaiters: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    public init(limit: Int, maximumWaiters: Int) {
        self.limit = max(1, limit)
        self.maximumWaiters = max(0, maximumWaiters)
    }

    public func enter() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            return true
        }
        guard waiters.count < maximumWaiters else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }

    public func leave() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot directly to the next waiter.
            waiters.removeFirst().1.resume(returning: true)
        }
    }

    public var activeCount: Int { active }
    public var waitingCount: Int { waiters.count }
}
