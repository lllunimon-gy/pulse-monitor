# Pulse

观察主 RunLoop 的忙碌区间，在超过阈值时记录事件与最近的业务轨迹。
它回答“什么时候开始无法响应、当时正在做什么”，不会伪造阻塞线程的调用栈。

作者 **gy** · MIT · iOS 15+ / macOS 12+ · Objective-C RunLoop probe + Swift 状态机

## 运行

Mac 上 `swift test`；Xcode 打开 `Examples/PulseExample.xcodeproj`。
示例有主线程阻塞、主线程锁等待、后台工作和正常状态四种对照。
事件检测在后台，UI 要等主线程恢复才能刷新。

```swift
let breadcrumbs = BreadcrumbBuffer(capacity: 64)
let monitor = HangMonitor(breadcrumbs: breadcrumbs) { event in
    // 私有串行交付队列；可写入 EventArchive，更新 UI 时切主线程。
    print(event.id, event.phase, event.duration)
}
monitor.start() // 主线程，持有 monitor
breadcrumbs.record(category: "navigation", message: "open-detail")
```

## 行为

默认阈值 250 ms，检查间隔 50 ms，可配置。一次卡顿只报告一次 detected，
恢复时发送同 ID 的 recovered。进入非活跃状态会丢弃进行中事件，不合成一个很长的后台卡顿。
Breadcrumb 使用固定容量环形缓冲区，字段长度受限；事件档案按 ID 更新并限制条数。
MetricKitRecorder 可接收系统诊断 JSON，交付时间不由本库控制。

## 限制

RunLoop 忙碌时间是代理指标，不等于每次用户感知延迟；嵌套 RunLoop、调试器暂停、调度延迟会影响判断。
recovered 的时长是下次采样时观察到的上界，不是精确的阻塞结束时间。
停止后已排队的回调仍可能到达；handler 必须轻量，慢 handler 会让交付队列积压。
不捕获 Crash、OOM、任意线程调用栈，不上传数据。Breadcrumb 不应包含请求体、token 或用户内容。
MetricKit 回调中的处理与存储队列由调用方安排。

[状态机与线程](Documentation/design.md) · [实验](Documentation/experiments.md) · [验证](Documentation/validation.md)
