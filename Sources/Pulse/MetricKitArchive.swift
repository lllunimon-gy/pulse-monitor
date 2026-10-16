import Foundation
import CryptoKit

public enum SystemPayloadKind: String, Codable { case metrics, diagnostics }

public struct SystemPayload: Codable, Identifiable {
    public let id: String
    public let kind: SystemPayloadKind
    public let receivedAt: Date
    public let topLevelKeys: [String]
    /// Counts only arrays at known keys; absent/changed schema is not interpreted as zero incidents.
    public let diagnosticCounts: [String: Int]
    public let rawJSON: Data
}

/// Version-tolerant raw evidence store. It deliberately does not attach payloads to local hang IDs.
public final class MetricKitArchive {
    private let url: URL
    private let limit: Int
    private let maxBytes: Int
    private let maxPayloadBytes: Int
    private let lock = NSLock()

    public init(url: URL, limit: Int = 10, maxBytes: Int = 4 * 1024 * 1024,
                maxPayloadBytes: Int = 512 * 1024) {
        precondition((1...1000).contains(limit) && maxBytes > 0 && maxPayloadBytes > 0)
        self.url = url; self.limit = limit; self.maxBytes = maxBytes
        self.maxPayloadBytes = maxPayloadBytes
    }

    public func load() throws -> [SystemPayload] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }

    private func read() throws -> [SystemPayload] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SystemPayload].self, from: boundedRead(url, maxBytes: maxBytes))
    }

    @discardableResult
    public func append(_ data: Data, kind: SystemPayloadKind, now: Date = Date()) throws -> Bool {
        guard data.count <= maxPayloadBytes else { throw ArchiveError.recordTooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArchiveError.invalidPayload
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let hash = SHA256.hash(data: Data(kind.rawValue.utf8) + canonical)
            .map { String(format: "%02x", $0) }.joined()
        let keys = ["hangDiagnostics", "crashDiagnostics", "cpuExceptionDiagnostics",
                    "diskWriteExceptionDiagnostics", "appLaunchDiagnostics"]
        var counts: [String: Int] = [:]
        for key in keys {
            if let array = object[key] as? [Any] { counts[key] = array.count }
        }
        let record = SystemPayload(id: hash, kind: kind, receivedAt: now,
                                   topLevelKeys: Array(object.keys.sorted().prefix(64)),
                                   diagnosticCounts: counts, rawJSON: data)
        lock.lock(); defer { lock.unlock() }
        var records = try read()
        guard !records.contains(where: { $0.id == hash }) else { return false }
        let encoder = JSONEncoder()
        guard try encoder.encode([record]).count <= maxBytes else { throw ArchiveError.recordTooLarge }
        records.append(record)
        records = Array(records.suffix(limit))
        var encoded = try encoder.encode(records)
        while encoded.count > maxBytes {
            records.removeFirst()
            encoded = try encoder.encode(records)
        }
        try atomicWrite(encoded, to: url)
        return true
    }
}
