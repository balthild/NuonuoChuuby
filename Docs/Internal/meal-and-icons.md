# 吃文件：删除检测、桌面图标、幽灵

## 删除检测：三条独立缺陷（同一批用户报告）

### 1. 幽灵位置错 —— 查询时机错位，不是索引缺失

探针实测（真实桌面、Finder 删除）：被删名字在**删除后 +0.18 s 仍在 AX 索引**、位置正确；
**+0.5 s 已消失**。而代码把索引查询放在「开始进食」时，那一刻名字早已被 2 s 一次的
`refresh()` 整体替换掉 → 返回 nil → 静默回落到鼠标位置（`MouseMonitor` 的最后一次点击/光标，
**从不查索引**）。

所以「保存按名称的索引」这个意图**没落地**：索引查了，但查得太晚。

- 修法：`anchorProvider` 改成在 `FileDeletionWatcher.handle`（**检测瞬间**）按名字查，
  命中即 `exactAnchor = true`；查不到才回落鼠标。
- **AX 是软依赖**：无授权 → 索引为空 → 回落鼠标。
- **有效窗口约 0.3–0.5 s，目前够用**。若日后晚到查询偶发落空，可在索引里留一份
  「最近 10 s 见过的 name→position」快照（未做）。
- 与 Cmd+Backspace 无关：`Sources/` 里**只有鼠标监听**，无键盘监听。原版有 Delete 键钩子，
  兼抓「被选中图标真实中心」；端口把它当「冗余的删除检测」删掉，连锚点采集职责一起丢了。

### 2. 一个文件被反复吃 —— 一次 Finder 删除可能产生两个 FSEvents removal

`Renamed`，再 `Renamed|Created`，相隔约 0.2 s（间歇发生）。检测器与队列都不按名字去重 → 两条 meal。

- 修法：按 **path** 去重，窗口 `duplicateWindow = 2.0`。去重记录在 `collectReady` 后
  **不清理**，所以「第一条已上菜、第二条 0.2 s 后才到」也被丢弃。
  不同目录的同名文件是两个独立 meal（用 path 而非 name）。
- **诊断要点**：用户后来看到的「同一位置连吃 6+ 次」是**误报** —— 日志里是 6 个**不同名字哈希**
  但同一锚点，那是探针造的 8 个文件（Finder 把新文件排在同一网格位）。
  **看名字哈希是否相同。**

### 3. 删完隔很久才去吃 —— 不是所有状态都接单

`enqueueMeals` 只在 `state == .idle || .curious` 时才 `beginNextMeal()`，
于是 `sleeping/waking/running/landing/rolling/satisfied/falling/chomping/licking`
**都不接单** —— 睡着时最长等 60 s 睡完。这是明确的移植缺口：原版同位置有
`Sleeping → BeginWake(forMeal:true)` / `Waking → _wakeForMeal = true` /
`Licking | (Running && purpose != Meal) → StartNextMeal()`。

- 修法：按 state 分派；**并且 `updateIdle` 顶部加**「若有排队 meal 先吃」，
  兜住那些当时不能被打断的状态（否则会等到下一次 idle 决策才吃）。
- **唤醒结束必须收敛到一处**：`updateState` 的定时器路径与 `didFinishClip("sleep_exit")`
  都会结束唤醒，前者曾绕过 `wakeForMeal`。现统一走 `finishWaking()`。
- `WakeForFood` 上游只定义、无生产者（上游漏了），我们主动用上了。

## 桌面图标坐标：AX 索引（`DesktopIconIndex`）

macOS 没有公开 API 读桌面图标位置，**辅助功能可以**，而且路径很短：

```
d=1 role=AXScrollArea desc=桌面  pos=(0,0)          size=(1728,1117)
d=2 role=AXGroup      desc=桌面  pos=(0,0)          size=(1728,1117)
d=3 role=AXImage desc=Xcode_16.4.xip pos=(1391,136) size=(56,56)
```

- `AXImage` 的 `desc` **就是文件名**，`pos` / `size` 是真实位置与尺寸（尺寸是幽灵图标的
  来源，见下一节）。坐标已经是左上原点、Y 向下，与 `DisplaySpace` 相同，不需要翻转。
- 定位容器**不匹配「桌面」字样**，而是取「最浅一层含 `AXImage` 子节点的元素」，
  所以不依赖系统语言。
- **索引是周期性（2 s）的，不是按需的**：删除或舔图标先查表；删除那一刻另外做一次活读
  （见「新建即删」一节）。被删图标的元素还会在树里留约 0.7 s（位置 / 尺寸仍正确），
  所以检测瞬间的活读来得及。索引同时是「舔图标」的候选来源，而 create 事件只报新增，
  覆盖不到启动时已有的图标、用户挪动与 Finder 重启，所以不能只靠事件驱动。
