# 渲染

## 两个渲染方式，默认是「网格移动的小窗口」

`PetPresenting` 是渲染方式的接缝；`AppDelegate` 按 `--pet-overlay` 选，启动时往日志写 `PetPresenter
Kind=grid|overlay`。

- **小窗口（默认）** —— `GridPetWindowController`。一个**两倍她大小**的窗口（气泡需要时更高更宽），
  放在**一格她那么宽**的网格上，她在窗口内取余数位置。窗口只在**跨格**时移动，格内只改她自己的
  `CALayer.position`。
- **全屏 overlay（`--pet-overlay`）** —— `OverlayPetWindowController`。每个显示器一块**永不移动的全
  屏透明窗口**，她是其中的 `CALayer` 子层，一切靠图层几何。

两者都是「她是 `contents = CGImage` 的 `CALayer`」，共用
`SpeechBubbleDrawing`、`PetLayerConventions`、 `CheekPinchLayer`、形状点
（`PetLayerConventions.shapeCorners`）与 `FrameInterpolation`。差别只在窗口多大、什么时候动。

**命名**：`panel` 只指 AppKit 的 `NSPanel` 对象本身（`PetChromePanel` 与前缀 `panel` 的实例变量）；
渲染方式只有两个名字 —— `grid`（默认的网格小窗口）与 `overlay`。已删除的 `--pet-panel` 是「每帧把窗
口挪到她身后」的那一代，别再用 `panel` 指现在的默认渲染方式。

**为什么默认是小窗口、两者的代价差多少，都在 [performance.md](performance.md) 的「网格渲染」一
节**（那是这两条代价轴的测量与折算）。这里只记怎么实现、以及哪些地方不能改。

### 两个陷阱 —— 都靠测量发现，别「简化」掉

1. **她绝不能是 layer-backed `NSView` 子视图。** AppKit 在其 **frame** 变化时重绘，而全屏窗口上这会
   把 384² 精灵在 **CPU** 上重新采样（`argb32_sample` 0% → 28%，比它省掉的窗口移动还多 —— overlay 实
   测 **17.8% → 23.7%**，比面板还差）。`layerContentsRedrawPolicy = .onSetNeedsDisplay` / `.never`
   **都挡不住**。 `CALayer` + `contents = CGImage`、用图层几何移动，0%。
2. **手工创建的 `CALayer` 不会自动关闭隐式动画**（`wantsLayer` 的视图会被代劳）。不设 `pet.actions =
   ["position"/"bounds"/"transform"/"contents"/"hidden": NSNull()]`， CA 会把每次位置变化缓动约 0.25
   s，症状是「**她追着鼠标跑** —— 速度永远指向光标、追不上、鼠标停了才到」。

### 承重约束（不是偏好）

- **她、气泡、幽灵的层级都必须 > 0**：三者都用 `PetChromePanel`，其 `petPanelLevel` = 菜单栏 + 1 =
  25。`FullscreenDetector` 匹配任何**填满显示器的 layer-0 窗口**且**不排除自己的 PID**，所以层级 0
  的窗口会把自己判成全屏 → 隐藏 → 恢复 → 闪烁。**25 也意味着她盖住菜单栏和 Dock**（有意）；同层之间
  不再靠层级区分先后，靠窗口/图层顺序。
- **`constrainFrameRect` 必须直通**（`PetChromePanel` 提供）：overlay 需要它才盖得住菜单栏那一条，她
  自己的窗口需要它才能让脚锚点挂出屏幕顶边。
- `onPlacementChanged` 必须报**她自己的方块**，绝不能报窗口的 frame，否则气泡会按整个窗口（overlay
  下是整个屏幕）来摆放。
- 命中测试在 `OverlayPetRootView.hitTest`（只有身体椭圆）。overlay 里手势拿到的已经是**她的**坐标；
  小窗口里她的方块在窗口内还有偏移（网格余数 + 气泡预留），而 `root.petRect` 记的就是那个偏移后的方
  块，所以 `cheekHitTest` / `beginPinch` 两个渲染方式都不用改。

### 已知差异

多显示器未验证（开发机单屏）。overlay 是每屏一块，她画在包含她中心的那个上；**跨屏时会被 overlay 的
窗口边缘裁掉**。小窗口只有一个（不是每屏一块），跟着她走，所以没有这个问题 —— 但它的气泡预留和网格映
射都没在多显示器上验证过。两者都列在 `todo.md`。

## 网格映射（小窗口）

窗口放在 `w·floor(pos/w)` 上（`w` = 她的尺寸），她在窗口内的位置是 `pos mod w`。因为格内只有图层在
动，窗口的矩形在那段时间**完全不变**。

