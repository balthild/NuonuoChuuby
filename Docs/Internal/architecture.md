# 架构

macOS 重写版 JiuNuoDesktopPet（原版是 C#/WPF 的 Windows 桌宠）。当前只做糯糯；菲比、双宠同屏、窗口恶
作剧均暂缓。

> 引用「本项目的约定」之前，先 grep 本仓库。历史上曾把别的仓库（Ledgeling、上游 submodule）的规则当
> 成本项目约定，据此论证过三个错误结论：「窗口标题永不读取」（本仓库无此说法）、「零权限」（用户明确
> 没有隐私要求，一次性 TCC 提示可接受）、「never commit to `main`」（本仓库只有 `main`，全部直接提
> 交）。**权限成本不能作为设计理由** —— 唯一有效的偏好是「重建后不为同一权限重复提示」，那由稳定的签
> 名身份解决（见 `signing.md`），不是靠避免权限。

## 世界模型

- `Platform/` —— `Platform` 协议只有 `windows()` 与 `monitors()` 两个方法。 `MacOSPlatform` 是**唯
  一**调用 `CGWindowListCopyWindowInfo` / `NSScreen` 的地方； `MockPlatform` 供测试使用。
- `World/` —— `Surface` 图。`SurfaceBuilder.build(windows:monitors:isTerrain:occludes:)` 做一维遮挡
  减法；`Surface.span` 是**整条边**，`Surface.visible` 是未被遮挡的若干段（中间被挡会留下**两
  段**）。`SurfaceProvider` 持有这张图；`FullscreenDetector` 是纯函数。
- `Pet/Perch.swift` —— `{key, t}`，她的支撑。`PetController` 每帧把她放到当前 surface 上；走动时把
  `foot.x` 折回 `t`。
- `SupportSurface` 与 `TerrainWindow` 已被删除（不是弃用）。

## 窗口建模（思路来自 Ledgeling）

核心决定：**不把窗口建模成对象，而是每轮从矩形重新推导出一整张几何图。**

一次枚举（`MacOSPlatform.windows()`）只取几何与少量身份字段：窗口号、owner PID、owner 名、bounds（已
是左上原点、Y 向下）、layer、alpha，以及**列表下标作为 z 序**（`CGWindowListCopyWindowInfo` 的列表顺
序就是前后顺序）。 **不读窗口标题。**

由此派生三层数据：

1. **`Surface`** —— 每个窗口四条边各一条（`SurfaceKey{owner: 窗口号, kind}`），外加每个显示器一条
   `floor`（owner 是显示器 id）。`Surface.span` 是**整条边**； `Surface.visible` 是未被遮挡的若干
   段。**只有 `windowTop` 与 `floor` 被标为可站立**；另外三条边照建但本轮不用。
2. **`WindowBody`** —— `{bounds, zIndex}`，回答「她的身体这个面积被谁盖住」这类一维边表达不了的问
   题。
3. **`Perch`** —— `{key, t}`，她在某条边上的位置；`t` 是沿 **`span`（整条边）** 的 0…1，不是世界坐
   标。被遮挡段也占 `t`，所以一条被切开的边对同一处物理位置给出同一个 `t`。

**遮挡 = 一维区间减法**：对第 i 个窗口，只减去列表里**更靠前**（`windows[..i]`）的窗口与这条边的重
叠。输入只有矩形与顺序。结果是 `[Span]` 而不是单个区间 —— 中间被挡会留下**两段**，空列表表示整条边不
可见。

### 为什么这样做

- 窗口移动/缩放被**精确且免费**地跟随：世界坐标每帧从当前几何重算，不需要速度匹配，也没有跟随时序抖
  动。
- 不依赖窗口标题、应用集成或任何权限，对任何 app 一视同仁。
- 遮挡是纯区间运算，可以用纯函数测试（`SurfaceBuilderTests`）钉住，不需要真实桌面。

### 代价与边界

