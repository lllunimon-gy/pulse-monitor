#if os(iOS)
import Foundation
import MetricKit

/// Optional system evidence, asynchronously delivered by the OS. No 1:1 local-event correlation.
@available(iOS 15.0, *)
public final class MetricKitRecorder: NSObject, MXMetricManagerSubscriber {
    private let receive: (Data, SystemPayloadKind) -> Void
    private let queue = DispatchQueue(label: "dev.gy.pulse.metrickit", qos: .utility)
    private let budget = DispatchSemaphore(value: 8)
    private let lock = NSLock()
    private var dropped = 0
    private var started = false

    public init(receive: @escaping (Data) -> Void) {
        self.receive = { data, _ in receive(data) }
        super.init()
    }

    public init(archive: MetricKitArchive, onError: @escaping (Error) -> Void = { _ in }) {
        self.receive = { data, kind in
            do { try archive.append(data, kind: kind) } catch { onError(error) }
        }
        super.init()
    }

    public var droppedPayloads: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    public func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    public func stop() {
        precondition(Thread.isMainThread)
        guard started else { return }
        started = false
        MXMetricManager.shared.remove(self)
    }

    private func enqueue(kind: SystemPayloadKind, serialize: @escaping () -> Data) {
        guard budget.wait(timeout: .now()) == .success else {
            lock.lock(); dropped += 1; lock.unlock()
            return
        }
        let budget = budget, receive = receive
        queue.async {
            defer { budget.signal() }
            receive(serialize(), kind)
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        payloads.forEach { payload in enqueue(kind: .diagnostics) { payload.jsonRepresentation() } }
    }
    public func didReceive(_ payloads: [MXMetricPayload]) {
        payloads.forEach { payload in enqueue(kind: .metrics) { payload.jsonRepresentation() } }
    }
    deinit { if started { MXMetricManager.shared.remove(self) } }
}
#endif