**气泡预留是平移格点，不是加宽格点**：气泡需要窗口为她留出四周的空间（她越大气泡越窄，`petSize ≥
气泡 宽` 时预留为 0），于是

```
窗口原点 = w·floor(pos/w) − reserve
她在窗口内的偏移 = (pos mod w) + reserve
```

**这两条必须一起改。** 加宽格点（让偏移落在 `[0, w + 2·reserve)`）会让窗口原点不再是 `w` 的整数倍，
窗口就变回每帧移动，网格的收益归零；平移则保持 `w` 周期不变。

预留是**按当前气泡算的**（`reserve(petSize:)`）：`horizontal = max(0, (气泡宽 − w)/2)`、
`above`/`below` 取其一。所以窗口平时是 `2w×2w`，有气泡时高一点、长台词时宽一点。**普通台词气泡比她还
窄 ⇒ 横向预留为 0**，所以绝大多数时间窗口一点都不加宽。

**`2w×2w` 是对称的，而她的运动大多只在一个轴上** —— 沿窗口顶边走是纯横向，沿竖边爬是纯竖向。按轴缩小
（甚至静止时完全不网格）看着划算，但收益只有约 0.1 pt，且某轴 slack 取 0 会让那个轴退化成每帧移窗
口： **已评估并否决，见 [rejected-approaches.md](rejected-approaches.md)**。

预留变化 → 一次 reshape（`setFrame`，AppKit 的 reshape 与 CA 提交同事务，不会闪）。一次气泡约两次
（show / hide），偶尔第三次（尾巴在屏幕顶上翻到脚下）—— 相比它换掉的每帧窗口移动，这个频率可以忽略
（见 [performance.md](performance.md)）。

### 跨格那一帧必须原子

跨格时窗口跳一整格、她的图层同时反向退回一格。**两者必须进同一个合成**，否则会看见她在错的位置上闪一
下。**AppKit 的 `setFrameOrigin` 会和 CA 提交合并，私有 `CGSMoveWindow` 不会** —— 这就是小窗口不用私
有调用的原因（这与「每帧移动窗口」那种做法的取舍相反：那时没有跨格补偿可撕裂，私有调用才划算）。

同一帧里也**不能**用插值：窗口的移动不可插值，而她的补偿是「为了屏幕上不动」，插值会让她滑一格。所以
跨格帧用 `FrameInterpolation.withoutAnimation`，格内帧才用 `animate`。

**气泡同理**：它在她窗口内也有偏移，所以窗口移动时也要反向补偿，于是 `SpeechBubbleLayerTarget` 带了
一个 `landsInstantly`（overlay 的窗口永不动，恒为 false）。

**「同一事务」现在是「同一次提交」**：`applyPlacement` 的每个分支都把 `onPlacementChanged` 放在那次
`FrameInterpolation` 闭包**之内**（以前在闭包之后），而 `FrameInterpolation` 只在最外层开事务、嵌套
调用只把 body 跑在那个事务里。于是她和气泡一帧只有一次 `CATransaction.commit()`。

这不改变任何一帧的动画语义：嵌套事务**继承**外层未设置的属性（`disableActions` 与
`animationDuration` 都从外层继承，子事务提交后外层的值原样恢复 —— 测试「A nested wrapper does not
replace the enclosing transaction's settings」盯住的就是这条），所以合并前后气泡拿到的时长与「是否关
动画」完全一样。省下的只有第二次提交。

**改前（2026-11-04 五场景 trace，主线程 inclusive，气泡可见的那几轮）**：`reposition` 118 / 80 / 44
/ 12 ms，同期 `CA::Transaction::commit()` 191 / 148 / 164 / 295 ms —— 第二次提交就在 `reposition`
里。

**改后实测（2026-11-05，`ps` 口径，跨进程交替 + 按撞击次数配对）**：场景取「窗口内抛起」（气泡几乎全
程在）。同活动量下 after 一律低于 before：

| 盒壁撞击 / 15 s | before | after | 差 |
| - | - | - | - |
| ~18 | 4.30（20 次） | 4.16（17 次） | −3% |
| 31 | 4.51 | 4.34 | −4% |
| 48 | 4.88 | 4.35 | −11% |

before 的 `%核` 随撞击数线性上升（约 0.02 pt/次），after 在 31→48 之间几乎持平 —— 和「省掉的是一
次**每帧**的提交，所以她动得越多省得越多」这个机制对得上。**结论是降了，但幅度小（0.1–0.5 pt），而且
必须按活动量配对看**：`%核` 本身随动作量走，不配对就会被进程间方差淹没（见
[performance.md](performance.md) 的跨进程交替那条）。