- **软依赖**：未授权辅助功能时索引为空，调用方退回 `DesktopIconGrid`
  （Finder 默认布局的近似坐标，见 `README.md` 的差异表）。
- 一次全量枚举约 **11 ms**（21 个图标），2 s 一次 ≈ 0.55% 单核 —— 这是它按低频索引、
  而不是按需读取的原因。

## 幽灵图标尺寸

用户报「假图标比真图标小一些」。真相：幽灵尺寸是固定的 `petSize * 0.34`，
**与图标无关**；桌面图标是 56，所以差 20%。**AX 早就读到了真实尺寸**（`kAXSize`），
只是构造 `DesktopIcon` 时丢掉了。上游其实也用真实尺寸，但用户明确指示：
**这类功能不对照上游**。

修法：`DesktopIcon` 带 `size`；`position(of:)` → `icon(of:)`（一次查询返回位置与尺寸）；
`Anchor = {point, exact, iconSize}` 一路传到 `show`。回落值仍是 `petSize * 0.34`
（仅当索引无数据：无 AX 或非桌面目录）。`GhostShown` 带 `Size` —— **它是判别字段**。

## 「新建即删」：锚点必须读活树，不是 2 s 缓存

用户报：新建文件夹 → 删除，趁她去吃第一个幽灵时再建一个再删，第二个幽灵更小、位置不对。
日志里 `Size="56" Exact="true"` 与 `Size="fallback"` 交替出现，
且 fallback 那条前一行总是 `DesktopIconIndex Icons="20"`。

**根因**：`anchorProvider` 只读 2 s 一次的**缓存索引**；「新建即删」的文件夹在一次刷新窗口内
生灭，索引从没存过它 → 回落鼠标（位置=光标；尺寸缺失 → 44.9 而不是 56）。
「有时候」= 文件夹恰好活过一次刷新就被记住了。

- 探针实测：一次完整 AX 枚举 **~11 ms**（21 个图标）；被删图标在进废纸篓后
  **仍在 AX 树里 ~0.7 s**（位置/尺寸正确）。所以**在检测瞬间做一次活读完全来得及**，且很便宜。
- 另一个探针：一次 create+delete = **一条** `[Renamed+Created] onDisk=false`，
  删除后 **+0.03 s** 送达。所以这个 bug **不是**重复事件、也不是去重窗口。
- **修法**：抽出私有 `readIcons()` 作为**唯一读路径**。删除那一刻就是一次 `refresh()`
  （读活树），并把名字**从缓存摘掉** —— 刚删的图标在 AX 里还会留 ~0.7 s，
  不摘就会进 `positions` 变成「舔图标」的候选（舔空位）。

**「读失败清空 vs 保留旧快照」—— 返回值与缓存状态是两件事。**
`let cached = ...` + `?? cached` 已经保住了兜底（失败时仍返回图标原位），所以缓存可以如实清空。
清空更正确：读失败只可能是 AX 被撤销 / Finder 不在 / 找不到容器，这些情况下她本就不该再
走向缓存里的位置；留着旧快照反而让「AX 被撤销」晚 ≤2 s 才纠正。
「stale beats no answer」把两者混为一谈 —— 别再犯。（唯一代价：Finder 重启会让
`positions` 空 ≤2 s，可自愈。）

## 一批文件只读一次

原设计每个名字一次全量 AX 枚举（~11 ms/次，主线程）；删 10 个文件约 110 ms 卡顿。

- `anchorProvider` 改成 `([String]) -> [String: Anchor]`（**契约：每个名字一个条目**）。
- `iconForDeletion(of:)` → `iconsForDeletion(of: [String])`。
- 单名字规则抽成静态私有函数（dprint 会把长三元换行成难读的形状，提取后明显更好读）。
- `guard let anchor = anchors[name] else { continue }` 是理论上的静默丢弃（契约违例），
  但闭包是 total 的，故未加诊断事件。
- 测试：`batchIsOneRead` —— 计数 reader 调用次数，5 个名字必须 = 1 次。

## 改名被当成删除

用户报：桌面文件改名她也会吃，**一次吃旧名、一次吃新名**，吃新名那次位置不准、图标偏小。

**根因**：`FolderWatcher` 把 `ItemRenamed` 一律当删除。而 `rename(2)` 在 FSEvents 里
**两个名字都带 `Renamed`**，所以一次改名产生两条「删除」。旧名那条查得到（元素还在），位置对；
新名那条查不到（新名从没出现在索引里，2 s 才刷新且渲染名未必等于 `kAXDescription`），
回落鼠标锚点 + 44.9 尺寸。

**这不是锚点时机 bug**，是「改名算不算删除」的判断从来没写。

**修法（`Meal/FolderEventBatch.swift`，纯函数）**：一次 FSEvents 回调 = 一个 batch，两条规则：

