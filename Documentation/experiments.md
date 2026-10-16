# 可复现性能实验

使用真机 Release 构建，先关闭调试器连接。记录设备/系统、工具链、提交 SHA、输入规模、
监控配置及原始 Instruments 结果。每组至少重复五次；先预热，再交错运行基线和候选组。
控制充电、低电量模式、热状态和其他前台活动；不要用模拟器数据证明能耗或真机收益。

## 操作与对照

| 实验 | 基线操作 | 优化/对照 | 查看信号 | Instruments 对照 |
|---|---|---|---|---|
| CPU 工作 | 主线程运行 600 ms | 后台执行同样工作 | Hang、CPU、业务 Span | Time Profiler / Hangs |
| sleep | 主线程等待 600 ms | 对照 CPU 实验 | 同样 Hang，CPU 未必高 | Thread State |
| 锁等待 | 后台持锁，主线程等待 | 后台结束后异步通知 | Hang、低 CPU 线索 | System Trace，检查实际锁拥有者 |
| 图片解码 | 主线程生成并解码 2048 px 图片四次 | 整段工作后台执行 | Hang、内存峰值、图片结果 | Allocations / Time Profiler |
| 列表更新 | 80 个 MainActor 短任务，各更新列表 | 后台计算，只更新一次 | 长刷新间隔、P95、交互情况 | Animation Hitches / SwiftUI |
| 模型生命周期 | 数组保留 8 MiB 模型，上限 8 个 | 临时模型离开作用域 | 弱观察、窗口内存趋势 | Memory Graph / Allocations |
| 慢消费者 | 十次 320 ms 卡顿，callback 等 2 s | 关闭 callback 延迟 | retained ≤ 2、drop/coalesce | Allocations / CPU |
| 生命周期 | 实验完成后前后台切换 | 持续前台 | 不合成后台长卡顿 | 设备日志与事件时间线 |

图片实验同时包含生成/编码和解码，当前 Span 测的是整个操作；不能据其总时长单独声称解码耗时。
内存实验是受控的强引用保留，不是制造未知泄漏。仍存活只意味着需要检查持有关系，
释放后 footprint 不一定立即回落。列表优化是示例工作调度变化，不是所有列表性能问题的修复。

## 检测边界

- 将 threshold/interval 改为 250/50 ms，构造 260 ms 区间，检查补发现 recovered。
- 使用 50/100 ms 采样对比延迟、probe 结束时间和回调交付延迟。
- 验证多个连续区间、嵌套 RunLoop、自定义 mode、调试器暂停和后台采样饥饿。
- 显式比较默认配置与容量故意很小的配置，检查丢失计数，不能把有损结果当成完整数据。
- 停止/重启期间，已经出队的 callback 可能完成，旧 timer 不能开启新事件。

## 流畅度和启动口径

FrameMonitor 是一次显式页面/交互窗口，capacity=600，报告窗口内 callback cadence。
它采用相邻刷新预算的较大值以降低刷新率下调的误报，不能精确归因 GPU、合成器或呈现帧。
切换页面、失活/恢复会重置窗口；不要把该值等同于系统 hitchTimeRatio。

示例的 example-init-to-first-appearance 仅测 DemoModel 初始化至首个 onAppear。
不覆盖 pre-main，不等于第一帧实际呈现，不等于系统冷启动。
业务接入时分别定义“内容可见”“首个交互可用”完成条件，再使用 Span 显式记录。

## 监控自身开销

分别测：全部关闭、仅 Hang、Hang+资源、全部开启四组。
默认示例每秒刷新 UI 和读取小型系统档案，它不是最小开销基准宿主。
用一个没有诊断 UI 的最小宿主测 SDK 本身的 CPU、唤醒、footprint 和文件写入；
对比采样 50/100 ms、资源 1/2 s，并记录事件数量。

## 回归工具

复制 Tools/benchmark-template.json，填入一个“越小越好”指标的至少五次实测值。
baseline/candidate 的 context 必须完全相同；commit 和 raw_artifact 用于追溯原始结果。
示例字段 monitoring 可以写 hang=50ms,resources=1s；input_size 写具体输入描述。

运行：
    python3 Tools/compare_benchmarks.py baseline.json candidate.json --relative-budget 0.10

默认比较中位数，增加超过 10% 返回退出码 1；输入不完整返回 2。预算是项目自定的筛查阈值，
不是统计显著性证明。零基线可显式设置 --absolute-budget，单位与输入一致。
该工具不替你采集 Instruments 数据，也不把缺失的真机测量替换成模拟数字。