## 两个「画在 overlay 里」的状态

有两个状态她**改画在一块全屏窗口里**（`OverlayPetSurface`），而不是她自己的小块窗口：

1. **被拖动**（`isBeingDragged`）。
2. **被关在窗口里且在动**（`isMovingInsideEnclosure`）—— 被抛起，或被侧壁撞击后在滑。静止躺在盒子底
   上时**不**切。

判据是 `controller.isMovingFast`，两件事是同一件：**她正在被快速移动**。拖动时她的速度就是指针速度；
盒子里则是盒壁在推她 —— 而那是**全应用最快的运动**，`maximumVelocityX/Y` 把她夹到 1350 / 1200 pt/s，
比她自己走的 92–118 pt/s 快一个数量级。

为什么值得切：小窗口下她要一直保持在窗口中央附近，于是**每走一个身位就要移一次窗口** —— 上面两种速度
下就是每几帧一次，正是网格只削弱而不消除的那项。全屏窗口**永不动**，所以那段时间每帧只有一次图层位置
变化，**零窗口移动**。

- 它的代价 —— 指针下到处是窗口 —— 正是小窗口要避开的。这里值得付，因为**两个状态都是短命的**：拖动在
  松开手时结束，盒子在她落到盒底安定后就停止甩她。暴露时间由它们封顶。
- **小块窗口原地不动**：拖动时 AppKit 会把余下的 `mouseDragged` 一直投给**按下时捕获按键的那个窗
  口**，无论指针走到哪，所以它不必跟着她 —— 不跟正是目的。它只是隐藏内容、待在那里。
- 她与气泡都在 overlay 里（气泡走同一个 `SpeechBubbleLayerHosting` 接缝），所以这些时候她说话气泡照
  样跟着。
- 状态结束后她回到小块窗口：那次 `applyPlacement` 发现窗口离她一整段距离，一帧跳过去，她的图层同帧补
  偿。

这块窗口盖住**所有显示器的并集**，所以跨显示器不需要任何变化。

**它对她做命中测试，别处一律穿透**（`OverlayPetRootView`：只有她的身体椭圆返回自己，其余返回 nil，和
overlay 渲染器同一套）。这一条是**必须**的，不是可选：以前它只在拖动期间升起，那时指针按着、事件由窗
口捕获处理，所以「不吃输入」看不出来；现在盒子状态会让它在**指针空着**时也升起数秒 —— 如果它还忽略鼠
标，她就会被画在一个点不到她的窗口里，**看得见、点不着**。

**升起/降下它只能由控制器的状态决定，不能由手势决定**（`syncOverlaySurface()` 是唯一的写入点，在每次
`applyPlacement` 开头对账）。这条是踩出来的：最初「按下 → 升起」「松开 → 降下」是两处独立判定，而它
们的条件并不相同 ——

- `beginDrag` 可能**被 policy 拒绝**（`.pinching` / `.climbing` / `.rolling` 等），但表面照样升起；
- `endPinch` 也可能**还没结束**（`cheek.release()` 之后弹簧要回弹若干帧，`isPinching` 在那期间仍为
  true），于是松开时走的是捏脸分支，**永远不去降下表面**。

两者叠加就留下一个**永久的**残留：她画在一块不吃点击的全屏窗口里，而小块窗口已经停止跟随她、还把她隐
藏了 —— **她看起来完全正常，但鼠标全部穿透**。复现窗口只有几帧（捏脸松开后立刻再按一下，且按点不在脸
颊上），所以是「有几率」。

### 降下它靠的是一次 placement 通知，而通知只在「变了」时发出（已修）

`applyPlacement()` **不是**每帧都跑：controller 只在她的脚变了整像素、尺寸变了、或 `isMovingFast` 变
了时通知一次（`notifyPlacementIfChanged()`）。原来的判据只有前两项，于是**结束**这一侧会漏 —— 盒内静
息的那一帧正是她**停止移动**的那一帧（`takeWholePixels` 只取整像素，而 `if step.hitVertical {
remainderY = 0 }` 每帧丢掉亚像素余数，静息帧的夹紧修正常常不足 1 px），脚不动 ⇒ 不通知 ⇒
`syncOverlaySurface()` 不再被调用，全屏表面就留在屏幕上。

用户报的现象是「在窗口内释放、落到盒底站稳后，有时要等约 **3 s** 才切回 grid，且松手位置离底边越远越
容易出现」，并**目视确认了切换就发生在气泡消失的那一瞬**：落地那句台词的气泡顶着她过了
`SpeechBubbleTiming.defaultDuration`（3.2 s），气泡过期时 `setExtent(nil)` 触发一次
`applyPlacement()`，才顺手把表面降下来。**这就是「越远越反常」的来源**：与距离无关，只看最后一跳到静
息的收尾落在什么亚像素相位上 —— 下落距离长到接近终速后，收尾相位不再随距离变化，于是要么几乎每次都
卡，要么几乎每次都不卡。