- 遮挡是**沿边的一维**判定，表达不了「一个窗口从侧面挡住她的身体」—— 那由
  `coveringWindow`（`WindowBody` + z 序）负责。
- 图是**有延迟的**：2 Hz 重建，下落期按时间 + 距离门控（约 5.5 Hz）。所以落地判定不能依赖图的刷新
  率，见 `physics.md`。
- `visible` 只回答「这条线有没有被盖住」，不是面积判定。
- **什么样的窗口算「普通窗口」由资格策略决定**：`layer == 0`、alpha ≥ 0.05、不是自己的 PID、且不小于
  140×60。`layer == 0` 同时也是全部的系统外壳过滤 —— Dock 在 20、菜单栏在 24、控制中心在 25，都高于
  0。**曾经还有一张 owner 名字黑名单，已删除**：`kCGWindowOwnerName` 是**本地化**的（中文系统上报
  「程序坞」「控制中心」），英文名单从来匹配不上，而这些窗口本来就靠 `layer != 0` 被排除了。这条策略
  与「它的顶边在哪」是两个独立问题，见 `physics.md`。

### 读取频率是分层的（关键设计）

| 用途 | 频率 | 来源 |
| - | - | - |
| 地形图（可站立的边 + 遮挡） | 2 Hz；下落期门控约 5.5 Hz | 全量枚举 |
| 身体采样（封闭候选、遮挡身体、侧撞） | 10 Hz | 全量枚举 |
| 跟随当前支撑的窗口 | **每帧** | 单窗口实时读 |

**「跟随」不用图**，因为图有最多 0.5 s 的滞后；单窗口实时读只回答「这个特定窗口现在在哪」，约 0.095
ms。所以「她脚下的窗口」是实时的，「世界上有哪些边」是慢的。

### 身份稳定性

`SurfaceKey.owner` 是窗口号，在窗口存活期间稳定，所以同一条边在多次图重建之间保持同一个 key，
`Perch` 因此能在图重建后继续指代同一处物理位置。窗口关闭后 key 从图里消失，支撑查找失败即按「支撑消
失」处理（`maintainGroundSupport` → 下落）。

## 目录

**Core 已按模块拆成多个 SwiftPM target。** 模块**只能依赖更低的模块**（无环），这是编译器强制的约
束：

| 模块 | 内部子目录 | 内容 |
| - | - | - |
| `PetFoundation` | `Common` `Vocabulary` `Physics` | 纯类型与策略，不依赖任何其它模块 |
| `PetDesktop` | `Platform` `Presentation` `World` | 读取桌面（窗口/显示器/地形图）与绘制几何 |
| `PetMedia` | `Asset` `Sprite` `Voice` | 美术与语音的加载、播放 |
| `PetBehaviour` | `Settings` `Life` `Meal` `Dialogue` | 她的状态、需求，以及吃东西/说话这些事 |
| `Pet` | `Cheek` | 她本人：大脑、身体与 overlay |
| `PetApp` | `App` `System` | 菜单栏与全部接线 |

- **模块边界是这次重构唯一的强制手段。** 2026-11 的重构先把 15 个目录之间**已经存在**的循环依赖解开
  （当时 14 个目录构成单一强连通分量），再按上表的层次切分 —— 因为 SwiftPM 的模块不允许成环。破环本
  身（`Presentation`/`Vocabulary` 的抽出、`DisplaySpace`/`DiagnosticsLog` 的下沉等）与模块切分是两件
  独立的事：前者修的是真实的归档错误，后者只是让它不再长回来。
- **跨模块使用符号要 `public`**（本仓库不对 API 稳定性作保证，所以这不是负担）。更重要的副作用是
  `internal` 重新变成「模块内可见」—— 这正是 `PetController` 内部能拆成多个文件、而不向全 app 暴露的
  原因。
- **改一个文件只重编它所在的模块。** 实测：改 `Pet` 模块 2.5 s；改底层而接口未变时下游会被整体跳过
  （llbuild 按输出签名判断）。拆分前任何一处改动都要重编整个 Core，9 s。
