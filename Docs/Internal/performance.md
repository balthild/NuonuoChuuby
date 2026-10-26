# 性能：实测数据与方法

> 所有数字都是**某台机器某个时刻**的，只用来看比例和方向，不要当常量引用。

## 怎么测（先读这条，踩过的坑最多）

- **测量 CPU 时间，不是 wall time**：`getrusage` 每秒（user+sys），或用
  `CLOCK_THREAD_CPUTIME_ID` 归因到单次调用。
  一次窗口服务器查询的 wall time 主要是 `mach_msg` 等待，那不是我们的 CPU。
- **永远用 `make rerun` 测**（LaunchServices 路径）。直接 exec
  `Contents/MacOS/NuonuoChuuby` 会报 ~10–16%，而同一二进制正常启动是 28–38%。
  这个差异造成过好几轮错误结论。
- **紧循环微基准会撒谎**：循环里调 `setFrame` 测到 27 µs，因为 CoreAnimation 合并了提交；
  真实在 run-loop 轮次之间的成本是 230–310 µs。窗口服务器查询同理：循环里 25 µs，
  应用里约 300 µs。**永远不要相信窗口服务器/AppKit 调用的紧循环微基准。**
- **对比两个运行要有内部控制**：找出一个「不是你改的东西」的每帧函数，
  确认它被同等次数地执行（见 `rendering.md` 气泡那段）。
- **A/B 必须跨进程交替**：同一进程连跑 3 次只是精确估计「那一次启动」。
  实测同一条件的两个进程分别给出 +6.38/+6.44/+6.45 与 +4.45/+3.97 ——
  进程间方差足以把 0.85 pt 的假效应伪装成 13%。**交替启动**，并拿一个本该相同的启动做 sanity check。
- **提高 tick 率的改动必须测稳态/idle**：拖动被拖动本身的工作主导，会掩盖 idle 的增加。
- `top -l 1` 的进程百分比是 0；前两个采样也不准，第三个起才精确。滞后的形状是
  `100*s/(s+0.85)` 而不是平滑窗口。`ps -o %cpu` 与 `htop` 正确。
- xctrace 导出里**只有 Running 行**（没有 Blocked），所以**栈归因系统性低估阻塞型开销**
  （比如 `waitUntilExit()` 的 100 ms 卡顿）。这类开销只能靠 A/B 看出来。
- 采样计数**不能**当分母：便宜的符号被采样得更少，分母会跟着被测对象移动。
  用自己记的精确计数器（例如拖动结束时的 `DragProfile` 事件）。

### xctrace 导出解析

`xcrun xctrace record --template 'Time Profiler' --attach <pid>` 可用于归因，
但**排最内层帧会误导**：多数样本是分配器 / CoreFoundation / CA 提交的杂音，没有单一热点。
应当统计「样本的调用链**包含**符号 X」的占比。

导出 XML 有 id/`ref` 去重：第一行内联定义、后续行只给 `ref`。
**直接 grep 原始 XML 或逐行解析会只看到一行。** 必须先解析 `frame`/`backtrace`/`thread`/
`thread-state` 的 ref，再按样本聚合。`.build/traces/analyze.py`（按线程的 inclusive 调用链占比）
与 `chains.py`（导出某线程最重的调用链）就是这套工具。

## 时间预算

- idle / 走动 / 拖动：**4–5% / ~25% / 28–38%**（改进前）；盒内 idle 在 30 Hz 节流后 **3.4%**。
- `TODO.md` 原来那个 `< 0.5%` idle 预算**从未测量过**，来自原版 Windows 的数字，
  对 60 Hz 透明 overlay 不是现实目标。
- **debug ≈ release for idle CPU**：idle 成本是框架 + run loop + 两次窗口枚举，不是我们的 Swift。
  不要用「release 更快」解释 idle 成本。
- 非主线程成本 0.01–0.2%。旧说法「约 4 个百分点在 CoreAnimation 线程上」是错的。

## 热点与它们真实的量级

| 项 | 成本 | 备注 |
| --- | --- | --- |
| 窗口服务器单窗口读 | **~300 µs CPU**（应用内） | 紧循环只有 25 µs，见上；**已由私有读替代，46 µs** |
| 10 Hz 全量枚举（~25 窗口） | ~0.48 ms/次 ⇒ ~1.3% | 盒外 idle 的最大单项 |
| 30 Hz 盒内重读 | 1.3–1.6% 绝对 idle | 盒内 idle 的最大单项；**改为私有读后按 30 Hz × 46 µs 折算约 0.14%** |
| `setFrame` | 230–310 µs/次 | 只有移动时，不是 idle 成本 |
| 一条 `writeEvent` 日志 | **45.4 → 26.3 µs** | 去掉每行 `stat` 后 |
| 一次 AX 全量枚举（~21 图标） | ~11 ms | 主线程 |

