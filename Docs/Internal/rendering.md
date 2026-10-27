# 渲染

## 全屏 overlay 是唯一渲染方式

桌宠不再移动窗口。每个显示器一个**永不移动的全屏透明窗口**，她是窗口里的一个
**`CALayer` 子层**，通过图层几何移动。
（历史上还有一条「移动小面板」的渲染路径，由 `--pet-panel` 选择、`PetWindowController` 实现；
**它已经连同 `GhostIconWindow` 一起删除**，现在只有 `OverlayPetWindowController`。）

**实测（Time Profiler，30 s，`all-thread Running / 30 s`，同一交互脚本）：**
拖动 **17.8% → 10.8%**（−39%），盒内 idle **5.7% → 3.9%**（−32%）。
归因：旧模型每帧付一次窗口移动事务（`_setFrameCommon` 2.4% + `commit_transaction` 4.9%
绝对值）；新模型是 0.19% + 1.3%。

### 两个陷阱 —— 都靠测量发现，别「简化」掉

1. **她绝不能是 layer-backed `NSView` 子视图。** AppKit 在其 **frame** 变化时重绘，
   而全屏窗口上这会把 384² 精灵在 **CPU** 上重新采样
   （`argb32_sample` 0% → 28%，比它省掉的窗口移动还多 —— overlay 实测 **17.8% → 23.7%**，
   比面板还差）。`layerContentsRedrawPolicy = .onSetNeedsDisplay` / `.never` **都挡不住**。
   `CALayer` + `contents = CGImage`、用图层几何移动，0%。
2. **手工创建的 `CALayer` 不会自动关闭隐式动画**（`wantsLayer` 的视图会被代劳）。
   不设 `pet.actions = ["position"/"bounds"/"transform"/"contents"/"hidden": NSNull()]`，
   CA 会把每次位置变化缓动约 0.25 s，症状是「**她追着鼠标跑** —— 速度永远指向光标、
   追不上、鼠标停了才到」。

### 承重约束（不是偏好）

- **overlay 的层级必须 > 0**（用 `PetPanelLevel.belowFloating` = 2，比气泡和幽灵低一级，
  好让它们画在她上面）。`FullscreenDetector` 匹配任何**填满显示器的 layer-0 窗口**
  且**不排除自己的 PID**，所以层级 0 的 overlay 会把自己判成全屏 → 隐藏 → 恢复 → 闪烁。
- `OverlayPetPanel` 必须保留 `constrainFrameRect` 直通，否则 AppKit 会把 overlay
  拉进 `visibleFrame`，它就不再覆盖菜单栏那一条。
- `onPlacementChanged` 必须报**她自己的方块**，绝不能报 overlay 的 frame，
  否则气泡会按整个屏幕来摆放。
- 命中测试在 `OverlayPetRootView.hitTest`（只有身体椭圆），手势拿到的点是**她的**坐标，
  所以 `cheekHitTest` / `beginPinch` 不用改。

### 已知差异

多显示器未验证（开发机单屏）。实现是每屏一个 overlay，她画在包含她中心的那个上。
**跨屏时会被 overlay 的窗口边缘裁掉** —— 旧模型不会。两者都列在 `todo.md`。

## 气泡也进了 overlay

它原本是跟随她的独立 `NSPanel`（每帧 `setFrame`），现在是 overlay 里她上方的一个 `CALayer`，
用 `position` 移动。两种渲染共用 `Dialogue/SpeechBubbleDrawing.swift`（度量 + 唯一的 `draw`），
所以窗口气泡与图层气泡不会漂移。`PetPresenting` 现在拥有 `speechBubble`，
因为「气泡是窗口还是图层」由渲染器决定。

**实测（12 s「拖到所有窗口外 → 掉到地板」，与旧构建同场景，主线程 Running / 12 s）：**
主线程 **1221 → 929 ms（−24%）**，全线程 **1676 → 1241 ms（−26%）**；
`updatePetFrame` 子树 **148 → 22**（气泡自己那部分 146 → 18）；`setFrame` **165 → 0**；
`commit_transaction` **238 → 89**。

