import Foundation
import PulseObjC
#if canImport(UIKit)
import UIKit
#endif

/// Configure/start/stop on the main thread. Handler runs on a bounded private serial delivery.
public final class HangMonitor {
    public let breadcrumbs: BreadcrumbBuffer
    public let evidence: EvidenceRecorder?
    private let probe: PLRunLoopProbe
    private let worker = DispatchQueue(label: "dev.gy.pulse.monitor", qos: .utility)
    private let delivery: EventDelivery
    private let interval: TimeInterval
    private let lock = NSLock()
    private var engine: HangStateMachine
    private var timer: DispatchSourceTimer?
    private var active = true
    private var running = false
    private var generation = 0
    private var lostIntervals = 0
    private var notifications: [NSObjectProtocol] = []

    public init(threshold: TimeInterval = 0.25, interval: TimeInterval = 0.05,
                breadcrumbs: BreadcrumbBuffer = BreadcrumbBuffer(), evidence: EvidenceRecorder? = nil,
                deliveryCapacity: Int = 64, handler: @escaping (HangEvent) -> Void) {
        precondition(threshold.isFinite && interval.isFinite && interval > 0 && threshold >= interval)
        self.interval = interval
        self.engine = HangStateMachine(threshold: threshold)
        self.probe = PLRunLoopProbe(threshold: threshold)
        self.breadcrumbs = breadcrumbs
        self.evidence = evidence
        self.delivery = EventDelivery(capacity: deliveryCapacity, handler: handler)
    }

    public var deliveryStatistics: DeliveryStatistics { delivery.statistics }
    public var droppedProbeIntervals: Int {
        lock.lock(); defer { lock.unlock() }
        return lostIntervals
    }

    public func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        lock.lock()
        engine.reset(); running = true; generation += 1
        let run = generation
        delivery.invalidate()
        #if canImport(UIKit)
        active = UIApplication.shared.applicationState == .active
        #else
        active = true
        #endif
        probe.reset()
        evidence?.setActive(active)
        lock.unlock()
        probe.start()
        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in self?.tick(generation: run) }
        timer = source; source.resume()
        #if canImport(UIKit)
        notifications = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.setActive(false) },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.setActive(true) }
        ]
        #endif
    }

    public func setActive(_ value: Bool) {
        precondition(Thread.isMainThread)
        lock.lock(); defer { lock.unlock() }
        guard active != value else { return }
        if !value { delivery.submit(engine.cancel(time: ProcessInfo.processInfo.systemUptime)) }
        active = value; engine.reset(); probe.reset()
        evidence?.setActive(value)
    }

    public func stop() {
        precondition(Thread.isMainThread)
        lock.lock()
        running = false; generation += 1; engine.reset()
        delivery.invalidate()
        lock.unlock()
        timer?.cancel(); timer = nil; probe.stop()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
    }

    private func tick(generation run: Int) {
        lock.lock(); defer { lock.unlock() }
        guard running, run == generation else { return }
        let state = probe.drain()
        lostIntervals += Int(state.droppedIntervals)
        let crumbs = breadcrumbs
        let recorder = evidence
        let events = engine.sample(time: ProcessInfo.processInfo.systemUptime,
                                   busySince: state.busy ? state.busySince : nil,
                                   completed: state.completed.map { BusyInterval(start: $0.start, end: $0.end) },
                                   active: active, breadcrumbs: { crumbs.snapshot() },
                                   evidence: { recorder?.snapshot(since: $0) })
        delivery.submit(events)
    }

    deinit {
        timer?.cancel(); delivery.invalidate()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        probe.stop()
    }
}
