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
6. **空闲时间用 `CGEventSourceSecondsSinceLastEventType`**：免权限，且无需额外监听。（免权限是附带好处，不是选择理由。）
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
> 另有一处**已知不一致**：「能不能挡住别人」在图里用 `isEligiblePlatform`（含「顶边可达」），
> 在窗口矩形采样里用 `isEligibleAppWindow`（不含），所以顶边压在菜单栏下的窗口在图里是
> occluder、在采样里不是。遮挡语义应收敛到 `isEligibleAppWindow`；未做，因为它会改变现有
> graph 的遮挡结果，需要单独确认。

---

## 4. 其他

- **签名**：发布版尚未单独生成证书，开发期复用 CalendarShouter 的（`OP_ITEM_REF="CalendarShouter Signing"`）。换证书会让 macOS 忘记已授予的自动化与文件夹授权，所以只换一次。
- **性能未实测**：预算目标是闲置 < 0.5% / 移动 < 2% CPU、< 80 MB 内存，但从未测量过。参考项目的 overlay 模型实测 **3.48% CPU**，已超出其 2% 目标 —— 值得我们自己实测一次再下结论。
  - **部分实测（2026-10-12）**：一次全量 `CGWindowListCopyWindowInfo`（25 个窗口）实测 **0.48 ms**。
    窗口容器与侧撞新增的 10 Hz 矩形采样因此约 **0.48% CPU**，恰好压在闲置预算上；
    叠加地形图的 2 Hz 刷新（0.1%）后略超 0.5%。若实测确认超标，首选把两者的采样合并成一次枚举。
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
