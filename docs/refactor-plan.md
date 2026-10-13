# NuonuoChuuby 重构计划：向 Ledgeling 的架构对齐

> **这份文档是本次重构的唯一权威来源。** 实施前请完整读完，并在动手前
> 用代码核对 §3「当前状态事实」里的每一条 —— 那些结论是我读码得出的，
> 但代码会变，**如果文档与代码冲突，以代码为准，并回头修正本文档**。

---

## 0. 这份文档怎么用

- 分阶段实施：**Phase 0 → A → B → C → E**，严格按顺序，**每个阶段单独提交**。
- 每个阶段结束时必须：`swift build` 干净 + `swift test` 全绿 + 应用可运行。
- **不要**把多个阶段合并成一个提交。**不要**在 Phase B 的 `span` 存在之前开始 Phase C。
- 计划里已锁定的决策**不要重新论证**；但如果你发现**证据**表明某个决策是错的，
  停下来指出，不要默默改掉。
- 本文档用中文写（与 `README.md` / `TODO.md` 一致）；**代码、标识符、注释保持英文**。

### 开始前必做

```sh
make test            # 素材由 make test 从 submodule 硬链提供；记录基线测试数与全绿状态
```

然后读：`README.md`（尤其「macOS 上的行为差异」表）、`TODO.md`、`Package.swift`、`Makefile`。

---

## 1. 目标与手段

**目标**：保留现有 Swift 应用，只把**世界模型**换成 Ledgeling 那套 ——
窗口几何 → 带遮挡减法的 surface 图 → 参数化棲位 `(SurfaceKey, t)`。

**要根除的 bug 族**：抖动 / 误触发（无理由被甩出）/ 脱离 / 悬空。
这些全部源于「世界坐标 + 速度匹配」这个模型，补丁只能缓解。

**明确不动的东西**：渲染层（`PetView` / `PetWindowController`）、脸捏变形、
幽灵图标窗、气泡窗、素材与打包、`Life/`、`Meal/`、`Cheek/`、`Voice/`、`Dialogue/`、
`Asset/`、`Settings/`。

**参考项目**：`~/Projects/Rust/Ledgeling`（fork `balthild/Ledgeling` @ `0b0014b9`，MIT）。
⚠️ 上游 `Lucerna-Systems/Ledgeling` 在 `402f60be` 已从 MIT 改为 PolyForm Strict
（禁止分发与修改），用户的 fork 停在仍是 MIT 的提交上。**结论：只借鉴技术思路，
不复制代码，也不依赖上游后续提交。**

---

## 2. 已锁定的决策（不要重新论证）

| # | 决策 | 理由 |
|---|---|---|
| D1 | **保留甩出行为，但改成一条显式释放规则** | 清掉棲位 + 给初速度，不再做速度匹配。Ledgeling 只做「受惊」；用户选 A（保留抛出感） |
| D2 | **窗口最大化顶飞允许消失** | 参数化后「被她跟着的窗沿带上天」才是对的；顶飞原本是为了掩盖宠物窗口被真实窗口裁切这个限制，而参数化后不再裁切。**记入 README 行为差异表** |
| D3 | **沿竖边行走推迟到下一轮** | 记入 `TODO.md` §2。本轮把图建全（四种边都产出），但**只启用 windowTop + floor** |
| D4 | **不做渲染协议层**（Ledgeling 的 `PetSurface`/`Scene`） | 我们有逐像素捏脸、幽灵图标窗、气泡窗三套共存窗口，单 overlay 表达不了，这个抽象**永远不会有第二个实现**。理由与 Ledgeling 保留它的理由（overlay 方案可能翻转）在这里不成立 |
| D5 | **不做自适应扫描节奏**（2 Hz ↔ 变化后 2 秒 10 Hz） | 常态**已经**是 2 Hz（`SurfaceProvider.refreshInterval = 0.5`），而**跟手度不走那张图**（见 §3）。自适应只能把「新窗沿被发现」的延迟从 0.5 s 缩短，收益极低 |
| D6 | **`Platform` 协议只放 `windows()` + `monitors()`** | 全仓库 grep 确认：**没有任何行为消费系统空闲时间或前台进程**（`LifeBehaviorPolicy.maximumIdleSeconds` 是桌宠自己的待机动画时长，不是系统空闲）。加进去就是投机性抽象 |
| D7 | **不做隐私 / 源码扫描测试** | 用户明确：自写自用，**没有隐私控制要求**（详见 §2.1） |
| D8 | **直接提交到 `main`，不开重构分支** | 每个阶段一个提交，任何提交点都全绿可运行，回滚用 `git revert` 单个提交。仓库无 push 即发布机制（无 CI），分支的隔离收益接近于零。已核实：本仓库只有 `main` 一个分支、17 个提交全部直接提交、零 merge commit。**不要引用任何「never commit to `main`」的说法**（见 §2.2） |

### 2.1 已撤回的错误论据（重要，避免重犯）

我在早期方案里用过错论据，**不要再用**：

1. **「窗口标题永不读取」不是本项目的约束。** 这句话出自 Ledgeling 的
   `AGENTS.md`/`CLAUDE.md` 约束 #1，因为 Ledgeling 是本工作区的文件夹之一，
   被当成了工作区指令读进了上下文。**grep 确认 NuonuoChuuby 全仓库没有这条。**