窗口服务器读的**可信数字来自整个应用 A/B**：跳过 45 次读/秒省了 1.3–1.5 个点
⇒ **每次约 300 µs**（应用内探针说 70–120 µs，A/B 更可信）。

Swift 字典桥接在 `MacOSPlatform.windows` 里是 CF 等价物的 **20 倍**
（164 → 69 µs/次枚举，字段相同）。只影响 debug 构建的数字。

### 盒内重读的 30 Hz 节流

`isResting` 时盒子以 30 Hz 重读；读到移动就恢复逐帧。`x == previousBox` 对未移动的窗口是精确的
（CGWindowList 的矩形是整数），所以跳过的帧是真的静止帧。

实测（盒内、idle、11 个 `top -l` 采样、丢掉第一个）：debug 5.01/5.38 → **3.42**；
release 4.75 → **3.44**。15 Hz 只到 3.85，所以 30 Hz 用一半的延迟拿到约 80% 的收益。
**取 30。** 代价是「发现盒子移动最多晚 33 ms」以及随后一次追赶帧 —— 已明确接受。

### 单窗口活读改用私有 `CGSGetWindowBounds`（2026-10-26）

她站在窗口上或盒子内时，每帧要问「这个窗口的矩形现在在哪」。之前走
`CGWindowListCopyWindowInfo([.optionIncludingWindow])`，而它为了四个数字构建整份窗口描述。
改用私有 `CGSGetWindowBounds` 后（`Platform/WindowServerBounds.swift`，`dlopen` 解析、
失败即回落公有读）：

- **293 µs → 46 µs / 次**（trace 内 inclusive，见下），约 **6 倍**。
- 盒内 idle：**2.87 → 2.19% 单核**（−0.69 pt，**−24%**）。两轮范围不重叠。
- Window Server 侧 45.0 → 43.9，在噪声内 —— 这项成本本来就在我们进程里。

**A/B 方法**：4 轮交替（`cg,cgs,cgs,cg`），每轮 `make rerun` 重启，20.35 s `getrusage` 差值，
同时录 20 s Time Profiler。每轮都有**同样的内部控制**：600 次活读、0 次回落、
0 次状态转换、盒子内心跳 2/2。省下的 148 ms / 20.35 s = 0.73 pt 与实测 0.69 pt 对上账。

**必须分开的两个 `SLWindowListCopyWindowInfo`**：`cgs` 轮的 trace 里仍有 83–103 ms 的
公有读，那是 `MacOSPlatform.windows()` 的周期枚举（2 Hz 图 + 10 Hz body），两轮相同。
把它和活读混在一起算，会把没变的成本记到被比较的那一项上。

**一处要更正的旧数字**：`rejected-approaches.md` 曾记「2.5 µs、便宜 12 倍」，
那是**紧循环**读数。app 内 46 µs 对 293 µs ⇒ 真实约 **6 倍**。
与 `setFrame`（循环 27 µs / 真实 230–310 µs）、单窗口枚举（循环 25 µs / 真实 ~300 µs）
是同一个陷阱：**私有调用的紧循环微基准尤其不可信，它连 IPC 都不会真的发生。**

**未测**：站在窗口顶边（`liveSurface`，60 Hz，预期收益翻倍）、多显示器、
以及整表枚举能否也改成私有（`CGSGetOnScreenWindowList` + level/alpha + 连接→PID，
还需 owner name 与 z 序，是另一个赌注）。
等价性验证只覆盖**在屏**窗口；最小化 / 其他 Space 的窗口没比较过 ——
两个调用点问的都是她在其上或其中的窗口，按定义在屏，所以这不构成风险，
但也**不要把结论外推**。

## 日志的成本

一条 `writeEvent` = **45.4 µs**，其中约 **19 µs 是每行的 `stat`**（`rotateIfNeeded` 每次问文件大小）。
`seekToEnd()` 本来就返回那个偏移、也本来就被调用，所以旋转改用它：**26.3 µs（−42%）**。
没有 `fsync` 是故意的（每帧一次磁盘写会引入这次改动本来要消除的停顿）。

**教训：把诊断事件对着每帧路径审一遍。** `AirborneCaught` 曾每帧写
（向上拖的窗口每帧重新接住她，累积 1252 行），即 60 × 45 µs ≈ **0.27% CPU**，
与它正在记录的节省是同一量级。现在用 `ChangeGate` 折叠。

## 拖动 vs `setFrame`：为什么 overlay 必须存在

