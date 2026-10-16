# 接入指南

## 最小卡顿检测

    let breadcrumbs = BreadcrumbBuffer(capacity: 64)
    let monitor = HangMonitor(breadcrumbs: breadcrumbs) { event in
        // 后台私有串行队列：按 event.id upsert。
        // 回调可能只收到自带现场的 recovered。
    }
    monitor.start() // 主线程；宿主需持有 monitor
    breadcrumbs.record(category: "navigation", message: "open-detail")

需要精确掌握“回调收到时”与“探针观察到时”的差异，应单独记录消费时间；
observedAtUptime 是检测队列的时间，不是 UI 更新时间。

## 完整现场

    let evidence = EvidenceRecorder(sessionID: UUID(), deviceModel: "your-device-class")
    evidence.setPage("product-detail")
    evidence.resources.start()
    let monitor = HangMonitor(evidence: evidence) { event in
        // 使用有界批次存储或消费，不在主线程落盘。
    }
    monitor.start()

    let parent = evidence.spans.begin("load-detail")
    let child = evidence.spans.begin("decode-images", parentID: parent)
    // 显式跨队列传递 token。
    evidence.spans.end(child)
    evidence.spans.end(parent)

ResourceMonitor 独立 start/stop；HangMonitor 会同步 EvidenceRecorder 的活跃状态。
若只使用资源监控，宿主自行调用 setActive。不要让多个 monitor 争用同一 EvidenceRecorder 的生命周期。
Span 的名称是 StaticString；页面/Breadcrumb 等动态字符串仍需由接入方保证没有敏感信息。
标签按 UTF-8 字节截断并保留完整编码：category 64、message 256、页面/Span/对象名称 128 字节。
不默认记录 URL、请求体、用户 ID 或 token。

## 批量落盘

    let archive = EventArchive(url: eventURL, limit: 100, maxBytes: 4 * 1024 * 1024)
    let batch = EventBatch(capacity: 100)
    // handler:
    batch.record(event)
    // 调用方后台队列每秒，或在导出/生命周期检查点：
    try batch.flush(to: archive)

EventBatch 的满载淘汰数与 HangMonitor 的交付丢弃数是不同阶段，需要分别观察。
停止前后是否 flush 由宿主决定。iOS 进入后台不保证异步磁盘写一定有机会完成，
对更强持久化要求应由宿主管理后台任务时间预算。

## 刷新节奏

    let frames = FrameMonitor()
    frames.start(page: "feed-scroll") // 主线程
    // 在明确的页面/滚动区间末尾读取：
    let report = frames.summary()
    frames.stop()

FrameMonitor 不自动监听生命周期；宿主在场景切换时 setActive。
多个 scene 应各自管理窗口，并为共享主线程的 Hang 数据提供明确上下文。
示例是单窗口教学程序，并不实现多窗口归属推断。

## 会话和系统证据

SessionRecorder 在调用方后台串行队列初始化、checkpoint 和读取。
它保存“上次最后一次可靠写入的状态”。unknown 不能转换为 OOM/Crash。
不要把 willTerminate 当成所有结束路径的可靠通知。

MetricKitRecorder(archive:onError:) 在主线程 start/stop，载荷在最多八个待处理项的后台队列处理。
超额丢弃有 droppedPayloads 计数；已经接受的载荷可以在 stop 后落盘。
MetricKitArchive 按类型和规范化 JSON 的 SHA-256 去重，默认 10 条/4 MiB，
单载荷 512 KiB。超预算抛错，不静默截断原始证据。
结构摘要只识别已知顶层诊断数组，未知字段原样保留。它不是完整调用栈解析或符号化器。

当前适配器保留 iOS 15 的 MXMetricManagerSubscriber 接口。
较新 SDK 对部分类型提供新的 API，迁移前需要在对应 SDK/设备验证可用性；
当前不宣称实现新 API 的全部指标。系统数据与本地事件只并列展示，不按时间强行配对。

## 0.1 → 0.2 行为变化

- HangPhase 新增 cancelled，穷举 switch 需更新。
- 交付按 ID 合并，历史补发现可只有 recovered，不再保证两次 callback。
- 有结束边界时 duration 使用区间结束；旧档案仍按上界理解。
- MetricKitRecorder 的 receive 现在在私有后台队列；更新 UI 需切主线程。
- 档案读取保留旧格式，新字段均可缺省；新版本新增字节预算，超预算会抛错。