2. **权限成本不能作为设计理由。** 用户对隐私无要求，**一次性弹窗完全可接受**。
   从 CalendarShouter 继承的那条偏好，特指「**重新构建后不要对同一权限重复弹窗**」
   —— 那是靠**稳定的签名身份**解决的（见 `TODO.md` §4），不是靠避免权限。
3. **`CGWindowListCopyWindowInfo` 不需要权限这个事实仍然成立**，但它只是
   「现状描述」，不是「必须保持」的设计目标。

### 2.2 「引用本项目约定」必须先 grep —— 一条真实踩过的坑

**成因：Ledgeling 曾是本工作区的文件夹之一，它的 `AGENTS.md` / `CLAUDE.md`
会作为工作区指令进入上下文，读起来像「这个工作区的规则」，但它是另一个项目的规则。**
> 2026-10-12 已把 `Ledgeling` 与 `JiuNuoDesktopPet` 从工作区文件夹中移除（去掉了机制），
> 而**两个参考仓库本身未被修改，仍干净**；那两个文件仍在磁盘上，所以**将来若重新把
> Ledgeling 加回工作区，污染会立刻回来**。

我已经因此产生过三次错误论据，并把它当成用户的要求去论证：

| 我错误引用的「约定」 | 真实来源 | 本仓库的实际情况 |
|---|---|---|
| 「窗口标题永不读取」 | Ledgeling `AGENTS.md`/`CLAUDE.md` 约束 #1 | grep 全仓库无此说法 |
| 「零权限 / 不引入辅助功能」 | Ledgeling 的产品约束 | 用户明确没有隐私要求，一次性弹窗可接受 |
| 「never commit to `main`，要在 worktree 开分支、开 PR」 | Ledgeling `AGENTS.md`/`CLAUDE.md`（原文含 "in its own worktree"） | **只有 `main` 一个分支，17 个提交全部直接提交，零 merge commit** → 已定为 **D8：直接提交到 `main`** |

**规则：凡是要说「本项目的约定是 X」，先在本仓库 grep；查不到就直说
「这是我推断的 / 来自别处」，不要包装成用户的规则。**
注意后两次错误都发生在我写下这条警告**之后** —— 所以「读过警告」并不足够，
**默认动作必须是先 grep 再断言**。
Ledgeling 的技术思路可以借鉴（§10），**它的流程与产品约束一律不适用**。

**已核实属于本仓库、可以引用的约定**：
- `make run` / `open` 启动才有正常的 TCC 授权弹窗（`README.md`）。
- 测试需要 `make test`（素材从 submodule 硬链到 `.build/test-assets`）；缺素材时 `TestSkip.missingAssets` 让测试**失败**而非跳过。
- 关闭 hardened runtime；签名证书自维护，换证书会清空已授权限（`README.md`、`Makefile`）。

> 另一个易混来源：上游 `Vendor/JiuNuoDesktopPet/CONTRIBUTING.md:22` 写了
> 「从最新 `main` 创建用途单一的分支」——那是**上游公开仓库给贡献者**的流程，
> 不是本仓库（用户自己的重写版）的习惯。
> 补充（已核实）：独立的 `JiuNuoDesktopPet` 仓库**没有任何 agent 指令文件**
> （深层搜索确认，含 `.github/` 下只有 `workflows`），所以它**不会**通过自动加载
> 污染上下文；风险只来自它的文档（`CONTRIBUTING.md` / `PRIVACY.md` /
> `RELEASE_READINESS.md` / `DEVELOPMENT.md`）里的产品与流程规则被误读成本项目规则。

---

## 3. 当前状态事实（实施前请用代码核对）

### 3.1 两条独立的「窗口感知」路径 —— 混淆它们会得出错误结论

| 路径 | 代码 | 频率 | 服务对象 |
|---|---|---|---|
| **A. 地形图** | `SurfaceProvider.refresh(displaySpace:)` → `WindowSurfaceProvider.enumerateEligibleWindows`（`CGWindowListCopyWindowInfo` 全量枚举 + 逐显示器资格过滤） | **2 Hz**（`refreshInterval = 0.5`） | **只服务决策** |
| **B. 脚下单窗口实时查询** | `PetController.resolveStandingSurface()` → `WindowSurfaceProvider.liveSurface` → `liveBounds(of:)`（`CGWindowListCreateDescriptionFromArray([id])`） | **每帧** | **跟手度** |

**路径 A 服务于**：`landingSurface()`（下落时判踩到哪条边）、`support()`（地面支撑 /
空闲决策的 `hasGroundSupport`）、`tryBeginClimb()`、`terrainEdgeActionIfAtEdge()`、
`finishGroundMove()`。即：**她决定「下一步做什么」时读这张图**。

**路径 B 服务于**：她站在某窗口上时的逐帧跟随。`WindowSurfaceProvider.liveSurface`
的文档注释自己就写明了理由：

> The surface map is only rebuilt every half second, which would make a dragged
> window feel jerky. Asking the window server about the single window the pet is
> standing on is cheap enough to do every frame.

**因此：扫描频率只决定「一条新窗沿最多 0.5 s 后才变得可站 / 可爬」，不决定跟手度。**

### 3.2 「拖窗时有可见延迟」的根因（**假设，必须实测**）

不是扫描频率。跟手路径已经是每帧实时查询。**延迟是自伤**：

`PetController.swift:748` —— `respondToSupportMotion` 里**只要窗口动了一帧（≥0.5pt）
就写一条 `PlatformRide` 日志**，即拖窗时**每帧一条**。

而 `DiagnosticsLog.append` 每写一行要做：