- 新增类型时先看它依赖什么再决定目录：跨子系统共用的「无行为」类型进 `Vocabulary`，被多个渲染方共用
  的几何进 `Presentation`。
- 依赖方向合法但概念上倒置的两条仍待修正：`Life → Settings`（成因是 `@Fallback` 属性包装器）与
  `System → Physics`（菜单栏 UI 直接用 `PetSizePolicy`）。

- `Sources/NuonuoChuuby/` —— 可执行文件，只有 `main.swift`（NSApplication 启动）。
- `Tests/NuonuoChuubyTests/` —— swift-testing。**测试数量以 `make test` 实际输出为准。**
- `Vendor/JiuNuoDesktopPet` —— 上游 submodule（资源 + C# 参考实现）。
- `App/Info.plist`、`Makefile`、`Tools/`、`README/NOTICE/LICENSE`。

## 依赖注入接缝

- `PetPresenting`：渲染方式的接缝（两个实现：默认的网格小窗口 `PetPanelWindowController` 与
  `--pet-overlay` 的全屏 `OverlayPetWindowController`）。协议把渲染细节挡在 controller 外面。
- `Platform`：所有窗口/显示器查询。
- `PetMealDelegate`、`PetControllerDelegate` 等协议的**扩展给默认空实现**，所以测试 spy 不必为新增方
  法全部实现。
- `DiagnosticsLog.shared` 是单例，但可 `configure(fileURL:enabled:)`，测试可指向临时文件。

**新增功能的典型做法**：纯逻辑抽成 struct/enum（可单测），副作用留在 controller/app 层。项目里大量
`*Policy` 类型就是这种「纯函数策略」。

## 存档文件的容错（`@Fallback`）

两份持久化文件——设置（`SettingsStore`）与养成状态（`PetLifeStateStore`）——的读法都是「解码抛异常就整
份丢弃、回落到全新默认值」；而 Swift 合成的 `Decodable` **不使用属性默认值**，缺 key 或类型不符就
抛。两者合起来，曾经意味着「给 `PetSettings` / `PetLifeState` 加一个字段，就把已有用户的全部设置或全
部养成记录静默重置」。

所以这两个 struct 的**每个字段**都包在 `@Fallback<...Default.X>` 里：缺 key、非可选字段上的 `null`、
值类型不符，都只影响那一个字段，其余照常读出。

- 实现：`Sources/PetBehaviour/Settings/Fallback.swift`（与 CalendarShouter 的
  `Settings/Fallback.swift` 是同一份）。行为由 `SettingsStoreTests.swift` 与
  `PetLifeStateStoreTests` 钉住。
- 字段的默认值**不在字段上**，而在 `PetSettingsDefault` / `PetLifeStateDefault` 里的同名 provider ——
  `FallbackProvider` 协议只带一个 `Value` 类型，没有地方放值，所以每个字段都要有自己的 provider 类
  型。
- **新增字段 = 一个 `@Fallback` + 一条 provider。** 不加 `@Fallback` 的字段会把整份文件拖下水（它一
  缺 key，`load()` 就整体回落到默认值），这是唯一还要记住的规矩。
- `fallbackValue` 可以是**计算属性**，`PetLifeStateDefault.LastUpdated` 就用了这一手：文件里没有时间
  戳时按「就是现在」处理，否则会被读成一段漫长缺席，把四项需求一次性抽干。要用「每次新生成一个」作默
  认值（例如新 identifier）时同理。
- 相关：`configure(fileURL:maximumBytes:enabled:)` 在启动时直接设初值、不写日志行，所以「日志关闭状
  态下启动」一行都不写（连 `ProcessStarted` 都没有）。为此外层把**设置加载提到 `configure` 之前**。

## 参考实现：Ledgeling（Rust/Tauri 的 macOS 桌宠）

