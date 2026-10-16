import XCTest
@testable import Pulse

final class MonitorTests: XCTestCase {
    func testThresholdDedupAndRecoveryShareID() {
        var engine = HangStateMachine(threshold: 0.25)
        XCTAssertTrue(engine.sample(time: 1.2, busySince: 1, active: true, breadcrumbs: []).isEmpty)
        let first = engine.sample(time: 1.3, busySince: 1, active: true, breadcrumbs: [])
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first.first?.phase, .detected)
        XCTAssertTrue(engine.sample(time: 2, busySince: 1, active: true, breadcrumbs: []).isEmpty)
        let last = engine.sample(time: 2.1, busySince: nil, active: true, breadcrumbs: [])
        XCTAssertEqual(last.first?.id, first.first?.id); XCTAssertEqual(last.first?.phase, .recovered)
    }
    func testBackgroundDiscardsPendingAndDoesNotProduceRecovery() {
        var engine = HangStateMachine(threshold: 0.25)
        _ = engine.sample(time: 1, busySince: 0, active: true, breadcrumbs: [])
        XCTAssertTrue(engine.sample(time: 20, busySince: 0, active: false, breadcrumbs: []).isEmpty)
        XCTAssertTrue(engine.sample(time: 21, busySince: nil, active: true, breadcrumbs: []).isEmpty)
    }
    func testIdleDoesNotReportHang() {
        var engine = HangStateMachine(threshold: 0.25)
        XCTAssertTrue(engine.sample(time: 1000, busySince: nil, active: true, breadcrumbs: []).isEmpty)
    }
    func testChangedBusyEpochEndsPreviousEvent() {
        var engine = HangStateMachine(threshold: 0.25)
        _ = engine.sample(time: 1, busySince: 0, active: true, breadcrumbs: [])
        let events = engine.sample(time: 2, busySince: 1.5, active: true, breadcrumbs: [])
        XCTAssertEqual(events.map(\.phase), [.recovered, .detected])
        XCTAssertNotEqual(events[0].id, events[1].id)
    }
    func testRingBufferPreservesRecentOrderAndBoundsStrings() {
        let buffer = BreadcrumbBuffer(capacity: 2)
        for n in 0..<3 { buffer.record(category: "test", message: "\(n)", uptime: Double(n)) }
        XCTAssertEqual(buffer.snapshot().map(\.message), ["1", "2"])
        buffer.record(category: String(repeating: "a", count: 100), message: String(repeating: "b", count: 500))
        XCTAssertEqual(buffer.snapshot().last?.category.count, 64)
        XCTAssertEqual(buffer.snapshot().last?.message.count, 256)
    }
    func testArchiveUpsertsAndPreservesCorruptFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.json")
        let archive = EventArchive(url: file, limit: 1)
        var engine = HangStateMachine(threshold: 0.25)
        let first = engine.sample(time: 1, busySince: 0, active: true, breadcrumbs: [])[0]
        try archive.append(first)
        let recovered = engine.sample(time: 2, busySince: nil, active: true, breadcrumbs: [])[0]
        try archive.append(recovered)
        XCTAssertEqual(try archive.load().count, 1)
        XCTAssertEqual(try archive.load().first?.phase, .recovered)
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try archive.append(first))
        XCTAssertEqual(try Data(contentsOf: file), Data([0xff]))
    }
    func testProbeAndMonitorCanStartStopRepeatedly() {
        XCTAssertTrue(Thread.isMainThread)
        let monitor = HangMonitor { _ in }
        monitor.start(); monitor.start(); monitor.setActive(false); monitor.setActive(true)
        monitor.stop(); monitor.stop(); monitor.start(); monitor.stop()
    }
}
