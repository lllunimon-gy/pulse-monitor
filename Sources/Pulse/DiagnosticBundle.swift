import Foundation

public struct DiagnosticBundle: Codable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let events: [HangEvent]
    public let spans: [PerformanceSpan]
    public let resources: [ResourceSample]
    public let frames: [FrameSample]
    public let frameSummary: FrameSummary?
    public let session: SessionRecord?
    public let previousSession: SessionRecord?
    public let systemPayloads: [SystemPayload]
    public let delivery: DeliveryStatistics?
    public let droppedProbeIntervals: Int
    public let droppedBatchEvents: Int?
    public let droppedSystemPayloads: Int?
    public let droppedSpans: Int?

    public init(events: [HangEvent], spans: [PerformanceSpan] = [], resources: [ResourceSample] = [],
                frames: [FrameSample] = [], frameSummary: FrameSummary? = nil,
                session: SessionRecord? = nil, previousSession: SessionRecord? = nil,
                systemPayloads: [SystemPayload] = [], delivery: DeliveryStatistics? = nil,
                droppedProbeIntervals: Int = 0, droppedBatchEvents: Int = 0,
                droppedSystemPayloads: Int = 0, droppedSpans: Int = 0) {
        schemaVersion = 1; exportedAt = Date()
        self.events = Array(events.suffix(100))
        self.spans = Array(spans.suffix(256))
        self.resources = Array(resources.suffix(240))
        self.frames = Array(frames.suffix(600))
        self.frameSummary = frameSummary
        self.session = session; self.previousSession = previousSession
        self.systemPayloads = Array(systemPayloads.suffix(10))
        self.delivery = delivery; self.droppedProbeIntervals = droppedProbeIntervals
        self.droppedBatchEvents = droppedBatchEvents
        self.droppedSystemPayloads = droppedSystemPayloads
        self.droppedSpans = droppedSpans
    }

    /// Call off the main thread. Export is explicit and contains caller-provided labels and raw system data.
    public func write(to url: URL, maxBytes: Int = 16 * 1024 * 1024) throws {
        precondition(maxBytes > 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= maxBytes else { throw ArchiveError.fileTooLarge }
        try atomicWrite(data, to: url)
    }
}