| 步骤 | 代价 |
|---|---|
| `timestamp()` 内 `DateFormatter()` 新建 + 设 `dateFormat` | 极慢，每次调用都重建（**仅 `write(_:)` 走这条**；`PlatformRide` 走的 `writeEvent(_:)` **不调** `timestamp()`） |
| `DiagnosticsPrivacy.field` → `message` → `flatten` + **2 次 `NSRegularExpression(pattern:)` 即时编译** | `PlatformRide` 有 5 个字段 → **每帧编译 10 次正则** |
| `createDirectory(withIntermediateDirectories: true)` | 每次写一次 mkdir |
| `rotateIfNeeded` → `attributesOfItem(atPath:)` | 每次写一次 stat |
| `FileHandle(forWritingTo:)` + `seekToEnd` + `write` + `close` | 每次 open/lseek/write/close |
| 全程 `NSLock` | 串行化 |

拖窗时 = **60 次/秒 ×（重建 DateFormatter + 编译 10 个正则 + 4 个文件系统系统调用）**，
**全部同步跑在主线程**（也就是跑 60 Hz 定时器和 `panel.setFrame` 的那个线程）。

> **⚠️ 链条上每一环都是读码确认的事实，但「量级足以造成用户看到的延迟」仍是假设。**
> Phase 0 的验证**必须**包含改前 / 改后的实测对比。**没有这份对比就不能宣布修好了。**

**Phase 0 实测（2026-10-12，本机，debug 构建，10 000 次取均值）**

| 调用（热路径上的每一步） | 改前 | 改后 |
|---|---|---|
| `DiagnosticsLog.writeEvent`（5 字段，含写文件） | 112.7 µs | 40.8 µs |
| 同上，不配文件（纯格式化） | 61.9 µs | 19.5 µs |
| `WindowSurfaceProvider.liveBounds`（窗口服务器查询） | 86.9 µs | 83.5 µs（未改） |
| `SurfaceProvider.support`（图扫描） | 0.6 µs | 0.6 µs（未改） |

**结论：「量级足以造成用户看到的延迟」不成立。** 拖窗时每帧的热路径约
改前 200 µs / 改后 125 µs，即一帧（16.67 ms）的 **1.2% → 0.75%**。
这个量级不可能产生用户可见的跟手延迟。热路径修复本身值得做（2.8×），
但**它不能解释**「拖窗有可见延迟」。

第二梯队候选（macOS 对非活动进程 `.floating` 面板的移动合并、`Timer` 漂移、
App Nap 定时器节流）**均未实测**。追加一个候选：`liveSurface` 在拖拽期间
若从窗口服务器读不到该窗口，会退回**最多 0.5 s 陈旧**的图条目（§3.3 已记录
该窗口会「短暂缺失」）—— 这**才是**一个可能的可见延迟来源，属 Phase B/C 范围。

> 附注：本次实现**没有**为每行日志加 `FileHandle.synchronize()`（fsync）。
> 旧代码从未 fsync（`close()` 不等于 fsync），逐行 fsync 会在主线程引入
> 阻塞式磁盘 I/O，恰好制造它要消除的卡顿；写直达内核已满足「应用崩溃不丢日志」。

### 3.3 现有「骑乘」机制的全部状态（Phase C 要删的东西）

| 成员 | 位置 | 作用 |
|---|---|---|
| `supportSourceID` | `PetController` | 正在骑的窗口 ID |
| `standSurface` | `PetController` | 她脚下的 surface（每帧刷新） |
| `lastSupportTop` | `PetController` | 上一帧的窗沿 y，用于算速度 |
| `supportMotionInitialized` | `PetController` | 速度基线是否有效 |
| `supportUnavailableSeconds` / `isInSupportGrace` | `PetController` | 支撑短暂消失的宽限 |
| `airborneSourceID` / `lastAirbornePlatformTop` | `PetController` | 空中时记下出发窗口，让上升的边再接住她 |
| `PlatformRidePhysics.evaluate` | `Physics/PlatformRidePhysics.swift:49` | 速度匹配：follow / launchUpward / releaseDownward |
| `PlatformRidePhysics.resolveAirborneContact` | 同文件 | 空中被上升的边顶起 |
| `WindowExpansionPhysics.evaluate` | 同文件:126 | 最大化顶飞 |

阈值现状（**这是对原版的有意偏离**，注释已说明）：`minimumDisplacement = 12`、
`throwSpeedThreshold = 900`（对齐 Ledgeling 的 `STARTLING_SPEED`）。
原版是 3pt / 360pt/s = 6pt/帧，一趟普通拖拽就会误触发。

**`supportRecoveryGraceSeconds = 0.35` 要保留** —— 私有 API 的窗口列表在拖拽期间
会短暂缺失该窗口，没有宽限就会掉下去。

### 3.4 会产生**可见行为变化**的地方

| 变化 | 说明 |
|---|---|
| 最大化顶飞消失 | 见 D2 |
| 多显示器语义可能变化 | 现在的 `AirborneBoundaryPolicy` 会在**每个显示器**边界反弹；参数化后 `t` 定义在整条边上，宠物**可能真的跨屏**。Phase C **保持现状语义**并用 mock 时间线钉住，不趁机重设计 |
| 竖边会被建进图但不启用 | 见 D3。`SurfaceKind` 四种边都产出，Pet 只用 windowTop + floor |

### 3.5 一个真实的死代码问题

