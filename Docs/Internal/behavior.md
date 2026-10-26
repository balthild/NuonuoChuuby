# 自主行为：巡逻、边缘动作、生命状态

## 巡逻（patrol）—— 一次失败的移植，修了三轮

用户报「从一个窗口跳到另一个窗口」的功能从来没触发过。**不是攀爬的问题**：
日志里 `ClimbBegin` 284 次、283 次起点在地面上。用户要的是**跳跃**：站在窗口 A 跳到旁边
（互不重叠但相近）的窗口 B。

### 第一轮（方向错了一半）

以为根因是「移植时把跳跃的横向速度丢了」：上游 `BeginTerrainHop` 是
`BeginFall(-560*scale, "TerrainHop", direction*315*scale)`，端口只有纵向 420、横向 0。
**这个缺口是真的**（已补），但**不是用户看不到它的原因**：补完横向速度后她仍然
「在窗口顶上只是走来走去」。

### 第二轮 —— 真正的根因：**patrol 从没被移植**

`.patrol` 是 `MovementPurpose` 的一个 case，但**全仓库零生产者**。
上游 `AutonomousAction.Wander` → `StartContinuousPatrol(preferClimb:false)`，
`.Explore` → `preferClimb:true`；`StartContinuousPatrol` → `ChooseNextPatrolTarget`
把 `targetX` 设成当前 run 的**某一端**（`margin = clamp(她窗口宽*0.20, 24, 72)`，方向交替），
到达时 `UpdateGroundRunning` 调 `TryBeginTerrainActionAtEdge`。
**所以「到端头」是上游唯一到达 edge 的路径，所有边缘行为都挂在它下面。**

端口用「均匀随机的中间点」代替（`inset = 20`），在 1200 宽的窗口上落在离端头 24 pt 内的概率约 4%，
再乘 20–48% 的动作抽签 ⇒ 约 0.8%/次 ⇒「从没见过」。

> **教训：`movementPurpose` 的 case 存在 ≠ 它被生产。**
> 本仓库栽过多次（`patrol`、`edgeJumpApproach`、`edgeSlideApproach` 都是只读不产）。
> 怀疑某个玩法不生效时，**先 grep 该 case 的生产者**，再看里面的数值。

### 修法要点

1. `Motion` 用上游值：`hopVelocityX 315 / hopVelocityY 560`、
   `jumpDownVelocityX 255 / jumpDownVelocityY 175`；`beginHop(direction:)`（nil = 随机）。
2. 新增 `beginPatrol(preferClimb:)` + `chooseNextPatrolTarget(preferClimb:)`：
   端点目标 + 方向交替 + `abs(next - foot.x) < 20` 时翻向；34% 概率先试爬窗。
3. `finishGroundMove` 新增 `.patrol` 分支：到达端点 → `terrainEdgeAction(at:)`；
   返回 nil（掉头或冷却中）→ 反向 + 下一段；无处可走才 `returnToIdle()`。
4. **删掉 `terrainEdgeActionIfAtEdge` 的位置判定**：上游 `TryBeginTerrainActionAtEdge`
   **没有位置判定**，它只从「巡逻到达」和受控 EdgeJump/EdgeSlide 调用。
   端口那个 24 pt 判定是自创的，而且**与巡逻停止距离冲突**（margin 44 > 24，
   加了巡逻也永远不满足）。顺带修好 `isDesktopFloor` 硬编码 false。
5. 新增 **14 s 冷却**（上游 `_nextTerrainActionAt = now + 14`）：
   否则窄窗口（几百 pt，2 秒一趟）会一直往边缘跳。

### 「无限巡逻」是上游设计，不是 port 的 bug

用户要求补上游的「巡逻按需打断」（`TryInterruptPatrolForNeed`），并**以为它能治「一直在走个不停」**。
实测证明不能：她当时 `hunger=46.8 / sleepiness=0.018`，而四个门槛是
`sleep>=62 / askForFood>=70 / lickIcon>=62 / roll>=65` ⇒ `available` 恒空 ⇒ 一次都不触发。
按速率（醒着时 `hunger +0.18/min`、`sleepiness +0.13/min`）算，最近的那个也要约 84 分钟才够。