探针（`Probes/WindowMoveProbe/`，每模式一个进程：3 s settle + 8 s IDLE + 20 s ACTIVE，
`ACTIVE − IDLE` 抵消启动尖峰/层级/合成）。`app` = 自己的 `getrusage`；
`ws` = Window Server 的累计 CPU（`ps -o time=` 每秒采样）。
**`move` 是让拖动可解释的对照：同样的鼠标运动，不移动窗口。**

| run | app Δ | ws Δ |
| --- | --- | --- |
| 拖动面板 | **+4.05** | **+15** |
| 只移动光标 | **+3.94** | **+15** |
| `setFrame` 60 Hz（无输入） | **+6.09** | **+6.7** |

- **拖动时的窗口跟随是免费的**：`drag − move` = +0.13 pt app、+1.2 pt ws。
- **但拖动整体不免费**：仅仅移动光标就让接收事件的应用 +3.9 pt、Window Server +15 pt。
  这是任何前台应用都要付的鼠标流成本（见下一节）。
- **`setFrame` 60 Hz 是应用进程里最贵的单项（+6.1 pt）**，且完全无指针运动。
  这正是全屏 overlay 消除的成本。
- **为什么本质不同**：拖动的移动是在 Window Server 自己的鼠标跟踪循环里执行的
  （因为指针在动，那个循环本来就在跑），应用被拖，它自己不发起移动。
  `setFrame` 是**每次调用**一次同步的应用→服务器 IPC + CoreAnimation 事务。
- **应用没有借用拖动路径的办法。** overlay / `CALayer` 位置是唯一便宜的应用驱动移动。

### 透明不便宜：`setFrame` 的成本与像素无关

| 模式 | app Δ | ws Δ |
| --- | --- | --- |
| 不透明 | +5.57 | +5.62 |
| 透明内容 | +5.76 | +5.73 |
| `alphaValue = 0` | +5.40 | +4.94 |
| 静态透明窗口 + 不透明 CALayer 用 `position` 移动 | **+1.05** | **+0.34** |

- **完全透明的窗口 `setFrame` 与不透明窗口完全相同**。透明不是窗口移动成本的杠杆。
- **连 `alphaValue = 0`（完全看不见的窗口）仍要约 +5.4 pt** —— Window Server 不会跳过移动
  一个不可见窗口。所以也不是在合成内容。
- **省下的是机制，不是像素**：静态窗口 + 移动 CALayer 便宜约 5 倍。
  **没有更便宜的 `setFrame`，只有「不移动窗口」。**

## 鼠标移动的开销（透明 overlay 的固有代价）

移动光标把 overlay 应用从 ~0.75% 抬到 ~6.5%，同时 Window Server +约 15 pt。
不是窗口切换（合成 CGEvent 移动流就能复现），也不是我们自己的全局事件监听
（当时的 `--pet-panel` 小窗口渲染器跑同一个 `MouseMonitor`，开销约 0；
它在 2026-10 中旬已被删除，只剩 overlay）。`PetController.step` 的绝对时间不变。

**成本位置（已钉住）**：`NSEventThread` 占活跃 CPU 的 34–39%，链路是
`CGSSnarfAndDispatchDatagrams → SLSGetNextEventRecordInternal → SLEventCreateNextEvent →
PullEventsFromWindowServerOnConnection` —— 私有 SkyLight 客户端**在我们进程里**
拉取并解析 Window Server 的事件数据报。主线程再加
`routeMouseMovedEvent → _routeMouseMovedEvent → -[NSWindow _reallySendEvent:]`（约 9–11%）。

`NSEventThread` 自身耗时（420 个 running 样本的叶子帧占比）：

| 占比 | 帧 | 含义 |
| --- | --- | --- |
| **35.7%** | `mach_msg2_trap` | 拉取数据报的 IPC 本身 |
| 6.2% | `_kernelrpc_mach_vm_deallocate_trap` | 释放数据报的 VM 缓冲 |
| **~9%** | `SLS::TokenizedCoding::*Decoder*`、`_SLEventRecordCreateWithBytesModern` | **解码** |
| ~6% | `szone_*`、`tiny_malloc_from_free_list` | 解码路径的分配器 |
| ~4% | `CF_IS_OBJC`、`__CFDataInit`、`NSData dataWithBytes:`、`NSCFArray objectAtIndex:` | 桥接成 Foundation |
| 3.3% | `__bsdthread_ctl` | 调度 |

**所以 decode 是真实存在的（~15–20%）**，而且它发生在连接级的拉取内部，
**在任何按窗口的判定之上** —— 这就是所有窗口级开关都无效的原因。
各种开关的实测结果见 `rejected-approaches.md`。

