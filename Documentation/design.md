# 检测证据与定位证据分开

Objective-C probe 使用 CFRunLoopObserver 和 os_unfair_lock，采集忙碌区间的开始时间。
beforeWaiting/exit 结束忙碌区间；活动重新开始时记录 systemUptime。这个时钟不受墙钟改动影响。
后台 DispatchSourceTimer 只读取快照，不向主线程同步派发任务。

状态机输入：当前单调时间、busySince、应用活跃状态和 Breadcrumb 快照。
超过阈值产生 detected；同一 busySince 不重复报告；忙碌区间改变时产生 recovered。
前后台切换清空 probe 和状态机。状态机只处理值，因此阈值、去重与恢复不需要真实 sleep 测试。

交付使用单独串行队列，不在锁内执行 handler。业务持有 monitor，timer 仅弱引用它。
start/stop/setActive 必须主线程调用；UIKit 生命周期通知也在主线程处理。
反复 start/stop 幂等，deinit 取消 timer、移除通知和 observer。

EventArchive 使用临时文件替换，但不承诺系统崩溃或断电耐久性。同 ID 更新代替新增，
损坏的旧档案会抛错并保留，避免自动覆盖证据。每个文件只使用一个 archive 实例。

MetricKit JSON 是独立证据，不能凭相近时间就声称与某次本地事件精确关联。
参考：https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app
