import SwiftUI
import UIKit
import ImageIO
import Pulse

@main
struct PulseExample: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

private final class ConsumerDelay {
    private let lock = NSLock()
    private var enabled = false
    func set(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return enabled }
}

private final class RetainedModel: NSObject {
    let bytes = Data(repeating: 0x7f, count: 8 * 1024 * 1024)
}

/// Main-thread UI state. Persistence is confined to io; probes/recorders synchronize internally.
final class DemoModel: ObservableObject {
    @Published var events: [HangEvent] = []
    @Published var status = "选择实验，对照事件与资源曲线"
    @Published var running = false
    @Published var experimenting = false
    @Published var optimized = false
    @Published var slowConsumer = false { didSet { consumerDelay.set(slowConsumer) } }
    @Published var memoryText = "等待资源采样"
    @Published var cpuText = "—"
    @Published var frameText = "等待刷新采样"
    @Published var lossText = "尚无事件"
    @Published var sessionText = "正在读取上次会话"
    @Published var systemPayloadCount = 0
    @Published var image: UIImage?
    @Published var listRevision = 0
    @Published var retainedCount = 0
    @Published var shareURL: URL?
    @Published var exporting = false

    let evidence: EvidenceRecorder
    private let crumbs = BreadcrumbBuffer()
    private let frames = FrameMonitor()
    private let lifetime = ObjectLifetimeTracker()
    private let consumerDelay = ConsumerDelay()
    private let io = DispatchQueue(label: "dev.gy.pulse.example.storage", qos: .utility)
    private let archive: EventArchive
    private let systemArchive: MetricKitArchive
    private let batch = EventBatch()
    private let root: URL
    private var session: SessionRecorder?
    private var monitor: HangMonitor?
    private var metricKit: MetricKitRecorder?
    private var refreshTimer: Timer?
    private var flushTimer: DispatchSourceTimer?
    private var retained: [RetainedModel] = []
    private var startup: UUID?
    private var page = "实验室"
    private var lifecycleState = SessionState.active
    private var activeExperiment: UUID?
    private var burstRemaining = 0