修法：判据收进 controller 成 `isMovingFast`（渲染器读它，placement 通知也看它，两边不会再各算一
遍）， `beginDrag` / `endDrag` 也各报一次。回归测试
`WindowEnclosureIntegrationTests.settlingIsReported`：三个余数非零的松手高度，修前三个全失败，修后全
过。

## 气泡是她窗口里的一个图层

它原本是跟随她的独立 `NSPanel`（每帧 `setFrame`）。**两个渲染方式下它现在都是她窗口里的
`CALayer`**，用 `position` 移动：overlay 里是 overlay 窗口的图层，小窗口里是她那块窗口上方预留处的图
层。所以**跟随她不再有任何窗口移动** —— 小窗口下这是必须的，因为独立气泡窗口会每帧移动窗口，那正是网
格在消除的东西。

气泡的尺寸（多高多宽、相对她居中还是在她脚下）由 `SpeechBubbleLayout` 决定，**只跟高度有关**、水平居
中且**允许超出屏幕两侧**（她本来也走不出两侧，台词又短，丢一两个字可接受）—— 这样「气泡相对她的位
置」就是一个纯函数，预留才能算得出来。度量与唯一的 `draw` 在 `Dialogue/SpeechBubbleDrawing.swift`；
文本**限 3 行、超出以省略号结尾**，否则带文件名的台词没有上界、预留就没有上界。

`PetPresenting` 拥有 `speechBubble`，因为「气泡是哪个窗口的图层」由渲染器决定。

**实测（12 s「拖到所有窗口外 → 掉到地板」，overlay 时代，主线程 Running / 12 s）：** 主线程 **1221 →
929 ms（−24%）**，全线程 **1676 → 1241 ms（−26%）**； `updatePetFrame` 子树 **148 → 22**；
`setFrame` **165 → 0**； `commit_transaction` **238 → 89**。

**怎么让比较公平**（可复用的部分）：她说话多少的跑间方差是明显混淆项，用两个**内部控制**控制住，而不
是祈祷。减去气泡后的 `applyPlacement` 是她自己的路径 —— **33 → 35 样本，没变**；而气泡可见时每帧都跑
的 `bubblePlacement` 是 **4 → 5 样本**，即气泡在两次运行里出现帧数相当。 **挑一个「不是你改的东西」
的每帧函数，确认它被同等次数地执行。**

**两个值得留住的发现：**

1. **文本排版与栅格化从来不是成本，窗口移动才是。** 12 s 里气泡所有栅格化合计 **0.75%** 主线程。文本
   尺寸本来就是缓存的，`draw`/`CTLine`/`drawWithRect` 采样 **0**。所以「预测量/预栅格化以省 CPU」是
   错的方向 —— 预栅格化只是让 `layer.contents` 拿到位图的**前置步骤**。
2. **`commit_transaction` 的节省（−149 样本）在栈归因里完全看不见。** 它是 runloop flush，栈里没有我
   们的任何调用者，所以气泡的 `setFrame` 每帧都在强制一次 CA 事务提交，而任何调用树查询都无法把它归
   因到气泡上。**只靠栈归因会系统性低估窗口移动；只有同一脚本上的 A/B 才能揭示。** 128（子树）+
   149（事务）≈ 292 ≈ 实测总降幅，这才让归因可信。

**实现约束**：气泡的三种颜色是动态的，栅格缓存 key **必须包含 appearance**；按 `contentsScale` 栅格
化，否则文字模糊；气泡层级从 `.floating`（3）降到 overlay 的（2，菜单栏那条是 25），所以它与其他浮动
窗口的先后关系变了。

## 捏脸与幽灵图标

- **捏脸**：两个渲染方式都一样，画在她自己图层的上方（`CheekPinchLayer` 的容器是 pet 图层的子层），
  所以它跟着她的位移、倾斜与镜像走。
- **幽灵图标**：两个渲染方式不一样。overlay 里它是 overlay 窗口的图层；小窗口里它**是一块独立的小窗
  口**（`GridGhostIcon`），因为它站在被删文件原来的位置，那个位置可能离她很远，塞不进她的窗口。它出
  现得少、**出现后从不移动**（只有 `transform` 在抖），所以那块窗口只 `setFrame` 一次、之后什么都不
  做。

## 窗口形状：转场会冻结它的包围盒，所以每块窗口都放三个隐形点

