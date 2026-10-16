import Foundation

public enum ArchiveError: Error {
    case fileTooLarge
    case recordTooLarge
    case invalidPayload
}

/// One instance per URL. Call on a background queue. Atomic replacement is not fsync durability.
public final class EventArchive {
    private let url: URL
    private let limit: Int
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private let lock = NSLock()

    public init(url: URL, limit: Int = 100, maxBytes: Int = 4 * 1024 * 1024,
                maxAge: TimeInterval = 7 * 24 * 3600) {
        precondition((1...10000).contains(limit) && maxBytes > 0 && maxAge.isFinite && maxAge > 0)
        self.url = url; self.limit = limit; self.maxBytes = maxBytes; self.maxAge = maxAge
    }

    public func load() throws -> [HangEvent] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }

    private func read() throws -> [HangEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([HangEvent].self, from: boundedRead(url, maxBytes: maxBytes))
    }

    public func append(_ event: HangEvent) throws { try append(contentsOf: [event]) }

    /// Batch updates into one write. A failed encode/oversized record leaves the old file untouched.
    public func append(contentsOf updates: [HangEvent], now: Date = Date()) throws {
        guard !updates.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var events = try read()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for event in updates {
            guard try encoder.encode([event]).count <= maxBytes else { throw ArchiveError.recordTooLarge }
            if let index = events.firstIndex(where: { $0.id == event.id }) {
                events[index] = event
            } else {
                events.append(event)
            }
        }
        events.removeAll {
            guard let date = $0.evidence?.context.capturedAt else { return false }
            return now.timeIntervalSince(date) > maxAge
        }
        events = Array(events.suffix(limit))
        var data = try encoder.encode(events)
        while data.count > maxBytes && !events.isEmpty {
            events.removeFirst()
            data = try encoder.encode(events)
        }
        try atomicWrite(data, to: url)
    }
}

func boundedRead(_ url: URL, maxBytes: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else { throw ArchiveError.fileTooLarge }
    return data
}

func atomicWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                         ofItemAtPath: url.path)
    #endif
}

/// Bounded coalescing buffer for batch persistence. The caller schedules flushes off the main thread.
public final class EventBatch {
    private let lock = NSLock()
    private let capacity: Int
    private var events: [HangEvent] = []
    private var dropped = 0

    public init(capacity: Int = 100) {
        precondition((1...10000).contains(capacity))
        self.capacity = capacity
    }

    public func record(_ event: HangEvent) {
        lock.lock(); defer { lock.unlock() }
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            if events.count == capacity { events.removeFirst(); dropped += 1 }
            events.append(event)
        }
    }

    public var droppedEvents: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    /// Serializes with record. On failure all buffered evidence remains available for retry.
    public func flush(to archive: EventArchive) throws {
        lock.lock(); defer { lock.unlock() }
        try archive.append(contentsOf: events)
        events.removeAll(keepingCapacity: true)
    }
}