`WindowSurfaceProvider.swift:32` 读 `kCGWindowName` 塞进 `TerrainWindow.title`，
而 `TerrainWindow` 自己的注释（`WindowTerrainEligibilityPolicy.swift:9`）写着
*"unused here"*，且**全仓库无任何消费方**。删字段 + 删读取。
**理由仅为「死代码」**，与 §2.1 无关。

---

## 4. 目标架构

```
Sources/NuonuoChuubyCore/
  Platform/                     ← 新增
    Platform.swift              PlatformWindow / Monitor / Platform 协议
    MacOSPlatform.swift         CGWindowList + NSScreen（唯一碰系统 API 的地方之一）
    MockPlatform.swift          脚本化窗口布局 + 显示器集合（测试用）
  World/
    Surface.swift               SurfaceKind / SurfaceKey / Span / Surface
    SurfaceBuilder.swift        窗口 + 显示器 → [Surface]，含遮挡减法
    SurfaceGraph.swift          CONTIGUOUS / JUMPABLE / AIR 邻接
    SurfaceTracker.swift        帧间 diff → Added / Lost / Moved(speed)
    FullscreenDetector.swift    纯函数：layer-0 窗口 ±2px 贴满某显示器
    WindowTerrainEligibilityPolicy.swift  保留（改吃 PlatformWindow）
    WindowSurfaceProvider.swift  ↓ 被 SurfaceBuilder 取代
    SupportSurface.swift         ↓ 被 Surface 取代
    SurfaceProvider.swift        ↓ 被 SurfaceBuilder 取代
  Pet/
    Perch.swift                 ← 新增：Perch{key, t}
    PetController.swift         ← 主要战场
    ...
  Physics/
    PlatformRidePhysics.swift   ↓ evaluate / resolveAirborneContact / WindowExpansionPhysics 全删
                                  （只留 supportRecoveryGraceSeconds）
```

**保持不变**：`App/ Sprite/ Life/ Voice/ Dialogue/ Cheek/ Meal/ Asset/ Settings/ System/`、
`Makefile`、`Tools/`、`App/Info.plist`。

### 4.1 类型草图（**草图，不是圣旨**；实施时可调整，但要保持语义）

```swift
// Platform/Platform.swift
public struct PlatformWindow: Sendable, Equatable {
    public var id: UInt32            // CGWindowID，作为 SurfaceKey.owner
    public var ownerPID: Int32
    public var ownerName: String
    public var bounds: PixelRect     // 左上原点、Y 向下、点
    public var layer: Int
    public var alpha: Double
    public var zIndex: Int           // 0 = 最前；**列表顺序就是 z 序**
}

public struct Monitor: Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var frame: PixelRect
    public var visibleFrame: PixelRect
    public var scale: Double
}

@MainActor
public protocol Platform {
    func windows() -> [PlatformWindow]
    /// **空数组 = 会话锁定 / 无显示器 → 挂起，绝不是空桌面。**
    func monitors() -> [Monitor]
}
```

```swift
// World/Surface.swift
public enum SurfaceKind: String, Sendable, CaseIterable {
    case windowTop, windowBottom, windowLeft, windowRight, floor
}

public struct SurfaceKey: Sendable, Hashable {
    public var owner: UInt32     // CGWindowID；floor 用显示器 id
    public var kind: SurfaceKind
}

public struct Span: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var length: Double { end - start }
    public func contains(_ t: Double) -> Bool { t >= start && t <= end }
}

public struct Surface: Sendable, Equatable {
    public var key: SurfaceKey
    /// **整条边**（含被遮挡部分）。`t` 定义在这上面，所以边被切断后棲位依然有效。
    public var span: Span
    /// 实际可见的片段；完全被盖住时为 nil。
    public var visible: Span?
    /// 水平边 = 边的 y；竖直边 = 边的 x。
    public var offset: Double
    /// 是否可达（窗口顶边必须在工作区内）。
    public var isReachable: Bool
}
```

```swift
// Pet/Perch.swift
public struct Perch: Sendable, Equatable {
    public var key: SurfaceKey
    /// 0…1，沿 `span`（整条边）取值。
    public var t: Double
    /// 世界坐标 = (span.start + t * span.length, offset)；每帧由当前 surface 反算。
    public func position(in surface: Surface) -> PixelPoint
}
```

```swift
// World/SurfaceTracker.swift
public enum SurfaceChange: Sendable, Equatable {
    case added(Surface)
    case lost(SurfaceKey)
    case moved(SurfaceKey, delta: Double, speed: Double)   // speed 用于「受惊」判定
}
```

### 4.2 遮挡减法（核心算法，别跳过）

按**窗口列表顺序**（前 → 后）遍历。对第 `i` 个窗口的某条水平边，能遮挡它的
**只有 `windows[..<i]`**（它后面的都在它下面）。把每条遮挡者的 x 区间从该边的
区间里减掉，剩下的就是 `visible`。

- 一维区间减法，输入只需**窗口矩形 + 顺序**。
- **跳过的后果**：宠物会站在被别的窗口盖住的**隐形窗沿**上，整个错觉崩掉。
- `span` 保持原样（整条边），`visible` 才是减法结果 —— 这个区分是 Phase C 的前提。

---

## 5. 阶段

### Phase 0 —— 诊断日志热路径修复（独立，先做）

**为什么先做**：§3.2。与重构无关，本身就该修；而且修完才能验证「延迟是否真是这个」。

**步骤**

