# 架构

macOS 重写版 JiuNuoDesktopPet（原版是 C#/WPF 的 Windows 桌宠）。当前只做糯糯；
菲比、双宠同屏、窗口恶作剧均暂缓。

> 引用「本项目的约定」之前，先 grep 本仓库。历史上曾把别的仓库（Ledgeling、上游 submodule）
> 的规则当成本项目约定，据此论证过三个错误结论：「窗口标题永不读取」（本仓库无此说法）、
> 「零权限」（用户明确没有隐私要求，一次性 TCC 提示可接受）、「never commit to `main`」（本仓库
> 只有 `main`，全部直接提交）。**权限成本不能作为设计理由** —— 唯一有效的偏好是「重建后不为
> 同一权限重复提示」，那由稳定的签名身份解决（见 `signing.md`），不是靠避免权限。

## 世界模型

- `Platform/` —— `Platform` 协议只有 `windows()` 与 `monitors()` 两个方法。
  `MacOSPlatform` 是**唯一**调用 `CGWindowListCopyWindowInfo` / `NSScreen` 的地方；
  `MockPlatform` 供测试使用。
- `World/` —— `Surface` 图。`SurfaceBuilder.build(windows:monitors:isTerrain:occludes:)`
  做一维遮挡减法；`Surface.span` 是**整条边**，`Surface.visible` 是未被遮挡的若干段
  （中间被挡会留下**两段**）。`SurfaceProvider` 持有这张图；`FullscreenDetector` 是纯函数。
- `Pet/Perch.swift` —— `{key, t}`，她的支撑。`PetController` 每帧把她放到当前 surface 上；
  走动时把 `foot.x` 折回 `t`。
- `SupportSurface` 与 `TerrainWindow` 已被删除（不是弃用）。

## 窗口建模（思路来自 Ledgeling）

核心决定：**不把窗口建模成对象，而是每轮从矩形重新推导出一整张几何图。**

一次枚举（`MacOSPlatform.windows()`）只取几何与少量身份字段：
窗口号、owner PID、owner 名、bounds（已是左上原点、Y 向下）、layer、alpha，
以及**列表下标作为 z 序**（`CGWindowListCopyWindowInfo` 的列表顺序就是前后顺序）。
**不读窗口标题。**

由此派生三层数据：

1. **`Surface`** —— 每个窗口四条边各一条（`SurfaceKey{owner: 窗口号, kind}`），
   外加每个显示器一条 `floor`（owner 是显示器 id）。`Surface.span` 是**整条边**；
   `Surface.visible` 是未被遮挡的若干段。
   **只有 `windowTop` 与 `floor` 被标为可站立**；另外三条边照建但本轮不用。
2. **`WindowBody`** —— `{bounds, zIndex}`，回答「她的身体这个面积被谁盖住」这类
   一维边表达不了的问题。
3. **`Perch`** —— `{key, t}`，她在某条边上的位置；`t` 是沿 **`span`（整条边）**
   的 0…1，不是世界坐标。被遮挡段也占 `t`，所以一条被切开的边对同一处物理位置
   给出同一个 `t`。

**遮挡 = 一维区间减法**：对第 i 个窗口，只减去列表里**更靠前**（`windows[..i]`）的窗口
与这条边的重叠。输入只有矩形与顺序。结果是 `[Span]` 而不是单个区间 ——
中间被挡会留下**两段**，空列表表示整条边不可见。

### 为什么这样做

- 窗口移动/缩放被**精确且免费**地跟随：世界坐标每帧从当前几何重算，不需要速度匹配，
  也没有跟随时序抖动。
- 不依赖窗口标题、应用集成或任何权限，对任何 app 一视同仁。
- 遮挡是纯区间运算，可以用纯函数测试（`SurfaceBuilderTests`）钉住，不需要真实桌面。

### 代价与边界

- 遮挡是**沿边的一维**判定，表达不了「一个窗口从侧面挡住她的身体」——
  那由 `coveringWindow`（`WindowBody` + z 序）负责。
