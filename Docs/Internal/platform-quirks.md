# macOS / AppKit 行为怪癖

本项目**依赖**的这些行为。不是风格偏好，改动前先确认。

## 窗口

- **`NSWindow.constrainFrameRect` 会把窗口夹进屏幕的 visible frame。**
  桌宠面板必须挂出屏幕顶边（她的脚锚点距面板顶约 129/132），所以面板要覆盖它、
  原样返回 frame。没有这个覆盖她会画在仿真位置下方约 130 pt —— 「浮着但没有窗口在她脚下」。
  overlay 同理（否则它不覆盖菜单栏那一条）。

- **`CGWindowListCreateDescriptionFromArray` 在这个 macOS 上返回空数组**
  （已验证：任何窗口、在屏不在屏都是 0 条）。
  单窗口查询要用 `CGWindowListCopyWindowInfo([.optionIncludingWindow], id)`（返回 1 条）。
  用错版本会让逐帧跟随静默退化成 0.5 s 的图。

- **`CGWindowListCopyWindowInfo` 的列表顺序就是 z 序**，且读 `kCGWindowName` 在实践中
  不花权限。我们曾把它读进 `TerrainWindow.title`，而没有任何消费者 —— 纯死代码。

- **读窗口的几何与身份（number/bounds/layer/alpha/ownerPID/name）不需要任何权限**，
  屏幕录制只对窗口**内容**（`CGWindowListCreateImage`、ScreenCaptureKit）才需要。
  所以地形与遮挡天然免权限。

- **窗口层级是粗粒度整数**：Dock 是 20、菜单栏是 24、`.floating` 是 3。
  所以「把她的窗口夹在 A、B 两个普通窗口之间」不可能（它们都是 0）。
  画在菜单栏上面需要 25+，但那样会盖住 Dock。

- **`.floating` 层级的窗口默认不进 Mission Control**，要加 `collectionBehavior .managed`。

