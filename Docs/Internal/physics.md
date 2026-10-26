# 物理：支撑、封闭盒、腾空

## 窗口封闭盒与侧撞（从上游移植）

移植了两个上游**曾经完全缺失**、且没有任何地方记录为取舍的窗口物理特性
（当时只有两个无生产者的死字符串 `"WindowSideImpact"` / `"EnclosureWindowLost"`）。

- `Physics/WindowEnclosurePhysics.swift` —— `resolve(...)` + `WindowEnclosureStep`，
  常数与 `Vendor/.../Core/WindowEnclosurePhysics.cs` 一一对应。
- `Physics/WindowSideCollisionPolicy.swift` —— 对应 `WindowSideCollisionPolicy.cs`。
  其中一个分支对良构矩形可证明不可达（两个边同时命中要求窗口比 2× 接触容差还窄），
  保留并加了注释。
- `World/WindowEnclosureEligibilityPolicy.swift` —— `isBoundedBody`
  （对一个显示器 frame **或** 其 visibleFrame 覆盖 ≥99% + 四角对齐 ≤4 pt）。
- `Life/WindowEnclosureBehaviorPolicy.swift` —— `shouldEscapeForMeal` / `allowsIconLick`。
- 封闭**不是** `PetState`：`enclosure: Enclosure?` + `step` 里提前返回，
  这样所有「按状态驱动」的规则（骑车、自主、剪辑表）都不用改。

### 两个容量谓词，故意不同 —— 不要合并

- `bodyFits`（**位置性**，`insets.contains(body)`）= **进入**：整个身体在里面。
- `boxHasRoom`（**尺寸性**）= **持续**：与 `resolve` 的「太窄」测试完全一致。

  用 `bodyFits` 做持续判定会**把她从一个她已经在里面的盒子里赶出去**，
  因为 `SubpixelMotion.takeWholePixels` 会让她有一帧最多越过墙 1 pt。
  所以「持续」的释放只可能由**缩放**触发，不可能由运动触发。

- 进入比上游**更严**：要求整个身体，而不只是身体中心。

### 采样率是真实偏差

上游每 **0.06 s** 重建一次 surface map（`MainWindow.xaml.cs:1437`），我们是 0.5 s。
侧撞阈值是按上游那个频率标定的，所以 `SurfaceProvider.sampleBodiesIfStale` 单独以
**10 Hz** 运行，与 2 Hz 的地形图分开。实测一次完整 `CGWindowListCopyWindowInfo`（25 个窗口）
约 **0.48 ms** ⇒ 10 Hz ≈ 0.48% CPU，正好在 idle 预算上。

### 侧撞**不**排除「她正骑着的那个窗口」——这是故意的

计划里本来要加这个判断，但身体矩形让它结构上不可能：身体底边在脚上方
**14.04 pt**（`bodyCollisionBottomCanvasY` 466 vs `footCanvasY` 498.667 × 220/512），
所以当她站在窗口顶上时，与该窗口的垂直重叠是 `max(0, -14.04) == 0`，低于 4 pt 的门槛。
**不要「修」这个**。上游靠调用方传进来的外部 hitbox（不含脚）得到同样效果。

「封闭盒阻止侧撞」是正确行为，不是 bug：她已经在一个窗口里了，那个窗口不可能再撞她，
上游也一样。曾把它误判为失败一次 —— 手势必须从窗口在她的**侧边**开始、并且**纵向覆盖**她。

### 墙会带着她走，除非盒子被猛拽

`PlatformRidePhysics.releaseDisplacement`（15 pt/tick ≈ 900 pt/s）从 `PetController.Motion`
移到了这里，使 perch 与盒底不会各自漂移。

**只设阈值是不够的**（第一次尝试在手动测试里失败）：携带语义会把墙的速度赋给她，
当墙改变速度（拖动停止或反向）时她还带着旧速度，离开地板，落地速度足以被判成「落地」——
于是每次慢速拖动都播一次落地动画 + 一句「好高」。

