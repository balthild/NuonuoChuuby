# 试过并否决的方案

每条都记**否决它的证据**，不是印象。重开之前先看这里的数字。

## 120 fps 直接渲染（否决）

把 tick 提到 120 Hz、去掉插值，让位置按显示器自身频率更新、没有插值滞后。精灵帧本身只有 11–18 fps，
所以位置是唯一能变的东西 —— **视觉上与插值相同**，真正差别只有约 12 ms 的延迟。

实测（同一构建 + 启动开关，三次 12 s 连续拖动）：主线程 887 vs 859 ms —— **120 Hz 直接与插值在拖动时
成本相当（+0.23%）**。但用户用 `htop` 看了更长的、基本不在拖动的时段，看到**平均 CPU 约 +1%**，不可
接受。用户的读数获胜。

**我的 A/B 为什么低估了它（值得留住的教训）**：我测的是连续拖动，但提高 tick 率的成本主要是**每 tick
固定工作翻倍** —— tick 即使她站着不动也每秒触发 120 次。拖动被拖动工作主导，掩盖了 idle 的增加。idle
时 `step` 占主线程 78%，而其中**没有按时间门控**的部分随 tick 翻倍。**评估任何提高 tick 率的东西，要
测稳态/idle。**

## 拖动绘制降到 30 Hz（否决）

用户想试「把拖动时图像的绘制频率从 60 降到 30」（靠 CA 插值补到 120）。

「绘制频率」在这个项目里就是**拖动中 `step()` 每 tick 调 `notifyPlacementIfChanged()` 的频率**（写
`layer.position` 那一步）；物理仿真本来就是 60 Hz。旋钮（已撤销）：`dragDrawInterval` +
`placementAnimationDuration` （glide 时长必须跟着变成该间隔，因为 **D 必须 = T**，见
`rendering.md`；只降绘制不降 glide 会「滑一下停一下」）。

**实测：htop CPU 约 −1%，但拖动手感明显变差，不值得。** 用户撤销了全部更改，没有留下提交。

为什么省得有限：只减了**一半的 CA 动画事务**，物理 tick 仍 60 Hz；而手感变差是必然的 —— 跟手延迟 =
`v·D`，`D` 从 1/60 变 1/30 就是延迟翻倍。平滑度与延迟是同一个参数。

若日后还想试：想省更多就必须把**拖动期间整个 tick**（物理也降）降到 30 Hz，那是另一个（物理保真度）
取舍，且要用同一脚本 A/B。

## 用 kqueue 替代 FSEvents（否决）

用户曾提出用 kqueue（「监听桌面不需递归」）。否决理由：

1. kqueue 在目录 fd 上只报「该目录变了」，**不给文件名**，必须自己 diff 目录列表才知道删了什么；
2. 目录 diff 拿不到「删除前」的图标位置，而 AX 索引恰恰能；
3. FSEvents 本就按路径注册、非递归语义可控，还带 per-file 标志。

（注：本机上 `open(O_EVTONLY)` 现在不阻塞了，因为此机 Desktop 已不是 iCloud 托管 —— 但这不改变 ①② 的
结论。）

## 用抛物线求交判定落点（否决）

想在松手时把她的运动当成真抛物线，与每条可见边求交，一次算出她会落在哪 —— 特别是用它回答「她下方这条
边该不该接住她」，从而免去逐帧复核。

否决理由：

1. **她的运动不是抛物线。** 水平有指数阻尼（`exp(-0.48·dt)`），竖直被终速夹紧（腾空 1350、盒内
   1400），每帧还要过 `SubpixelMotion.takeWholePixels` 的整像素量化加余数。解析解与真实轨迹必然不一
   致；要对上就得积同一组 ODE 加同一套量化 —— 那就是仿真本身。