**怎么让比较公平**（可复用的部分）：她说话多少的跑间方差是明显混淆项，用两个**内部控制**控制住，
而不是祈祷。减去气泡后的 `applyPlacement` 是她自己的路径 —— **33 → 35 样本，没变**；
而气泡可见时每帧都跑的 `bubblePlacement` 是 **4 → 5 样本**，即气泡在两次运行里出现帧数相当。
**挑一个「不是你改的东西」的每帧函数，确认它被同等次数地执行。**

**两个值得留住的发现：**

1. **文本排版与栅格化从来不是成本，窗口移动才是。** 12 s 里气泡所有栅格化合计
   **0.75%** 主线程。文本尺寸本来就是缓存的，`draw`/`CTLine`/`drawWithRect` 采样 **0**。
   所以「预测量/预栅格化以省 CPU」是错的方向 —— 预栅格化只是让 `layer.contents`
   拿到位图的**前置步骤**。
2. **`commit_transaction` 的节省（−149 样本）在栈归因里完全看不见。** 它是 runloop flush，
   栈里没有我们的任何调用者，所以气泡的 `setFrame` 每帧都在强制一次 CA 事务提交，
   而任何调用树查询都无法把它归因到气泡上。**只靠栈归因会系统性低估窗口移动；
   只有同一脚本上的 A/B 才能揭示。** 128（子树）+ 149（事务）≈ 292 ≈ 实测总降幅，
   这才让归因可信。

**实现约束**：气泡的三种颜色是动态的，栅格缓存 key **必须包含 appearance**；
按 `contentsScale` 栅格化，否则文字模糊；气泡层级从 `.floating`（3）降到 overlay 的（2，
菜单栏那条是 25），所以它与其他浮动窗口的先后关系变了。

## 捏脸与幽灵图标也进了图层树

与气泡一致：捏脸与幽灵都画在 overlay 的图层树里。
（旧的「把捏脸烤进 384² 位图」与 `GhostWindow` 窗口实现已删除。）

## 窗口形状：转场会冻结它的包围盒，所以四角各放一个隐形点

overlay 是全屏**透明**窗口，只有精灵所在那一块不透明。这带来两个后果，而它们出自同一个量：

- **好的一面**：点击穿透。窗口服务器只把不透明像素算作该窗口的区域，其余像素的点击交给后面的窗口。
- **坏的一面**：切换 Space 时窗口的**形状（不透明像素的包围盒）被冻结**，而内容继续实时更新 ——
  所以她一下落，冻结包围盒下方就被裁掉，看起来是「被横切成两半」。

实测（`_ignored/space-probe/`，三个对照探针）得到的关键不对称：
**形状用包围盒判定，点击用逐像素判定。**

| 覆盖方式 | 转场截断 | 点击穿透 |
| --- | --- | --- |
| 无层 | 被裁 | 穿透 |
| 整片 alpha=0 | 被裁 | 穿透 |
| **整片 alpha=1/255** | 不裁 | **被抢** |
| **四角各一个 2×2 pt、alpha=1/255 的点** | **不裁** | **穿透** |

所以修法是 `OverlayPetWindowController.shapeCorners(in:)`：每块 overlay 的根层放
**三个 2×2 pt、alpha 1/255 的点**（`shapeCornerActions` 禁用隐式动画），位置让它们的
包围盒尽量接近整窗。三个点而不是四个，且都离屏幕边缘 **1 pt**，是为了少抢点击：

- **两个在底部**（左下、右下）。指针很容易停在屏幕角落（它会顶住），1 pt 之外几乎点不中。
- **一个在顶部正中央**。左上角是苹果菜单、右上角是通知中心，两处都是活控件；中间的菜单栏
  什么都没有（MacBook 上那里是刘海）。**不要**把点放回顶部两角。

