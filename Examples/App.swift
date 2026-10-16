import SwiftUI
import Pulse

@main struct PulseExample: App { var body: some Scene { WindowGroup { ContentView() } } }
final class DemoModel: ObservableObject {
    @Published var events: [String] = []
    private var monitor: HangMonitor?
    private let crumbs = BreadcrumbBuffer()
    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PulseExample/events.json")
        let archive = EventArchive(url: root)
        monitor = HangMonitor(breadcrumbs: crumbs) { [weak self] event in
            var text = "\(event.phase.rawValue)：\(Int(event.duration * 1000)) ms"
            do { try archive.append(event) } catch { text += "；存储失败：\(error)" }
            let result = text
            DispatchQueue.main.async { self?.events.insert(result, at: 0) }
        }
    }
    func start() { monitor?.start() }
    func stop() { monitor?.stop() }
    func block() {
        crumbs.record(category: "experiment", message: "main-thread-sleep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Thread.sleep(forTimeInterval: 0.6) }
    }
    func background() {
        crumbs.record(category: "experiment", message: "background-work")
        DispatchQueue.global().async { Thread.sleep(forTimeInterval: 0.6) }
    }
    func lockWait() {
        crumbs.record(category: "experiment", message: "main-lock-wait")
        let lock = NSLock()
        DispatchQueue.global().async {
            lock.lock()
            DispatchQueue.main.async { lock.lock(); lock.unlock() }
            Thread.sleep(forTimeInterval: 0.6); lock.unlock()
        }
    }
}
struct ContentView: View {
    @StateObject private var model = DemoModel()
    var body: some View {
        NavigationView { List {
            Text("以下按钮故意制造短暂卡顿。事件列表在主线程恢复后更新。")
            Button("主线程阻塞 600 ms") { model.block() }
            Button("主线程等待锁") { model.lockWait() }
            Button("后台工作对照") { model.background() }
            Button("停止") { model.stop() }
            Button("开始") { model.start() }
            ForEach(Array(model.events.enumerated()), id: \.offset) { item in Text(item.element) }
        }.navigationTitle("Pulse · gy") }.onAppear { model.start() }.onDisappear { model.stop() }
    }
}