而且上游**更狠**：`DecideAutonomousBehavior` 的 `default`（= `.rest`）分支也是
`StartContinuousPatrol(preferClimb:false)` —— **rest 也去巡逻**。
端口把 `.rest` 做成「站着不动」，本来就比上游安静。

打断逻辑本身已按上游实现（每 5 s 检查、`PatrolInterrupted` 事件），但它是「有需求就停」，
不是「走一会儿就停」。

### 60/40 腿部决策（**有意偏离上游**）

用户对「走个不停」的观感不满，提出：**自主走动 60% 走到尽头，40% 走到随机点并停留；
到尽头后若边缘动作冷却没到，就重新判定 60/40。**

一次「自主走动」是一**串 leg**，每个 leg 在前一个结束时才决定：

- `rollIsEdgeLeg()`（`edgeLegChance = 0.6`）为真 → `beginPatrolLeg()`（purpose `.patrol`）；
- 为假 → `beginStroll(purpose:)`（上游 `StartGroundMove` 的形状：
  `travel = 80…241` × 随机方向、夹进 run、太近(<36) 改去远端、<24 放弃）。
- 爬窗尝试**只在 leg 开始时**做（上游在每次选目标时都试，两者差别见「上游的爬窗冷却」）。

**「到尽头无动作可做就重新判定」必须同时覆盖 turnaround 和冷却中两种情况。**
用户只说了冷却那半句；turnaround 那半边也要重判，否则地板 78% 的到达都会立刻掉头再走，
60/40 形同虚设。

### 数值（均与上游对齐）

- **停靠边距**：`patrolStopMargin = clamp(petSize * 0.20, 24, 72)`。上游量的是**她自己那个窗口**
  的宽度（`GetWindowRect(_windowHandle)`），不是地形窗口的宽度 —— 这里用 `petSize`，是同一件事。
- **放弃与翻向**：`maximumX - minimumX < 42` 时这个 leg 直接放弃（走不了几步，不如不动）；
  起点距目标 `< 20` pt 时翻向，否则就是一次零距离行走。
- **爬窗 34%**（`preferClimb` 时必试）。
- **边缘动作冷却 14 s**（`_nextTerrainActionAt = now + 14`），否则窄窗口上（2 秒一趟）
  她每次到边都往边缘跳。

### 上游的爬窗冷却，端口一条都没有

上游有 `_nextClimbAttemptAt` 的三个门：选中目标后 **12 s**、滑落后 **24 s**、成功后 **20 s**。
端口没有这些冷却，替代品是「每个 leg 只试一次」—— leg 之间隔着走过去的时间。
**若改成上游那样在每个目标选择处都试，就必须同时把这三个冷却补上**，
否则她会反复往同一个爬不上去的边上撞。

### 地板横向是整个显示器，不是工作区

`SurfaceBuilder` 给每个显示器建一条 `floor`：`offset` 取 `visibleFrame.bottom`（工作区底边，
已排除菜单栏与 Dock），但 `span` 取**整个 `frame` 的宽度**。上游的地板用工作区宽度。
所以 Dock 停在左/右边缘时，她会沿地板线走进被 Dock 保留的那条竖带；那里她画在 Dock 之下
（Dock 是 CGWindowLevel 20，overlay 是 2）。这是接受的现状，未打算修。

### 仍未动的同族缺口

- `movementPurpose` 的 `edgeJumpApproach` / `edgeSlideApproach` **仍无生产者**
  —— 受控「从边缘跳/滑」的菜单项不存在（上游对应 `StartControlledEdge`）。
- 上游还有**每个自主动作的独立 CD**（Wander 9 / Explore 18 / Sleep 90 / AskForFood 65 /
  LickIcon 70 / Roll 42 / Hop 24 / Rest 5），端口**完全没有**；只给打断路径加了 CD。
- `TryInterruptPatrolForNeed` 只打断 `.patrol`（上游还打断 `.climbApproach`）。
- `.wander` / `.explore` 因为 40% 的 stroll 重新有了生产者，旧说法「这两个 purpose 是死代码」作废。

## 生命状态与「饱」