**每一块能画她的窗口都需要这个 —— 现在是三块**（小窗口、`--pet-overlay` 的每屏面板，以及拖动 / 盒内
弹跳时用的全屏表面 `OverlayPetSurface`）。她的窗口是**透明**的，只有精灵（和气泡）所在那一块不透明；
而她是窗口里的图层，**会在窗口内移动** —— 所以不加东西的话，窗口的**形状**（不透明像素的包围盒）就是
她当下那一块，她一动就出了形状范围。

- **好的一面**：点击穿透。窗口服务器只把不透明像素算作该窗口的区域，其余像素的点击交给后面的窗口。
- **坏的一面**：切换 Space 时窗口的**形状（不透明像素的包围盒）被冻结**，而内容继续实时更新 —— 所以
  她一下落，冻结包围盒下方就被裁掉，看起来是「被横切成两半」。overlay 下这个包围盒就是整块屏；小窗口
  下它是整块窗口（她能在里面走到任何地方）；拖动表面下是全部显示器的并集。

实测（`_ignored/space-probe/`，三个对照探针）得到的关键不对称： **形状用包围盒判定，点击用逐像素判
定。**

| 覆盖方式 | 转场截断 | 点击穿透 |
| - | - | - |
| 无层 | 被裁 | 穿透 |
| 整片 alpha=0 | 被裁 | 穿透 |
| **整片 alpha=1/255** | 不裁 | **被抢** |
| **四角各一个 2×2 pt、alpha=1/255 的点** | **不裁** | **穿透** |

所以修法是 `PetLayerConventions.shapeCorners(in:)`：在**每一块能画她的窗口**的根层放**三个 2×2 pt、
alpha 1/255 的点**（`PetLayerConventions.shapeCornerActions` 禁用隐式动画），位置让它们的包围盒尽量
接近整窗。三块窗口各自按自己的尺寸放：`--pet-overlay` 每块屏放一次；小窗口放一次，尺寸变（气泡预留变
了）时重建；拖动表面每次 `show` 按显示器并集放一次。**这块表面曾经漏掉，于是只要她在表面里被切桌面就
照样会被裁 —— 复发与定位过程见 [physics.md](physics.md)。** 三个点而不是四个，且都离屏幕边缘 **1
pt**，是为了少抢点击：

- **两个在底部**（左下、右下）。指针很容易停在屏幕角落（它会顶住），1 pt 之外几乎点不中。
- **一个在顶部正中央**。左上角是苹果菜单、右上角是通知中心，两处都是活控件；中间的菜单栏什么都没有
  （MacBook 上那里是刘海）。**不要**把点放回顶部两角。

代价：包围盒因此**四条边各内缩 1 pt**，转场期间最外侧 1 pt 会被裁。overlay 下就是她的脚底（她的脚正
好落在 `y = 显示器高度`）；小窗口下是窗口边缘那 1 pt，通常是她旁边的空余 —— 实测都看不出。

**`--pet-outline` 给网格窗口画一条可见边框。** 它是诊断开关（不参与正常启动），画的正是这三个点要保
住的那个矩形：**边框被切** = 形状被切，**边框完好而她被切** = 问题在别的窗口或精灵那一层。它还让「她
当时画在哪块窗口里」一眼可见 —— 表面升起时那块小窗口原地不动，所以边框会留在**抓起来之前**的位置。那
块表面漏掉三个点，就是靠这条边框定位的。

**不要改成「整屏铺一层」**（会把点击一起抢走），**也不要删掉这三个点**（截断立刻回来），**更不要新增
一块能画她的窗口而不放点**。`WindowShapeCornerTests` 钉住三件事：点的数量与位置、**顶部两角必须空
着**、以及包围盒恰好只内缩 `PetLayerConventions.shapeCornerInset`。少一个点、或多内缩 1 pt，都会在某
个方向上重新开始裁。**但它只测几何，测不出「某块窗口忘了用它」** —— 那正是复发的原因，只能靠上面那条
边框用眼睛发现。完整机制见 [physics.md](physics.md)。

- **捏脸：控制器不再合成位图。** 新增 `cheekPinchState`（`{geometry, dynamics}`）与委托方法
  `didUpdateCheekPinch`（协议扩展给默认空实现）。`didProduceFrame` **永远送 cel 本身**，捏脸作为「叠
  在上面的一层」由 presenter 画。 overlay 用 `Pet/Cheek/CheekPinchLayer.swift`（容器是 **pet 图层的
  子层**，白捡 lean+mirror），几何在 `CheekPinchShapes.swift`（纯路径）。
- **lean 必须在 `didUpdateCheekPinch` 里重设**：pinch 可以多帧不送新 cel，只在 `didProduceFrame` 里
  设 transform 会让倾斜不跟手。