1. `System/DiagnosticsLog.swift`
   - `DateFormatter` 提为静态/实例常量，**绝不每次写都新建**。
   - 两条脱敏正则预编译为静态 `NSRegularExpression`。
   - 目录只建一次（记一个 `didCreateDirectory` 标志）。
   - 缓存 `FileHandle`，不再每行 open/close。**保留每行 flush** —— 崩溃后的诊断不能丢。
2. `Pet/PetController.swift:748` —— `PlatformRide` 只在**响应发生变化**时记录，
   而不是窗口每动一帧就记。`PlatformLaunch` / `PlatformDownwardRelease` /
   `PlatformSupportGrace` 已有各自的节流，检查一遍即可。
3. 加测试断言该事件被合并（或至少断言「同响应连续帧只产出一条事件」）。

**验证**
- `swift build` + `swift test` 全绿。
- **改前 / 改后各抓一次主线程热栈**：`make run` → 拖动一个她站在上面的窗口 →
  用 `sample <pid> 3` 或 Instruments Time Profiler 抓帧时间/热栈，**对比后写进提交信息**。
- 若对比显示延迟未改善 → 归因错误，去查第二梯队候选（macOS 对非活动进程
  `.floating` 面板的移动合并；`Timer` 在重负载下的漂移），**并如实记录**。

---

### Phase A —— `Platform` 抽象（小，行为中性）

**步骤**

1. 新增 `Platform/Platform.swift`（§4.1 草图；**只有 `windows()` 和 `monitors()`**）。
2. 新增 `Platform/MacOSPlatform.swift`：把 `WindowSurfaceProvider.enumerateEligibleWindows`
   的枚举体、以及 `DisplaySpace.init()` 里的 `NSScreen` 读取挪到它后面。
3. 新增 `Platform/MockPlatform.swift`：脚本化注入窗口布局与显示器集合。
4. `DisplaySpace` 新增 `init(monitors:primaryHeight:)`；`@MainActor init()` 变成
   套在 `MacOSPlatform` 外面的薄封装。
5. `SurfaceProvider` 改吃 `Platform` 而不是直接调窗口服务器。

**验证**：`swift build`；`swift test` 全绿；新增一个**纯 mock** 构建
`DisplaySpace` + surface 列表的测试（不碰窗口服务器、不需要素材）。

**提交**：独立提交，行为完全不变。

---

### Phase B —— Surface 图 + 遮挡减法（中，纯函数、增量）

**步骤**

1. 新增 `Surface` / `SurfaceKey` / `SurfaceKind` / `Span`；
   **区分 `span`（整条边）与 `visible`（未遮挡片段）**。
2. 新增 `SurfaceBuilder.build(windows:monitors:)`：按列表顺序做一维遮挡减法，
   **四种边都产出**（D3）。**先写边界用例测试，再写实现。**
3. `SurfaceProvider` 改为架在 `SurfaceBuilder` 之上：公开 API（`[SupportSurface]`）
   **保持不变**，内部按 `kind == .windowTop || .floor` 过滤派生。
   单一数据源，而且**遮挡减法立刻生效** —— 顺手关掉 `TODO.md` §2 第 2 条。
4. 移植 Ledgeling 的边界用例：完全遮挡、部分重叠、嵌套窗口、屏幕外、多显示器、
   完全相同的 bounds。
5. 删 `TerrainWindow.title` 与 `kCGWindowName` 读取（§3.5）。

> **实施修正（2026-10-12，以代码为准）**
> - `Surface.visible` 实现为 **`[Span]`（列表）而非 `Span?`**：§4.2 说「把遮挡者的
>   区间减掉，**剩下的**」，而一条边被中间的遮挡者切开后会剩下**两段**，单值表达不了。
>   空列表 = 完全被盖住。`isFullyOccluded` / `isVisible(t:)` 为便利封装。
> - `SurfaceBuilder.build` 的签名是 `build(windows:monitors:isEligible:)`：**遮挡者取全部
>   窗口**（前方的窗口即使本身不是地形也会遮挡），**产出 surface 的才过 `isEligible`**。
> - `SupportSurface` 的 `bottom`（唯一消费方是 `WindowClimbPlanner.effectiveBottom`）
>   不在 `Surface` 里，派生时按 `key.owner` 回查窗口矩形取得 —— 该字段在 Phase C 随
>   `SupportSurface` 一并消失。
> - 第 5 条（删 `TerrainWindow.title`）**提前到 Phase A 完成**：`TerrainWindow` 被
>   `PlatformWindow` 取代，若把它带过 Phase A 就得为它写一阶段的死代码。
>
> **Phase B 遮挡集修正（2026-10-12，修 bug）**
> §4.2 原写「能遮挡它的只有 `windows[..<i]`」，实现时字面照做 —— **这是错的**：
> 遮挡集里混进了**我们自己的透明浮层**（宠物面板 `.floating` = layer 3、气泡窗、
> 幽灵图标窗）。宠物面板恰好在她脚下，于是她把**自己正踩着的窗沿**挖出一个洞，
> `landingSurface` / `support` 全部落空 —— 表现为「拖到窗口上方仍直接掉到屏幕底部」、
> 「站在窗口上」永不成立。
> **修正：只有本身可作地形的窗口（`isEligible`）才参与遮挡。** 普通应用窗口照旧互相
> 遮挡（真正的用途），而我们自己的浮层、Dock、HUD、各类 panel 不再挖洞。
> 代价（已知、可接受）：别的应用的**不透明浮层**盖住一段窗沿时不再遮挡，宠物可能站在
> 被它盖住的位置 —— 远比「所有窗沿都不可站」轻。

