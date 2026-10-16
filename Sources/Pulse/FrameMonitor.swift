import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct FrameSample: Codable {
    public let uptime: TimeInterval
    public let interval: TimeInterval
    public let expectedInterval: TimeInterval
    public var isLong: Bool { interval > expectedInterval * 1.5 }
    public var excess: TimeInterval { max(0, interval - expectedInterval) }
}

public struct FrameSummary: Codable {
    public let page: String
    public let sampleCount: Int
    public let longIntervals: Int
    public let p95Interval: TimeInterval?
    /// Proxy from callback cadence; not the system animation hitch time ratio.
    public let excessTimeRatio: Double
}

struct FrameAccumulator {
    private var last: (timestamp: TimeInterval, expected: TimeInterval)?
    private var samples: BoundedBuffer<FrameSample>
    init(capacity: Int) { samples = BoundedBuffer(capacity: capacity) }
    mutating func reset() { last = nil; samples.removeAll() }

    mutating func record(timestamp: TimeInterval, targetTimestamp: TimeInterval, uptime: TimeInterval) {
        let expected = targetTimestamp - timestamp
        guard timestamp.isFinite, expected.isFinite, expected > 0, uptime.isFinite else {
            last = nil; return
        }
        defer { last = (timestamp, expected) }
        guard let previous = last, timestamp > previous.timestamp else { return }
        // Use the larger adjacent budget to avoid treating a refresh-rate downshift as a long frame.
        samples.append(FrameSample(uptime: uptime, interval: timestamp - previous.timestamp,
                                   expectedInterval: max(expected, previous.expected)))
    }

    func snapshot() -> [FrameSample] { samples.snapshot() }
    func summary(page: String) -> FrameSummary {
        let values = samples.snapshot()
        let sorted = values.map(\.interval).sorted()
        let p95 = sorted.isEmpty ? nil : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        let total = values.reduce(0) { $0 + $1.interval }
        return FrameSummary(page: page, sampleCount: values.count,
                            longIntervals: values.filter(\.isLong).count, p95Interval: p95,
                            excessTimeRatio: total > 0 ? values.reduce(0) { $0 + $1.excess } / total : 0)
    }
}

#if canImport(UIKit)
private final class DisplayLinkTarget: NSObject {
    weak var owner: FrameMonitor?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

/// Main-thread-only, one explicit page/interaction window at a time. No global always-on FPS polling.
public final class FrameMonitor {
    private var accumulator: FrameAccumulator
    private var link: CADisplayLink?
    private let target = DisplayLinkTarget()
    private var page = "unknown"

    public init(capacity: Int = 600) {
        precondition((1...10000).contains(capacity))
        accumulator = FrameAccumulator(capacity: capacity)
        target.owner = self
    }

    public func start(page: String) {
        precondition(Thread.isMainThread)
        stop()
        self.page = boundedLabel(page, bytes: 128)
        accumulator.reset()
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30,
            maximum: Float(UIScreen.main.maximumFramesPerSecond),
            preferred: Float(UIScreen.main.maximumFramesPerSecond))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public func stop() {
        precondition(Thread.isMainThread)
        link?.invalidate(); link = nil
    }

    /// Reset the baseline across inactive periods; suspended time is never a long-frame sample.
    public func setActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        link?.isPaused = !active
        accumulator.reset()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        accumulator.record(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp,
                           uptime: ProcessInfo.processInfo.systemUptime)
    }

    public func snapshot() -> [FrameSample] {
        precondition(Thread.isMainThread)
        return accumulator.snapshot()
    }

    public func summary() -> FrameSummary {
        precondition(Thread.isMainThread)
        return accumulator.summary(page: page)
    }

    deinit { link?.invalidate() }
}
#endif