    init() {
        let sessionID = UUID()
        evidence = EvidenceRecorder(sessionID: sessionID)
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulseExample")
        archive = EventArchive(url: root.appendingPathComponent("events.json"))
        systemArchive = MetricKitArchive(url: root.appendingPathComponent("metrickit.json"))
        startup = evidence.spans.begin("example-init-to-first-appearance")
        evidence.setPage(page)
        let batch = batch, consumerDelay = consumerDelay
        monitor = HangMonitor(evidence: evidence, deliveryCapacity: 2) { [weak self] event in
            if consumerDelay.read() { Thread.sleep(forTimeInterval: 2) }
            batch.record(event)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let index = self.events.firstIndex(where: { $0.id == event.id }) {
                    self.events[index] = event
                } else {
                    self.events.insert(event, at: 0)
                    self.events = Array(self.events.prefix(100))
                }
            }
        }
        metricKit = MetricKitRecorder(archive: systemArchive) { [weak self] error in
            DispatchQueue.main.async { self?.status = "系统诊断存储失败：\(error.localizedDescription)" }
        }
        io.async { [weak self] in
            guard let self = self else { return }
            do {
                self.session = try SessionRecorder(url: self.root.appendingPathComponent("session.json"), id: sessionID)
                let text = self.session?.previous == nil ? "首次会话" :
                    "上次：\(self.session?.previous?.state.rawValue ?? "unknown")；退出原因 unknown"
                let old = try self.archive.load().sorted { $0.observedAtUptime > $1.observedAtUptime }
                DispatchQueue.main.async {
                    self.sessionText = text
                    // A fresh process uptime cannot order previous-session records against this session.
                    let liveIDs = Set(self.events.map(\.id))
                    self.events = Array((self.events + old.filter { !liveIDs.contains($0.id) }).prefix(100))
                }
            } catch {
                DispatchQueue.main.async { self.status = "读取失败，保留原档案：\(error.localizedDescription)" }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: io)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            do { try self.batch.flush(to: self.archive) }
            catch { DispatchQueue.main.async { self.status = "事件保存失败：\(error.localizedDescription)" } }
        }
        flushTimer = timer
        timer.resume()
    }

    func start() {
        guard !running else { return }
        running = true
        monitor?.start()
        evidence.resources.start()
        frames.start(page: page)
        metricKit?.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        guard running else { return }
        running = false
        monitor?.stop()
        evidence.resources.stop()
        frames.stop()
        metricKit?.stop()
        refreshTimer?.invalidate(); refreshTimer = nil
        checkpoint()
    }

    func firstAppearance() {
        evidence.spans.end(startup)
        startup = nil
        start()
        checkpoint()
        recordSmokeState("first-appearance")
    }

    func recordSmokeState(_ phase: String) {
        let record: [String: Any] = [
            "phase": phase,
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "argumentRequested": ProcessInfo.processInfo.arguments.contains("--pulse-smoke"),
            "environmentRequested": ProcessInfo.processInfo.environment["PULSE_SMOKE"] == "1"
        ]
        io.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                try data.write(to: self.root.appendingPathComponent("smoke-status.json"), options: .atomic)
            } catch { DispatchQueue.main.async { self.status = "实验状态写入失败：\(error.localizedDescription)" } }
        }
    }

    func setPage(_ value: String) {
        page = value
        evidence.setPage(value)
        crumbs.record(category: "page", message: value)
        if running { frames.start(page: value) }
        checkpoint()
    }

    func lifecycle(_ phase: ScenePhase) {
        let active = phase == .active
        lifecycleState = active ? .active : (phase == .background ? .background : .inactive)
        evidence.setActive(active)
        frames.setActive(active)
        if running { monitor?.setActive(active) }
        checkpoint()
    }

    func memoryWarning() {
        evidence.resources.recordMemoryWarning()
        crumbs.record(category: "memory", message: "system-warning")
        checkpoint(memoryWarning: true)
    }

    private func checkpoint(memoryWarning: Bool = false) {
        let page = page, state = lifecycleState
        let footprint = evidence.resources.snapshot().last?.footprintBytes
        io.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.batch.flush(to: self.archive)
                try self.session?.checkpoint(state: state, page: page, footprintBytes: footprint,
                                             memoryWarning: memoryWarning)
            } catch { DispatchQueue.main.async { self.status = "会话保存失败：\(error.localizedDescription)" } }
        }
    }

    private func refresh() {
        let memory = evidence.resources.memorySummary()
        let growth = memory.growthBytes.map { String(format: "%+.1f MiB", Double($0) / 1_048_576) } ?? "—"
        memoryText = "窗口峰值 \(megabytes(memory.peakBytes)) · 变化 \(growth) · 警告 \(memory.warnings)"
        if let sample = evidence.resources.snapshot().last {
            cpuText = sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "等待差分"
        }
        let summary = frames.summary()
        frameText = "\(summary.sampleCount) 个间隔 · 长间隔 \(summary.longIntervals) · P95 " +
            (summary.p95Interval.map { String(format: "%.1f ms", $0 * 1000) } ?? "—")
        if let stats = monitor?.deliveryStatistics {
            lossText = "保留 \(stats.retainedEvents) · 丢弃 \(stats.droppedEvents) · 合并 \(stats.coalescedUpdates)"
        }
        io.async { [weak self] in
            guard let self = self else { return }
            do {
                let count = try self.systemArchive.load().count
                DispatchQueue.main.async { self.systemPayloadCount = count }
            } catch { DispatchQueue.main.async { self.status = "系统档案读取失败：\(error.localizedDescription)" } }
        }
        for observation in lifetime.check() {
            status = "\(observation.label)：\(observation.stillAlive ? "仍存活，检查持有关系" : "已释放")"
        }
    }

    private func begin(_ name: StaticString) -> Bool {
        guard !experimenting else { return false }
        experimenting = true
        activeExperiment = evidence.spans.begin(name)
        crumbs.record(category: "experiment", message: String(describing: name))
        status = "正在运行：\(name)"
        return true
    }

    private func finish(_ text: String) {
        evidence.spans.end(activeExperiment)
        activeExperiment = nil
        experimenting = false
        status = text
    }

    func compute() {
        guard begin("cpu-work") else { return }
        if optimized {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                burnCPU(seconds: 0.6)
                DispatchQueue.main.async { self?.finish("后台计算完成，检查主线程对照") }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                burnCPU(seconds: 0.6)
                self.finish("主线程计算完成")
            }
        }
    }

    func sleep() {
        guard begin("main-sleep") else { return }
        recordSmokeState("stall-scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Thread.sleep(forTimeInterval: 0.6)
            self.finish("主线程等待完成，比较 CPU 与计算实验")
            self.recordSmokeState("stall-finished")
        }
    }

    func lockWait() {
        guard begin("lock-contention") else { return }
        let lock = NSLock()
        if optimized {
            DispatchQueue.global().async {
                lock.lock()
                Thread.sleep(forTimeInterval: 0.6)
                lock.unlock()
                DispatchQueue.main.async { self.finish("通过异步完成通知避免主线程等待") }
            }
        } else {
            DispatchQueue.global().async {
                lock.lock()
                DispatchQueue.main.async {
                    lock.lock(); lock.unlock()
                    self.finish("锁等待完成；锁拥有人需用 Instruments 验证")
                }
                Thread.sleep(forTimeInterval: 0.6)
                lock.unlock()
            }
        }
    }

    func decodeImages() {
        guard begin("image-decode") else { return }
        let work = {
            let result: UIImage? = autoreleasepool {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 2048))
                let data = renderer.pngData { context in
                    UIColor.systemIndigo.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
                    for index in 0..<200 {
                        UIColor(hue: CGFloat(index) / 200, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                        context.fill(CGRect(x: (index * 43) % 2048, y: (index * 71) % 2048,
                                            width: 180, height: 180))
                    }
                }
                var result: UIImage?
                for _ in 0..<4 {
                    autoreleasepool {
                        if let source = CGImageSourceCreateWithData(data as CFData, nil),
                           let cg = CGImageSourceCreateImageAtIndex(source, 0,
                               [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                            result = UIImage(cgImage: cg)
                        }
                    }
                }
                return result
            }
            DispatchQueue.main.async {
                self.image = result
                self.finish("图片生成与解码完成；优化版把整段工作移到后台")
            }
        }
        if optimized { DispatchQueue.global(qos: .userInitiated).async(execute: work) }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work) }
    }

    func mainActorBurst() {
        guard begin("main-actor-burst") else { return }
        if optimized {
            DispatchQueue.global(qos: .userInitiated).async {
                burnCPU(seconds: 0.48)
                DispatchQueue.main.async {
                    self.listRevision += 1
                    self.finish("后台批处理后只更新一次 UI")
                }
            }
        } else {
            burstRemaining = 80
            for _ in 0..<80 {
                Task { @MainActor in
                    burnCPU(seconds: 0.006)
                    self.listRevision += 1
                    self.burstRemaining -= 1
                    if self.burstRemaining == 0 { self.finish("80 个 MainActor 短任务完成") }
                }
            }
        }
    }

    func memoryCycle() {
        guard begin("memory-retention") else { return }
        if optimized {
            autoreleasepool {
                let object = RetainedModel()
                lifetime.expectRelease(object, label: "临时模型", after: 2)
            }
            finish("临时模型已离开作用域，2 秒后检查")
        } else if retained.count < 8 {
            let object = RetainedModel()
            retained.append(object)
            lifetime.expectRelease(object, label: "被数组持有的模型", after: 2)
            retainedCount = retained.count
            finish("保留 \(retainedCount) 个 8 MiB 模型，上限 8 个")
        } else {
            finish("已达到实验上限；请释放后重试")
        }
    }

    func releaseMemory() {
        retained.removeAll()
        image = nil
        retainedCount = 0
        status = "已释放示例持有；物理内存不承诺立即回落"
    }

    func backpressure() {
        guard begin("slow-consumer") else { return }
        slowConsumer = true
        repeatStall(remaining: 10)
    }

    private func repeatStall(remaining: Int) {
        guard remaining > 0 else {
            finish("十次短卡顿完成，观察队列丢弃与合并计数")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Thread.sleep(forTimeInterval: 0.32)
            self.repeatStall(remaining: remaining - 1)
        }
    }

    func export() {
        guard !exporting else { return }
        exporting = true
        let spans = evidence.spans.snapshot(), resources = evidence.resources.snapshot()
        let frameSamples = frames.snapshot(), summary = frames.summary()
        let delivery = monitor?.deliveryStatistics
        let lost = monitor?.droppedProbeIntervals ?? 0
        let droppedSystem = metricKit?.droppedPayloads ?? 0
        let droppedSpans = evidence.spans.droppedSpans
        io.async {
            do {
                try self.batch.flush(to: self.archive)
                let bundle = DiagnosticBundle(events: try self.archive.load(), spans: spans, resources: resources,
                    frames: frameSamples, frameSummary: summary, session: self.session?.current,
                    previousSession: self.session?.previous, systemPayloads: try self.systemArchive.load(),
                    delivery: delivery, droppedProbeIntervals: lost,
                    droppedBatchEvents: self.batch.droppedEvents,
                    droppedSystemPayloads: droppedSystem, droppedSpans: droppedSpans)
                let file = self.root.appendingPathComponent("Pulse-diagnostics.json")
                try bundle.write(to: file)
                DispatchQueue.main.async { self.shareURL = file; self.exporting = false }
            } catch {
                DispatchQueue.main.async {
                    self.status = "导出失败：\(error.localizedDescription)"
                    self.exporting = false
                }
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        flushTimer?.cancel()
    }
}

private func burnCPU(seconds: TimeInterval) {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    var value = 0.25
    while ProcessInfo.processInfo.systemUptime < end {
        value = sin(value + 0.0001)
    }
    withExtendedLifetime(value) {}
}

private func megabytes(_ value: UInt64?) -> String {
    value.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "—"
}

struct ContentView: View {
    @StateObject private var model = DemoModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showingShare = false
    @State private var smokeStarted = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationView { lab.navigationTitle("Pulse 实验室") }
                .tabItem { Label("实验", systemImage: "waveform.path.ecg") }.tag(0)
            NavigationView { timeline.navigationTitle("事件时间线") }
                .tabItem { Label("事件", systemImage: "clock") }.tag(1)
            NavigationView { health.navigationTitle("资源与证据") }
                .tabItem { Label("资源", systemImage: "chart.xyaxis.line") }.tag(2)
        }
        .onAppear {
            model.firstAppearance()
            beginSmokeIfReady()
        }
        .onChange(of: scenePhase) {
            model.lifecycle($0)
            beginSmokeIfReady()
        }
        .onChange(of: tab) { model.setPage(["实验室", "事件", "资源"][$0]) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.memoryWarning()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            beginSmokeIfReady()
        }
        .onChange(of: model.shareURL) { showingShare = $0 != nil }
        .sheet(isPresented: $showingShare, onDismiss: { model.shareURL = nil }) {
            if let url = model.shareURL { ShareSheet(url: url) }
        }
    }

    private func beginSmokeIfReady() {
        let requested = ProcessInfo.processInfo.arguments.contains("--pulse-smoke") ||
            ProcessInfo.processInfo.environment["PULSE_SMOKE"] == "1"
        guard requested, !smokeStarted else { return }
        guard UIApplication.shared.applicationState == .active else {
            model.recordSmokeState("waiting-for-active")
            return
        }
        smokeStarted = true
        model.recordSmokeState("experiment-requested")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.sleep() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { tab = 1 }
    }

    private var lab: some View {
        List {
            Section {
                Text(model.status).font(.callout)
                HStack {
                    Label(model.running ? "监控中" : "已停止", systemImage: model.running ? "record.circle" : "pause.circle")
                    Spacer()
                    Button(model.running ? "停止" : "开始") { model.running ? model.stop() : model.start() }
                }
                Toggle("使用优化版本", isOn: $model.optimized)
                    .disabled(model.experimenting)
            } footer: {
                Text("实验会有意制造短暂卡顿。每次只运行一个实验；事件界面在主线程恢复后刷新。")
            }
            Section("计算、等待与调度") {
                Button("CPU 计算 600 ms", action: model.compute)
                Button("主线程 sleep 600 ms", action: model.sleep)
                Button("锁等待 / 异步完成", action: model.lockWait)
                Button("MainActor 短任务 / 后台批处理", action: model.mainActorBurst)
            }.disabled(model.experimenting)
            Section("图片与内存") {
                Button("生成并解码 2048 px 图片", action: model.decodeImages).disabled(model.experimenting)
                Button("模型进入 / 退出（8 MiB）", action: model.memoryCycle).disabled(model.experimenting)
                Button("释放图片与模型", action: model.releaseMemory)
                Text("当前保留 \(model.retainedCount) / 8 个模型").foregroundColor(.secondary)
                if let image = model.image {
                    Image(uiImage: image).resizable().scaledToFit().frame(height: 160)
                }
            }
            Section("滚动与交付压力") {
                NavigationLink("列表更新实验") { ListExperiment(model: model) }
                Button("十次卡顿 + 慢消费者", action: model.backpressure).disabled(model.experimenting)
                Toggle("事件回调延迟 2 秒", isOn: $model.slowConsumer)
                Text(model.lossText).font(.caption.monospaced())
            }
        }
    }

    private var timeline: some View {
        List {
            if model.events.isEmpty {
                Text("还没有卡顿事件。先运行主线程等待或计算实验。").foregroundColor(.secondary)
            }
            ForEach(model.events) { event in
                NavigationLink(destination: EventDetail(event: event)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(String(format: "%.0f ms", event.duration * 1000)).font(.headline.monospacedDigit())
                            Spacer()
                            Text(event.phase.rawValue).font(.caption)
                        }
                        Text(event.evidence?.context.page ?? "旧版事件").font(.subheadline)
                        Text(event.id.uuidString.prefix(8)).font(.caption.monospaced()).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var health: some View {
        List {
            Section("资源窗口") {
                Text(model.memoryText)
                Text("进程 CPU：\(model.cpuText)")
                Text("100% 表示一个 CPU 核心，可超过 100%。").font(.caption).foregroundColor(.secondary)
            }
            Section("当前页面刷新节奏") {
                Text(model.frameText)
                Text("这是 DisplayLink 回调节奏的代理指标，不代表 GPU 耗时或系统 Hitch 比率。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("可靠性") {
                Text(model.lossText)
                Text(model.sessionText)
                Text("系统诊断档案：\(model.systemPayloadCount)")
                Text("MetricKit 由系统异步交付；没有载荷不代表没有问题。").font(.caption).foregroundColor(.secondary)
            }
            Section {
                Button(model.exporting ? "正在导出…" : "导出诊断包", action: model.export)
                    .disabled(model.exporting)
            } footer: {
                Text("导出包含事件标签、设备环境和系统原始诊断。示例不自动上传数据。启动 Span 只测初始化至首次出现，不等于系统启动耗时。")
            }
        }
    }
}

private struct ListExperiment: View {
    @ObservedObject var model: DemoModel
    var body: some View {
        List {
            Section {
                Toggle("后台批处理", isOn: $model.optimized).disabled(model.experimenting)
                Button("运行列表更新", action: model.mainActorBurst).disabled(model.experimenting)
                Text("边滚动边观察，比较两种更新方式。")
            }
            ForEach(0..<160, id: \.self) { index in
                HStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hue: Double(index % 20) / 20, saturation: 0.65, brightness: 0.9))
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading) {
                        Text("性能样本 \(index)")
                        Text("更新批次 \(model.listRevision)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("列表更新")
        .onAppear { model.setPage("列表更新") }
        .onDisappear { model.setPage("实验室") }
    }
}

private struct EventDetail: View {
    let event: HangEvent
    var body: some View {
        List {
            Section("事件") {
                Text(event.id.uuidString).font(.caption.monospaced())
                Text("状态：\(event.phase.rawValue)")
                Text(String(format: "持续 %.1f ms", event.duration * 1000))
                Text(event.endedAtUptime == nil ? "时长为观测上界 / 尚无结束边界" : "已记录 RunLoop 结束边界")
                Text("页面：\(event.evidence?.context.page ?? "unknown")")
                Text("来源：\(event.evidence?.source ?? "legacy")").font(.caption)
            }
            Section("发现时的业务轨迹") {
                ForEach(Array(event.breadcrumbs.enumerated()), id: \.offset) { _, crumb in
                    Text(String(format: "%+.0f ms  ", (crumb.uptime - event.startedAtUptime) * 1000) +
                         "\(crumb.category) · \(crumb.message)").font(.caption.monospaced())
                }
            }
            Section("业务区间（时间相关性，不代表因果）") {
                ForEach(event.evidence?.spans ?? []) { span in
                    VStack(alignment: .leading) {
                        Text(span.name)
                        Text(span.duration.map { String(format: "%.1f ms", $0 * 1000) } ?? "进行中")
                            .font(.caption.monospaced())
                    }
                }
            }
            Section("资源趋势") {
                let samples = event.evidence?.resources ?? []
                if samples.isEmpty { Text("此事件没有资源样本") }
                else {
                    ResourceSparkline(samples: samples).frame(height: 110)
                    ForEach(Array(samples.suffix(12).enumerated()), id: \.offset) { _, sample in
                        Text(String(format: "%+.1f s  ", sample.uptime - event.startedAtUptime) +
                             "\(megabytes(sample.footprintBytes)) · CPU " +
                             (sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"))
                            .font(.caption.monospaced())
                    }
                }
            }
        }.navigationTitle("诊断现场")
    }
}

private struct ResourceSparkline: View {
    let samples: [ResourceSample]
    var body: some View {
        GeometryReader { geometry in
            let values = samples.compactMap { $0.footprintBytes.map(Double.init) }
            let low = values.min() ?? 0
            let high = max(low + 1, values.max() ?? 1)
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) / CGFloat(max(1, values.count - 1)) * geometry.size.width,
                                        y: geometry.size.height * (1 - CGFloat((value - low) / (high - low))))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(Color.indigo, lineWidth: 2)
        }.accessibilityLabel("内存趋势，数值见下方列表")
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