1. 带 `Renamed` 但**此刻仍在磁盘上** → 那是去处，永不是删除（新名字）。
2. 带 `Renamed` 且已消失 → 只在**同批没有落点**时才算删除。批里有落点 ⇒ 只是改名。
   `Removed`（unlink）永远算删除。

- 探针实测的形状：目录内改名成对到达（同批、id 相邻，落点 onDisk=1）；
  移出目录 / 移入废纸篓是**单独一条**；**多条拖废纸篓会合并成一个 batch 但都是「消失的 rename」，
  没有落点** → 规则 2 不会误伤连删。
- 落点判定用 `fileExists`：事件送达时新名字已在磁盘上、旧名字已消失
  （回调发生在 `rename(2)` 返回之后）。这正是 2 s 索引做不到的事。
- **批次级配对的已知代价**：同一次击键里「删一个 + 改名一个」会把删除也一起取消。
  真正区分需要 inode 关联（fstatat），判断为过度设计，先不做。
- 新增 `DeletionIgnored Reason="renamed"` 事件 —— 改名被吃掉和「她压根没看见文件」
  在屏幕上一模一样。
- **别把「改名对」当成规则 1 的重复**：规则 1 挡新名字，规则 2 挡老名字，缺一个就漏一条 meal。

## 幽灵吃完不消失（两个独立根因）

**(1) 主要根因：被 dismiss 的幽灵会被 overlay 重建「复活」。**
presenter 的 `ghostIcons` 登记表**只在 `makeGhostIcon()` 时**才清理已 dismiss 的项
（= 等下一顿饭）。而 `rebuildOverlays()`（显示器参数变化通知：分辨率/显示器增删/
**显示器睡眠唤醒**）会对每一项 `rebind()`，而 `rebind()` 只判 `isHidden` ——
于是把「已经消失、opacity 已归 1、只是被移出图层树」的层**重新挂回**新 root 层，
此后没有任何东西会再摘掉它。

- 探针实测（真 NSWindow + 0.8 s）：`show` → 1 子层；`fadeOut` 后 0.4/1.2 s → 0 子层
  （完成块确实会跑）；再 `rebind()` → **又是 1 子层、opacity 1.0、not hidden** → 永久可见。
  所以「0.25 s 淡出」不是问题，`rebind` 才是。
- 修法：`rebind()` 加 `!isDismissed` 守卫（承重）；`rebuildOverlays` 里先清掉已 dismiss 的项。
- 触发窗口是**「一顿吃完 → 下一顿开始」之间**，所以睡眠唤醒/改分辨率随手就能撞上 ——
  这就是「低概率」的来源。

**(2) 次要根因：`activeMeal` 只有两条出口。**
`completeActiveMeal`（chomp 播完）与 `requeueActiveMeal`（**只有 `beginDrag` 与 `quietMode` 调**）
是唯一收尾。于是进食途中**被捏脸**、**被窗口侧边撞飞**、菜单「回家」都会让 `activeMeal`
永久非 nil → 幽灵永远不走，**且 `beginNextMeal` 的 `guard activeMeal == nil` 让她从此再也不吃**。

- 修法（一处不变量，不要逐个出口打补丁）：在 `step` 的状态分派之后加
  「`activeMeal != nil` 且不在 `.chomping`、也不在 `.running` + `movementPurpose == .meal`
  ⇒ `requeueActiveMeal(reason:)`」。
- **必须按 state 判，不能按 movementPurpose**：`beginFall` 的 `purpose` 参数是可选，
  侧边撞击那条不传 → `movementPurpose` 仍是 `.meal`。
- `MealRequeued` 事件带 `Reason` —— 被遗弃的进食与「她压根没去」从外面看一样。

## 幽灵在「删除那一刻」就出现

用户需求：删除的一瞬间幽灵就显示；删多个时一起显示。

**CALayer 动画天然只作用于该层**，而且每个幽灵本来就是一个独立的 `OverlayGhostIcon`
（各自一个 `CALayer`），所以「待吃」与「被吃」只是**同一个层的两种状态**：
`show(anchor)` 静止 → `update(visual)` 逐帧驱动。**不需要第二个图层，也不需要「移动图层」。**
`FrameInterpolation.withoutAnimation` 对 `update()` 关掉隐式动画，`noActions` 里故意留出
`opacity` 给 `fadeOut`。

真正的改动只是「何时创建/显示」：原先在 `didBeginMeal` 才建幽灵，现在在**入队那一刻**。
`PetMealDelegate` 新增 `didEnqueueMeals`（只报告**被接受**的项，队列满丢弃的不报）。
`didBeginMeal` 改成「有则复位，无则新建」—— 覆盖「被打断的 meal 幽灵已淡出、重新开始时需复现」。
`GhostShown` 只在入队时打一次。