代价：包围盒因此**四条边各内缩 1 pt**，转场期间她在最外侧 1 pt 内会被裁。她的脚正好落在
`y = 显示器高度`，所以脚底 1 pt 会被切 —— 实测看不出。

**不要改成「整屏铺一层」**（会把点击一起抢走），**也不要删掉这三个点**（截断立刻回来）。
`OverlayShapeCornerTests` 钉住三件事：点的数量与位置、**顶部两角必须空着**、以及包围盒
恰好只内缩 `shapeCornerInset`。少一个点、或多内缩 1 pt，都会在某个方向上重新开始裁。
完整机制见 [physics.md](physics.md)。

- **捏脸：控制器不再合成位图。** 新增 `cheekPinchState`（`{geometry, dynamics}`）与
  委托方法 `didUpdateCheekPinch`（协议扩展给默认空实现）。`didProduceFrame` **永远送 cel 本身**，
  捏脸作为「叠在上面的一层」由 presenter 画。
  overlay 用 `Cheek/CheekPinchLayer.swift`（容器是 **pet 图层的子层**，白捡 lean+mirror），
  几何在 `CheekPinchShapes.swift`（纯路径）。
- **lean 必须在 `didUpdateCheekPinch` 里重设**：pinch 可以多帧不送新 cel，
  只在 `didProduceFrame` 里设 transform 会让倾斜不跟手。
- **幽灵**：新 `GhostIconPresenting` 协议 + `PetPresenting.makeGhostIcon()` 工厂。
  overlay 画在 root 层的子层里，并保留一份注册表，`rebuildOverlays()` 后 `rebind()`，
  否则换显示器会把幽灵的层一起丢掉（`rebind` 的 `!isDismissed` 守卫见 `meal-and-icons.md`）。

### CALayer 坐标约定（探针实测）—— 唯一的真风险

root `isGeometryFlipped = true` + pet 层 `anchorPoint (0.5,1)` / `position (cx, bottom)`
+ **CAShapeLayer 的 `path` 直接用左上原点、Y 向下**（如 `CGPath(rect: 0,0,10,10)`
落在 pet 的**左上**）。**内容不会被镜像**（所以精灵和气泡才是正的），flip 只改「位置从哪头算」。

所以捏脸层**不要再给容器设 `isGeometryFlipped`** —— 会二次翻转，形状跑到脚上。
`CheekPinchLayerTests` 把叠加层渲染成位图、取非白像素质心，断言落在「脸」那一段。
**已验证**：给容器加 `isGeometryFlipped = true` 会让它变红。

## 捏脸锚点：384 px 精灵空间

`CheekPinchGeometry` 的锚点必须按 `512/384` 折算。存原始值时它们小了 25%、也偏高 ——
嘴巴画在 `y*0.75`（额头），用户报「左眼上方有东西」。
被替换掉的那个测试是自证式的（`leftX * s - 122 * s`），**它把 bug 编码进了断言** ——
不要写这种形状的测试。

这个渲染器曾有过两次翻转 CTM 的 bug：`CGContext.draw(_:in:)` 假定左下原点，
所以底图必须在「让用户 Y 向下」的那次翻转**之前**画。

## 捏脸打断剪辑时必须 `play("idle")`

`CheekPinchGeometry` 的锚点**只描述一个姿势**（idle）。捏脸允许打断 `.landing`，
而控制器只把捏脸叠在 cel 上、**不动 `animator`**，`land` 剪辑继续播（压扁 + 张嘴），
于是「捏脸特效」和「张开的嘴巴」一起错位。

修法 = **上游原样**：捏脸开头 `animator.play("idle")`。选它而不是「禁止在 landing 捏脸」：
一行修好**所有**被中断剪辑（falling/curious/rolling…），且不给输入留死区；
禁止方案只堵 `.landing` 一个症状。

**顺带发现（未修）**：`.falling` 也能捏脸，而 `beginPinch` 会把 velocity 清零 →
**僵在半空**。上游的状态白名单本来把 `Landing`/`Falling` 一起挡掉，
端口改用 `DragInteractionPolicy` 时两个都漏了。