2. **窗口会移动、也会出现**。为此现有设计专门逐帧重问：`liveSurface` 的单窗口实时读、
   `refreshAirborneCatcher` 从 10 Hz 身体采样里选目标、`fallRefreshInterval` / `fallRefreshDistance`
   的图刷新。任何在松手时算出的交点都会在下一次身体采样（100 ms）后作废。
3. **它解决的问题不存在。** 「她会在哪条边上落地」不需要提前预测：她本来就在逐帧真实运动，只要在她真
   正跨过那条边的那一帧问一次即可 —— 更便宜，而且永远与实际轨迹一致。最终采用的是把入场谓词变成**持
   续不变量**，见 `physics.md` 盒内下落那一条。

## 用 `AXObserver` 通知替代追读轮询（否决）

想用 AX 通知替掉「新图标出现后每 0.25 s 读一次」的轮询。实测（真机、Finder 建/删文件夹）， **19 个通
知名在 app 与 icon container 上全部注册成功**（注册成功 ≠ 会触发）：

- **`AXCreated` 从不触发** —— Finder 不为桌面图标发它。这是否决的决定性事实。
- `AXUIElementDestroyed` 会触发（删除后 ~0.2–0.3 s），**但那时元素已失效**：所有属性都是
  `kAXErrorInvalidUIElement`，**读不到位置**。所以它既不能替代 FSEvents 的删除检测，也不能替代活读。
- 创建期唯一会触发的是 `AXSelectedChildrenChanged`（+0.18…+1.36 s 共 6 次），但它语义是「选中项变
  了」，只是因为 Finder 会**选中**新建的文件夹才顺带触发；拖入/下载等不改变选中的创建不会触发它 ——
  作为「出现」信号不可靠。

**结论：追读轮询保留，这是唯一可用的方式。**

## 拖动时把气泡重定位节流到 20 Hz（否决）

降低了成本，但引入明显的**气泡抖动**，已回滚。

## 把她的窗口夹在另外两个窗口之间（不可行）

`NSWindow.level` 是粗粒度整数，**所有**普通窗口都在 `CGWindowLevel 0`，所以「A 和 B 之间」没有可用
值；降低层级会掉到 Dock（20）与菜单栏（24）之下；二维裁剪也不行（窗口投影由**遮挡者**画，且窗口不都
是矩形，裁成矩形仍会从两者里透出）。详见 `physics.md` 的「被覆盖的封闭盒」。

## 鼠标移动开销：所有窗口级/连接级开关都无效

背景与机制见 `performance.md`。以下是**逐个实测**的结果。

| 手段 | 层级 | 结果 |
| - | - | - |
| 会话全局 `CGEventTap` 丢弃 `.mouseMoved` | 会话 | **有效，−80%**（app Δ +6.07 → +1.0…+1.4，`NSEventThread` 样本 420 → 0），但**所有 app 都失去 hover** |
| `ignoresMouseEvents = true`（公有） | 窗口 | 只省 **~0.36 pt（约 13%）**，且点击/拖动/捏脸全废 |
| `CGSSetWindowEventMask(mask: 0)`（私有） | 窗口 | 无变化 |
| `CGSSetWindowTags` + `CGSTagTransparent`（私有） | 窗口 | 无变化 |
| `CGSSetMouseEventEnableFlags(cid, wid, false)`（私有） | 窗口 | 无变化，**且调用本身在本机是空操作** |
| `CGSSetEventMask`（私有，连接级） | 连接 | 无变化（投递计数相同） |

### 关于那个 StackOverflow 答案

问题：_Opaque NSWindow and WindowServer poor performance_（SO #59309522）。答案把过载归因于
`ignoresMouseEvents` **未设置**时的「第三态」——每次鼠标移动做一次透明命中测试，并说显式设 `true` 即
可消除。

**它不是我们的成本。** 我们设了（用户确认有效：拖不动她），app 与 ws 都没动；而且那个 13% 的节省来自
投递**之后**的路由，不是命中测试。（他们的复现用 5000 个 layer，我们 overlay 只有约 3 个，本来也不太
可能撞上。）