**生产代码只有 overlay 一个 presenter**；`GhostIconWindow` / `--pet-panel` 那条路已不存在
（grep 无匹配）。别照旧笔记去找它。

## 安静模式对删除的处理（已与上游对齐）

上游分两种情况：

1. **安静模式开着时发生删除** → 在门口丢掉（入队与建幽灵**之前**），既不入队也无幽灵，
   **且不打日志**。端口一致。
2. **打开安静模式时队列已有东西** → 上游**清空整个队列并关掉所有幽灵窗**
   （active 那个也一并清）。

端口原先只做了 1，`quietMode.didSet` 只把 active 放回队首（幽灵淡出），队列和其余幽灵都留着
—— 屏幕上挂着两个「待吃」图标，而模式说的是「只站立/睡觉」。

修法：新增 `discardAllMeals(reason:)` —— 取走 active + 整个队列，对每项调 `didFinishMeal`，
打 `MealsDiscarded`。**语义区别：requeue 是「推迟」，discard 是「不要了」**，
日志事件也分开，否则两者从外面看一样。

## Finder 发布新图标要 0.2–1.2 s

用户复现日志里**每一次 `Live="0"`**，失败那批 `Resolved="1"` 且 `Size="fallback"`。

- 探针（真机、Finder 建文件夹）：文件夹出现后 AX 元素要 **0.20 / 0.34 / 0.36 / 0.42 / 0.67 /
  1.19 s** 才出现（6 次采样）。**Finder 不会立刻发布新图标。**
- 失败链：只活 ~1.5 s 的文件夹 → 2 s 轮询大概率整段生命都没读到 → 删除时刻的活读也来不及
  （Finder 还没发布）→ 回落到鼠标 + 44.9 pt。「偶尔」= 2 s 轮询恰好落在图标存活窗口里。
- 另一个探针确认：Finder 删除后元素**仍在** AX 树里，所以不是「删除太快元素没了」。

**修法：新文件出现时进入「追读」**（不是替换 2 s 轮询）：

- `FolderEventBatch.Outcome` 新增 `appeared`（`created && !removed && isOnDisk`
  —— **移到废纸篓也是 created+renamed 但 isOnDisk=false**，所以仍靠磁盘事实判定）。
- 只转发**桌面目录**下的（索引只认桌面图标，Downloads 会白等）。
- `DesktopIconIndex.awaitAppearance(of:)`：只对新出现的名字，每 **0.25 s** 读一次、最多 **3 s**。

**为什么不替换 2 s 轮询**：`icons` 是「舔图标」走的完整快照，而 create 事件**只能报新增**，
覆盖不到启动时已存在的图标、用户挪动/重排后的位置、Finder 重启。
两者目的不同：2 s 轮询 = 全量基线（~11 ms/2 s ≈ 0.55%）；追读 = 只在出现后短促爆发
（最坏 12 次 × 11 ms）。

真机验证（同一手势 4 次「建 → 0.4 s 删」）：修复前 `Live=0`、失败项 `Size="fallback"`；
修复后**全部 `Size="56"`**（3 次 `Live=1`，1 次 `Live=0` 但 `Resolved=1` 且尺寸正确
—— 说明快照已被追读预热）。`Size` 是判别字段。

## 吃图标的幽灵动画

上游单人进食动画：**先原地抖一下，再随张嘴缩小、旋转、被吸进嘴里**。

- `Meal/MealConsumptionAnimation.swift`（纯函数，**画布单位**）：
  `shake 0–0.55 s` → `flight 0.55–1.22 s` → `vanish 1.22–1.35 s`。
  位移按 `mouthCanvas → suctionMouthCanvas` 插值，横向分两段（第一段占 `105/146`，
  这个分数来自糯糯的 `191-45`），**纵向在第一段就到位** —— 这是上游的形状，别「修正」。
- **时间轴与咀嚼剪辑无关**：`chomp` 剪辑 2.4 s，而上游 1.35 s 就把食物收掉，
  最后 1 s 她在嚼空气。这是上游行为，不是 bug。
- 缩放走 `transform`（`bounds` 保持自然尺寸），`CATransform3DConcat(rotate, scale)`
  = 上游 WPF 的「先 Scale 再 Rotate」。**旋转的视觉方向未用眼睛验证**
  （±4° 抖动 + 12° 倾角，朝向不敏感）。

## 其他约束

- 一次删 30 个受 `maximumBufferedDeletions = 24` 上限约束。
- Trash 监听已删除：`rm` 等直接解链的删除**根本不进回收站**，所以「Trash 里没有」什么都证明不了；
  而且它也不能纠正误吃（文件被拖到别处时 Trash 无新增）。原来那个 2.5 s 等待
  **本身就是为佐证而设**，没有佐证后改成 0.5 s 沉降窗（只是躲开瞬时重复事件，顺便更快）。
