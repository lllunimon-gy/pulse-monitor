import Foundation

public enum SessionState: String, Codable { case active, inactive, background, ended }

public struct SessionRecord: Codable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public var updatedAt: Date
    public var state: SessionState
    public var lastPage: String
    public var memoryWarnings: Int
    public var lastFootprintBytes: UInt64?
}

public enum PreviousSessionAssessment: String, Codable {
    case explicitlyEnded
    case unknown
}

/// A breadcrumb of the previous session, never an OOM/crash classifier.
/// Create and mutate on a caller-owned background serial queue.
public final class SessionRecorder {
    public let previous: SessionRecord?
    public let previousAssessment: PreviousSessionAssessment
    public private(set) var current: SessionRecord
    private let url: URL

    public init(url: URL, id: UUID = UUID(), now: Date = Date()) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            previous = try JSONDecoder().decode(SessionRecord.self, from: boundedRead(url, maxBytes: 64 * 1024))
        } else {
            previous = nil
        }
        previousAssessment = previous?.state == .ended ? .explicitlyEnded : .unknown
        current = SessionRecord(id: id, startedAt: now, updatedAt: now, state: .inactive,
                                lastPage: "unknown", memoryWarnings: 0, lastFootprintBytes: nil)
        try persist(current)
    }

    public func checkpoint(state: SessionState, page: String, footprintBytes: UInt64? = nil,
                           memoryWarning: Bool = false, now: Date = Date()) throws {
        var next = current
        next.updatedAt = now; next.state = state
        next.lastPage = boundedLabel(page, bytes: 128)
        next.lastFootprintBytes = footprintBytes
        if memoryWarning { next.memoryWarnings += 1 }
        try persist(next)
        current = next
    }

    private func persist(_ record: SessionRecord) throws {
        try atomicWrite(JSONEncoder().encode(record), to: url)
    }
}
