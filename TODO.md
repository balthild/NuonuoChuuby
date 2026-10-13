# 待办与已知问题

本文件记录**已知但尚未解决**的问题，以及有意推迟的工作。已完成的能力见 `README.md`。

---

## 1. 窗口骑乘：弹起后停在高处（**已由重构根除**，2026-10-12）

**原现象**（用户报告）：快速上甩窗口后，桌宠弹起并停在一个较高的位置不再下落；用户认为那个高度「应该没有窗沿」。

**根因**：旧模型用「世界坐标 + 速度匹配 + 一个可按 id 追踪的窗口」表达支撑，这套机制允许出现「处于落地/待机状态、但没有任何支撑」这一状态 —— 那就是真正的悬空。

**为什么现在不可能再发生**：重构 Phase C 把支撑换成参数化棲位 `(SurfaceKey, t)`（见
`docs/refactor-plan.md`）。`maintainGroundSupport` 每 tick 对 `idle / running / sleeping /
landing / curious` 五种落地状态运行，且只有两条路：

- 已有棲位 → 解析出当前 surface；解析不到则走 0.35 s 宽限，宽限过期即 `releasePerch()` + `beginFall()`；
- 没有棲位 → `acquirePerch()`：要么找到 surface 并锚定，要么 `beginFall()`。

即：**落地状态与「没有支撑」不能并存**。新增的 `neverFloating` 测试（4000 tick 慢速拖拽）
逐 tick 断言这条不变量。

**验证状态（诚实说明）**：本条**没有**重做手工拖拽复现 —— 真实拖拽无法脚本化
（AppleScript 的 `set bounds` 是瞬移，不是手势）。依据是**结构性不变量** + 4000 tick 测试
+ 实测日志中 **0 条**非 `falling` 的 `Support="none"` 心跳。若再次观察到该现象，按新问题处理。

**如何确诊（保留）**：读 `~/Library/Application Support/NuonuoChuuby/activity.log` 里的
`StatusHeartbeat`（每 10 秒一条）：`Support="none"` 且 `State` 不是 `falling` = 真悬空。

---

## 2. 从 Ledgeling 参考到的改进（**有意推迟**）

参考项目：<https://github.com/Lucerna-Systems/Ledgeling>（Rust/Tauri，macOS 桌宠）。值得借鉴、但尚未实施：

> **处置状态（2026-10-12）**：全面定案见 `docs/refactor-plan.md`。
> 第 1、2、4、5 条**由重构实施**；第 3、6 条的「免权限/免弹窗」理由**已撤回**；
> 第 7 条保留但改成**显式释放规则**；第 8 条**不采纳**；第 9 条为新增的延后项。

1. **参数化锚定（重构）**：把宠物位置存成 `(SurfaceKey{owner,kind}, t)` 而非世界坐标，每帧由当前 surface 反算屏幕位置。窗口移动/缩放由此**免费且精确**跟随，不需要速度判定，也不会有抖动。`t` 定义在**整条边**（含被遮挡部分）上，所以边被别的窗口切断后锚点依然有效。这是根治「抖 / 误触发 / 脱离」的方案，但改动较大。
2. ~~**遮挡减法**：按 z 序（窗口列表顺序，front-to-back）做一维区间减法，只保留**可见**的边。输入只需窗口矩形 + 顺序。当前实现不做减法，所以桌宠可能站在被别的窗口盖住的**隐形窗沿**上。~~
   **已实施（2026-10-12，重构 Phase B）**：`World/SurfaceBuilder.swift` 按窗口列表顺序做一维区间减法，`Surface.span`（整条边）与 `Surface.visible`（未遮挡片段，可能多段）分离。`SurfaceProvider` 只把可见片段派生成可站的 `SupportSurface`。见 `docs/refactor-plan.md` Phase B。
3. **开机自启改用 `~/Library/LaunchAgents` plist**：绕开 `SMAppService` 的 Team-ID 签名要求。（原先还写了「去掉了现在 `osascript` 方案的系统事件授权弹窗」这个理由，**已撤回**：授权弹窗是一次性的，不构成设计理由。）
4. ~~**锁屏 / 零显示器当作挂起**：macOS 在锁屏或显示器休眠时会报告「零个显示器」，绝不能当成空桌面。当前 `DisplaySpace` 会退化成默认矩形，属于同类 bug。~~
   **已实施（2026-10-12，重构 Phase E）**：`PetController.step` 在 `displaySpace.displays.isEmpty`
   时直接返回 —— 不模拟、不位移。显示器恢复非空即继续。
