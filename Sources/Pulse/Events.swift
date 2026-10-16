import Foundation

public struct Breadcrumb: Codable, Equatable {
    public let uptime: TimeInterval
    public let category: String
    public let message: String
}

public final class BreadcrumbBuffer {
    private let lock = NSLock()
    private var buffer: BoundedBuffer<Breadcrumb>
    public init(capacity: Int = 64) {
        precondition((1...4096).contains(capacity))
        buffer = BoundedBuffer(capacity: capacity)
    }
    /// Use static labels, never credentials, request bodies or user content.
    public func record(category: String, message: String,
                       uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard uptime.isFinite else { return }
        let item = Breadcrumb(uptime: uptime, category: boundedLabel(category, bytes: 64),
                              message: boundedLabel(message, bytes: 256))
        lock.lock(); buffer.append(item); lock.unlock()
    }
    public func snapshot() -> [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return buffer.snapshot()
    }
}

public enum HangPhase: String, Codable { case detected, recovered, cancelled }

public struct HangEvent: Codable, Identifiable {
    public let id: UUID
    public let phase: HangPhase
    public let startedAtUptime: TimeInterval
    public let observedAtUptime: TimeInterval
    public let duration: TimeInterval
    /// Nil for an ongoing/cancelled event or a legacy upper-bound duration.
    public let endedAtUptime: TimeInterval?
    /// Frozen at detection; recovery never replaces the original breadcrumbs.
    public let breadcrumbs: [Breadcrumb]
    public let evidence: EventEvidence?
    public let durationBasis: String?

    func updated(phase: HangPhase, time: TimeInterval, end: TimeInterval?,
                 evidence: EventEvidence? = nil) -> HangEvent {
        HangEvent(id: id, phase: phase, startedAtUptime: startedAtUptime,
                  observedAtUptime: time, duration: max(0, (end ?? time) - startedAtUptime),
                  endedAtUptime: end, breadcrumbs: breadcrumbs,
                  evidence: evidence ?? self.evidence,
                  durationBasis: phase == .detected ? "ongoing-observation" :
                    (phase == .cancelled ? "cancelled-observation" :
                        (end == nil ? "observation-upper-bound" : "observed-runloop-boundary")))
    }
}

struct BusyInterval: Equatable {
    let start: TimeInterval
    let end: TimeInterval
}

struct HangStateMachine {
    let threshold: TimeInterval
    private var pending: HangEvent?
    init(threshold: TimeInterval) { self.threshold = threshold }
    mutating func reset() { pending = nil }
    mutating func cancel(time: TimeInterval) -> [HangEvent] {
        defer { pending = nil }
        return pending.map { [$0.updated(phase: .cancelled, time: time, end: nil)] } ?? []
    }
    mutating func sample(time: TimeInterval, busySince: TimeInterval?, active: Bool,
                         breadcrumbs: [Breadcrumb]) -> [HangEvent] {
        sample(time: time, busySince: busySince, completed: [], active: active,
               breadcrumbs: { breadcrumbs }, evidence: { _ in nil })
    }
    /// Idle ticks never copy breadcrumbs or resource histories.
    mutating func sample(time: TimeInterval, busySince: TimeInterval?,
                         completed: [BusyInterval], active: Bool,
                         breadcrumbs: () -> [Breadcrumb],
                         evidence: (TimeInterval) -> EventEvidence?) -> [HangEvent] {
        guard active else { reset(); return [] }
        var result: [HangEvent] = []
        func make(_ start: TimeInterval, observed: TimeInterval) -> HangEvent {
            HangEvent(id: UUID(), phase: .detected, startedAtUptime: start,
                      observedAtUptime: observed, duration: max(0, observed - start),
                      endedAtUptime: nil, breadcrumbs: breadcrumbs(), evidence: evidence(start),
                      durationBasis: "ongoing-observation")
        }
        if let current = pending, busySince != current.startedAtUptime {
            let end = completed.first { $0.start == current.startedAtUptime }?.end
            let enriched = current.evidence?.addingRecovery(evidence(current.startedAtUptime))
            result.append(current.updated(phase: .recovered, time: time, end: end, evidence: enriched))
            pending = nil
        }
        let recoveredStart = result.first?.startedAtUptime
        for interval in completed where interval.end - interval.start >= threshold {
            guard interval.start != recoveredStart,
                  interval.start != pending?.startedAtUptime else { continue }
            let event = make(interval.start, observed: interval.end)
            result.append(event.updated(phase: .recovered, time: time, end: interval.end))
        }
        if pending == nil, let start = busySince, time - start >= threshold {
            let event = make(start, observed: time)
            pending = event
            result.append(event)
        }
        return result
    }
}
