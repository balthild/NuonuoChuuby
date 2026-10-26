# 测试

框架是 swift-testing。**测试数量以 `make test` 实际输出为准**，不要把数字写进文档再引用。

## 测试必须与随机种子无关

`PetController` 的 idle 计时与自主决策早期抽的是**全局** `Double.random`，
而 swift-testing 并行跑套件，所以她做什么取决于别的套件消耗了多少随机数 ——
两个测试约 1/10 概率失败。

**修复分两步，第二步才是关键：**

1. `Common/PetRandom.swift`：可播种 SplitMix64；`PetController.randomSeed`
   （默认 nil → 系统熵），**全部**随机调用改走 `using: &random`。
2. **只播种不够。** 扫 40 个种子发现其中 1 个仍让测试失败 —— 播种只是把测试
   **钉在一个幸运种子上**，没有消除脆弱性。根因是某个装置先跑 40 帧让地形图稳定，
   而那 40 帧里自主行为把她移开了地面。
   修法：**物理类装置在步进前就设 `quietMode`**（只留 `.rest`/`.sleep`，不移动她）。
   重扫 40 个种子 → 0 失败；连跑 15 次全套件干净。

**种子扫描是判断「测试是否与种子无关」的有效手段** —— 只看固定种子通过是不够的。

未路由的：`PetDialogueSelector.choose` 仍用全局 `Int.random`；它的测试是属性式的
（断言不变量而非具体值），不抖动。

## 测试陷阱（都真实踩过）

- **「只能在测试里构造」不是缺陷。** 有些几何在真实桌面上无法复现
  （例如普通窗口顶边拖到菜单栏下面）。纯函数测试存在的**理由**就是它。
  不要因此把它记成未解决 bug。
- **`platform.setWindows` 连调两次** ⇒ 第二次在任何帧运行前就替换了第一次，
  脚本窗口从未被采样，测试**空过**。一帧要看到的每个窗口都放进同一个列表。
- **perch 的可见性检查会掩盖「离开 perch 后的走动」。** 只有她的 `foot.x` 留在起跳边的
  span **内**，测试才会真正走到「漂移」规则；否则 `isPerchSpotVisible` 先拒掉这个位置，
  测试在漂移规则被完全删除时也能通过。把她放在**地板**（边覆盖整个显示器）或足够宽的窗口上。
- **`#expect` 里不能有 mutating 调用** —— 先提到局部变量。
- **`#expect` 的注释参数是 `Comment` 不是 `String`** —— `"a" + "b"` 在那里不编译，
  用一个插值字面量。
- **到达判定不要复刻控制器里的容差。** 助手函数在**移动后**判 `abs(foot.x - target) <= 5`
  是错的：控制器在**移动前**判，浮点残差让她早一帧返回（实测 `1351.0000000000005`），
  于是断言读到的是「还没翻向」的状态。**读「她接下来做了什么」（purpose 变了 / target 变了）。**
- **依赖定时器的测试是 timing-dependent 的。** 「等待会放弃」的测试第一版让真实 Timer 触发，
  reader 调用次数不确定（报 `reads → 3`，期望 2）。修法是把间隔与等待时长做成**可注入实例值**，
  测试里把间隔设成 3600（永不触发）并手动调 `pollForAppearance()`；
  **等待长度必须在创建等待之前设**（它在创建时固定）。
- **断言写死一个 bug 的值，等于把 bug 编码进测试。** 例如
  `box.bottom + 8`、`leftX * s - 122 * s` 这种自证式断言。写测试时问「这条断言在实现正确时会失败吗」。
- **测试缝隙的绕过**：`provider.setBodies(...)` **完全绕过** `sampleBodiesIfStale`，
  所以通过这个缝做的集成测试**钉不住采样器内部的改动**。采样器行为要在驱动真实
  `platform.windows()` 的测试里钉。
- **`MockPlatform.windows()` 按列表顺序赋 `zIndex`**（与 `MacOSPlatform` 一致）。
  默认全 0 时，任何读 z 序的 mock 测试都是哑的。
- **只改一处会让两个谓词打架时**，测试要同时覆盖 entry 与 ongoing 两条路径
  （否则会出现「能进但装不下」的坏状态）。

## 已验证「去掉实现就变红」是这里的惯例

每当修一个可观测缺陷，顺手确认：**把修复回退，测试确实变红**。文档里记的「已验证变红」
都是这么来的。没有这一步的测试只证明「现在通过」，不证明它钉住了什么。

## 测试资源

- 需要美术资源的测试在没有种子时抛 `TestSkip.missingAssets` —— 也就是**失败**（不是跳过）。
  先链接资源再跑，或直接用 `make test`。
- 直接 `swift test` 会报 `missingAssets`；`make test` 会链接资源并传 `NUONUO_ASSET_ROOT`。
- 硬链接必须同卷：临时目录与仓库不同设备时 `ln` 会报 Cross-device link，
  所以测试资源放在**仓库内**的构建目录，不用系统临时目录。

## 写测试时的调试手段

- `runTests` 只跑相关文件，`get_errors` 看编译/诊断。
- 新逻辑若没有可测缝（依赖真实 FSEvents / AX），先加一个 `debug*` 接缝再测；
  项目里已有一批（`debugBeginPatrol`、`debugPatrolTargetX`、`debugClearTerrainActionCooldown`、
  `debugSetLife`、`debugCurrentClip`、`debugQueuedMealCount`、`debugForcedEdgeLeg`、
  `debugAwaitingAppearances` 等）。