**验证**
- `swift test`；移植的边界用例通过。
- 现有 `TerrainTests`（16 个）**要么原样通过，要么只在 fixture 确实存在被遮挡窗口时调整**
  —— 若需调整，**在提交信息里点名是哪一个、为什么**。
- 手动：`make run`，拖一个窗口盖住她脚下的窗口，确认她**不再站在隐形边上**。

---

### Phase C —— 参数化锚定（大，核心重写）

> **整个 Phase C 必须是一个提交。** 新旧两条跟随路径**不能并存** —— 它们会互相打架。

**步骤**

1. `Perch{key, t}` 取代 `supportSourceID` + `lastSupportTop` + `supportMotionInitialized`
   + `standSurface` 这一串机制。屏幕位置**每帧由实时 surface 反算**。
2. **删除** `PlatformRidePhysics.evaluate` 的速度匹配、`resolveAirborneContact`、
   `WindowExpansionPhysics`。换成 D1 的一条显式规则：
   > 若棲位所指的 surface 在**一个 tick 内位移超过 `releaseDisplacement`**，
   > 清空棲位并给她一个初速度。
   保留 `supportRecoveryGraceSeconds`。
3. **失去支撑变成结构性判定**：当且仅当
   - surface 从图里消失，或
   - `span` 不再包含 `t`，或
   - 它变得不可达（例：最大化后跑到菜单栏下方）

   才释放棲位。**这正是 `TODO.md` §1「弹起后停在高处」的根治点** ——
   「处于落地状态却没有任何支撑」这个状态变得**不可表示**。
4. `landingSurface` 改为在 `span` 上判定（脚从 `fromY` 穿过 `toY`）；
   `beginFall` 仍是进入空中的**唯一入口**。
5. 多显示器边界语义**保持现状**（§3.4），用 mock 时间线钉住，不重设计。
6. 删掉 Phase B 的兼容层与 `SupportSurface`（若无其他使用者）。

**测试账本（30 个骑乘相关测试）**

| 处置 | 数量 | 内容 |
|---|---|---|
| **原样保留** | 11 | `TransientPlatformSupportTests` 的 2 个宽限测试 + `PlatformRideIntegrationTests` 中 9 个（slowDragIsRidden / slowDownwardIsFollowed / lostWindowGrace / rideWorksWhileWalking / leavingGroundStopsTracking / hopStopsTracking / landingAdoptsNewWindow / landingAdoptsWindow / landingOnFloorTracksNothing） |
| **重写为显式释放规则** | 2 | `fastUpwardLaunch` / `fastDownwardRelease` → 「快速甩动释放棲位并抛出」（D1） |
| **删除** | 17 | `PlatformRidePhysicsTests` 的 10 个阈值测试（`evaluate` 被删）+ `AirbornePlatformContactTests` 4 个（`resolveAirborneContact` 被删）+ `WindowExpansionBounceTests` 2 个（D2）+ `ControllerPlatformRideTests` 1 个（`downwardDragReleases` 直接调 `evaluate`，随之失效） |

> **核对修正（2026-10-12，以代码为准）**：原表把 `WindowExpansionBounceTests` 记成 3 个，实际是 **2** 个；漏记的 `ControllerPlatformRideTests.downwardDragReleases` 才是第 17 个。总数 30 不变。

> **不得静默删除。** 每一条删除都要在提交信息里说明「为什么这个行为不再存在」。

> **Phase C 实施修正（2026-10-12，以代码为准）**
> - `Surface` 增加 `ownerBounds`（拥有者的完整矩形）。攀爬需要窗口**底边**，单条边表达不了；
>   `SupportSurface.bottom` 的唯一消费方是 `WindowClimbPlanner`，该字段已随 `SupportSurface`
>   一起删除。
> - `currentSurface(for:)` 对窗口**先用每帧实时读，实时读不到再退回图里同 key 的条目**
>   （与旧行为一致）。因此真正的释放条件是「**surface 从图里消失**」；实时读失败 ≠ 释放。
> - 释放阈值实现为 `Motion.releaseDisplacement = 15`：**单个 tick 的位移**（≈ 900 pt/s @60fps）。
> - 三种结构性失效（surface 缺失 / 不可达 / 她所在处已被遮挡）**共用** 0.35 s 宽限，之后才
>   `releasePerch()` + `beginFall()`。
> - `Perch.t` 是沿整条 `span` 的**归一化**值（0…1）。原表述「`span` 不再包含 `t`」对归一化
>   `t` 无意义，实现取其实意：**由 `t` 推导出的世界坐标不再落在任何可见片段内**。
> - 测试账本：删除 17、保留 11、重写 2、**新增 3**（`monitorUnplug` / `unreachableDrops` /
>   `neverFloating`）。总数 173 → 159。

**验证**
- `swift test` 全绿。
- **新增 mock 驱动的时间线回放测试**：
  1. 拖动窗口 → 她精确跟随（不是「差不多跟随」）
  2. 让她脚下的窗口 关闭 / 最小化 / 移出屏幕 → 她下落
  3. 快速甩动 → 释放 + 抛出（D1）
  4. 显示器插拔
  5. **`neverFloating` 不变量**：跑 ~4000 tick，断言**落地状态下 `standSurface` 永不为 nil**
     （移植 Ledgeling 的同类测试）
- 保留 `StatusHeartbeat` 作为现场诊断手段。
- **`TODO.md` §1 的症状若确实消失，才把它从「未解决」移走。**
- **在本提交里**补上 README 行为差异表的「窗口最大化顶飞」一行（D2）——
  必须与代码同提交，**不能提前**写进 README（那会让文档描述尚未存在的行为）。

