# 内部笔记

这个目录记录**项目本身**的知识：设计理由、踩过的坑、被否决的方案、测量结论。

写入规则：

- 只记**从代码里看不出来**的东西：为什么这样做、试过什么行不通、哪些值是承重的。
- 不记**只与某台机器/某个人的环境**有关的内容（本机核数、个人偏好等），那些不属于仓库。
  但**项目级的决策理由**要记，即使它由某个人的环境引出（例如为什么用自签名证书）。
- 已经有测试钉住的行为，在这里只写「为什么」和「怎么发现的」，不抄测试实现。
- 一条记录若被新证据推翻，就地更正，不要保留两个矛盾的结论。

| 文件 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 世界模型、目录结构、依赖注入接缝、设置存储 |
| [physics.md](physics.md) | 窗口封闭盒、侧撞、腾空/落地、遮挡与支撑的有效性 |
| [behavior.md](behavior.md) | 自主行为、巡逻与边缘动作、生命状态、台词 |
| [meal-and-icons.md](meal-and-icons.md) | 删除检测（FSEvents/AX）、幽灵图标、吃图标动画 |
| [rendering.md](rendering.md) | 全屏 overlay、气泡/捏脸/幽灵的图层化、位置插值 |
| [performance.md](performance.md) | 实测 CPU、热点、测量方法与其陷阱 |
| [rejected-approaches.md](rejected-approaches.md) | 试过并否决的优化/方案，以及否决它的证据 |
| [testing.md](testing.md) | 测试约定、可播种 RNG、反复踩到的测试陷阱 |
| [build-and-assets.md](build-and-assets.md) | 资源获取、打包、构建细节 |
| [signing.md](signing.md) | 为什么用自维护的自签名证书，以及 ad-hoc / Developer ID 为什么不行 |
| [diagnostics.md](diagnostics.md) | 日志系统、诊断事件、从外面看不见的失败 |
| [platform-quirks.md](platform-quirks.md) | 本项目依赖的 macOS/AppKit 行为怪癖 |