所以地板是**粘性的**：`resolve` 接收 `wasOnFloor`（controller 上一帧的 `enclosure.isResting`）；
为真且未被猛拽时，她的脚留在墙上、`velocityY = bottomWallVelocity` —— 与 perch 的 `follow` 语义一致。
被猛拽才释放：上升的地板以（夹紧后的）墙速把她抛出，下降的地板把她留下 —— perch 的 D1 规则。
腾空时，地板由**她**的速度（`< restRelativeSpeed`）**和**墙的速度共同判定，否则反弹。

四面墙统一是「猛拽 = 撞击，否则携带」；横向以前把**任何**相对速度都当撞击，所以普通侧向拖动也在尖叫。
`impactSpeed` 现在只记录真正的反弹 —— 携带不是撞击。这也修掉一个重叠：
一次相对速度落在 70–115 的软着陆会报告 `impactSpeed >= 70`，于是 controller 走
「尖叫 + `.falling`」分支并**静默忽略 `isResting`**。

门槛是**速度**不是位移：`releaseDisplacement = 15` 是**每 60 Hz tick**（= 900 pt/s）。
一旦两个矩形可能相隔多于一帧，直接比较位移就会把拖动读成弹指。
`yankDisplacement(overSeconds:)` = `15 * (seconds / (1/60))`；`resolve` 收 `baselineSeconds`
（nil ⇒ 一帧 ⇒ 与此前逐位相同）。`wallVelocity` 用同一基线做除法。
曾有个被否决的做法是把 `previousBox = box` 跨过间隔重新取基准 —— 那是掩盖：
它把整个手势静默吞掉，于是落在一个间隔内的猛拽会被「携带」而不是「抛出」。

### 回归：向下拖的地板把她带走了（已修）

用户报：盒内**快速向下**拖动让她贴着下边缘走、永远不掉。这是**粘性地板改动的回归** ——
在它之前没有「猛拽」分支，`nextBottom > bottomBoundary` 直接失败，她被留下。

- **我第一次的诊断是错的**（怪 `isResting` 从不清除）。两个改动**各自独立充分**，
  正是这一点暴露了误归因 —— 所以验证时要**一次只回退一个改动**。
- **真正的原因**：猛拽分支写成「先把她放到新地板上，再决定速度」。
  对**向下**的猛拽，这等于每帧把她搬到新地板上、速度为零 —— 被带着走、报告 `idle`、
  永远不进 `.falling`。
- **修法（物理，承重）**：猛拽只对**向上**猛拽的地板生效（`bottomWallVelocity < 0`）。
  向下走开的地板完全不约束她：她从静止处下落。
- **地板的速度不能跟着她走**：携带会把墙速**赋给**她（相对速度数学需要），所以释放时
  她拿的是地板的速度。保留它让她「带初速下落」（实测 877.5 pt/s）而不是从静止掉落 ——
  这正是用户相对窗口顶边能感觉到的差别。所以向下猛拽分支同时把 `velocityY` **和** `offsetY`
  归零：那一帧她完全不动，复现 perch 路径「零初速」的语义。
- **修法（controller，简化）**：`enclosure.isResting = step.isResting` 无条件赋值。
  旧的「只有速度够快才清」是一个三分支的偶然，从来没有被论证过。

行为现在是：释放 → 下落 → 下降的**天花板**接住她（不能穿过）→ 以盒子速度被携带 →
拖动停止时落到新地板。天花板接住在一个只有约 2 倍她身高的盒子里不可避免。

### 窗口最大化：没有专门的顶飞规则（有意不移植）

上游有一条专用反弹：支撑消失**且** `IsZoomed(支撑窗口)` 时，
`WindowExpansionPhysics.Evaluate` 返回 `(±260·scale, −820·scale)`（横向背离显示器中心），
播一句尖叫并把下落原因记成 `WindowMaximized`。

端口**没有**这条规则。最大化只是让窗沿（窗口顶边）快速上移，是否被甩出完全由通用的
「单 tick 位移超过 `releaseDisplacement`」规则决定 —— 所以慢速最大化通常只是沿窗沿
把她举上去，并不会飞。

`windowMaximized` 这句台词于是改挂在**「抱着她的盒子变大」**上：按 `boxGrowthTolerance`
比较尺寸（位置变化不算），用 `ChangeGate`，所以拖拽式改大小只报一次。见 `behavior.md`。