- **幽灵**：新 `GhostIconPresenting` 协议 + `PetPresenting.makeGhostIcon()` 工厂。 overlay 画在 root
  层的子层里，并保留一份注册表，`rebuildOverlays()` 后 `rebind()`，否则换显示器会把幽灵的层一起丢掉
  （`rebind` 的 `!isDismissed` 守卫见 `meal-and-icons.md`）。

### CALayer 坐标约定（探针实测）—— 唯一的真风险

root `isGeometryFlipped = true` + pet 层 `anchorPoint (0.5,1)` / `position (cx, bottom)`

- **CAShapeLayer 的 `path` 直接用左上原点、Y 向下**（如 `CGPath(rect: 0,0,10,10)` 落在 pet 的**左
  上**）。**内容不会被镜像**（所以精灵和气泡才是正的），flip 只改「位置从哪头算」。

所以捏脸层**不要再给容器设 `isGeometryFlipped`** —— 会二次翻转，形状跑到脚上。
`CheekPinchLayerTests` 把叠加层渲染成位图、取非白像素质心，断言落在「脸」那一段。**已验证**：给容器
加 `isGeometryFlipped = true` 会让它变红。

## 捏脸锚点：384 px 精灵空间

`CheekPinchGeometry` 的锚点必须按 `512/384` 折算。存原始值时它们小了 25%、也偏高 —— 嘴巴画在
`y*0.75`（额头），用户报「左眼上方有东西」。被替换掉的那个测试是自证式的（`leftX * s - 122 *
s`），**它把 bug 编码进了断言** —— 不要写这种形状的测试。

这个渲染器曾有过两次翻转 CTM 的 bug：`CGContext.draw(_:in:)` 假定左下原点，所以底图必须在「让用户 Y
向下」的那次翻转**之前**画。

## 捏脸打断剪辑时必须 `play("idle")`

`CheekPinchGeometry` 的锚点**只描述一个姿势**（idle）。捏脸允许打断 `.landing`，而控制器只把捏脸叠在
cel 上、**不动 `animator`**，`land` 剪辑继续播（压扁 + 张嘴），于是「捏脸特效」和「张开的嘴巴」一起
错位。

修法 = **上游原样**：捏脸开头 `animator.play("idle")`。选它而不是「禁止在 landing 捏脸」：一行修
好**所有**被中断剪辑（falling/curious/rolling…），且不给输入留死区；禁止方案只堵 `.landing` 一个症
状。

**顺带发现（未修）**：`.falling` 也能捏脸，而 `beginPinch` 会把 velocity 清零 → **僵在半空**。上游的
状态白名单本来把 `Landing`/`Falling` 一起挡掉，端口改用 `DragInteractionPolicy` 时两个都漏了。

## 位置插值：恰好一帧的图层动画

仿真仍是 60 Hz，但 `position` 交给 CA 时带一个**恰好一个 tick** 的线性动画，于是渲染服务器按显示器自
身的 120 Hz 采样这条曲线，而不是显示 60 Hz 阶梯。 `Presentation/FrameInterpolation.swift`。

**平滑度就是延迟 —— 它们是同一个参数。** tick 间隔 `T`、时长 `D`，跟随滞后正好是 `v * D`。 `D < T`
会提前结束然后停顿（比不插值更糟）；`D > T` 让滞后线性增长并被下一个目标截断（0.25 s 就是「她追着鼠
标跑」）。所以 **`D = T` 是唯一正确值**，不是「越小越好」。

**成本（同构建 A/B，12 s 连续拖动，`git stash` 切换）：主线程 824 → 909 ms，即 +0.71% 绝对
CPU（6.87% → 7.58%）**；全线程 +0.31%，即 **+118 µs/tick**。自耗时能对上账：`commit_transaction`
+8、`_copyRenderLayer` +6、`collect_layers_` +6、 `thread_flags_` +6、`collect_animations_` +6、字符
串哈希/比较 +12、`mach_msg2_trap` +37 ≈ 81。**所以隐式动画是在我们的进程里创建、编码、提交的**，渲染
服务器只负责播放。「插值不花我们的 CPU」是错的。

**为什么连续拖动是对的测量场景**（下落不是）：`updateDrag` 只写 `foot`、不通知放置，所以放置由
`step()` 每 tick 驱动一次 —— 固定 60 Hz 计时器，两次运行**次数相同**。下落在整个窗口里只移动一段，两
个长度不同的下落相差约 3 倍，总数不能相减。 **不要把一次下落外推成「每个移动帧的成本」。**