5. ~~**全屏应用时挂起**：识别方式是「存在一个 layer-0 窗口逐边贴合某显示器 bounds（±2px）」。~~
   **已实施（2026-10-12，重构 Phase E）**：`World/FullscreenDetector.swift` 是**纯函数**
   `isFullscreenAppActive(windows:monitors:)`，由 `SurfaceProvider.refresh` 每 2 Hz 求值，
   `PetController.step` 据此挂起。注意：**最大化**（绿钮）的窗口停在菜单栏之下，不会误判为全屏。
   **挂起时隐藏她（2026-10-12，用户报告后修改）**：原先挂起只让 `step` 提前返回，而 `animator.tick`
   在返回之后 —— 于是她带着**固定的一帧**浮在全屏应用之上，读起来像坏了（拖动才会换一帧，
   然后再次固定）。现在 `PetController` 上报 `didChangeSuspension`，`PetWindowController` 隐藏/恢复
   自己的面板，`AppDelegate` 顺带收起气泡与幽灵图标（一次进行中的进食被打断时，幽灵图标也要一起
   收起，否则同样会留在全屏应用上）。原项目**没有**任何全屏处理（全屏只在菲比捣蛋选目标时被用来
   排除），所以这是本移植版自己的取舍，已记入 README 行为差异表。>
> **挂起恢复时位移基准必须重设（2026-10-12，用户报告）**：`PetController` 里每个「运动」都是
> **两次采样之差 ÷ 一帧**（骑乘的地面、盒子的四壁、扫过她的窗口边）。挂起期间这些都不被询问，
> 基准值也不会更新；恢复的第一帧于是把**整个挂起期**的位移除以**一帧**，普通移动被读成「有什么
> 东西猛拽过她」。实测复现的正是最后一条：**侧撞**（日志 `WindowSideImpact EdgeVelocityX="1100"`
> —— 钳制上限，说明原始差值远超真实边速），她被打飞 400pt。
> `resumeFromSuspension()` 重设三处基准（`lastPerchOffset`、`enclosure.previousBox`、窗口矩形采样）。
> **注意清空 `previousWindowBodies` 并不够**：`windowBodies` 本身也停在挂起前，下次采样会把它当成
> 「上一次」，坏配对只是被推迟一次采样。所以 `SurfaceProvider` 用一个 `nextBodySampleIsBaseline`
> 标记，让重基线后的第一个采样**以自己为基准**（差值为零）。
> 同时补了两个诊断事件：`FallStarted`（原项目 C# 有、我们缺；`beginFall` 原先只设 `fallReason`
> 而从不记录它，导致任何位置异常都无法定位原因）与 `SuspensionChanged`。6. **空闲时间用 `CGEventSourceSecondsSinceLastEventType`**：免权限，且无需额外监听。（免权限是附带好处，不是选择理由。）
7. **窗口快速移动 = 「受惊」反应，而不是把宠物甩出去**（`STARTLING_SPEED = 900`）。我们目前保留原版的抛出行为，阈值已对齐 900。
8. ~~**扫描节奏**：2 Hz 常态，变化后 2 秒内 10 Hz；挂起时完全不扫描。渲染静止 30 Hz / 移动 60 Hz。~~
   **不采纳**：常态**已经**是 2 Hz（`SurfaceProvider.refreshInterval = 0.5`），
   且跟随精度不走那张图（走每帧单窗口实时查询 `liveSurface`/`liveBounds`），
   只影响「新窗沿被发现」的延迟，收益极低。**但第 4、5 条的「挂起」仍然要做。**

9. **沿竖边行走 / 沿竖边栖位**（重构后才谈得上）：当前只有水平边（窗口顶边 + 地面）。
   参数化锚定落地后，竖边会被建进图但**只启用顶边**；沿竖边走留到下一轮。

---

## 3. 未实现的角色与功能

- **菲比啾比**：`PetCharacterProfile` 的间接层已完整保留，角色专属分支（食物、捣蛋）也已就位，属增量工作而非合并。
- **双宠共存 / 配对互动**：依赖菲比。
- **窗口捣蛋**（踢、藏帽、撕裂真实窗口）：**未实现的原因是整个功能尚未开工**；所需**辅助功能 + 屏幕录制**两项权限均可接受。