- **无边框非激活面板**：`[.borderless, .nonactivatingPanel]` +
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`，
  用 `orderFrontRegardless()` 显示，从不抢焦点。

- **全屏检测**：`FullscreenDetector` 只匹配**填满显示器的 layer-0 窗口**，
  且**不排除自己的 PID** —— 所以 overlay 的层级不能是 0，否则它会把自己判成全屏、
  隐藏、恢复、闪烁。

- **切换 Space 时窗口服务器会报出相邻桌面的窗口**（实测 2026-10-27，`_ignored/space-probe`）。
  `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` 在转场期间同时
  返回**多个桌面**的窗口，按转场滑动的「桌面条带」坐标排列：1728 宽的显示器上出现
  `x=-5294`、`x=-1763`、`x=2609` 这类值。转场结束后列表回到只有当前桌面的窗口。
  - 触摸板手势切换时这个状态持续 **1–2.5 s**，且每秒变化多次（同一次手势里 `n=10 → n=3 → n=2`
    反复出现）。Ctrl+方向键的转场短得多，可能根本观察不到。
  - **转场结束后 `.optionOnScreenOnly` 会正确排除别桌面的窗口**（实测：切走后
    `leftBehind=[98, 717, 2575]`，这三个都不在列表里）。所以「在不在当前桌面」**不用猜**：
    **窗口在不在 `.optionOnScreenOnly` 的列表里**就是答案。她所在的窗口每次都从这里采样，
    所以 `windowBodies` 里有没有它 = 在不在这个桌面上（见 `physics.md`）。
  - **几何判断不出来**。切走时窗口的矩形**一点没变**（实测 `rect=136,86` 前后相同），
    公有读和私有 `CGSGetWindowBounds` 都照旧返回那个矩形。所以「不在任何显示器内」只能覆盖
    **转场途中**；转场结束后它就在屏幕里，只是不在这张桌面上。
  - 单窗口查询（`.optionIncludingWindow`）里，别桌面的窗口**没有 `kCGWindowIsOnscreen` 字段**
    （在屏的有）。这是唯一精确的单窗口「在屏」信号，代价约 89 µs；本仓库用免费的那条
    （在屏采样里的成员关系）。
  - **转场中同一桌面上的所有窗口位移完全相同**（实测四个窗口一个采样里全是 `-569`，
    精确到 0.001）。手拖只能移动一个窗口，所以「两个以上窗口同向同量横移」= 桌面在滑。
    `DesktopSlideDetector` 用的就是这个，它比「出现离屏窗口」更可靠 —— 快捷键切换可能
    根本不出现离屏窗口，但两个窗口不会一起移动。
  - 这一条是「切换桌面后她浮空 / 获得横向初速度 / 站在别的桌面的窗口边缘上去」的根因：
    那些窗口被当成了地形、遮挡体和侧撞体。见 `physics.md`。

- **私有 `CGSGetWindowBounds` 是单窗口矩形的正解**（`dlopen` SkyLight 后 `dlsym`，
  不链接；符号缺失就回落到公有读）。`CGSMainConnectionID()` 取连接 id，返回 0 才是成功。
  - **必须查返回码**：不存在的窗口返回 `kCGErrorFailure`（1000），而输出矩形是
    `(inf, inf, 0, 0)` —— 看上去像「在无穷远处」，当矩形用会静默把一切算错。
  - 返回的矩形**已是整数**（`kCGWindowBounds` 同），所以盒内 30 Hz 节流的
    「矩形相等即静止」判据不受影响。已验证：窗口按 0.25/0.75 pt 步进移动 40 帧，
    两侧 0 处不符、0 个分数字段。
  - 在 macOS 15.7.7 上实测 26 个在屏窗口与 `kCGWindowBounds` **逐字段相同**。
  - **别在紧循环里量它**：循环读数 2.5 µs，app 内 46 µs。见 `performance.md`。

## 绘图

- **`NSView.isFlipped = true` 只改坐标原点，不镜像内容。**
  `CGContext.draw(_:in:)` 假定左下原点、**不会**补偿，所以底图必须在翻转**之前**画；
  `NSImage.draw(in:)` 会补偿。
- **`CALayer` 的 `isGeometryFlipped` 与 `CAShapeLayer.path`**：
  root 翻转后，`path` 直接用左上原点、Y 向下即可。**不要再给子容器加
  `isGeometryFlipped`，会二次翻转**（形状跑到脚上）。
- **手工创建的 `CALayer` 不会自动关闭隐式动画**（`wantsLayer` 的视图会被代劳）。
  必须显式给 `actions` 字典填 `NSNull()`，否则每次位置变化都被缓动约 0.25 s。
- **放在 `actions` 里的 `CABasicAnimation` 模板根本不会插值**，
  只有**事务的 duration** 有效。很容易写成静默空操作。

## 事件与鼠标

- **`ignoresMouseEvents` 只影响点击/拖动等路由，不影响鼠标移动流的投递与解码。**
  实测：设了它移动开销仍在，投递计数仍约 1190/12 s。它能让点击穿透（这是它文档里的行为），
  也顺带省掉投递**之后**路由的约 13%，代价是拖不动她。

- **窗口/连接级的私有事件掩码都挡不住移动流**：成本发生在
  `PullEventsFromWindowServerOnConnection` 里，是连接级的、在按窗口判定之上。
  详见 `rejected-approaches.md`。

- **`CGSGetWindowTags` 对所有 tag 都读回 0**，不能用它确认写入；
  `CGSSetWindowTags` / `CGSGetWindowTags` 的 size 参数**必须是 32**（否则 `kCGErrorFailure`）。
  `CGSTagTransparent` 确实生效，但**只对点击**。
- **私有 API 返回 `kCGErrorSuccess` 不等于生效**：`CGSSetMouseEventEnableFlags` 返回 0，
  但连它文档承诺的「事件传给下一个窗口」都做不到。**必须验证副作用。**

- **`NSEvent.addLocalMonitorForEvents` 是可靠的「本进程实际收到多少事件」计数器**，
  是判断投递是否被改变的唯一直接手段。

- **`CGEventTap` 是会话全局的**：回调返回 nil 会把事件从全系统流里删掉，所有 app 都受影响。

- **FSEvents 的语义**：
  - `rename(2)` 在 FSEvents 里**两个名字都带 `Renamed`**（旧名与新名各一条）；
  - 移到废纸篓/移出目录是**单独一条**（带 `Renamed`，但目标不在磁盘上）；
  - 多条拖废纸篓会合并成一个 batch，但都**没有落点**；
  - 事件送达时新名字已经在磁盘上、旧名字已消失（回调发生在 `rename(2)` 返回之后）。
  - **目录监听必须用 FSEvents**，不要用 `open()` + DispatchSource（在 File Provider 目录上会挂起）。
- **Finder 不为桌面图标发 `AXCreated`**；`AXUIElementDestroyed` 触发时元素已失效
  （所有属性 `kAXErrorInvalidUIElement`）。用 AX 通知做「出现/删除」信号不可行。
- **Finder 发布一个新图标的 AX 元素需要 0.2–1.2 s**（实测 6 次采样）。
  删除后元素还会在树里留约 0.7 s（位置/尺寸仍正确）。

## 时间与内存

- **`NSApplication` 的主线程 `Timer` 放 `.common` 模式**才能在菜单打开或拖动循环期间继续跑。
- **仿真里的「移动」都是两次采样之差**：挂起/全屏/睡眠造成的空隙必须在恢复时重新取基准，
  否则整段间隔会被除以一帧（见 `physics.md`）。
- **`stateElapsed` 每个状态都重置，不能当全局钟**；需要全局时间就用单独累计的 `elapsedSeconds`。

## 测量

- `top -l 1` 的进程百分比是 0；前两个采样不准，第三个起才精确。`ps -o %cpu` / `htop` 正确。
- **紧循环微基准对窗口服务器/AppKit 调用不可信**（CA 会合并提交）。
- xctrace 导出**只有 Running 行**，栈归因系统性低估阻塞型开销。
- 沙盒/文件描述符层面的信号：`make rerun`（LaunchServices）与直接 exec 的 CPU 差 2–3 倍。