### 已解决：着地状态却没有支撑

「弹起来、停在高处、不掉下去」曾是一个着地状态但没有支撑。
参数化支撑（`Perch`）让它**不可表达**：`maintainGroundSupport` 每 tick 对 `ridesSupport`
为真的状态运行（即排除 `falling climbing dragging pinching chomping licking satisfied
rolling waking`，也排除 purpose 为 `meal` / `iconLick` 的自由行走），它只有两条路 ——
已有棲位就解析当前 surface，没有棲位就 `acquirePerch()`。任何一条解析不到都走
`handlePerchLost`：0.35 s 宽限（只给非地板，地板不会闪没）；过期即 `releasePerch()`
+ `beginFall()`。**落地状态与「没有支撑」不能并存。**
由 `neverFloating`（4000 tick 慢速拖拽，逐 tick 断言）钉住。
**没有**重做手工拖拽复验 —— AppleScript 的 `set bounds` 是瞬移而不是手势；依据是结构性
不变量、该测试，以及实测日志里 0 条非 `falling` 的 `Support="none"` 心跳。
若再观察到，按新问题处理。

## 被覆盖的封闭盒

被前面一个窗口完全盖住时，她看起来像站在空气上。

**不要试图把她的窗口夹在另外两个窗口之间** —— 做不到：`NSWindow.level` 是粗粒度整数，
**所有**普通窗口都在 `CGWindowLevel 0`，所以「A 和 B 之间」没有可用值；降低层级又会掉到
Dock（20）与菜单栏（24）之下；二维裁剪也被否决（窗口投影是**遮挡者**画的，
而且窗口不都是矩形，把她裁成矩形仍会从两者里透出来）。

决定：**被盖住的支撑不是支撑** —— 与「被盖住的窗沿不能站」是同一条规则。

- `World/WindowBody.swift` —— `{bounds, zIndex}`；10 Hz 采样带 z 序。
- `World/WindowOcclusionPolicy.swift` —— `coveringWindow(of:her:among:)` 返回覆盖她
  身体中心的**最前面**窗口（zIndex 越小越前），或 nil。**只有「最前面」不会振荡**：
  任何盖住它又盖住她的窗口一定更靠前。
- 宽限期到期时：若遮盖窗口的墙能装下她整个身体（`bodyFits`，与手动放下同一谓词），
  她会被**转移到那个窗口里**（`WindowEnclosureTransferred`）；装不下才下落
  （`fallReason = "EnclosureCovered"`，已登记在 `LandingVoicePolicy`）。
  转移保持速度与状态，设 `previousBox = newBounds`（所以第一帧墙速为 0）并重置宽限期。
  她已经画在最上层、也已经在新的墙内，所以**一个像素都不动** —— 交接不可见，
  只有最终停在哪里变了。
- `enclosureCoverageGraceSeconds = 0.6`（已用眼睛确认；1.0 太慢。别在没有抱怨时重新调）。
- **进入盒子时选中「身体装得下的最前面窗口」，绝不按面积最小。**
  这是真实 bug（用户报告）：当「小的在前」反转为「小的在大窗口后面」时，按面积会把她带进小的，
  遮挡规则又把她交给大的 —— 连续两次捕获，她看起来掉了两次。
  「最前面」也保住了原意（大窗口里的小窗口会接住她），因为她确实显式地在前面的那个里面。
- 进入还要求：**从她的脚到盒底之间没有任何可以落上去的东西**。她下方的一个窗口顶是落点，
  不是被吞的理由。边界是盒子的**内底** —— 盒子**下方**的表面不算落点，
  因为到达它意味着穿过盒子。
  这条判定读地形图，所以 `endDrag` 在松手时**强制执行一次图刷新**（上游在
  `RefreshSurfaceMap(force: true)` 的同一位置也这么做），否则读到的可能是最多 0.5 s 前的图。
  **只在入场生效**：被遮挡后的转移（`transferEnclosure`）不做这个询问，因为那里她已经
  在盒子里运动，不是在松手瞬间。