> 「窗口容器」与「窗口侧撞」已于 2026-10-12 移植（`WindowEnclosurePhysics`、
> `WindowSideCollisionPolicy`、`WindowEnclosureEligibilityPolicy`）。它们此前**既未实现、
> 也未在任何文档里记为取舍**，只是 `LandingVoicePolicy` 里两个没有生产者的死字符串
> （`"WindowSideImpact"` / `"EnclosureWindowLost"`）；现已补进 README 的行为差异表。
>
> 同一批还加了一条**上游没有**的处理：**容器被更前置的窗口盖住超过 0.6 s，就不再算那个盒子**
> （`WindowOcclusionPolicy`）。**盖住她的那个窗口若装得下她（与拖拽入场同一判据 `bodyFits`），
> 她就改由它抱着**（`WindowEnclosureTransferred`）；只有装不下才放下她（`EnclosureCovered`）。
> 选「遮住她的窗口里最靠前的那个」不是随意 —— 比它更靠前又能把她也遮住的窗口会自己成为
> 选中者，所以这个选择不可能来回震荡。
> 原因是桌宠的窗口层级无法插进两个普通窗口之间（它们都在 CGWindowLevel 0），所以被盖住的
> 盒子会让她看起来悬空。**这不能修好部分遮挡**：被挡住的半边仍然画在前置窗口之上（置顶
> overlay 的固有性质）；要像素级正确需要逐窗 ScreenCaptureKit 捕捉，代价与滞后都不值得。
> 宽限期是 `PetController.enclosureCoverageGraceSeconds`（0.6 s）。
> 注意：**盖住她的窗口必须遮住她可能出现的位置**。只盖住容器一部分、而她恰好落在未遮住
> 的那部分时，宽限期会重置 —— 这是对的（她在那里看得见）。
>
> 入场选取的是**最靠前的**那个装得下她的窗口，不是面积最小的。按面积选会让「被大窗口遮住
> 的小窗口」把她抢走，而遮挡规则接着又把她交给大窗口 —— 连着两次捕获，看起来就是下落了
> 两段。按 z 序选同时保留了「大窗口里套着一个小窗口时她进小窗口」这个原有行为。
> `MockPlatform.windows()` 现在也按列表顺序赋 `zIndex`（与 `MacOSPlatform` 一致），
> 否则默认全 0，任何读 z 序的 mock 测试都是哑的。
>
> 入场还有第二道条件：**她脚下到盒底之间不能有可站的窗沿**。有就先落在那条窗沿上，
> 不会穿过前置窗口被吞进大窗口（`landsOnTheWindowInFront`）。边界是**盒底以下**的窗沿
> 不算 —— 落到那里等于穿过她所在的盒子（`surfaceBelowTheBoxDoesNotBlock`）。
> 这条判定读地形图，所以 `endDrag` 里**强制执行一次图刷新**（原版 `RefreshSurfaceMap(force: true)`
> 同样位置也这么做），否则读到的可能是最多 0.5 s 前的旧图。
> 注意这条只在**入场**生效；**被遮挡后的转移**（`transferEnclosure`）不做这个询问，
> 因为那里她已经在盒子里运动，不是在松手瞬间。
>
> 上下拖动另有一条阈值，与站在窗沿上共用 `PlatformRidePhysics.releaseDisplacement`
> （15 pt/帧 ≈ 900 pt/s）。但**光加阈值不够**：托举会把壁速直接赋给她，壁速一变（拖拽
> 停下或换向）她就带着旧速度飞出去，落回时又被判成硬着陆 —— 于是每次慢拖都以弹跳和
> 一句「好高」结束。所以地板是**粘的**：`wasOnFloor` 为真且未被猛拽时，她的脚就贴在
> 地板上、速度取壁速（与棲位 `follow` 同语义）。猛拽时才释放：地板上升把她抛出、
> 地板下降把她留下（与棲位 D1 同规则）。
> 四壁的判定统一为「猛拽才撞、否则托着走」：横向原本是「任何相对速度都算撞击」，
> 导致普通横拖也被当成撞击而尖叫。
>
> **地板被向下猛拽时不得重新放置她**（这是上一版引入的 regression，已修）。猛拽分支当初写成
> 「先把她放到新底壁上，再决定速度」，于是快速下拖时她每帧都被搬到新底壁上、速度又恰好被置 0
> —— 既不生成 `*.falling`（控制器那支要求 `速度 > 35`），也让她紧紧跟着底壁下行。现在的判定是：
> 只有**地板升上来撞到她**（`bottomWallVelocity < 0`）才需要重新放置；地板**落走**时她根本不受约束，
> 从静止自由下落（与棲位对下降面的规则一致）。
>
> 同时把 `enclosure.isResting` 改成直接取用 `step.isResting`。原先只在「她速度够快」时才清除该标志，
> 这是三段式分支结构的副产品、从未经过论证；向下猛拽恰好速度为零，标志就一直留着。
>
> 顺带修掉一处语义重叠：`impactSpeed` 现在只记**真正的碰撞**，托举不算。原先柔和对地的
> 相对速度落在 70–115 区间时会报 `impactSpeed ≥ 70`，于是控制器走了尖叫＋转 `.falling`
> 的分支，**压掉了本应生效的 `isResting`**。
>
> ### 空中（`state == .falling`）的两条规则
>
> 释放判定读**实时**位置（每帧），落点判定读**地形图**（0.5 s 一次）。这个不对称在
> 快速拖动的窗口上必然出错，两个方向都实测复现过：
>
> 1. **空中每帧重建地形图**（`PetController.step` 里 `if state == .falling { refresh }`）。
>    否则快速下拖的窗口被按「它已经离开的位置」判定落点：她落在半空的旧位置上，随即被
>    实时读重新释放，如此循环，**被钉在同一点不动**（实测：窗口顶端已到 1440，她还锚在
>    840），直到图刷新时窗口已移出工作区，她才落到底。代价是空中每帧一次枚举
>    （实测 0.48 ms），落地即停。
> 2. **追及规则**（`resolveAirborneSupport`）：窗口上升快于她被抛出的速度时，会从下方
>    越过她、把她吞进去，她只能掉到底（实测 `foot.y` 落到 1117）。规则是——被抛出的那个
>    窗口若顶边已到/高于她脚底且仍以 ≥360 pt/s 上升，就**把她放回顶边**，并至少给它自己的
>    速度（她若已有更快的上抛速度则保留）。这是**恢复**原版的 `resolveAirborneContact`：
>    它当初随速度匹配一起被删（`docs/refactor-plan.md` Phase C），但缺失留下了这个洞。
> 3. 只跟踪**因窗口移开而被抛出**的情形（`PlatformLaunch` / `PlatformDownwardRelease`）；
>    用户自己甩出去的不跟，否则会被钉回原来那个窗口。
>
> 另有一处**部分修好**：「能不能挡住别人」与「能不能站上去」共用一个谓词。
> `SurfaceBuilder.build` 只收一个 `isEligible`，却同时用来决定 ①她能否站在顶边、②它挡不挡别人；
> 而 `isEligiblePlatform` = `isEligibleAppWindow` ∧ **顶边可达**，后半句对 ② 毫无意义。
> **已修（2026-10-12，第一步）**：采样现在把**所有**合格普通窗口都收进来，用
> `WindowBody.isEnclosureCandidate`（= `isBoundedBody`）标记哪些能当容器。
> 遮挡（`coveringWindow`）读**全部**，容器与侧撞只读标记为真的（侧撞与上游一致，
> 它的 `WindowBodies` 也用 `IsBoundedBody` 过滤）。修好的是这条实测过的 bug：
> **最大化窗口盖住盒子时，她永远不出来**（实测 bodies=`[盒子]`、`coveringWindow=nil`、
> 2 秒后仍被困）。`transferEnclosure` 也补上了容器资格检查 —— 这是第一步的**前置条件**，
> 否则她会被转移进一个最大化窗口、封在整个屏幕里。
> **已修（2026-10-12，第二步）**：`SurfaceBuilder.build` 现在收**两个**闭包 —— `isTerrain`
> （她能否站在顶边）与 `occludes`（它是否不透明且在前面）。后者只用 `isEligibleAppWindow`，
> 因为**顶边在哪里与"它挡不挡得住东西"无关**。修好的是一条能演示的 bug：
> 顶边被拖到菜单栏之下的窗口原本**不遮挡**别人，于是 `isPerchSpotVisible` 问道于图会得到
> 「可见」，她就站在一条**实际被盖住**的窗沿上（看起来浮在那个窗口的中间）。
> 钉住它的测试 `menuBarTopWindowStillOccludes` 在改动前报红（`visible.isEmpty → false`）。
> 注意**只有"顶边压进菜单栏"这一类会变**：每一条可站窗沿的 y 都 < `workArea.bottom`，
> 所以"整个窗口在屏幕下方之外"的窗口永远不会遮挡任何可站窗沿 —— 改不改都一样。
> `WindowClimbPlanner` 用 `span` 而非 `visible`，`floors` 也硬编码 `visible = [span]`，均不受影响。
>
> **手工验收的边界（2026-10-12，记录用）**：「顶边压进菜单栏的窗口仍能遮挡」这条**只能**由
> 纯函数测试（`menuBarTopWindowStillOccludes`）钉住 —— 真实 macOS 上**普通窗口很难把标题栏
> 拖到菜单栏之下**（能被完全推上去的通常是无边框/工具栏样式的窗口，或全屏过渡中的瞬态），
> 所以没有可靠的桌面步骤可以手工复现那种几何。这不是缺陷：「只能在测试里构造」恰恰是这类
> 不变量需要测试的原因。**若以后出现"她站在一条看不见的窗沿上"之类的报告**，这里就是第一
> 个该怀疑的地方，届时再想办法构造可复现的几何。
> 与此无关的一项：系统设置的「双击窗口的标题栏以」控制的是 **zoom**，zoom 后的窗口停在菜单栏
> **下方**（`top >= workArea.top`），既不触发这次的判据，也不属于本改动覆盖的情形。

