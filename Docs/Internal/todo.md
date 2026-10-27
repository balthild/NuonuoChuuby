# 未完成的工作

本文件只记**还没做的**事。已完成功能的设计理由、测量数据与踩坑记录在其余
`Docs/Internal/` 文件里（索引见 [README.md](README.md)）；这里只留「做什么」和指向。

## 1. 角色与玩法

- **菲比啾比**。`PetCharacterProfile` 的间接层与角色专属分支（食物、捣蛋）已经就位，
  属增量工作，不是合并。
- **双宠共存 / 配对互动**。依赖菲比。
- **窗口捣蛋**（踢、藏帽、撕裂真实窗口）。整个功能尚未开工；所需辅助功能 + 屏幕录制
  两项权限均可接受，目前只是功能本身尚未开始。

## 2. 巡逻与边缘动作

背景与已修的部分见 [behavior.md](behavior.md)。

- `movementPurpose` 的 `edgeJumpApproach` / `edgeSlideApproach` **仍无生产者**：
  受控「从边缘跳 / 滑」的菜单项不存在（上游对应 `StartControlledEdge`）。
- 上游每个自主动作的独立冷却（Wander 9 / Explore 18 / Sleep 90 / AskForFood 65 /
  LickIcon 70 / Roll 42 / Hop 24 / Rest 5）没有移植，目前只有打断路径有冷却。
- `TryInterruptPatrolForNeed` 只打断 `.patrol`，上游还会打断 `.climbApproach`。

## 3. 地形

- **沿竖边行走 / 沿竖边栖位**。竖边已按四条边建进图，但只有 `windowTop` 与 `floor`
  被标为可站立。参数化锚定落地后才谈得上，留给下一轮。
- **桌面滑动时她被横切成两半**。下落中切换 Space，她会被从某个高度切断：只显示上半、
  下半是背景，切断位置每次不同；站立时切换不出现。已排除窗口矩形、图层几何、上方遮挡，
  并**证伪**「捕获到更新了一半的画面」——转场全程冻结精灵后截断仍在（只是动画也停了）。
  「转场时隐藏」与「用 `kCGSWorkspaceWillChange` 抢在动画前隐藏」两条路都已实测失败
  （前者影响不到合成；后者该事件在 app 内 0 次送达，`didChange` 比自己的采样还晚约 1 秒）。
  下一步要看**合成层面**：逐帧取屏内容，区分「与背景错位」和「图层被截」。
  全部证据与已排除项见 [physics.md](physics.md) 文末。

## 4. 推迟的方案

- **开机自启改用 `~/Library/LaunchAgents` plist**。`StartupRegistrationService` 现在走
  `osascript`（`SMAppService` 需要 Team ID）。原先「免去 System Events 授权弹窗」的
  理由**已撤回** —— 一次性提示不是设计理由。所以这条现在**没有明确收益**，
  除非 osascript 登录项本身出了实际问题才值得换。

## 5. 性能：还能降的项目（按收益排序，均未做）

1. **地形图重建与矩形采样合并成一次枚举**。两者需要的 rect 完全相同，只差可按需丢弃的
   遮挡计算；省掉 2 Hz 那次枚举，约 −0.1%（release）/ −0.35%（debug），行为不变。
2. **把 Swift 字典桥接换成 CoreFoundation 直读**（现在只剩 `MacOSPlatform.windows`；
   `liveBounds` 已改为私有读）。实测解析快 20 倍（164 → 69 µs/次，结果逐字段一致），
   约 −0.1%（release）/ −1%（debug）。只影响 debug 数字的可读性，不影响发布版。
3. **睡着时按 10 Hz 跑 `step`**。`sleep` 片段是 8 帧 × 0.185 s ≈ 5.4 fps，10 Hz 在视觉上
   完全一样；这是唯一能砍掉「每帧固定开销」（运行循环 + 框架 + 绘制推送）的办法。
   能降到多少未测（当前基线见 [performance.md](performance.md)）。
   与第 1 项不相交：容器内不会进入 `.sleeping`。
4. **Metal 渲染实验**。在干净树的独立分支做 A/B，先固定同一交互脚本与统计口径。
   目标是在不降低体感帧率的前提下，比当前 CALayer 再降低拖动 / 下落 CPU；
   必须优先做纹理复用（避免每帧图像上传 / 转换），否则可能比 CALayer 更差。

## 6. 未测 / 未验证

- **整表枚举能否也私有化未知**：`CGSGetOnScreenWindowList` + level/alpha + 连接→PID，
  还要 owner name 与 z 序 —— 比单窗口读大得多的赌注（上限约 1.3 + 0.5 pt）。
- **私有 `CGSGetWindowBounds` 的收益只测过盒内 idle**。站在窗口顶边（`liveSurface`，
  60 Hz）预计翻倍，未测；多显示器未测。等价性也只覆盖在屏窗口，
  见 [platform-quirks.md](platform-quirks.md)。
- **多显示器全未验证**（开发机单屏）：overlay 每屏一块、她画在含其中心的那块上；
  **跨屏时会被 overlay 的窗口边界裁切**（旧模型不会）；AX 桌面图标在负坐标
  （第二显示器在左侧）下的表现也未验证。
- **多屏混合 DPI 未验证**。全程用点规避了大部分换算，但没有真实混合 DPI 组合的实测。
- **原版 Windows 的交互成本未归因**：拖动后下落与窗口抛起两个场景成本相同，提示成本可能
  来自指针输入，但没有跑「只移动光标」对照。

## 7. 待查的线索

- **「落地成功，下一帧 perch 被判 covered」**。落地用
  `isVisible(atCoordinate:inset: 10)`（更严），perch 用 `isVisible(at:)`（inset 0，更松）；
  同一张图上不可能严过而松不过，所以两者之间图被重建过。不是那次改动引入的。
  已加 `PerchCovered` 诊断，至今未触发。详见 [physics.md](physics.md) 文末。

## 8. 发布

- **发布版尚未单独生成签名证书**，开发期复用 CalendarShouter 的
  （`OP_ITEM_REF="CalendarShouter Signing"`）。换证书会让 macOS 忘记已授予的自动化与
  文件夹授权，所以只换一次。见 [signing.md](signing.md)。