### 为什么私有调用返回 0 不能当证据

`CGSSetMouseEventEnableFlags` 头文件承诺「为否时事件传给下一个窗口」，实测点击**仍被前景窗口接收**，
而同一探针里的 `ignoresMouseEvents` 对照能把它送到后面。 **这些私有 API 返回 `kCGErrorSuccess` 并不
代表生效 —— 必须验证副作用。**

同类陷阱：`CGSGetWindowTags` **对每个 tag 都读回 0**，无法确认写入；
`CGSSetWindowTags`/`CGSGetWindowTags` 的 size 参数**必须是 32**（否则返回 `kCGErrorFailure` 1000）；
而 `CGSTagTransparent` **确实生效**（点击穿透），只是**只对点击**，不影响移动流。

### 「tag + CGEventTap 按距离动态切换」也不成立

- tag 根本不 gate 移动流，**没有可切换的东西**；
- 即便只用全局 tap 做动态切换：成本是「光标在哪里移动」就付的，而 overlay 铺满全屏。只在光标**远
  离**她时丢弃 ⇒ 等于绝大部分时间全系统关闭 hover；只在**靠近**她时丢弃 ⇒ 一点都省不到。
- 唯一能省的是会话全局销毁事件，而它必然影响所有 app。

## 用 Accessibility 做窗口跟踪（否决）

拿不到 z 序，而 z 序是遮挡减法的唯一输入；没有公开的 `AXUIElement → CGWindowID` 映射；只覆盖实现了
AX 的应用（Java / X11 / 部分游戏窗口不报）；逐属性读取是跨进程 IPC，对方应用卡住时会阻塞。它改善的也
只是「新窗沿被发现」的延迟，不是用户感受到的跟随延迟。 Ledgeling 的 macOS 层同样只用
`CGWindowListCopyWindowInfo`。

**桌面图标坐标是 AX 的正确用途**（那里只有 AX 能给出真实坐标），见 `meal-and-icons.md`。

## 用固定常数 RNG 替代可播种 RNG（否决）

用户问过「要不要加一个测试专用 RNG、永远返回固定数」。结论是不要：

1. **确定性早就有** —— `TestAssets.randomSeed` + `PetRandom` 已经是逐位可复现；「固定数 RNG」不会让
   非确定的东西变确定。
2. 真正的缺陷是**测试编排**（判定窗口里混进了不属于它的行为），任何 RNG 都改不了。
3. 「固定数」消掉了「序列漂移」这一种脆弱，却换来另一种（红绿取决于常量是否巧合通向方便行为），
   且**两个测试无法共存**（同一 draw 站点一个要打滑一个要成功，单常量给不了）。

若日后真需要「依赖特定随机结果」的测试，正解是**可编排脚本序列**的 RNG，而不是「永远同一值」。**优先
用领域接缝（`quietMode`）而不是随机性 hack。**

## 从 stub 之外删除 Trash 佐证（已做，非否决）

原版监听 Windows `$Recycle.Bin` 读原始路径，那是它的主检测手段；macOS 无逐项元数据，移植时 Trash 被
降级成「佐证」。但它也不能纠正误吃，且 `cameFromTrash` 只赋值、无读取方。 **`rm` 等直接解链的删除根
本不进回收站**，所以「Trash 里没有」什么都证明不了。现已删除，沉降窗从 2.5 s 改成 0.5 s。详见
`meal-and-icons.md`。

## 自写 dmg 排布脚本（否决，已删除）

先写过 `Tools/create-dmg.sh`：暂存目录 → `hdiutil create` 读写镜像 → 挂载 → AppleScript 让 Finder 摆
窗口 → `hdiutil convert` UDZO。它没有做任何 `create-dmg` 1.2.1 不做的事，而后者还多做了 `chmod -Rf
go-w`、删 `.fseventsd`、Finder 自动化被拒时**退出 64**。