---

## 4. 其他

- **签名**：发布版尚未单独生成证书，开发期复用 CalendarShouter 的（`OP_ITEM_REF="CalendarShouter Signing"`）。换证书会让 macOS 忘记已授予的自动化与文件夹授权，所以只换一次。
- **性能实测（2026-10-12）**：预算目标（闲置 < 0.5% / 移动 < 2% CPU、< 80 MB 内存）**从未被验证过是否现实**，
  而且原定数值来自原项目的 Windows 测量。实测结果（`top -l` 的逐秒采样，容器内闲置、她静止）：

  | 状态                  | 总 CPU     | 备注                      |
  | --------------------- | ---------- | ------------------------- |
  | 容器内闲置（debug）   | **3.4%**   | 降频读取前是 **5.0–5.4%** |
  | 容器内闲置（release） | **3.4%**   | 降频读取前是 **4.8%**     |
  | 走动                  | ~25%       |                           |
  | 拖动                  | **28–38%** | 每次窗口移动约 3.5–5 ms   |

  **两件必须先说清楚的事：**
  1. **启动方式会让数字差 2–3 倍。** 直接 exec `Contents/MacOS/NuonuoChuuby` 实测约 10–16%，
     而 `make rerun`（`open -n`，即 LaunchServices）是 28–38%。**必须用 `make rerun` 量。**
  2. **`debug` 与 `release` 的闲置成本几乎一样**（3.42% vs 3.44%，同机同状态各 11 次采样）。
     所以闲置成本不是我们的 Swift 逻辑（那部分 -O 后该掉 5–7 倍），而是每帧的框架/绘制/运行循环开销，
     再加上两次窗口服务器枚举。**别用「release 会更快」来搪塞闲置成本。**
