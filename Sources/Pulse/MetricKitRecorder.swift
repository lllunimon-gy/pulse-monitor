#if os(iOS)
import Foundation
import MetricKit

/// Optional, OS-delivered diagnostics. They are not synchronized with HangMonitor events.
@available(iOS 15.0, *)
public final class MetricKitRecorder: NSObject, MXMetricManagerSubscriber {
    private let receive: (Data) -> Void
    private var started = false
    public init(receive: @escaping (Data) -> Void) { self.receive = receive; super.init() }
    public func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }; started = true; MXMetricManager.shared.add(self)
    }
    public func stop() {
        precondition(Thread.isMainThread)
        guard started else { return }; started = false; MXMetricManager.shared.remove(self)
    }
    public func didReceive(_ payloads: [MXDiagnosticPayload]) { payloads.forEach { receive($0.jsonRepresentation()) } }
    public func didReceive(_ payloads: [MXMetricPayload]) { payloads.forEach { receive($0.jsonRepresentation()) } }
    deinit { if started { MXMetricManager.shared.remove(self) } }
}
#endif