**两个必须保持 `NSNull()` 的 key**：`contents`（动画它会把一帧精灵交叉淡入下一帧 —— 她看起来永远模
糊）与 `transform`（它带着镜像翻转，会插值穿过零缩放 —— **她每次转身都会压扁**）。所以
`transform`（含 lean）保持瞬时。气泡必须加入同一事务 —— 现在也就是同一次提交（见「跨格那一帧必须原
子」一节），否则她滑行时尾巴会离开她的头；气泡被**显示**时反而必须关掉动画，否则它会从上次出现的地方
飞进来。

**一个值得记住的陷阱**：把 `CABasicAnimation` 模板留在 `actions` 字典里**根本不会插值** —— 500 ms 时
长下 `presentation()` 仍然恰好落后一次提交。**只有事务的时长有效。** 很容易写成静默空操作，于是看起
来像「插值没用」。

**未验证**：省略 `position` 的 `actions` 字典是否仍允许隐式动画。它在无头测试进程里断言不了
（`action(forKey:)` 在那里对每个 key 都返回 nil），只能靠眼睛。

## 慢 tick 下帧的驻留：她能不能跟着 `sleep` 一起降频

[performance.md](performance.md) 的「睡着时降到 10 Hz」只敢用在 `sleep` 循环上，理由是「10 Hz 落不到
别的剪辑的帧边界上」。**这半句是对的，但原文那句「`sleep` 的 0.185 s 刚好是整齐倍数」是错的** ——
0.185 不是 0.1 的整数倍，而它照样能降。真正的原因要量出来（`_ignored/keyframe-probe/cadence.swift`：
一个 16 帧剪辑、三种推进方式、60 Hz 采样屏幕读每帧的驻留）：

| 推进方式 | `frameSeconds` | 驻留 min/median/max | 直方图 |
| - | - | - | - |
| keyframes @ 10 Hz tick | 0.135 | 133/133/150 ms | 133ms×199, 150ms×22 |
| **tick 累加 @ 10 Hz tick** | 0.135 | **100/100/200 ms** | 100ms×144, **200ms×77** |
| tick 累加 @ 60 Hz tick（今天的参照） | 0.135 | 133/133/150 ms | 133ms×199, 150ms×22 |
| keyframes @ 10 Hz tick | 0.185 | 183/183/200 ms | 183ms×145, 200ms×16 |
| **tick 累加 @ 10 Hz tick** | 0.185 | **100/200/200 ms** | 100ms×24, **200ms×137** |
| tick 累加 @ 60 Hz tick | 0.185 | 183/183/200 ms | 183ms×145, 200ms×16 |

1. **画面只能在 tick 上改，所以驻留必然被量化成 tick 的整数倍、不再均匀。** `sleep` 的 0.185 s 在 10
   Hz 下大多是 200 ms、约每六帧才补一个 100 ms；而 idle 的 0.135 s 是近乎**均匀交替**的 100/200 ms。
   前者读作「略慢」，后者读作「一顿一顿」—— **用户目视确认**：tick 累加 @ 10 Hz 那一栏看得出顿
   挫，keyframes @ 10 Hz 与 tick @ 60 Hz 两栏都是匀速的。
2. **把下标改成按时间算没用。** 「按 `Int(t / frameSeconds)` 取帧」与「累加、溢出时前进」测出来**逐
   位相同**（都是 100/200 ms、直方图 144/77）：换的只是取哪一帧，改不了「只有 tick 能改画面」这件
   事。

**所以要让 idle 也降频，只能把帧的节奏交给渲染服务器** —— 上表 keyframes @ 10 Hz 与 tick @ 60 Hz 的
直方图**完全一致**（199/22），也就是 `CAKeyframeAnimation` + 10 Hz tick 得到的正是今天 60 Hz 的外
观。**它不是优化，而是前提**，而它已经做了（见本节末的「实现」与 [performance.md](performance.md) 的
「醒着静止也降到 10 Hz」）。

### 把 `contents` 交给 `CAKeyframeAnimation`：接线上量过的五件事

（探针 `_ignored/keyframe-probe/main.swift`。它用一个采样远慢于帧率的计时器来证明帧是渲染服务器自己
推进的 —— 若帧只在 app 看的时候前进，那里会读出 2 fps。）

- **它确实自己走。** 采样器只 2 Hz，而 0.135 s 的剪辑仍以 **7.43 fps**（期望 7.41）推进。
- **`presentation()?.contents` 按身份认得出当前帧**（`===` 比对帧数组），所以捏脸的 `sampleColor` 仍
  能拿到「屏幕上那一帧」。
- **`keyTimes` 必须 0→1**，所以 n 帧要 **n+1** 个时间；多出的那个是端点值：循环填回绕帧，非循环填末
  帧。