只借思路，**不复制代码、不依赖上游任何 commit**。上游于 `402f60be` 从 MIT 改为 **PolyForm
Strict**（禁止分发与修改）；用户的 fork `balthild/Ledgeling` 停在仍是 MIT 的 `0b0014b9`，参考的内容
都在这个 pin 上。下列取舍在出现新证据之前为**终态**。

**定位（fork `0b0014b9`）**：macOS 平台层在 `src-tauri/src/platform/macos.rs`
（`CGWindowListCopyWindowInfo(1|16, 0)`、把列表下标直接当 `z_index`），地形图 / 遮挡减法 / 边界用例
在 `src-tauri/src/world/`，`STARTLING_SPEED = 900` 在 `src-tauri/src/pet/`。它的
`tests/privacy.rs`（源码扫描）本项目不采用。

> 其中两条思路已经落到本项目的具体结构里：位置用 `(SurfaceKey, t)` 而不是世界坐标、遮挡用一维区间减
> 法。完整说明见上面的「窗口建模」。

**采纳**

- **桌宠位置是 `(SurfaceKey{owner,kind}, t)`，不是世界坐标。** 世界坐标每帧按当前表面重算，所以窗口
  移动/缩放被精确且免费地跟随 —— 不需要速度匹配，不会抖动。 `t` 定义在**整条边**上（含被遮挡段），所
  以被别的窗口切开的边仍用同一个 `t`。
- **遮挡 = 一维区间减法**：对每个窗口，只有列表里更靠前的窗口遮挡它；沿边减去重叠。输入只有窗口矩
  形 + 列表顺序。
- **`CGWindowListCopyWindowInfo` 只用几何相关的
  key**（number/layer/bounds/alpha/ownerPID/isOnscreen）。
- **快速移动窗口 → 保留「抛出」，但作为一条显式的释放规则**（perch = nil + 初速），不做速度匹配。阈
  值对齐到 900 pt/s。
- **全屏 = 一个 layer-0 窗口匹配某显示器 bounds（误差 2 px 内）**，实现为**纯函数**，不是 `Platform`
  方法。
- **零显示器 = 会话锁定 → 挂起**，绝不当成空桌面。

**否决**

- **扫描 2 Hz、变化后 2 s 内 10 Hz**：我们已经 2 Hz，而跟随不用那张图（逐帧单窗口实时读）。
- **idle 30 Hz / 移动 60 Hz 的固定渲染节拍**：我们按精灵剪辑逐帧渲染。
- **用 `CGEventSourceSecondsSinceLastEventType` 取系统 idle 时间**：本应用不消费。
- **混合 DPI 的逐显示器缩放**：我们用点工作，绕开了它（真机混合 DPI 仍未验证）。
- **webview overlay 渲染器、包格式、声明式 pack FSM、awareness 提示阶梯、packs→多宠、
  `PetSurface`/`Scene` 渲染协议**：我们有程序化捏脸形变、幽灵图标、气泡；单个 overlay 表达不了它们，
  抽象没有第二实现。
- **跨显示器行走语义的重设计**：只**钉住现状**（每个显示器边界反弹的语义不变），不趁机重设计。

**部分采纳**

- 用 `~/Library/LaunchAgents` plist 自启可能仍优于 `osascript`，但「避免 System Events 提示」这个理
  由**无效** —— 一次性提示没问题。

## 坐标与单位

- 仿真用**点**，左上原点、Y 向下（对齐原版的 DIP 模型，所以 `displayScale = 1`）。 `DisplaySpace` 负
  责 AppKit 的 Y 翻转。
- 画布空间是 512 单位；运行时帧是 384 px（`SpriteGeometry.canvasToRuntime`）。 **所有精灵锚点都是画
  布单位。**
- 唯一例外：捏脸装配用的是 **384 px 精灵空间**（上游就是拿 `point * 384 / 512` 去判定的），所以
  `CheekPinchGeometry.geometry` 把字面量整体乘 `512/384` 折算回画布单位。见 `rendering.md`。