`hunger` 与 `fullness` **都是独立字段**，谁也不是另一个的 derived（速率/初值都不同，无法互推）。
但 `fullness` 在 Swift 里近乎死状态（只有一个消费者：`.rest` 权重），于是让它承担「饱」的判定：

- `LifeBehaviorPolicy.comfortablyFullThreshold = 60` + `isComfortablyFull(_:)`
  （**只看 fullness，不看 hunger**）。
- 取 60 的依据：`fullness` 起始 24、每餐 +6…14（均值 10），4 餐 ≈ 63.5 > 60，
  与旧的 `hunger <= 2` **在同一顿饭触发**，所以视觉行为基本不变（阈值 68 会晚一餐，别改回去）。
- `completeActiveMeal` 的 `stuffed` 用它；`MealCompleted` 事件带 `Fullness`。
- `AutonomousBehaviorPlanner` 的 `.rest` 权重改用同一常量，全仓库只有一个「饱」的数字。
- 上游其实是另一条规则（看 `_foodQueue.Count > 0`），Swift 端口曾自创 `hunger <= 2`。
  读 fullness 比两者都更贴「她吃饱了」的本意。

## 台词：无生产者的 cue 已接线

用户指令：**不删除，给每条找个合适的位置用上，不管上游。**
查证发现其中一些在**上游也是死的**（`FeastContinues`/`AnotherBite`/`IconTaste`/`Stuffed`
在 C# 里同样无调用点，是旧设计残留），所以落点是新设计的，不是复刻。

- **饥饿/饱腹波段 → 无事件的自言自语**。这是唯一「没有事件可挂」的一类。
  `Dialogue/PetMoodSpeech.swift` 是纯函数：`line(life:fastingMode:) -> (cue, voice)?`；
  `comfortablyFull` 优先于饥饿波段（吃是唯一同时推动两者的行为，方向相反）；
  fasting 只屏蔽饥饿两条，不屏蔽「饱」。只在 `state == .idle && !quietMode` 说。
- **间隔走随机**（45…95 s）。最初写成常量 70 只是为了不改种子序列，用户要求改回随机
  （「不该踩节拍器说话」）。
- 其余落点：`exploration`→`.explore`；`mealQueueContinues`→入队时已有待吃；
  `hungryRequestQueued`→入队但因腾空/剪辑中走不开（原来那条是静默 `break`）；
  `feastContinues`→`advanceAfterMeal` 还有排队；`anotherBite`→`beginChomp` 时队列仍非空；
  `iconTaste`/`iconsHidden`→`lick` 剪辑结束时，按舔的是真 AX 图标还是猜的网格
  （`iconLickUsedRealIcons`）；`windowMaximized`→箱子**变大**（按 size 比较，位置变化不算；
  用 `ChangeGate`，拖拽式改大小只报一次）；`voiceEnabled|Disabled` /
  `deleteReactionEnabled|Disabled`→菜单回调。
  「关声音」那条**只有气泡没有语音**，因为语音刚被关掉 —— 刻意的。

## 菜单里的饥饿度

- `System/HungerDisplayPolicy.swift`（纯函数）：阈值 **55 / 80**（**上游值**），
  百分比、`clamp`。颜色也抄上游调色板。
- 视图在 `StatusItemController`：自定义行视图 + **手绘**圆角进度条
  （`NSProgressIndicator` 高度不可控，5 pt 做不到）。
- **取数是拉取，不是推送**：`hungerSource: (() -> Double)?` 在 `menuNeedsUpdate` 里读 ——
  饥饿度在菜单关着时一直在漂，缓存会过期（原版是每 0.25 s 推一次）。
- 显隐接 `PetModePolicy.shouldShowProgressDisplay`（禁食/无限模式隐藏）：
  禁食时 `hunger` 名义恒为 0，显示「0%」会误导。**用户尚未表态要不要永远显示。**
- **最小宽度属于 menu 而不是 item**：AppKit 会把 item view 拉伸到 menu 内容宽度，
  所以设 `menu.minimumWidth` + item view 的 `autoresizingMask = [.width]`。
- `Common/Double.swift` 的 `roundedToInt()`：`clamp` 不会让 NaN 变有限，
  所以 `Int(rounded())` 会 trap。
