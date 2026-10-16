import Foundation
import PulseObjC
#if canImport(UIKit)
import UIKit
#endif

/// Configure/start/stop on the main thread. Events are delivered on a private serial queue.
public final class HangMonitor {
    public let breadcrumbs: BreadcrumbBuffer
    private let probe = PLRunLoopProbe()
    private let worker = DispatchQueue(label: "dev.gy.pulse.monitor", qos: .utility)
    private let delivery = DispatchQueue(label: "dev.gy.pulse.events", qos: .utility)
    private let interval: TimeInterval
    private let handler: (HangEvent) -> Void
    private let lock = NSLock()
    private var engine: HangStateMachine
    private var timer: DispatchSourceTimer?
    private var active = true
    private var running = false
    private var notifications: [NSObjectProtocol] = []

    public init(threshold: TimeInterval = 0.25, interval: TimeInterval = 0.05,
                breadcrumbs: BreadcrumbBuffer = BreadcrumbBuffer(), handler: @escaping (HangEvent) -> Void) {
        precondition(threshold.isFinite && interval.isFinite && interval > 0 && threshold >= interval)
        self.interval = interval; self.engine = HangStateMachine(threshold: threshold)
        self.breadcrumbs = breadcrumbs; self.handler = handler
    }
    public func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        lock.lock(); engine.reset(); running = true
        #if canImport(UIKit)
        active = UIApplication.shared.applicationState == .active
        #else
        active = true
        #endif
        lock.unlock()
        probe.start()
        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source; source.resume()
        #if canImport(UIKit)
        notifications = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(false) },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(true) }
        ]
        #endif
    }
    public func setActive(_ value: Bool) {
        precondition(Thread.isMainThread)
        lock.lock(); active = value; engine.reset(); probe.reset(); lock.unlock()
    }
    public func stop() {
        precondition(Thread.isMainThread)
        lock.lock(); running = false; engine.reset(); lock.unlock()
        timer?.cancel(); timer = nil; probe.stop()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
    }
    private func tick() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let state = probe.snapshot()
        let events = engine.sample(time: ProcessInfo.processInfo.systemUptime,
                                   busySince: state.busy == 0 ? nil : state.busySince,
                                   active: active, breadcrumbs: breadcrumbs.snapshot())
        lock.unlock()
        let handler = self.handler
        for event in events { delivery.async { handler(event) } }
    }
    deinit {
        timer?.cancel()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        probe.stop()
    }
}
