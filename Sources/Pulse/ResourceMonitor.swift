import Foundation
import PulseObjC

public struct ResourceSample: Codable {
    public let uptime: TimeInterval
    public let footprintBytes: UInt64?
    /// Process CPU delta / wall time. 100% means one core, and values may exceed 100%.
    public let cpuPercent: Double?
    public let thermalState: String
}

public struct MemorySummary: Codable {
    public let samples: Int
    public let peakBytes: UInt64?
    public let growthBytes: Int64?
    public let warnings: Int
}

struct CPUTracker {
    private var previous: (time: TimeInterval, cpu: Double)?
    mutating func reset() { previous = nil }
    mutating func sample(time: TimeInterval, cpu: Double?) -> Double? {
        guard time.isFinite, let cpu = cpu, cpu.isFinite else { previous = nil; return nil }
        defer { previous = (time, cpu) }
        guard let last = previous, time > last.time, cpu >= last.cpu else { return nil }
        return (cpu - last.cpu) / (time - last.time) * 100
    }
}

/// A low-frequency process sampler. Resource values are supporting evidence, not root causes.
public final class ResourceMonitor {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.gy.pulse.resources", qos: .utility)
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var buffer: BoundedBuffer<ResourceSample>
    private var cpu = CPUTracker()
    private var active = true
    private var generation = 0
    private var warnings = 0

    public init(interval: TimeInterval = 1, capacity: Int = 120) {
        precondition(interval.isFinite && interval >= 0.2 && (1...4096).contains(capacity))
        self.interval = interval
        buffer = BoundedBuffer(capacity: capacity)
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let run = generation
        cpu.reset()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.sample(generation: run) }
        timer = source
        source.resume()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        timer?.cancel(); timer = nil; cpu.reset()
    }

    public func setActive(_ value: Bool) {
        lock.lock(); active = value; cpu.reset(); lock.unlock()
    }

    public func recordMemoryWarning() {
        lock.lock(); warnings += 1; lock.unlock()
    }

    private func sample(generation run: Int) {
        lock.lock()
        let shouldRead = active && timer != nil && run == generation
        lock.unlock()
        guard shouldRead else { return }
        let reading = PLReadResources()
        lock.lock(); defer { lock.unlock() }
        guard active, timer != nil, run == generation else { return }
        let percent = cpu.sample(time: reading.uptime, cpu: reading.cpuValid != 0 ? reading.cpuSeconds : nil)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        buffer.append(ResourceSample(uptime: reading.uptime,
                                     footprintBytes: reading.memoryValid != 0 ? reading.footprintBytes : nil,
                                     cpuPercent: percent, thermalState: thermal))
    }

    public func snapshot(since: TimeInterval = 0) -> [ResourceSample] {
        lock.lock(); defer { lock.unlock() }
        return buffer.snapshot().filter { $0.uptime >= since }
    }

    public func memorySummary() -> MemorySummary {
        lock.lock(); defer { lock.unlock() }
        let values = buffer.snapshot().compactMap(\.footprintBytes)
        let growth = values.first.flatMap { first in
            values.last.map { Int64(clamping: $0) - Int64(clamping: first) }
        }
        return MemorySummary(samples: values.count, peakBytes: values.max(), growthBytes: growth, warnings: warnings)
    }

    deinit { timer?.cancel() }
}

/// Weak observations only: stillAlive is a lead to inspect ownership, not proof of a leak.
public final class ObjectLifetimeTracker {
    private struct Entry {
        weak var object: AnyObject?
        let label: String
        let deadline: TimeInterval
    }
    public struct Observation: Codable {
        public let label: String
        public let stillAlive: Bool
    }
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []

    public init(capacity: Int = 64) {
        precondition((1...1024).contains(capacity))
        self.capacity = capacity
    }

    @discardableResult
    public func expectRelease(_ object: AnyObject, label: String, after delay: TimeInterval = 2,
                              uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard delay.isFinite, delay >= 0, uptime.isFinite else { return false }
        lock.lock(); defer { lock.unlock() }
        guard entries.count < capacity else { return false }
        entries.append(Entry(object: object, label: boundedLabel(label, bytes: 128), deadline: uptime + delay))
        return true
    }

    public func check(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Observation] {
        lock.lock(); defer { lock.unlock() }
        let due = entries.filter { $0.deadline <= uptime }
        entries.removeAll { $0.deadline <= uptime }
        return due.map { Observation(label: $0.label, stillAlive: $0.object != nil) }
    }
}