- **热点的构成（已归因部分）**：
  - **窗口服务器查询是唯一的量级性成本，而且它比微基准贵一个数量级。**
    单窗口 `CGWindowListCopyWindowInfo([.optionIncludingWindow])` 在独立进程的紧循环里只有
    **25 µs CPU**（墙钟 98 µs），但在 app 里实际值约 **300 µs**（由下面的 A/B 反推：
    省下 45 次/秒 ⇒ 省 1.3–1.5 个百分点 ⇒ 每次约 300 µs）。**这正是「紧循环微基准不能信」的又一例**，
    和 `setFrame` 那次（循环里 27 µs，真实 230–310 µs）是同一个陷阱。
  - 10 Hz 窗口矩形采样：同样按 ~300 µs/次计，摊薄约 **1.3%**，是容器外闲置的最大单项。
  - `updateWindowEnclosure`：每帧一次实时读取。**已两轮优化**：先去掉「每帧读两次同一个矩形」
    （`enclosureFitsTheBox` 会再读一次），再把静止时的读取降到 30 Hz。合计把容器内闲置从 6–9% 降到 3.4%。
  - `setFrame` 每次约 230–310 µs，但只在移动时发生，不是闲置成本。
  - 非主线程几乎不花 CPU（**0.01–0.2%**）：之前记的「约 4 个百分点在 CoreAnimation 其它线程上」不成立。
- **已做的降耗（2026-10-13）**：
  1. **容器静止时把实时读取降到 30 Hz**（`enclosureRestingResampleInterval`），盒子一有位移立刻恢复每帧。
     实测 **debug 5.0→3.4%、release 4.8→3.4%**。取 30 Hz 而不是 15 Hz：收益的绝大部分在前一半，
     而「她察觉盒子开始动」的延迟与频率成反比，那个延迟就是代价（60→30 Hz 省 1.3 点，30→15 Hz 只再省 0.3 点）。
     **代价（有意接受）**：盒子开始移动后最多晚 33 ms 才被她感知，且第一帧是「追上」而不是平滑跟随。
  2. **把「甩」的判据改成速度**（`PlatformRidePhysics.yankDisplacement(overSeconds:)`）。
     上游的 15 pt 本来就是「60 Hz 下每帧的位移」，即 900 pt/s；一旦两次读取之间隔了不止一帧，
     按位移判就会把一次普通拖动读成猛甩。改成速度后，**整个甩动落在两次读取之间的抖动仍然会把她甩出去**，
     而同一段位移摊在更长间隔上就只是拖动。由 `yankIsASpeedNotADistance` 与
     `aFlickBetweenReadsStillThrowsHer`（在旧实现下为红）钉住。