## 打开菜单时卡一下（已修）

用户报：菜单打开时整程序卡顿（下落中开菜单会看到她卡一下）。

**根因**：`StatusItemController.refreshMenuState()` 每次显示菜单都**同步** spawn
`/usr/bin/osascript` 并 `waitUntilExit()`，阻塞主线程约 100 ms（实测 96–119 ms/次）。
而 `refreshMenuState` 有三个触发点，其中右键桌宠那条与前一个重复，所以约 200 ms。
唯一昂贵的是「登录时启动」的勾选状态（要走 System Events 查每个 login item）。

trace 证据（40 s，主线程 Running 1794 样本）：`StartupRegistrationService` **6.47%**，
而自定义菜单视图 **0 样本** —— 菜单自身不贵。

**方法论要点**：`waitUntilExit()` 期间主线程是 **Blocked**，而 xctrace 导出**只有 Running 行**，
所以**栈归因系统性低估阻塞型开销**，真实卡顿比 trace 里的 6.5% 更大。
这与「气泡 `setFrame` 的 `commit_transaction` 没有我方调用栈」是同一类问题。

修法：缓存「登录时启动」的值（仅 nil 时读一次真值），切换后**重读真值**（注册可能失败），
并去掉 `popUpMenu` 里冗余的 `refreshMenuState()`。

**代价（已接受）**：在系统设置里直接增删 login item，菜单勾选要等下次切换/重启才纠正。
「既实时又零阻塞」不可得 —— 异步读会让打开瞬间仍显示旧值。

## 拖动/下落高 CPU 的调查结论（历史）

起点是「拖动和下落时约 30% CPU」。先做路径分析，再最小风险修改，然后才转为实测剖析。
两个早期优化没有用户可见改善后，停止盲调。

- **主因是高频位置变化下的窗口系统事务成本，不是精灵绘制。** 决定性线索是用户指出
  「拖动时 CPU 只在鼠标移动时上升；鼠标不动就像 idle」。
- 有效改动：拖动期间限制昂贵刷新、下落期改为**按时间 + 距离门控**的刷新
  （图重建占比 21.9% → 9.7%）、消除无操作的窗口 frame/level 赋值、气泡不再无谓重绘。
- **最终答案不是微优化某个 API，而是换渲染架构**（全屏 overlay + CALayer），见 `rendering.md`。

## 探针必须「计数」才能信它的 CPU 读数

第一版独立探针在「光标动」与「不动」时报出相同的 CPU，而它被用来下结论。
它是**无效的**：探针的窗口**根本没有收到移动流**，所以「无变化」什么都证明不了。

替代探针镜像 `OverlayPetPanel`（全屏、borderless、non-activating、层级 2、透明），
并用 `NSEvent.addLocalMonitorForEvents` **统计 `.mouseMoved`**、每阶段打印计数。
它自证有效：idle **0.05% / 0 次**，active **2.70–2.83% / 1150–1220 次**。
合成移动事件由**后台线程**发出，所以测到的是投递路径，不掺探针自己产生事件的成本。

**规则：任何测这个开销的探针，必须展示非零的移动计数，否则它的 CPU 读数无意义。**
行为类断言同理 —— 每个私有 API 调用都要配一个**已知有效**的对照。

## 原版的 Windows 占用（作为参照）

在 Parallels 的 Win11 客户机（8 逻辑核）里跑原版 v1.3.3.0：

- idle：**~306 MiB 私有工作集**（稳定 60 s），峰值 638 MiB（启动），22–24 线程。
- CPU idle **约 11–12% 的单核 = 8 核的 1.4%** —— 任务管理器的 1–1.5% 就是这么来的。
- **`< 0.5%` 的 idle 预算只有在「多核总和」口径下才成立，而且只有我们达到**：
  我们的 3.4% 是 `top` 的**单核**口径（14 逻辑核）⇒ 约 **0.24% 全核**。
  原版 idle 是单核 11% = **8 核的 1.4%**，它**没有**达到这个预算。
- 交互（拖动+放下 / 窗口抛）**无法区分**：中位数 **17.6 vs 19.9% 单核**，
  即比 idle 高 6–9 个点。两个不同物理场景成本相同，与「成本是指针而不是她的物理」
  一致 —— 和 macOS 探针的 `drag ≈ move` 结论同一形状。
  （尚未跑「只移动光标」的对照，所以还不能完全归因。）
- 内存只在交互期增长、**不回落**：306 → 335 MiB，交互约 +6 MiB/分钟，
  纯 idle 时基本平（334.2 → 335.5）。形状像 GC 堆在分配下增长，但没有证据表明它被回收过。
