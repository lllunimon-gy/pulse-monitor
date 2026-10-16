import XCTest
@testable import Pulse

final class DiagnosticsTests: XCTestCase {
    private func event(start: Double = 1, end: Double = 2) -> HangEvent {
        var engine = HangStateMachine(threshold: 0.25)
        return engine.sample(time: end, busySince: nil, completed: [.init(start: start, end: end)],
                             active: true, breadcrumbs: { [] }, evidence: { _ in nil })[0]
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("archive.json")
    }

    func testCompletedBetweenTicksIsRecoveredWithObservedEnd() {
        var engine = HangStateMachine(threshold: 0.25)
        XCTAssertTrue(engine.sample(time: 1.25, busySince: 1.01, active: true, breadcrumbs: []).isEmpty)
        let events = engine.sample(time: 1.30, busySince: nil,
                                   completed: [.init(start: 1.01, end: 1.27)], active: true,
                                   breadcrumbs: { [] }, evidence: { _ in nil })
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].phase, .recovered)
        XCTAssertEqual(events[0].duration, 0.26, accuracy: 0.0001)
        XCTAssertEqual(events[0].endedAtUptime, 1.27)
    }

    func testRecoveryPreservesDetectionBreadcrumbsAndUsesProbeEnd() {
        let buffer = BreadcrumbBuffer(capacity: 1)
        buffer.record(category: "screen", message: "before")
        var engine = HangStateMachine(threshold: 0.25)
        let detected = engine.sample(time: 1.3, busySince: 1, active: true, breadcrumbs: buffer.snapshot())[0]
        buffer.record(category: "screen", message: "after")
        let recovered = engine.sample(time: 2, busySince: nil, completed: [.init(start: 1, end: 1.4)],
                                      active: true, breadcrumbs: { buffer.snapshot() }, evidence: { _ in nil })
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].id, detected.id)
        XCTAssertEqual(recovered[0].breadcrumbs.first?.message, "before")
        XCTAssertEqual(recovered[0].duration, 0.4, accuracy: 0.0001)
    }

    func testHistoryHandlesMultipleCompletedIntervalsThenCurrentBusyEpoch() {
        var engine = HangStateMachine(threshold: 0.25)
        let events = engine.sample(time: 4, busySince: 3.5,
                                   completed: [.init(start: 1, end: 1.3), .init(start: 2, end: 2.1),
                                               .init(start: 3, end: 3.3)],
                                   active: true, breadcrumbs: { [] }, evidence: { _ in nil })
        XCTAssertEqual(events.map(\.phase), [.recovered, .recovered, .detected])
        XCTAssertEqual(Set(events.map(\.id)).count, 3)
    }

    func testIdleSamplingDoesNotCaptureEvidence() {
        var engine = HangStateMachine(threshold: 0.25)
        _ = engine.sample(time: 10, busySince: nil, completed: [], active: true,
                          breadcrumbs: { XCTFail("idle snapshot"); return [] },
                          evidence: { _ in XCTFail("idle evidence"); return nil })
    }

    func testLifecycleCancellationIsNotRecovery() {
        var engine = HangStateMachine(threshold: 0.25)
        let first = engine.sample(time: 1.3, busySince: 1, active: true, breadcrumbs: [])[0]
        let cancelled = engine.cancel(time: 1.4)
        XCTAssertEqual(cancelled.first?.id, first.id)
        XCTAssertEqual(cancelled.first?.phase, .cancelled)
        XCTAssertNil(cancelled.first?.endedAtUptime)
        XCTAssertTrue(engine.cancel(time: 1.5).isEmpty)
    }

    func testDeliveryCoalescesAndBoundsWholeEvents() {
        let queue = DispatchQueue(label: "test.delivery")
        queue.suspend()
        let delivered = expectation(description: "latest event")
        let terminal = event()
        let delivery = EventDelivery(capacity: 1, queue: queue) { value in
            XCTAssertEqual(value.id, terminal.id)
            XCTAssertEqual(value.phase, .recovered)
            delivered.fulfill()
        }
        delivery.submit([terminal.updated(phase: .detected, time: 1.3, end: nil), terminal])
        delivery.submit([event(start: 3, end: 4)])
        XCTAssertEqual(delivery.statistics.retainedEvents, 1)
        XCTAssertEqual(delivery.statistics.coalescedUpdates, 1)
        XCTAssertEqual(delivery.statistics.droppedEvents, 1)
        queue.resume()
        wait(for: [delivered], timeout: 2)
        queue.sync {}
        XCTAssertEqual(delivery.statistics.retainedEvents, 0)
    }

    func testSlowConsumerRetainsCapacityForRecovery() {
        let entered = expectation(description: "detected entered")
        let terminalDelivered = expectation(description: "recovery delivered")
        let release = DispatchSemaphore(value: 0)
        let terminal = event()
        let delivery = EventDelivery(capacity: 1) { value in
            if value.phase == .detected {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            } else {
                XCTAssertEqual(value.id, terminal.id)
                terminalDelivered.fulfill()
            }
        }
        delivery.submit([terminal.updated(phase: .detected, time: 1.3, end: nil)])
        wait(for: [entered], timeout: 2)
        for n in 0..<20 { delivery.submit([event(start: Double(n + 3), end: Double(n + 4))]) }
        delivery.submit([terminal])
        XCTAssertEqual(delivery.statistics.retainedEvents, 1)
        XCTAssertEqual(delivery.statistics.droppedEvents, 20)
        release.signal()
        wait(for: [terminalDelivered], timeout: 2)
    }

    func testInvalidateSuppressesQueuedCallbacks() {
        let queue = DispatchQueue(label: "test.invalidated")
        queue.suspend()
        let delivery = EventDelivery(capacity: 1, queue: queue) { _ in XCTFail("stale delivery") }
        delivery.submit([event()])
        delivery.invalidate()
        XCTAssertEqual(delivery.statistics.invalidatedEvents, 1)
        queue.resume()
        queue.sync {}
    }

    func testLegacyArchiveDecodesWithUnknownPrecision() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","phase":"recovered",
          "startedAtUptime":1,"observedAtUptime":2,"duration":1,"breadcrumbs":[]}]
        """
        let events = try JSONDecoder().decode([HangEvent].self, from: Data(json.utf8))
        XCTAssertNil(events[0].endedAtUptime)
        XCTAssertNil(events[0].evidence)
        XCTAssertNil(events[0].durationBasis)
    }

    func testArchiveBatchUpsertsAndRejectsOversizeWithoutChangingFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = event()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let budget = try encoder.encode([item]).count + 8
        let archive = EventArchive(url: url, limit: 10, maxBytes: budget)
        try archive.append(contentsOf: [item, event(start: 3, end: 4)])
        XCTAssertEqual(try archive.load().count, 1)
        let old = try Data(contentsOf: url)
        let crumbs = BreadcrumbBuffer()
        for _ in 0..<64 { crumbs.record(category: "test", message: String(repeating: "a", count: 256)) }
        var engine = HangStateMachine(threshold: 0.25)
        let large = engine.sample(time: 2, busySince: 1, active: true, breadcrumbs: crumbs.snapshot())[0]
        XCTAssertThrowsError(try archive.append(large))
        XCTAssertEqual(try Data(contentsOf: url), old)
    }

    func testFailedBatchCanBeRetriedAndIsBounded() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let batch = EventBatch(capacity: 1)
        batch.record(event())
        let latest = event(start: 3, end: 4)
        batch.record(latest)
        XCTAssertEqual(batch.droppedEvents, 1)
        XCTAssertThrowsError(try batch.flush(to: EventArchive(url: url, maxBytes: 2)))
        let archive = EventArchive(url: url)
        try batch.flush(to: archive)
        XCTAssertEqual(try archive.load().first?.id, latest.id)
    }

    func testSpansPreserveParentageAndRejectActiveOverflow() {
        let recorder = SpanRecorder(capacity: 2, activeLimit: 2)
        let parent = recorder.begin("parent", uptime: 1)
        let child = recorder.begin("child", parentID: parent, uptime: 2)
        XCTAssertNil(recorder.begin("overflow", uptime: 2))
        recorder.end(child, uptime: 3)
        recorder.end(child, uptime: 4)
        recorder.end(parent, uptime: 5)
        XCTAssertEqual(recorder.droppedSpans, 1)
        let spans = recorder.snapshot()
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[1].parentID, parent)
        XCTAssertEqual(spans[1].duration, 1)
    }

    func testCPUUsesDeltasSupportsMultipleCoresAndResetsAcrossInactivity() {
        var cpu = CPUTracker()
        XCTAssertNil(cpu.sample(time: 1, cpu: 10))
        XCTAssertEqual(cpu.sample(time: 2, cpu: 12), 200)
        cpu.reset()
        XCTAssertNil(cpu.sample(time: 100, cpu: 13))
        XCTAssertNil(cpu.sample(time: 101, cpu: nil))
        XCTAssertNil(cpu.sample(time: 102, cpu: 14))
    }

    func testFrameCadenceUsesVariableBudgetAndResetsBackgroundGap() {
        var frames = FrameAccumulator(capacity: 4)
        frames.record(timestamp: 1, targetTimestamp: 1 + 1.0 / 120, uptime: 1)
        frames.record(timestamp: 1 + 1.0 / 60, targetTimestamp: 1 + 2.0 / 60, uptime: 2)
        XCTAssertEqual(frames.summary(page: "list").longIntervals, 0)
        frames.record(timestamp: 1.1, targetTimestamp: 1.1 + 1.0 / 60, uptime: 3)
        XCTAssertEqual(frames.summary(page: "list").longIntervals, 1)
        frames.reset()
        frames.record(timestamp: 100, targetTimestamp: 100.016, uptime: 100)
        XCTAssertEqual(frames.summary(page: "list").sampleCount, 0)
    }

    func testFrameWindowEvictsOldSamplesAndRejectsInvalidTimestamps() {
        var frames = FrameAccumulator(capacity: 2)
        for n in 0..<5 { frames.record(timestamp: Double(n), targetTimestamp: Double(n) + 0.016, uptime: Double(n)) }
        XCTAssertEqual(frames.snapshot().count, 2)
        frames.record(timestamp: .nan, targetTimestamp: 0, uptime: 0)
        frames.record(timestamp: 10, targetTimestamp: 10.016, uptime: 10)
        XCTAssertEqual(frames.snapshot().count, 2)
    }

    func testLifetimeTrackerDoesNotRetainObjects() {
        let tracker = ObjectLifetimeTracker(capacity: 1)
        var object: NSObject? = NSObject()
        weak var weakObject = object
        XCTAssertTrue(tracker.expectRelease(object!, label: "view-model", after: 1, uptime: 1))
        object = nil
        XCTAssertNil(weakObject)
        XCTAssertTrue(tracker.check(uptime: 1.5).isEmpty)
        XCTAssertEqual(tracker.check(uptime: 2).first?.stillAlive, false)
    }

    func testUnfinishedSessionRemainsUnknown() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try SessionRecorder(url: url)
        try first.checkpoint(state: .background, page: "list", memoryWarning: true)
        let second = try SessionRecorder(url: url)
        XCTAssertEqual(second.previous?.id, first.current.id)
        XCTAssertEqual(second.previous?.memoryWarnings, 1)
        XCTAssertEqual(second.previousAssessment, .unknown)
        try second.checkpoint(state: .ended, page: "list")
        let third = try SessionRecorder(url: url)
        XCTAssertEqual(third.previousAssessment, .explicitlyEnded)
    }

    func testMetricKitDeduplicatesCanonicalJSONAndKeepsKindsSeparate() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = MetricKitArchive(url: url, limit: 2)
        let first = Data(#"{"hangDiagnostics":[{}],"version":1}"#.utf8)
        let reordered = Data(#"{"version":1, "hangDiagnostics":[{}]}"#.utf8)
        XCTAssertTrue(try archive.append(first, kind: .diagnostics))
        XCTAssertFalse(try archive.append(reordered, kind: .diagnostics))
        XCTAssertTrue(try archive.append(reordered, kind: .metrics))
        XCTAssertEqual(try archive.load().count, 2)
        XCTAssertEqual(try archive.load().first?.diagnosticCounts["hangDiagnostics"], 1)
        XCTAssertThrowsError(try archive.append(Data("[]".utf8), kind: .diagnostics))
    }

    func testMetricKitCorruptionIsPreservedAndPayloadIsBounded() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data([0xff])
        try corrupt.write(to: url)
        let archive = MetricKitArchive(url: url, maxPayloadBytes: 16)
        XCTAssertThrowsError(try archive.append(Data("{}".utf8), kind: .metrics))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertThrowsError(try archive.append(Data(repeating: 0, count: 17), kind: .metrics))
    }

    func testBundleRoundTripsAndRejectsOversizedExport() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bundle = DiagnosticBundle(events: [event()])
        try bundle.write(to: url)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(DiagnosticBundle.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertThrowsError(try bundle.write(to: url, maxBytes: 2))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