- **若要继续降**（按收益排序，均未做）：
  1. **把地形图重建与矩形采样合并成一次枚举**（两者需要的 rect 完全相同，只差可按需丢弃的遮挡计算）：
     省掉 2 Hz 那次枚举，约 −0.1%（release）/ −0.35%（debug），行为不变。
  2. **把两处 Swift 字典桥接换成 CoreFoundation 直读**（`MacOSPlatform.windows` 与 `liveBounds`）：
     实测解析快 **20 倍**（164 µs → 69 µs/次，结果逐字段一致）。release 约 −0.1%，debug 约 −1%，行为不变。
     注意这只影响 debug 数字的可读性，不影响发布版。
  3. **睡着时按 10 Hz 跑 step**：`sleep` 保持片段是 8 帧 × 0.185 s ≈ 5.4 fps，10 Hz 在视觉上完全一样。
     这是唯一能砍掉「每帧固定开销」（运行循环 + 框架 + 绘制推送）的办法，release 3.4% 有望降到 1–2%。
     注意它与第 1 项不相交：容器内不会进入 `.sleeping`（`updateWindowEnclosure` 会早退）。
  4. 私有 `CGSGetWindowBounds`：矩形与 `kCGWindowBounds` 在 24 个窗口上**逐字段相同**、便宜 **12 倍**
     （2.5 µs CPU），可让实时读取几乎免费。但要引入私有符号，倾向不做。
- **测试套件是概率性绿的（2026-10-13 实测，与性能改动无关）。**
  连跑 20 次 `make test`，约 2 次失败，失败者总是同一族：
  `AirborneSupportTests.fastDownwardDragIsCaught`、`SuspensionTests.resumingKeepsHerFooting`
  （在**未改动**的 `main` 上同样如此，2/20）。原因几乎肯定是 `PetController` 里的
  `Double.random`（闲置计时、自主行为选择）用的是**全局 RNG**，而 swift-testing 并行跑各 suite，
  于是「她下一步做什么」取决于别的测试恰好吃掉了多少随机数。修法是给 `PetController` 注入
  一个可播种的 RNG 供测试使用；未做，因为它与本次改动无关。
- **渲染架构：全屏 overlay（现为默认）与跨屏裁切（2026-10-13）**：宠物改为「每屏一块全屏透明窗口 +
  宠物是其中的 `CALayer` 子层」，**窗口不再移动**，只移动图层。实测（`xctrace` Time Profiler，30 s，
  全线程 Running / 30 s，同一交互脚本）：拖动 **17.8% → 10.8%**，容器内闲置 **5.7% → 3.9%**。
  归因：旧模型每次移动都在付窗口移动事务（`_setFrameCommon` 2.4% + `commit_transaction` 4.9% 绝对），
  新模型把这两项压到 0.19% 与 1.3%。
  **两个必须记住的坑（都是先测出来才发现的）：**
  1. 宠物**不能**用 `NSView` 子视图：AppKit 在子视图 frame 变化时就会重绘它，把 384² 精灵用
     **CPU 重采样**进目标矩形（`argb32_sample` 0% → 28%，比窗口移动本身更贵），
     `layerContentsRedrawPolicy` 拦不住。必须用 `CALayer`（`contents = CGImage`，靠图层几何移动）。
  2. 手工 `CALayer()` **不会**像 `wantsLayer` 的视图那样自动禁用隐式动画；不处理的话每次改
     `position` 都被 CA 用 ~0.25 s 缓动动画过去，症状是「**她追着鼠标跑**」（方向永远指向鼠标、
     追不上、鼠标停下后过一会儿才到；气泡无此问题，因为它是 `NSWindow`）。
     修法：`pet.actions = ["position"/"bounds"/"transform"/"contents"/"hidden": NSNull()]`。
  旧路径保留在 `--pet-panel` 后面（由 `Pet/PetPresenting.swift` 协议隔离），用于回退与对照。
  **未验证 / 已知行为差异：**
  - **多显示器完全未验证**（开发机单屏）。实现为每屏一块 overlay，宠物画在「含其中心点」的那块上，
    其余 overlay 的子层隐藏（完全不绘制 ⇒ 全透明 ⇒ 点击穿透）。
  - **宠物跨显示器边界时会被 overlay 窗口边界裁切**，旧模型不会。多屏验证时一并处理。
  - overlay 的层级取 `belowFloating`（= 2），必须 **> 0**：`FullscreenDetector` 只看 `layer == 0`、
    不排除自身 PID，层级为 0 会让它自触发挂起 → 隐藏 → 恢复 → 挂起，形成可见闪烁。