## 腾空：落地读数必须和「被抛」一样新鲜（已修）

两个用户报告的症状，同一族根因：**让下落开始的那次释放读的是实时窗口（每帧），
而结束下落的那次落地读的是地形图（2 Hz）**。窗口在 0.5 s 内移动很远就会被判错。

- **向下拖** → 图里还是旧顶边，于是她**落在窗口已经离开的位置**，下一帧被实时读数重新释放，
  反复 —— **钉在半空的一点**，直到图刷新、发现窗口离开工作区。
  修法：`step` 在 `state == .falling` 时**每帧**重建图（~0.48 ms/帧，只在下落期间）。
- **向上拖** → 窗口上升得比她被抛得快，**从下方越过并吞掉她**，她掉到地板。
  修法：`resolveAirborneSupport` —— 若当初抛她的那个窗口的顶边在她脚下或以上，
  且仍以 ≥ `Motion.airborneCatchUpSpeed`（360 pt/s）上升，就把她放回它的边上、
  速度至少给到窗口速度（她原本抛得更快则保留）。这**恢复了原版的 `resolveAirborneContact`**，
  它在 Phase C 删除速度匹配时被一起删掉，于是留下这个洞。
- 只追踪**从她脚下移走**的窗口（`PlatformLaunch` / `PlatformDownwardRelease`）；
  用户抛的方向不追踪，否则她会反复被「接回」刚被拖离的窗口。在 `land`、`beginDrag`、进入盒子时清除。
- **必须在 `releasePerch()` 之前捕获** —— `maintainGroundSupport` 先释放 perch 再调 `beginFall`，
  所以在 `beginFall` 里读 `perch` 是 nil。

## 落地不再依赖地形图的重建频率（已修）

以前落地判定是**穿越测试**：「边的偏移落进这一帧脚扫过的带里」。
窗口可以在两次采样之间穿过她，所以穿越测试只有在采样恰好在窗口路径内时才触发 ——
这就是快速上升的窗口吞掉她、她掉到地板的原因。

**修法是把它变成「状态」而不是「穿越」**：「它的顶边在我的脚之下或之上（同一侧），
且仍以足够速度上升」。状态不关心采样频率。三部分：

1. **接住她的窗口**取自**身体采样（10 Hz）**，不是地形图，并且每个下落帧重新选。
   从图里选才让刷新率变得承重：以 2000 pt/s 拖动的窗口在 25 Hz 下就已经陈了 66 px，
   在 0.25 s 下陈 400 px，足以选错窗口 —— 选错就让她穿过正确的那个。
   **把「选谁」与图解耦是降低频率的前提。**
2. **它在哪**来自单窗口实时读（实测 0.095 ms），所以图有多陈都不影响位置。
3. **遮挡仍然来自图**，因为实时读不重算遮挡 —— 它报整条边，据此落地会把她放在被盖住的点，
   下一帧 perch 被拒绝，她又从静止处掉下去。

实测（同一构建 + 启动开关，12 s 反复抛）：图重建从 **311 → 100** 次采样，
约 **−2.0% 绝对 CPU**（按下落帧归一）。**5.5 Hz（0.25 s / 100 pt）几乎拿到全部收益**；
2.8 Hz 只多省 0.2%，却让遮挡信息陈旧一倍。所以取中间那个。另外真正的约束一直是
**距离触发（26 pt）**，不是 30 Hz 时钟 —— 实际达到 25 Hz。

顺带修掉一个潜伏 bug：`isPerchSpotVisible` 曾用 `perch.position(in: graphSurface)`
把 `perch.t` 映射到**图**的 span 上，而 `t` 是按她实际落到的那个 surface 算的，
而落地现在可能返回**实时** surface。两者 span 不同（窗口被横向拖动）时，
它问的是一个她并不站着的点。现在问她的**世界坐标**。

