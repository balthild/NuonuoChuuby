# 诊断与可观测性

## 本仓库的老大难：失败从外面看不见

她画在所有东西上面，所以以下几种失败在屏幕上一模一样：

- 「图说被盖住」与「什么都没盖她」；
- 「改名被吃掉」与「她压根没看见文件」；
- 「进食被遗弃」与「她压根没去」；
- 「幽灵摆错位」与「索引读取失败」。

**对策：每一种新的静默失败都配一个诊断事件**，不要只靠代码路径推理。
新增事件时把能区分的字段一起打上（例如 `Size` 是幽灵路径的判别字段，
`Live`/`Resolved` 是锚点路径的判别字段）。

## 日志开关（用户要求的设计）

需求：菜单里加开关，只在启用时写日志；**开关这个操作永远写入**；
**关闭时把已提交未写的日志写进去，不要丢弃**。

两个需要澄清的前提（当时回答了用户）：

1. **没有中央节流。** `Common/ChangeGate.swift` 只在 `PetController` 的 3 处热路径逐点使用。
   「45 → 26.3 µs」是**去掉每行的 `stat`**，不是节流。
2. **没有「已提交但未写」的日志可丢**：`append` 每行同步 `write(2)` 到 fd，
   调用方与文件描述符之间**没有队列/用户态缓冲**。
   真正的风险是**顺序**：「关闭」那行必须在标志改动**之前**写，否则它自己就是第一条被丢掉的。

实现要点：

- `DiagnosticsLog.isEnabled`（`private(set)`）；`append` 里 `guard isEnabled`；
  抽出 `writeLineLocked`（锁已持有时写）。
- `setEnabled(_:)` 是**唯一**改动点，且
  `if enabled { isEnabled = true; write(enabled) } else { write(disabled); isEnabled = false }`
  —— **顺序就是承重结构**。
- **启动不算「关闭这个操作」**：`configure(..., enabled:)` 直接设初值、不写行，
  所以「关闭状态下启动」一行都不写（连 `ProcessStarted` 都没有）。
  为此外层把设置加载提到 `configure` 之前。

## 事件行的时间戳

所有 `write()` 行都有 `[yyyy-MM-dd HH:mm:ss.SSS]` 前缀，但 event 行原来只带 `session=`
（= 启动时刻），所以「这个文件活了多久」「读到删除隔了多久」这类问题**从日志里量不出来** ——
两个线上问题都卡在这里，只能另写探针。

- 成本实测：`DateFormatter.string` = **0.9 µs/次**，对 26.3 µs 的行是 **+3.4%**；
  手写格式化只快一点，不值得。直接用现成的 `timestamp()`。
- `session=` 已删除（全仓库只有生产、无消费者）—— 它本来就是从上游 C# 移植过来的，
  上游也没有每行时间。
- 顺带补了 `IconAppeared` / `IconNeverAppeared`，把一次文件的一生闭成环：

```
04.737 IconAppeared   Waited="0.26"        ← Finder 发布延迟，应用内活体测得
05.315 DeletionIcons  Read="ok(21)" Live="1" Resolved="1" SnapshotAge="0.6"
06.125 DeletionDetected
06.127 GhostShown     Anchor="1541,892" Size="56"
```

## 「数量」类日志要门控在完整结论上

`DesktopIconIndex` 曾只在数量变化时打 `Icons="N"`，而且 `0` 把三种完全不同的原因糊在一起
（AX 未授权 / Finder 未运行 / 找不到图标容器）；幽灵摆错位时分不清「读失败」与
「读成功但名字不在里面」。

现在 `Reader` 返回 `IconReading { icons([...]); unavailable(Failure) }`，
`Failure = accessibilityNotTrusted | finderNotRunning | noIconContainer`，
门控键包含整个结论（可读性、数量、失败原因），所以「空桌面」和「没授权」不再长得一样。

删除路径额外打一行 `DeletionIcons`：`Read`/`Asked`/`Live`/`Resolved`/`Prefix`/`SnapshotAge`。
- `Live` = 从这次**活读**里拿到的名字数；
- `Resolved` = 最终有锚点的数量（含回落上一份快照）；
- `SnapshotAge` = 回落所用快照的年龄；
- `Prefix` = 没找到但别的名字以「它 + "."」开头的数量（隐藏扩展名不匹配的迹象）。

探针实测：Finder 的 `kAXDescription` **带扩展名**，20 个图标与磁盘文件名 20/20 一致，
所以 `Prefix` 本机恒为 0 —— 该假设**已排除**。

## 每帧路径上的事件要审

见 `performance.md`：一条事件 26.3 µs，60 Hz 就是 0.16%/s 的固定开销。
`AirborneCaught` 曾每帧写，累积上千行。**用既有的 `ChangeGate` 折叠重复事件。**

## 用得上的事件（排查入口）

`StatusHeartbeat`（状态/位置/支撑，周期快照）、`StateTransition`、`FallStarted`
（`fallReason` 的唯一出口）、`SuspensionChanged`、`PetPresenter`（`Kind=panel|overlay`，
用来确认哪个渲染器在跑）、`MealRequeued`、`MealsDiscarded`、`DeletionDetected`、
`DeletionIgnored`、`GhostShown`、`PatrolInterrupted`、`PerchCovered`、`DragProfile`、
`LoggingEnabled`/`LoggingDisabled`。

**「她浮在半空」的排查起点**：`StatusHeartbeat` 里 `Support="none"` 加上一个「着地」状态，
就是新 bug 的形状（参数化支撑之前，这种状态根本不可表达）。