---

### Phase E —— 挂起（小）

**步骤**

1. 新增**纯函数** `World/FullscreenDetector.swift`（layer-0 窗口 ±2px 贴满某显示器），
   **而不是** `Platform.fullscreenAppActive` 方法 —— 它只是对已有数据的判定，
   因此可以脱离 Mac 测试。
2. **`DisplaySpace` 拿到零个显示器 = 挂起，绝不退化成默认矩形**：停止模拟、
   定时器空转、什么都不算。关掉 `TODO.md` §2 第 4、5 条。
3. 显示器集合恢复非空时继续。

**验证**：零显示器 + flush 窗口检测的单元测试；手动锁屏 / 拔显示器，
从 `activity.log` 确认没有运行、没有位移。

> **Phase E 实施修正（2026-10-12）**
> - 挂起判定放在 `PetController.step` 的**开头**，`return` 掉后面的全部模拟（移动、
>   状态机、动画、心跳）。零显示器时甚至连地形图都不再重建。
> - **例外**：出于「怎么知道该恢复」的需要，`refreshIfStale` 仍以 2 Hz 运行 ——
>   它是全屏检测的唯一数据来源，停掉它就再也发现不了全屏应用退出。这是为可恢复性
>   付的极小代价（一次 2 Hz 的窗口枚举），并不违反「不动」。
> - 新增 `debugStep` 测试缝（与既有 `debugMaintainGroundSupport` 同风格），用来断言
>   零显示器下 60 帧内 `foot` 完全不变、状态仍是 `idle`。

---

## 6. 独立交付项：AX 真实桌面图标坐标（**不属于上面任何阶段**）

**为什么独立**：与 Ledgeling 重构**零耦合**。而且这是本项目**唯一真正值得引入
Accessibility 权限**的地方。

**问题**：`Meal/DesktopIconGrid.swift` 自己的注释写着 —— macOS 无公开 API 取真实图标
坐标，所以它**按 Finder 默认排布近似**，且「deliberately not presented as the icon's
true position」。原版在 Windows 上是从桌面 ListView 读**真实坐标**的 ——
这是如实记录在 README 里的一处保真度差距。

**可行性实验：已跑，通过（2026-10-12）**

终端进程已有辅助功能权限（`AXIsProcessTrusted = true`）。真实输出：

```
d=1 role=AXScrollArea desc=桌面  pos=(0,0)        size=(1728,1117)
d=2 role=AXGroup      desc=桌面  pos=(0,0)        size=(1728,1117)
d=3 role=AXImage desc=Xcode_16.4.xip pos=(1391,136) size=(56,56)
d=3 role=AXImage desc=prts           pos=(1391,32)  size=(56,56)
d=3 role=AXImage desc=sing-box       pos=(1513,32)  size=(56,56)
```

结论：
1. **真实坐标可读**，路径很短：`app → AXScrollArea(desc=桌面) → AXGroup(desc=桌面) → AXImage*`。
2. **`desc` 就是文件名** → 直接得到「**文件名 → 真实坐标**」映射，
   与现有**按文件名匹配**的删除检测天然对得上，不需要额外身份推断。
3. **坐标空间一致**：AX 是左上原点、Y 向下（`AXScrollArea` `(0,0,1728,1117)`、
   菜单栏 `(0,0,1728,37)`），与 `DisplaySpace` **完全同构，无需翻转换算**。
   > ⚠️ **待验证**：负坐标（第二显示器在左侧）与多显示器情形，实施时确认。

**设计约束（关键）**

- **图标被删除后 AX 元素立即消失** → 不能「删除发生时再去读」，**必须提前缓存**。
  所以这是一个**周期性索引**（文件名 → 坐标），删除事件到达时查表。
- **`DesktopIconGrid` 必须保留**作为**未授权时的降级路径**，不是删掉。

**成本（需用户确认）**：应用从「除删除进食的目录授权外不需要其他权限」变成
「请求辅助功能」。因为有降级路径，是**软依赖**。

**工作量**：BFS 从 app 根访问了 381 个节点；但按上面那条固定路径**直接定位**到桌面组
再读图标，约几十次 IPC。2 秒轮询与现有窗口枚举同档。

**建议**：做，**单独交付**，不进 Phase。

> **已实施（2026-10-12，用户确认后独立提交）**
> - `Meal/DesktopIconIndex.swift`：可注入的 `Reader`（测试用假数据，无 AX）、
>   `icons: [String: DesktopIcon]`、`positions`、`start(interval: 2)`、`stop()`。
> - 读取路径**不匹配语言**：不再去找 description 为「桌面」的元素，而是
>   **广度优先找最浅一层「有 AXImage 子节点」的元素**，再读它的 AXImage 子节点。
>   理由：写死中文「桌面」在别的系统语言下会失效。
> - 位置取图标 **中心**（AX `position` + `size`/2），直接就是 `DisplaySpace` 的
>   左上原点、Y 向下坐标，无需换算。
> - `PetController.tryBeginIconLick` 优先用索引坐标，索引为空时退回 `DesktopIconGrid`；
>   `AppDelegate` 的幽灵图标锚点也优先用 `index.position(of: item.displayName)`。
> - 授权：启动时 `requestTrustIfNeeded(prompt: true)` 请求一次；未授权则索引为空、全程降级。
> - ⚠️ **仍未验证**：负坐标（第二显示器在左侧）与多显示器情形 —— 实验环境没有这样的布局。
> - 测试：`DesktopIconIndexTests` 4 个（注入 reader，不需要辅助功能）。总数 165 → 169。