一个仍未解释的线索：她成功落地一次，下一帧 perch 又被判 `covered`、从静止掉到地板。
注意两个判定的 inset **不同**：落地用 `isVisible(atCoordinate:inset: 10)`，
perch 用 `isVisible(at:)`（inset 0，更**宽松**）—— 更严的过了、更松的没过，
在同一张图上不可能，所以中间图被重建过。不是这轮引入的。已加 `PerchCovered` 诊断事件，
此后没再触发，因为**「被盖住」是唯一从外面看不见的失败**：
她画在所有东西上面，所以「图说被盖住」和「什么都没盖她」在屏幕上一模一样。

## 地板位置：盒底 = 窗口下边缘（0 内缩）

历史上有三个值，只有 0 对：

- 最初是 `box.bottom + 8` —— 太低。
- 随后改成 `box.bottom - 6` —— 太高（「脚又离窗口下边缘太高了」）。
- 现在 `box.bottom` —— 正确。

**决定性测量**（解 PNG alpha 边界）：`sprites/runtime/{idle,walk,land}/*.png` 全是 384²，
**最低不透明行 = 373（0 基）= 374** = `runtimeFootBaseline` → 画布 **498.667 = `footCanvasY`**。
精灵帧在脚下方**没有任何透明留白**，脚的可见像素正好落在脚锚点。
屏幕地板是 `visibleFrame.bottom`，脚锚点落在那里时可见脚正好压在工作区底边 —— 用户确认这是对的，
所以窗口地板的正确目标同样是**窗口自身的下边缘**。

`WindowEnclosurePhysics.walls(of:inset:)` 只内缩左/右/上，**地板留在下边缘**；
`bodyFits`、`boxHasRoom`、`resolve` 三处必须用同一个「墙」定义，否则 entry 与 `boxHoldsHer`
会在 6 pt 上打架。**`PixelRect.insetBy(_:)` 是对称的**，所以要有这个非对称版本。

6 pt 内缩本来只对**两侧和天花板**成立（她的身体圆润，会压到窗口圆角；脚不会）。
原版 Windows 对四边一律内缩，那是**上游的误差**，不是要复刻的行为。

另有一个相关 bug：移植时漏掉了「封闭路径要用**含脚**的包围盒」。上游同一处对比鲜明：
侧撞用 `GetPetCollisionBounds()`（不含脚），而封闭/进入/为吃食离开用
`GetPetCollisionBounds(_character.Geometry.FootCanvasY)`（含脚）。
`resolve` 的落地分支是 `offsetY = bottomBoundary - pet.bottom`，贴地的是**传入矩形的底边**。
端口传的是身体矩形（底边 466，脚是 498.667），差 32.67 画布单位 × `petSize/512`，
所以「越放大越明显」（size 132 → 低 2 pt，220 → 8 pt，330 → 16 pt）。
`bodyRect(bottomCanvasY:)` 这个参数一直都在但全仓库无人传值 —— 那是没接完的线。
现在封闭路径四处统一用 `enclosureBodyRect`。
**不要改**：`updateWindowSideCollisions`（上游也不含脚，而且「身体底边离脚 14.04 pt
使侧撞结构上不可能命中脚下的窗」这条依赖它）、`coveringWindow`（判据是身体中心）、
`releaseEnclosureForMeal`（只用来选朝哪个墙出去）。

## 支撑的有效性：遮挡资格（两步）

`SurfaceBuilder.build` 同时回答两个不同的问题，最初共用一个 `isEligible`，
而 `isEligiblePlatform` = `isEligibleAppWindow` **∧ 顶边可达**，第二个条件对遮挡毫无意义。
同时 `coveringWindow` 读的是 `windowBodies`，那里 AND 了 `isBoundedBody`，
于是**最大化窗口根本没被采样**。三个集合因此各不相同：

| 窗口 | 遮挡 | 覆盖 |
| --- | --- | --- |
| 屏幕中间的普通窗口 | ✓ | ✓ |
| **最大化窗口** | ✓ | ✗ |
| **顶边在 Dock 下** | ✗ | ✓ |

**第一步**：一次采样存下**所有**合格普通窗口，并标记哪些能装下她
（`WindowBody.isEnclosureCandidate` = `isBoundedBody`，配 `Dictionary.enclosureCandidates`）。
遮挡读**全部** body；封闭与侧撞只用候选（与上游一致，上游的 `WindowBodies` 也过滤了）。
零额外枚举。这修掉一个实测 bug：**最大化窗口盖住盒子时，她被永久困在里面**
（bodies == `[the box]`，`coveringWindow == nil`）。`transferEnclosure` 也必须加同样的检查 ——
它原来只测 `bodyFits`，之所以安全**仅仅因为**最大化窗口不在采样里。