- **非循环 + 不设 `fillMode` 会跳回模型值**（实测：播完立刻显示帧 0）。`fillMode = .forwards`（配
  `isRemovedOnCompletion = false`）或把模型值设成末帧，都停在最后一帧。
- **必须显式 `add(_:forKey:)`**，不能指望隐式动画那条路（`FrameInterpolation` 的事务管不到它）。
- **探针自己踩过一次下面那个坑**：忘了给 `contents` 设 `NSNull()`，于是 CA 把每帧交叉淡入淡出，画面
  残影、还**把顿挫糊掉了** —— 用户一眼看出「中间和右边有残影」，而那正是本仓库 `petActions` 存在的理
  由。关掉之后直方图逐位不变，说明它只影响观感、不影响帧身份，但一个看起来「更顺」的观感足以让人得出
  错误结论。

**范围已定：只接管循环剪辑。** 非循环剪辑都是转场（tick 保持 60 Hz），于是上面第 4 条那个坑、以及
`didFinishClip` 驱动的状态机（`land`/`curious` → idle、`chomp` → 完成进食）都不会被碰到。

### 实现（2026-11-06）：一个周期 + 一个「下一步」

- **`SpriteLoop`**（`PetFoundation/Vocabulary/SpriteLoop.swift`）是一个周期：帧数组（**ping-pong 已
  展开**，所以渲染服务器只需重复它）、`frameSeconds`。`SpriteAnimator.currentLoop` 对非循环剪辑返回
  nil，`didBeginLoop` 与 `didChangeTo` **互斥** —— 接手的是谁，由动画师说，渲染器照做。
- **走路规则只有一份**：`SpriteAnimator.step(from:direction:in:)`，tick 用它推进；周期按定义生成（转
  向不重复两端）。`SpriteAnimatorTests` 把「CA 会播的序列」与「tick 实际走出来的序列」按**旋转**比较
  —— 单元测试里的 CA 部分断言不了，但两边的**帧序列**可以，而那就是全部契约。
- **`contents` 必须 `calculationMode = .discrete`**，否则 CA 插值 = 两帧交叉淡入（`petActions` 禁止
  隐式动画就是为了这条）。
- **交接要带上循环**：拖动表面是按需创建的，只拷 `contents` 会让她**整段拖动静止不动** —— 而拖动正好
  是循环剪辑。`PetLayerConventions.handOver(from:to:)` 现在重装动画。**它从周期的开头重播，没有保留
  相位**：每次交接都恰好伴随剪辑切换（开始/结束拖动），而切换本来就从第一帧开始，所以我认为无事可做
  —— 但**这条没有目视验证过**，若拖动开始那一下看到姿势跳帧，就是这里。
- **捏脸取色改读 `presentation()`**：循环播放时模型值一直是周期的第一帧，**屏幕上那一帧只有渲染服务
  器知道**。`presentedFrame(of:among:)` 用身份比对取出它。若取不到就回落到模型值。
- **`animator.announceCurrent()`** 是「重说一遍现在播的是什么」的唯一入口，`PetController.start()`
  用它 —— 原先那里直接读一帧，而循环是没有「当前帧」可读的。
- **盒内静止刻意不降速**（理由在 [performance.md](performance.md)）。

**收益（实测，详情与数据在 [performance.md](performance.md) 的「醒着静止也降到 10 Hz」）**：醒着静止
**1.17 → 0.59 pt，约减半**；两臂区间不重叠、8 轮状态全同。用户目视确认动画与改前一样顺。

## 挂起时隐藏她

进入真全屏应用（绿按钮 / ⌃⌘F）时她曾**冻结在一帧、可见地盖在应用上**，拖动只改一帧又冻结。原
因：`step` 在挂起时提前返回，而 `animator.tick` 在那之后 —— 所以什么都没推进，**也没有任何东西隐藏
她**（全仓库没有 `petWindow.hide()`），而面板的 `collectionBehavior` 带 `.fullScreenAuxiliary` +
`.canJoinAllSpaces`，所以她会加入全屏空间。

修法：`PetControllerDelegate.didChangeSuspension`（由 `isSuspended` 驱动，只有变化时才通
知），`orderOut` / `orderFrontRegardless`（从不抢焦点），再触发 `onSuspensionChanged` 让 AppDelegate
也收起气泡和幽灵。

- **报告的症状是挂起，不是渲染 bug** —— 收到「冻结但可见」的报告时不要去查绘图。
- 只有真全屏会触发：zoom 后的窗口停在菜单栏。`Cmd+Enter` 在某些应用里是全屏，但检测器读的是几何，不
  是快捷键。