- 图是**有延迟的**：2 Hz 重建，下落期按时间 + 距离门控（约 5.5 Hz）。
  所以落地判定不能依赖图的刷新率，见 `physics.md`。
- `visible` 只回答「这条线有没有被盖住」，不是面积判定。
- **什么样的窗口算「普通窗口」由资格策略决定**：`layer == 0`、alpha ≥ 0.05、
  不是自己的 PID、owner 不在 chrome 名单里（Window Server / Dock / 控制中心 /
  通知中心 / Spotlight / SystemUIServer / WindowManager / loginwindow / universalaccessd）、
  且不小于 140×60。这条策略与「它的顶边在哪」是两个独立问题，见 `physics.md`。

### 读取频率是分层的（关键设计）

| 用途 | 频率 | 来源 |
| --- | --- | --- |
| 地形图（可站立的边 + 遮挡） | 2 Hz；下落期门控约 5.5 Hz | 全量枚举 |
| 身体采样（封闭候选、遮挡身体、侧撞） | 10 Hz | 全量枚举 |
| 跟随当前支撑的窗口 | **每帧** | 单窗口实时读 |

**「跟随」不用图**，因为图有最多 0.5 s 的滞后；单窗口实时读只回答「这个特定窗口现在在哪」，
约 0.095 ms。所以「她脚下的窗口」是实时的，「世界上有哪些边」是慢的。

### 身份稳定性

`SurfaceKey.owner` 是窗口号，在窗口存活期间稳定，所以同一条边在多次图重建之间保持同一个 key，
`Perch` 因此能在图重建后继续指代同一处物理位置。窗口关闭后 key 从图里消失，
支撑查找失败即按「支撑消失」处理（`maintainGroundSupport` → 下落）。

## 目录

- `Sources/NuonuoChuuby/` —— 可执行文件，只有 `main.swift`（NSApplication 启动）。
- `Sources/NuonuoChuubyCore/` —— 其余全部，按子系统分：
  `Platform App Sprite Physics Life Voice Dialogue Cheek World Meal System Asset Settings`。
- `Tests/NuonuoChuubyCoreTests/` —— swift-testing。**测试数量以 `make test` 实际输出为准。**
- `Vendor/JiuNuoDesktopPet` —— 上游 submodule（资源 + C# 参考实现）。
- `App/Info.plist`、`Makefile`、`Tools/`、`README/NOTICE/LICENSE`。

## 依赖注入接缝

- `PetPresenting`：渲染方式的接缝（历史上用于在「全屏 overlay / 移动面板」之间切换；
  现在只有 overlay 一个实现，但协议与工厂仍在，避免把渲染细节漏进 controller）。
- `Platform`：所有窗口/显示器查询。
- `PetMealDelegate`、`PetControllerDelegate` 等协议的**扩展给默认空实现**，
  所以测试 spy 不必为新增方法全部实现。
- `DiagnosticsLog.shared` 是单例，但可 `configure(fileURL:enabled:)`，测试可指向临时文件。

**新增功能的典型做法**：纯逻辑抽成 struct/enum（可单测），副作用留在 controller/app 层。
项目里大量 `*Policy` 类型就是这种「纯函数策略」。

## 设置存储（一个已知的易踩点）

`SettingsStore.load()` 在解码失败时**直接 `return PetSettings()`**，而 Swift 合成的
`Decodable` **不使用属性默认值** —— 缺 key 就抛。合起来的结果是：
**给 `PetSettings` 增加任何新字段，都会让已有用户的全部设置被静默重置。**

- 目前只有一个用户且自用，所以**没有**逐字段 `init(from:)`。
- 若日后需要保留旧设置，这是必须先修的地方（补自定义 `init(from:)` 或改用
  `decodeIfPresent` + 默认值）。
- 相关：`configure(fileURL:maximumBytes:enabled:)` 在启动时直接设初值、不写日志行，
  所以「日志关闭状态下启动」一行都不写（连 `ProcessStarted` 都没有）。
  为此外层把**设置加载提到 `configure` 之前**。

## 参考实现：Ledgeling（Rust/Tauri 的 macOS 桌宠）