**第二步**：`build` 收**两个**闭包 —— `isTerrain`（能不能站在它顶边）与 `occludes`
（是否不透明且在前）。后者只用 `isEligibleAppWindow`：窗口顶边在哪与它是否遮挡毫无关系。
修掉的是一个**可演示**的 bug：窗口被拖到顶边在菜单栏下方时不遮挡，于是
`isPerchSpotVisible` 从图里读成「可见」，她站在一个实际被盖住的边上 —— 看起来像浮在窗口中间。
受影响**只有**「顶边在工作区之上」这一种情形：所有可站立的边都有 `y < workArea.bottom`，
而遮挡要求 `occluder.top <= y < occluder.bottom`，所以完全在屏幕下方的窗口永远不可能遮挡可站立的边。

**顺序是承重的**：第一步（采样器标记候选）必须先做，因为 `transferEnclosure`
只是**因为**最大化窗口不在采样里才没把她封死在最大化窗口内。

### 手工验收有边界 —— 「用手复现不出来」不等于缺陷

第二步的修改只能由**纯函数测试**钉住。在真实桌面上，普通窗口的顶边**不可能**被拖到菜单栏下面
（能上去的通常是 borderless/工具栏样式，或全屏过渡的瞬态）。所以这个几何没有可靠的桌面操作流程。
**「只能在测试里构造」是测试存在的理由，不是测试的缺陷。**
若以后收到「她站在一条看不见的窗沿上」的报告，这里是第一个该怀疑的地方。

顺带：系统设置里「双击窗口标题栏以」控制的是 **zoom**，而 zoom 后的窗口停在菜单栏**下方**，
所以它既不触发这个谓词、也不被这次修改覆盖。

## 遮挡者必须是「地形合格」的窗口

我们自己的 overlay（桌宠面板 `.floating`、气泡、幽灵图标）也在 CGWindowList 里，
且正好在桌宠位置上。把它们当遮挡者会在她站的那条边上**挖一个洞**
→ `landingSurface`/`support` 返回 nil → 她从所有窗口旁掉下去。
`SurfaceBuilder` 用 `isEligible` 过滤遮挡者。

## 她只能落在脚「扫过」的表面

`landingSurface` 在 `[fromY, toY]` 里找。地板之下什么都没有，所以脚低于地板就意味着
她掉出屏幕。`updateDrag` 把她夹进显示器的 `visibleFrame.bottom`。
任何其他移动 `foot` 的路径都需要同样的保护。

## 仿真中的「空隙」不能被当成移动

离开全屏应用后她曾**被横向甩出约 400 pt**。现场日志决定性：
`SuspensionChanged Suspended="false"` → `WindowSideImpact EdgeVelocityX="1100"` →
`FallStarted Reason="WindowSideImpact" Velocity="1112,-144"`，其中 1100 是**夹紧值**。

**这里每一处「移动」都是一帧内两次采样之差** —— 她骑着的窗沿（`lastPerchOffset`）、
盒子的四面墙（`enclosure.previousBox`）、扫过她的窗口边（`previousWindowBodies`）。
挂起期间一个都不问、也都不重新取基准，所以回来的第一帧把整个间隔除以一帧。
`WindowSideCollisionPolicy` 还**乘以** `bodySampleElapsed`，所以误差在两个方向上都静默。

`resumeFromSuspension()` 重置三者。**只清 `previousWindowBodies` 不够**（第一次尝试在现场失败），
因为 `windowBodies` 也是陈的，它会成为下一对的 previous，坏的那对只是晚一个采样。
`SurfaceProvider.nextBodySampleIsBaseline` 让空隙后的第一次采样**从自己开始**（差值为零）。

`PetController.updateDisplaySpace` 仍会把她夹进显示器，这是空隙移动她的另一条路径，尚无测试。
