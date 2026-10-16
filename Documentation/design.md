# 检测、证据和交付

## RunLoop 探针

Objective-C probe 只在 os_unfair_lock 内读写 POD 状态。beforeWaiting/exit 结束忙碌区间，
其他 activity 在空闲状态下开启区间。忙碌时间是代理指标，不能代表精确触摸延迟、
绘制完成时间或线程根因。嵌套 RunLoop 仍可能拆分外层工作，调试器暂停和调度延迟也会影响结果。

除了当前状态，probe 使用固定 64 项环形缓冲记录超过阈值的已结束区间。
短于阈值的区间不占历史容量。drain 在锁内复制 POD、清空待取历史，在锁外创建对象。
溢出保留最新区间，累计丢失数由 HangMonitor.droppedProbeIntervals 暴露。

因此，250 ms 阈值、50 ms 采样时，1.01–1.27 秒的忙碌区间即使在采样中没有观察到
达到阈值的 busy 状态，也能在 1.30 秒检查时产生 recovered。后台队列长期得不到调度、
超过历史容量或探针未覆盖的 RunLoop 模式仍可能漏报。

时钟统一使用 systemUptime。事件内的 uptime 只允许在同一运行会话内关联，不能跨进程、
设备或系统诊断窗口按相近数字进行连接。

## 事件状态

- detected：采样时仍忙碌。duration 是当时已观察到的忙碌时长。
- recovered：观察到区间结束；有 endedAtUptime 时使用 probe 的结束边界。
- cancelled：应用失活打断了本次测量，不代表已经恢复，也不合成后台卡顿。

后台补发现的完整区间可以只产生一个 recovered。首次发现的 breadcrumbs/context 冻结；
恢复时合并有界 Span/资源现场。历史补发现事件的快照只能反映“采样时仍保留的证据”，
无法追溯已经被环形缓冲淘汰的现场。

若正在跟踪的区间结束记录因历史溢出丢失，恢复退化到采样上界，并通过
durationBasis = observation-upper-bound 标识。未声称精确结束时间。

生命周期切换清空 probe/engine；重复 setActive 同一值不重置事件。
stop/start 的运行代次使旧 timer handler 失效。所有生命周期 API 都在主线程调用。

## 有界交付

EventDelivery 默认最多保留 64 个事件 ID；示例设为 2 以便观察背压。

- 同 ID 更新合并为最新记录，recovered 自带原始发现现场。
- 已交付 detected 的事件保留一个容量位置，直到 terminal 更新。
- 满载拒收新事件；正在跟踪且被拒收的 detected 的后续恢复也丢弃。
- 后台 drain 同一时刻仅有一个任务，用户 handler 在所有锁外执行。
- 暴露 retained/dropped/coalesced/invalidated 计数。

这是“按 ID 更新最新状态”的订阅契约，不保证每个状态转换都交付。调用方不能依赖
detected/recovered 成对回调来计算事件数量。stop 丢弃尚未出队的记录；已经出队的
callback 是 in-flight，可能在 stop 返回后执行。stop 不等待用户代码，避免互相等待死锁。
事件被 stop 丢弃后，调用方已收到的 detected 不会伪装成 recovered。

## 现场与资源

EvidenceRecorder 组合会话/页面标签、SpanRecorder 和 ResourceMonitor。
资源采样独立启动，默认每秒一次、120 个样本；不随 50 ms 卡顿检查频率采集。
snapshot 提取事件开始前最多 5 秒至当前采样时刻的可用数据。恢复时补充到恢复采样时刻；
不保证额外的恢复后观察窗口。

进程 CPU 使用 getrusage 的累计用户/系统 CPU 时间差除以单调时间差；100% 代表一个核。
内存使用 task_vm_info.phys_footprint，失败时为 nil。峰值/增长是当前缓冲窗口内的值，
不是进程全生命周期峰值。热状态作为背景信息。CPU 和内存相关性不能单独证明根因。

Span 默认最多 64 个进行中、128 个已完成，显式 parentID 适用于跨队列业务。
每个接受的 Span 对应一个 OSSignposter interval；结束幂等。容量拒收返回 nil，
调用方仍可安全调用 end(nil)。静态名称应描述操作，不应包含业务数据。

## 存储和导出

EventArchive 保留原有 JSON 数组格式，可读取旧版缺少可选证据字段的记录。
默认 100 个事件、4 MiB、7 天；无墙钟上下文的旧记录只按容量淘汰。
年龄淘汰发生在写入时；load 不修改档案。批量 upsert 一次编码写入，字节超限淘汰最老事件。
单条记录超预算会抛错，旧文件保留。损坏文件不会被自动覆盖。每个 URL 只能有一个实例。

EventBatch 提供最多 100 个 ID 的合并缓冲，满载淘汰最早记录并计数。示例每秒 flush，
失败保留批次以便重试。会话检查点和导出也先 flush。进程突然退出可能丢失尚未写入的批次；
原子替换不承诺断电/fsync 耐久性。iOS 使用首次解锁后可访问的文件保护级别。

诊断包 schemaVersion=1，显式导出，默认最多 16 MiB；超限失败而不静默丢证据。
包内分别记录探针、交付队列、批次、Span 和系统载荷各阶段的丢弃计数。
原始 MetricKit 载荷以 Data/Base64 存入 JSON，保持系统来源，不按时间强行绑定事件。

## 平台与线程

iOS 15+、macOS 12+。FrameMonitor 和 MetricKitRecorder 仅 iOS 可用。
macOS 的 HangMonitor 不自动读取 AppKit 生命周期，宿主应主动 setActive。
本包不是 Crash 捕获器、不采集任意线程栈、不包含上传或符号化服务。
