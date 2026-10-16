# Pulse

一个可解释、可复现的 iOS 稳定性与性能诊断实验室。

从主 RunLoop 忙碌区间出发，把卡顿与业务轨迹、Span、CPU/内存趋势放到同一个现场，
再用对照实验验证。系统诊断保留独立来源，代理指标不冒充根因。

作者 **gy** · MIT · iOS 15+ / macOS 12+ · Swift Package · Objective-C 探针 + Swift 诊断层

## 运行

Mac 上运行：

    swift test --enable-code-coverage
    python3 -m unittest discover -s Tools -p 'test_*.py' -v

Xcode 打开 Examples/PulseExample.xcodeproj，运行 PulseExample。
示例提供“实验 / 事件 / 资源”三个页面，以及显式诊断包导出。
真机性能对比请使用 Release，关闭调试器，并记录完整环境。

## 能力

| 模块 | 已实现 | 解释边界 |
|---|---|---|
| HangMonitor | 忙碌检测、已结束区间补发现、结束边界、取消、运行代次 | RunLoop 是响应性的代理指标 |
| 有界交付 | 按 ID 合并、终态容量预留、丢弃/合并统计 | 不保证每个状态都有一次 callback |
| 现场 | 会话/页面、冻结 Breadcrumb、父子 Span、signpost、资源趋势 | 时间重叠不代表因果 |
| ResourceMonitor | 进程 CPU 差分、phys_footprint、热状态、窗口峰值/增长 | 低频采样可能漏过瞬时峰值 |
| FrameMonitor | 页面窗口、动态刷新预算、长间隔、P95、超额时间比例 | DisplayLink cadence，不等于 GPU/hitchTimeRatio |
| 生命周期 | 弱对象观察、内存警告、上次会话检查点 | 未完成会话的退出原因保持 unknown |
| MetricKit | 有界接收、原始载荷、类型标记、摘要、内容去重 | 系统异步交付，不强行关联本地事件 |
| 存储 | 批量 upsert、条数/字节/年龄限制、损坏保留、诊断包 | 不承诺断电或系统强杀前必定落盘 |
| 实验与回归 | CPU/锁/图片/列表/内存/MainActor/背压对照，基准比较工具 | 真机性能结果需要实际采集 |

## 最小接入

    let breadcrumbs = BreadcrumbBuffer(capacity: 64)
    let monitor = HangMonitor(breadcrumbs: breadcrumbs) { event in
        // 后台回调，按 event.id 更新。事件可能直接是 recovered。
        print(event.id, event.phase, event.duration)
    }
    monitor.start() // 主线程；持有 monitor
    breadcrumbs.record(category: "navigation", message: "open-detail")

完整证据通过 EvidenceRecorder 注入；资源监控独立 start/stop。
详见 [接入和迁移](Documentation/integration.md)。

## 实验路径

1. 主线程计算与 sleep：比较相同卡顿时间下的资源表现。
2. 锁等待与异步完成：理解检测证据和锁归因的区别。
3. 图片/列表：切换优化版本，观察调度与更新频率的变化。
4. 模型保留/释放：看窗口趋势，验证弱观察不会持有对象。
5. 慢消费者：验证队列上限、合并和丢弃计数。
6. 前后台切换：确认暂停时间没有被合成卡顿。

每次实验包含操作、观测信号和 Instruments 对照，见 [实验协议](Documentation/experiments.md)。
示例会有意制造短暂卡顿，UI 在主线程恢复后才刷新。

## 验证与限制

CI 执行 macOS 测试、Python 工具测试、iOS Simulator 构建、启动和事件持久化检查，
保存示例截图。当前没有伪造的真机 CPU/能耗数字；设备验证状态见 [验证范围](Documentation/validation.md)。

不捕获 Crash、任意线程调用栈，不自动上传，不推断 OOM。嵌套 RunLoop、调试器暂停、
自定义 mode 和调度饥饿仍可能影响检测。用户标签必须脱敏。
停止后已出队的 handler 仍可能完成；所有磁盘操作应放在后台。

[设计与线程](Documentation/design.md) · [路线图](Documentation/roadmap.md) · [变更](CHANGELOG.md)