## 位置插值：恰好一帧的图层动画

仿真仍是 60 Hz，但 `position` 交给 CA 时带一个**恰好一个 tick** 的线性动画，
于是渲染服务器按显示器自身的 120 Hz 采样这条曲线，而不是显示 60 Hz 阶梯。
`Pet/FrameInterpolation.swift`。

**平滑度就是延迟 —— 它们是同一个参数。** tick 间隔 `T`、时长 `D`，跟随滞后正好是 `v * D`。
`D < T` 会提前结束然后停顿（比不插值更糟）；`D > T` 让滞后线性增长并被下一个目标截断
（0.25 s 就是「她追着鼠标跑」）。所以 **`D = T` 是唯一正确值**，不是「越小越好」。

**成本（同构建 A/B，12 s 连续拖动，`git stash` 切换）：主线程 824 → 909 ms，
即 +0.71% 绝对 CPU（6.87% → 7.58%）**；全线程 +0.31%，即 **+118 µs/tick**。
自耗时能对上账：`commit_transaction` +8、`_copyRenderLayer` +6、`collect_layers_` +6、
`thread_flags_` +6、`collect_animations_` +6、字符串哈希/比较 +12、`mach_msg2_trap` +37 ≈ 81。
**所以隐式动画是在我们的进程里创建、编码、提交的**，渲染服务器只负责播放。
「插值不花我们的 CPU」是错的。

**为什么连续拖动是对的测量场景**（下落不是）：`updateDrag` 只写 `foot`、不通知放置，
所以放置由 `step()` 每 tick 驱动一次 —— 固定 60 Hz 计时器，两次运行**次数相同**。
下落在整个窗口里只移动一段，两个长度不同的下落相差约 3 倍，总数不能相减。
**不要把一次下落外推成「每个移动帧的成本」。**

**两个必须保持 `NSNull()` 的 key**：`contents`（动画它会把一帧精灵交叉淡入下一帧 ——
她看起来永远模糊）与 `transform`（它带着镜像翻转，会插值穿过零缩放 ——
**她每次转身都会压扁**）。所以 `transform`（含 lean）保持瞬时。
气泡必须加入同一事务，否则她滑行时尾巴会离开她的头；气泡被**显示**时反而必须关掉动画，
否则它会从上次出现的地方飞进来。

**一个值得记住的陷阱**：把 `CABasicAnimation` 模板留在 `actions` 字典里**根本不会插值** ——
500 ms 时长下 `presentation()` 仍然恰好落后一次提交。**只有事务的时长有效。**
很容易写成静默空操作，于是看起来像「插值没用」。

**未验证**：省略 `position` 的 `actions` 字典是否仍允许隐式动画。它在无头测试进程里断言不了
（`action(forKey:)` 在那里对每个 key 都返回 nil），只能靠眼睛。

## 挂起时隐藏她

进入真全屏应用（绿按钮 / ⌃⌘F）时她曾**冻结在一帧、可见地盖在应用上**，拖动只改一帧又冻结。
原因：`step` 在挂起时提前返回，而 `animator.tick` 在那之后 —— 所以什么都没推进，
**也没有任何东西隐藏她**（全仓库没有 `petWindow.hide()`），而面板的
`collectionBehavior` 带 `.fullScreenAuxiliary` + `.canJoinAllSpaces`，所以她会加入全屏空间。

修法：`PetControllerDelegate.didChangeSuspension`（由 `isSuspended` 驱动，
只有变化时才通知），`orderOut` / `orderFrontRegardless`（从不抢焦点），
再触发 `onSuspensionChanged` 让 AppDelegate 也收起气泡和幽灵。

- **报告的症状是挂起，不是渲染 bug** —— 收到「冻结但可见」的报告时不要去查绘图。
- 只有真全屏会触发：zoom 后的窗口停在菜单栏。`Cmd+Enter` 在某些应用里是全屏，
  但检测器读的是几何，不是快捷键。