当初的两条理由都不成立：

1. 「不引入依赖」——Makefile 早已用 nix 取 `svu` 和 `gettext`；
2. 「控制每一步」——步骤完全相同，只是换成了别人维护。

自写版唯一领先的地方，是它处理了「重复打包」和「失败后残留」，而这两点在 Makefile 里各一行就够（`rm
-f "$(DMG)" "$(DIST_DIR)"/rw.*.dmg`）。**结论：能用现成工具就别自己写；只在工具确实缺能力时才自
写**（`sign-app.sh` 是例子， codesign 与临时 keychain 的那些步骤没有现成工具能替）。

## `-cross-module-optimization`（否决，2026-11）

拆成多模块后给 release 加 `-Xswiftc -cross-module-optimization`，想让跨模块调用仍能内联。**实测它在
本项目不内联我们自己的代码**，已移除。

开/关该标志各做一次干净构建的对照：

- 标志确实到达编译器并改变代码生成：release 二进制 1,851,984 → 1,878,480 字节（**+26 KB**）。
- 但消费方目标文件里**仍保留对被调方的未定义符号引用**：`nm -u
  .build/release/Pet.build/PetController+Walking.swift.o` 在两种情况下都命中 `SubpixelMotion`。调用
  还在，就是没内联。
- 机制：CMO 要从依赖模块里读 SIL，而 `PetFoundation.swiftmodule` 里**没有序列化 SIL**（`sil_stage`
  出现 0 次，函数体局部变量名也不在其中）。唯一能提供 SIL 的 `-serialize-sil` 被 SwiftPM 直接拒绝
  （`Build/LLBuildCommands.swift: unknown argument: '-serialize-sil'`）。
- 增量构建不受影响（改底层文件：开 1.80 s / 关 1.75 s），所以它既没有收益也没有代价——只是没用。

**验证内联的正确方法是 `nm -u <consumer>.o | grep <callee>`**：内联了，未定义引用就消失。下面两种做
法都不成立，别再走一遍：

1. **用「等价改写」对比目标文件哈希。** 优化后两种写法可能编译出完全相同的机器码，「对象没变」什么也
   证明不了。
2. **在函数体里放字符串常量再用 `strings` 找。** 字符串常量会被合并到一处，内联也不会把它复制进消费
   方；短于 16 字节的标记还会被 Swift 的小字符串优化内联进代码，`strings` 根本看不到。

另外：探针脚本别放在 `.build/` 下——`make clean` 会删掉它，脚本静默失败后「探针没生效」看起来和「没内
联」完全相同。

## 整表窗口枚举私有化（否决，2026-11-03）

把 `MacOSPlatform.windows()` 的 `CGWindowListCopyWindowInfo` 换成 `CGSGetOnScreenWindowList(0, …)`
加逐窗口 `CGSGetWindowLevel` / `Alpha` / `Owner` / `ConnectionGetPID`，并借此**跳过没人读的 chrome
窗口**（只有 `layer == 0` 会被当地形 / 遮挡体 / 身体）。

**等价性完全成立**（在屏集合、z 序、level、alpha、bounds、PID 逐字段一致；app 内 500 次比对零差异、
零回落），**但慢 14%**：每次枚举 830 → 945 µs，总 idle 1.88 → 2.08 pt。

机制与 `CGSGetWindowBounds` 的成功**恰好相反**：那个是拿私有读**替代**一个「为四个数字构建整份描述字
典」的昂贵批量调用；整表枚举却是拿 N 次服务器往返**换**一次批量，而**至少要为每个在屏窗口读一次
level** 才能跳过 chrome，单这一项（~19 窗口 × ~29 µs ≈ 550 µs）就接近公有一次枚举的全部成本。

数据、探针与两处 API 陷阱（`targetCID` 必须为 0、`CGSGetWindowAlpha` 实际是 `float *`）见
`performance.md` 与 `platform-quirks.md`。