---

## 7. 文档修正（已决定，待落盘）

| 文件 | 现文 | 改为 |
|---|---|---|
| `README.md:53` | 全局按键（Delete）：`需要辅助功能权限，**不做**；改为监听文件事件` | `**不做**：FSEvents 已覆盖删除检测，按键钩子只是冗余的提前量；权限本身不是障碍` |
| `README.md:55` | 菲比窗口捣蛋：`需要辅助功能 + 屏幕录制权限，**未实现**` | `**未实现**（整个功能尚未开工）；需要辅助功能 + 屏幕录制，两项权限均可接受` |
| `README.md` 桌面图标位置行 | `**系统没有公开 API**，用 Finder 默认布局近似（见 DesktopIconGrid），不是图标真实位置` | 若采纳 §6：`通过辅助功能读取 Finder 桌面图标真实坐标（见 DesktopIconIndex）；未授予辅助功能时降级为 Finder 默认布局近似` |
| `README.md:57` | 首次使用弹出桌面/下载目录授权 | 补一句：还会请求**辅助功能**权限用于读取桌面图标真实位置；拒绝则自动降级 |
| `TODO.md:40` | `**空闲时间用 CGEventSourceSecondsSinceLastEventType**：免权限（替代全局键盘监听）。` | `…：免权限，且无需额外监听。` |
| `TODO.md` §2 第 3 条 | LaunchAgents「**去掉了现在 osascript 方案的系统事件授权弹窗**」 | 删掉这个理由（授权弹窗是一次性的，不作为选择理由）；保留「绕开 SMAppService 的 Team-ID 签名要求」 |
| `TODO.md` §3 窗口捣蛋 | `需要**辅助功能 + 屏幕录制**两项权限，侵入性强。` | `未实现的原因是整个功能尚未开工；**辅助功能 + 屏幕录制**两项权限均可接受。` |
| `TODO.md` §2 | — | **新增**：把「评估 Accessibility API」记为**已评估、不采纳**（用于窗口跟踪），理由：拿不到 z 序、无公开 `AXUIElement → CGWindowID` 映射、覆盖面不全（Java/X11/部分游戏窗口不报）、逐属性 IPC 可能阻塞。**但**桌面图标坐标是它的正确用途（§6） |
| `TODO.md` §2 | — | **新增**：沿竖边行走（D3，下一轮） |
| `README.md` 行为差异表 | — | **新增一行**：最大化顶飞（D2）——⚠️ **必须在 Phase C 的提交里一起加**，不能提前，否则 README 会描述尚未存在的行为 |

`TODO.md` §4 的签名说明**不用改** —— 「换证书会让 macOS 忘记已授权限，所以只换一次」
正是「避免重建后重复弹窗」的本意，与用户要求一致。

---

## 8. 风险与坑

| 风险 | 说明 / 缓解 |
|---|---|
| **Phase C 是真重写** | 工作量大于 A+B+E 之和，且**中途不能留半成品**（两套跟随路径会打架）。可考虑 A+B+E+Phase 0 先合并交付（「隐形窗沿」问题立刻修掉），C 单独一次大改 |
| `t` 定义在整条边上 | 如果误定义在 `visible` 上，边被切断后棲位就会漂。**这是 Phase B 必须先把 `span`/`visible` 分开的原因** |
| 多显示器语义变化 | 见 §3.4，Phase C **保持现状**并用 mock 钉住 |
| 竖边是**新能力** | 原版没有「沿竖边走」，D3 把它推迟是对的 |
| `WindowSurfaceProvider.liveBounds` | **唯一值得保留的旧代码** —— 它已经是「每帧查单个窗口」的正确做法，只是位置该挪到 `Platform` 后面 |
| 测试数量基线 | **已实测（2026-10-12）：157 个测试，0 失败。** 旧笔记的 127 / 157 说法以本次输出为准 |
| 素材依赖 | 测试需要 `make test`（素材从 submodule 硬链），否则 `TestSkip.missingAssets` 会让测试**失败**（不是跳过） |

---

## 9. 明确不做

- webview overlay 渲染器；Ledgeling 的 pack 格式；声明式 pack 驱动 FSM；
  awareness/nudge 阶梯；packs → 多宠。
- 渲染协议层（D4）。
- 自适应扫描节奏（D5）。
- 跨显示器行走语义的重设计（只钉住现状）。
- 沿竖边行走（D3，下一轮）。
- 签名 / 发布 / App Store，以及 `TODO.md` 里已经诚实记录为未完成的所有事项。

---

## 10. 参考：Ledgeling 里值得一读的具体位置

| 主题 | 位置 |
|---|---|
| macOS 平台层（`CGWindowListCopyWindowInfo(1\|16, 0)`） | `src-tauri/src/platform/macos.rs:114`、`:170` |
| z 序 = 列表顺序（`z_index: windows.len()`） | 同上，约 `:135` |
| 全屏检测（layer-0 逐边贴合 ±2px） | `platform/macos.rs` 与 `world/` |
| surface 图 / 遮挡减法 / 边界用例测试 | `src-tauri/src/world/` |
| `STARTLING_SPEED = 900` | `src-tauri/src/pet/` |
| 隐私源码扫描测试（**仅作参考，本项目不采用**） | `src-tauri/tests/privacy.rs` |