只借思路，**不复制代码、不依赖上游任何 commit**。上游于 `402f60be` 从 MIT 改为
**PolyForm Strict**（禁止分发与修改）；用户的 fork `balthild/Ledgeling` 停在仍是 MIT 的
`0b0014b9`，参考的内容都在这个 pin 上。下列取舍在出现新证据之前为**终态**。

**定位（fork `0b0014b9`）**：macOS 平台层在 `src-tauri/src/platform/macos.rs`
（`CGWindowListCopyWindowInfo(1|16, 0)`、把列表下标直接当 `z_index`），地形图 / 遮挡减法 /
边界用例在 `src-tauri/src/world/`，`STARTLING_SPEED = 900` 在 `src-tauri/src/pet/`。
它的 `tests/privacy.rs`（源码扫描）本项目不采用。

> 其中两条思路已经落到本项目的具体结构里：位置用 `(SurfaceKey, t)` 而不是世界坐标、
> 遮挡用一维区间减法。完整说明见上面的「窗口建模」。

**采纳**

- **桌宠位置是 `(SurfaceKey{owner,kind}, t)`，不是世界坐标。** 世界坐标每帧按当前表面重算，
  所以窗口移动/缩放被精确且免费地跟随 —— 不需要速度匹配，不会抖动。
  `t` 定义在**整条边**上（含被遮挡段），所以被别的窗口切开的边仍用同一个 `t`。
- **遮挡 = 一维区间减法**：对每个窗口，只有列表里更靠前的窗口遮挡它；沿边减去重叠。
  输入只有窗口矩形 + 列表顺序。
- **`CGWindowListCopyWindowInfo` 只用几何相关的 key**（number/layer/bounds/alpha/ownerPID/isOnscreen）。
- **快速移动窗口 → 保留「抛出」，但作为一条显式的释放规则**（perch = nil + 初速），
  不做速度匹配。阈值对齐到 900 pt/s。
- **全屏 = 一个 layer-0 窗口匹配某显示器 bounds（误差 2 px 内）**，实现为**纯函数**，
  不是 `Platform` 方法。
- **零显示器 = 会话锁定 → 挂起**，绝不当成空桌面。

**否决**

- **扫描 2 Hz、变化后 2 s 内 10 Hz**：我们已经 2 Hz，而跟随不用那张图（逐帧单窗口实时读）。
- **idle 30 Hz / 移动 60 Hz 的固定渲染节拍**：我们按精灵剪辑逐帧渲染。
- **用 `CGEventSourceSecondsSinceLastEventType` 取系统 idle 时间**：本应用不消费。
- **混合 DPI 的逐显示器缩放**：我们用点工作，绕开了它（真机混合 DPI 仍未验证）。
- **webview overlay 渲染器、包格式、声明式 pack FSM、awareness 提示阶梯、packs→多宠、
  `PetSurface`/`Scene` 渲染协议**：我们有程序化捏脸形变、幽灵图标、气泡；单个 overlay
  表达不了它们，抽象没有第二实现。
- **跨显示器行走语义的重设计**：只**钉住现状**（每个显示器边界反弹的语义不变），
  不趁机重设计。

**部分采纳**

- 用 `~/Library/LaunchAgents` plist 自启可能仍优于 `osascript`，
  但「避免 System Events 提示」这个理由**无效** —— 一次性提示没问题。

## 坐标与单位

- 仿真用**点**，左上原点、Y 向下（对齐原版的 DIP 模型，所以 `displayScale = 1`）。
  `DisplaySpace` 负责 AppKit 的 Y 翻转。
- 画布空间是 512 单位；运行时帧是 384 px（`SpriteGeometry.canvasToRuntime`）。
  **所有精灵锚点都是画布单位。**
- 唯一例外：捏脸装配用的是 **384 px 精灵空间**（上游就是拿 `point * 384 / 512` 去判定的），
  所以 `CheekPinchGeometry.geometry` 把字面量整体乘 `512/384` 折算回画布单位。
  见 `rendering.md`。