- **对话气泡也搬进了 overlay 图层（2026-10-13）**：气泡原先是一块独立的 `NSPanel`，跟着她每帧
  `setFrame`。现在它是同一块 overlay 里、宠物图层**之上**的 `CALayer`（`Dialogue/OverlaySpeechBubbleController.swift`），
  只改 `position`。窗口版气泡保留给 `--pet-panel`（`SpeechBubbleWindowController`），两者共用一个
  `Dialogue/SpeechBubbleDrawing.swift`，所以画的形状与量出的尺寸必然一致。
  实测（12 s「拖到窗口外→落屏幕底」，与同一场景的旧 trace 对照，主线程 Running / 12 s）：
  主线程 **1221 → 929 ms（−24%）**，全线程 **1676 → 1241 ms（−26%）**；
  `updatePetFrame` 子树 **148 → 22**（其中气泡本身 146 → 18）；`setFrame` **165 → 0**；
  `commit_transaction` **238 → 89**。
  **对照组证明这不是场景差异**：`applyPlacement` 里**去掉气泡后的宠物部分 33 → 35 样本（没变）**，
  「气泡可见时每帧都跑」的 `bubblePlacement` 是 4 → 5 样本（气泡出现的帧数相当）。
  两个结论值得单独记：
  1. **贵的从来不是文本排版，也不是光栅化**，是**窗口移动**。新的光栅化总计只占主线程 **0.75%**
     （12 s 内所有气泡的排版 + 绘制）。所以「预先测量尺寸 / 预先光栅化以省 CPU」是错的方向 ——
     尺寸本来就已缓存，绘制本来就几乎免费；预先光栅化**唯一**的用处是给 `layer.contents` 提供位图，
     它是让图层方案成立的**使能步骤**，不是收益来源。
  2. **`commit_transaction` 的降幅（−149 样本）在栈归因里永远看不到** ——它是 runloop flush，
     调用链里没有我们的任何函数（已核实）。也就是说气泡的窗口移动每帧都在**强制一次 CA 事务提交**，
     而这笔开销只有 A/B（同一脚本跑新旧两版）才能归给它。**只做栈归因会系统性低估窗口移动的代价。**
  实现上必须注意：气泡的三种颜色都是动态颜色（随明暗主题变），所以缓存位图的键**必须含 appearance**；
  位图要按 `contentsScale` 光栅化，否则文字发虚；气泡层级从 `floating`(3) 一并降到 overlay 的层级
  （2，进菜单栏条时 25），副作用是它与其它 floating 窗口的相对次序变了；`PetPresenting` 现在自己持有
  `speechBubble`，因为两种渲染方式决定了气泡是窗口还是图层。`--pet-panel` 回退路径已实测仍走窗口气泡
  （`speechBubble.getter → init → show → reposition` 都在协议身后被调用过）。
- **位置插值：1/60 s 的短动画（2026-10-13）**：模拟仍按 60 Hz tick，但 `position` 交给 CA 用
  **恰好一个 tick** 的线性动画插值，于是渲染服务器按显示器自身的 120 Hz 采样这条位置曲线。
  效果是位置从「每 16.7 ms 一跳」变成连续滑动（本机 `NSScreen.maximumFramesPerSecond == 120`）。
  实现见 `Pet/FrameInterpolation.swift`。
  **代价与原理（都是实测，不是推断）：**
  - 平滑度就是延迟，两者是同一个参数。动画时长 $D$、tick 间隔 $T$ 时，跟随滞后恰为 $v \cdot D$。
    $D<T$ 会先走完再停住（**严格劣于不插值**），$D>T$ 延迟线性增长且会被下一个目标打断
    （0.25 s 时长就是「她追着鼠标跑」）。所以 **$D = T$ 是唯一正确值**，不是「越小越好」。
  - **持续拖动 12 s A/B（同一脚本，`git stash` 切换同一份代码）：主线程 824 → 909 ms，
    即 +0.71% 绝对 CPU（6.87% → 7.58%）**，全线程 +0.31%。折算 **每 tick +118 µs**。
    新增开销全部是 CA 隐式动画的记账，self-time 对账正好闭合：`commit_transaction` +8、
    `_copyRenderLayer` +6、`collect_layers_` +6、`thread_flags_` +6、`collect_animations_` +6、
    `__CFStringHash`+`CFEqual` +12、`mach_msg2_trap`（IPC）+37 ≈ 81。
    **即隐式动画的创建/编码/提交都在我们进程里，渲染服务器只播放** ——「插值不花我们的 CPU」是错的。
  - **两个必须保持 `NSNull()` 的键**：`contents`（一旦动画就是两帧精灵交叉淡入淡出，她会一直发虚）、
    `transform`（携带转身的镜像翻转，会经过 scale=0，**她会瞬间被压扁**）。所以 `transform` 连同倾斜角
    都保持瞬时。
  - **实测踩到的坑**：把 `CABasicAnimation` 模板放进 `actions` 字典**根本不插值**（500 ms 时长下
    `presentation()` 仍恰好落后一次提交，不随时长变化）。**只有 transaction 的 duration 有效。**
  - 气泡必须走同一个 transaction，否则她滑动时尾巴会离开头顶；气泡**首次出现**时反而要禁用动画。
  - **未验证**：actions 字典「没有 position 键」是否仍允许隐式动画，无法在无窗口的测试进程里断言
    （那种环境下 `action(forKey:)` 对任何键都返回 nil），只能靠眼睛确认。
