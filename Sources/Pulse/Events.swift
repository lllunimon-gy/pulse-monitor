import Foundation

public struct Breadcrumb: Codable, Equatable {
    public let uptime: TimeInterval
    public let category: String
    public let message: String
}
public final class BreadcrumbBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var slots: [Breadcrumb?]
    private var next = 0
    private var count = 0
    public init(capacity: Int = 64) {
        precondition(capacity > 0 && capacity <= 4096)
        self.capacity = capacity; self.slots = Array(repeating: nil, count: capacity)
    }
    /// Record labels, not request bodies, credentials or user content. Strings are bounded.
    public func record(category: String, message: String, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let item = Breadcrumb(uptime: uptime, category: String(category.prefix(64)), message: String(message.prefix(256)))
        lock.lock(); defer { lock.unlock() }
        slots[next] = item; next = (next + 1) % capacity; count = min(count + 1, capacity)
    }
    public func snapshot() -> [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        let first = (next - count + capacity) % capacity
        return (0..<count).compactMap { slots[(first + $0) % capacity] }
    }
}
public enum HangPhase: String, Codable { case detected, recovered }
public struct HangEvent: Codable {
    public let id: UUID
    public let phase: HangPhase
    public let startedAtUptime: TimeInterval
    public let observedAtUptime: TimeInterval
    public let duration: TimeInterval
    public let breadcrumbs: [Breadcrumb]
}

struct HangStateMachine {
    let threshold: TimeInterval
    private var pending: (id: UUID, start: TimeInterval)?
    init(threshold: TimeInterval) { self.threshold = threshold }
    mutating func reset() { pending = nil }
    mutating func sample(time: TimeInterval, busySince: TimeInterval?, active: Bool,
                         breadcrumbs: [Breadcrumb]) -> [HangEvent] {
        guard active else { reset(); return [] }
        var events: [HangEvent] = []
        if let current = pending, busySince != current.start {
            events.append(HangEvent(id: current.id, phase: .recovered, startedAtUptime: current.start,
                                    observedAtUptime: time, duration: max(0, time - current.start), breadcrumbs: breadcrumbs))
            pending = nil
        }
        if pending == nil, let start = busySince, time - start >= threshold {
            let id = UUID(); pending = (id, start)
            events.append(HangEvent(id: id, phase: .detected, startedAtUptime: start,
                                    observedAtUptime: time, duration: time - start, breadcrumbs: breadcrumbs))
        }
        return events
    }
}

/// Bounded, per-instance event archive. Call only on a background queue.
public final class EventArchive {
    private let url: URL
    private let limit: Int
    private let lock = NSLock()
    public init(url: URL, limit: Int = 100) { precondition(limit > 0); self.url = url; self.limit = limit }
    public func load() throws -> [HangEvent] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }
    private func read() throws -> [HangEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([HangEvent].self, from: Data(contentsOf: url))
    }
    public func append(_ event: HangEvent) throws {
        lock.lock(); defer { lock.unlock() }
        var events = try read()
        if let i = events.firstIndex(where: { $0.id == event.id }) { events[i] = event }
        else { events.append(event) }
        events = Array(events.suffix(limit))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(events).write(to: url, options: .atomic)
    }
}
