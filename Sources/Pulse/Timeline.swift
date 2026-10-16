import Foundation
import os

public struct EventContext: Codable {
    public let sessionID: UUID
    public let appVersion: String
    public let build: String
    public let systemVersion: String
    public let deviceModel: String
    public let page: String
    public let active: Bool
    public let capturedAt: Date
}

public struct PerformanceSpan: Codable, Identifiable {
    public let id: UUID
    public let parentID: UUID?
    public let name: String
    public let start: TimeInterval
    public let end: TimeInterval?
    public var duration: TimeInterval? { end.map { max(0, $0 - start) } }
}

/// Thread-safe, bounded spans. A nil token means the active-span budget was exhausted.
public final class SpanRecorder {
    private struct Active {
        let span: PerformanceSpan
        let state: OSSignpostIntervalState
    }
    private let lock = NSLock()
    private let signposter = OSSignposter(subsystem: "dev.gy.pulse", category: "Business")
    private let activeLimit: Int
    private var active: [UUID: Active] = [:]
    private var completed: BoundedBuffer<PerformanceSpan>
    private var dropped = 0

    public init(capacity: Int = 128, activeLimit: Int = 64) {
        precondition((1...1024).contains(capacity) && (1...1024).contains(activeLimit))
        completed = BoundedBuffer(capacity: capacity)
        self.activeLimit = activeLimit
    }

    @discardableResult
    public func begin(_ name: StaticString, parentID: UUID? = nil,
                      uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID? {
        guard uptime.isFinite else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard active.count < activeLimit else { dropped += 1; return nil }
        let id = UUID()
        let label = String(String(describing: name).prefix(128))
        let span = PerformanceSpan(id: id, parentID: parentID, name: label, start: uptime, end: nil)
        let state = signposter.beginInterval("PulseSpan", id: signposter.makeSignpostID(), "\(label, privacy: .public)")
        active[id] = Active(span: span, state: state)
        return id
    }

    public func end(_ id: UUID?, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let id = id, uptime.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        guard let item = active.removeValue(forKey: id) else { return }
        signposter.endInterval("PulseSpan", item.state)
        completed.append(PerformanceSpan(id: id, parentID: item.span.parentID, name: item.span.name,
                                         start: item.span.start, end: max(item.span.start, uptime)))
    }

    public func snapshot(since: TimeInterval = 0) -> [PerformanceSpan] {
        lock.lock(); defer { lock.unlock() }
        return (completed.snapshot() + active.values.map(\.span))
            .filter { ($0.end ?? .infinity) >= since }.sorted { $0.start < $1.start }
    }

    public var droppedSpans: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    deinit {
        for item in active.values { signposter.endInterval("PulseSpan", item.state) }
    }
}

public struct EventEvidence: Codable {
    public let source: String
    public let context: EventContext
    public let spans: [PerformanceSpan]
    public let resources: [ResourceSample]

    func addingRecovery(_ other: EventEvidence?) -> EventEvidence {
        guard let other = other else { return self }
        var mergedSpans = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
        for span in other.spans { mergedSpans[span.id] = span }
        var mergedResources = Dictionary(uniqueKeysWithValues: resources.map { ($0.uptime, $0) })
        for sample in other.resources { mergedResources[sample.uptime] = sample }
        return EventEvidence(source: source, context: context,
                             spans: Array(mergedSpans.values.sorted { $0.start < $1.start }.suffix(256)),
                             resources: Array(mergedResources.values.sorted { $0.uptime < $1.uptime }.suffix(240)))
    }
}

public final class EvidenceRecorder {
    public let spans: SpanRecorder
    public let resources: ResourceMonitor
    public let sessionID: UUID
    private let lock = NSLock()
    private var page = "unknown"
    private var active = true
    private let appVersion: String
    private let build: String
    private let deviceModel: String

    public init(sessionID: UUID = UUID(), deviceModel: String = "unspecified",
                spans: SpanRecorder = SpanRecorder(), resources: ResourceMonitor = ResourceMonitor()) {
        self.sessionID = sessionID
        self.deviceModel = String(deviceModel.prefix(128))
        self.spans = spans
        self.resources = resources
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    public func setPage(_ label: String) {
        lock.lock(); page = String(label.prefix(128)); lock.unlock()
    }

    public func setActive(_ value: Bool) {
        lock.lock(); active = value; lock.unlock()
        resources.setActive(value)
    }

    public func snapshot(since: TimeInterval) -> EventEvidence {
        lock.lock()
        let context = EventContext(sessionID: sessionID, appVersion: appVersion, build: build,
                                   systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                   deviceModel: deviceModel, page: page, active: active, capturedAt: Date())
        lock.unlock()
        return EventEvidence(source: "local-runloop-proxy", context: context,
                             spans: spans.snapshot(since: max(0, since - 5)),
                             resources: resources.snapshot(since: max(0, since - 5)))
    }
}