- **120 fps 绘制实验（未做，见下）**：把 tick 提到 120 Hz、去掉插值，让位置**和精灵**都按 120 Hz 更新。
  预估代价：tick 相关开销（`step` + 每 tick 的图层提交/IPC）翻倍，即约 +0.7~1.5% 绝对 CPU。
- **Metal 渲染实验（延后）**：在 clean tree 的独立分支做 A/B，前提是先固定同一交互脚本与同一统计口径。
   - 目标：确认是否能在不降低体感帧率的前提下，较当前 CALayer 再降低拖动/下落 CPU。
   - 技术约束：若实施，必须优先做纹理复用（避免每帧图像上传/转换），否则可能比 CALayer 更差。
- **多屏混合 DPI 未验证**：当前全程用点（points）规避了大部分换算问题，但未在真实混合 DPI 的多屏组合上验证过。
- **桌面图标位置是近似值**：macOS 无公开 API，`DesktopIconGrid` 用 Finder 默认布局近似，不是图标真实坐标。

---

## 5. 桌面图标真实坐标：辅助功能**可以**做到（**已实施**，2026-10-12）

**结论：Accessibility 不适合窗口跟踪，但适合这件事。** 实验已于 2026-10-12 跑通：

```
d=1 role=AXScrollArea desc=桌面  pos=(0,0)        size=(1728,1117)
d=2 role=AXGroup      desc=桌面  pos=(0,0)        size=(1728,1117)
d=3 role=AXImage desc=Xcode_16.4.xip pos=(1391,136) size=(56,56)
d=3 role=AXImage desc=prts           pos=(1391,32)  size=(56,56)
d=3 role=AXImage desc=sing-box       pos=(1513,32)  size=(56,56)
```

1. **真实坐标可读**，路径很短：`app → AXScrollArea(desc=桌面) → AXGroup(desc=桌面) → AXImage*`。
2. **`desc` 就是文件名** → 直接得到「文件名 → 真实坐标」映射，与现有**按文件名匹配**
   的删除检测天然对得上。
3. **坐标空间与 `DisplaySpace` 一致**（左上原点、Y 向下），无需换算。
   ⚠️ 待验证：负坐标（第二显示器在左侧）与多显示器情形。

**设计约束**：图标被删除后 AX 元素立即消失 → **不能等删除发生再去读，必须提前缓存**。
所以它是**周期性索引**，删除事件到达时查表。`DesktopIconGrid` **保留**作为未授权时的降级路径。

**代价**：应用会请求**辅助功能**权限（软依赖，有降级）。详见 `docs/refactor-plan.md` §6。

**已实施（2026-10-12，独立提交）**：`Meal/DesktopIconIndex.swift` 周期性（2 秒）读取
Finder 桌面图标，建「文件名 → 坐标」索引；`PetController.tryBeginIconLick` 优先用它，
索引为空时退回 `DesktopIconGrid`；幽灵图标锚点也优先用真实坐标。
读取路径不依赖语言（不匹配「桌面」字样），而是**取最浅一层「含 AXImage 子节点」的元素**。
⚠️ 仍**未验证**：负坐标（第二显示器在左侧）与多显示器情形。

---

## 6. Accessibility 用于**窗口跟踪**：已评估，不采纳

拿不到 z 序（而 z 序是遮挡减法的唯一输入）；无公开 `AXUIElement → CGWindowID` 映射；
只覆盖实现了 AX 的应用（Java/X11/部分游戏窗口不报）；逐属性读取是跨进程 IPC，
对方应用卡住时会阻塞。且它改善的只是「新窗沿发现延迟」，**不是**用户感受到的跟随延迟。
Ledgeling 的 macOS 层同样只用 `CGWindowListCopyWindowInfo`，全文未用 AXUIElement。

**但**桌面图标坐标是它的正确用途 —— 见第 5 节。
