# 糯糯啾比（NuonuoChuuby）

《啾糯桌宠》（JiuNuoDesktopPet）的 macOS 移植版。原项目是 C#/WPF 的 Windows 桌宠；本项目用 Swift 编写，面向 macOS。

**当前阶段：只实现「糯糯」。「菲比啾比」的窗口捣蛋、双宠共存、配对互动留待后续版本。**

## 安装

首次安装：

```sh
brew tap balthild/tap
brew trust balthild/tap
brew install --cask nuonuo-chuuby
```

更新：

```sh
brew upgrade --cask nuonuo-chuuby
```

## 开发

```sh
git submodule update --init     # 取上游素材仓库
make rerun                      # 构建、打包、签名并启动
```

`make help` 列出全部目标。

## 目录

| 路径 | 内容 |
| - | - |
| `Sources/NuonuoChuuby/` | 可执行目标，只负责 `NSApplication` 引导 |
| `Sources/NuonuoChuubyCore/` | 全部逻辑与界面 |
| `Sources/NuonuoChuubyCore/Asset/AssetManifest.swift` | 生成的素材清单（不提交，每次构建重生成） |
| `Tests/` | swift-testing 测试 |
| `App/Info.plist.template` | 拼装时由 `envsubst` 补上 bundle id 与版本号 |
| `Tools/` | 素材清单生成/链接、签名、证书脚本 |
| `Makefile` | 格式化、构建、测试、打包、签名 |
| `Vendor/JiuNuoDesktopPet/` | 上游素材仓库（submodule） |

代码按子系统分目录：`App` `Sprite` `Physics` `Life` `Voice` `Dialogue` `Cheek` `World` `Meal` `System` `Asset` `Settings`。

## 素材

角色形象与录音的**再分发授权尚未明确**（见上游 `ASSET_RIGHTS.md`）。因此本项目：

- 仓库里**不包含任何素材字节**：清单（路径 + 固定 commit）在构建时从 submodule 生成并编译进二进制，仓库只提交 submodule 指针；
- 开发期由 `make app` 从 submodule 直接硬链（hard link）进 `.app`，不复制；
- 发布版**首次启动时**按清单从上游（jsdelivr）下载到
  `~/Library/Application Support/NuonuoChuuby/assets/<commit>/`。
  清单固定了 commit，所以换了 pin 才会重新下载。

这样做感染性与原 Windows 版相同，但不会通过本仓库再分发素材。

## macOS 上的行为差异

原项目依赖 Win32，有些能力在 macOS 上没有等价物。这里列出大致差异，详细见[内部文档](Docs/Internal/)。

| 能力 | Windows | macOS |
| - | - | - |
| 窗口地形（站在窗口上） | `EnumWindows` + Win32 style 位 | 读窗口矩形来建地形，**不需要任何权限**。被别的窗口盖住的那一段窗沿不能站 |
| 自主走动 | 醒着时几乎不停，每一段路都走到当前表面的某一端 | **有意偏离**：每段路 60% 走到尽头（尽头决定跳／下滑／跳下），40% 走到附近一个随机点并停下 —— 所以只有后一种趟次结束时她会停几秒（约 1–5 s）再决定下一步 |
| 窗口最大化顶飞 | 最大化时把桌宠顶飞 | **已移除**：没有专门的反弹规则，是否被甩出只取决于通用的「单帧位移超过阈值」释放规则 |
| 全屏应用 | 无处理，桌宠浮在全屏应用之上 | **挂起并隐藏她**（连同气泡与幽灵图标），退出全屏即恢复。绿钮「最大化」停在菜单栏下方，**不触发** |
| 窗口容器（把桌宠拖进窗口内部） | 拖进去松手即被关住，保留惯性、受重力、撞四壁弹跳 | 已实现。判据比原版严：要求**整个身体**都在窗口内；松手时脚下到窗口底部之间若有可站的窗沿，先落到那里，而不是被吞进大窗口。中小幅拖动时四壁（含地板）**托着她走**，只有很急的甩动才会把她抛起／落下／从侧壁抡飞。容量不足时只有「窗口被改小」或「桌宠被调大」能让她出来 |
| 容器被更前置的窗口盖住 | 无处理，看起来像悬空站在看不见的窗口里 | macOS 不允许把自己合成在两个普通窗口之间。被盖住超过 0.6 s 后，装得下她的前置窗口**改为抱着她**；装不下才放她落下。部分遮挡不做像素级遮罩 |
| 窗口侧撞 | 窗口左右边缘扫过身体时，按撞击方向和窗口速度施加抛飞冲量 | 已实现，阈值与原版一致 |
| 删除文件进食 | 回收站 `$I*` 元数据 + 桌面 ListView 跨进程读取 | 监听桌面与下载目录，按文件名判定「消失」并等一个短暂的沉降窗。**不做回收站比对**（`rm` 不进回收站，「回收站里没有」证明不了任何事）；**改名不算删除** |
| 桌面图标位置 | 跨进程读取 ListView 真实坐标 | 用**辅助功能**读 Finder 桌面图标的真实坐标；未授权时降级为 Finder 默认布局近似 |
| 全局按键（Delete） | `WH_KEYBOARD_LL` 钩子 | **不做**：删除检测已由文件事件覆盖，按键钩子只是冗余的提前量；权限本身不是障碍 |
| 开机自启 | 注册表 Run 键 | `osascript` 登录项（自签名证书下 `SMAppService` 不可用），按路径匹配 |
| 菲比窗口捣蛋 | 移动真实窗口 | **未实现**（整个功能尚未开工）；需要辅助功能 + 屏幕录制，两项权限均可接受 |

首次使用删除文件进食时，macOS 会弹出**桌面/下载目录访问权限**请求 —— 这是系统 TCC 授权，不是证书问题。

应用还会请求**辅助功能**权限，用于读取桌面图标的真实位置（见上表）。这是**软依赖**：
拒绝或不授权时会自动降级为布局近似，其余功能不受影响。

上表中各项的判定细节、阈值与实测理由：

- 走动、边缘动作、饥饿与台词 → [behavior.md](Docs/Internal/behavior.md)
- 窗口地形、容器、侧撞、腾空与落地 → [physics.md](Docs/Internal/physics.md)
- 全屏挂起、overlay 与图层 → [rendering.md](Docs/Internal/rendering.md)
- 删除检测、桌面图标坐标 → [meal-and-icons.md](Docs/Internal/meal-and-icons.md)
- 开机自启所依赖的签名与权限 → [signing.md](Docs/Internal/signing.md)

## 构建与签名

`.app` 由 Makefile 手工拼装，不使用 Xcode 工程，也不需要 Xcode 工具链。

签名用自维护证书（`Tools/create-signing-cert.sh` 生成，存在 1Password 的
`NuonuoChuuby-Signing` 条目里），**关闭 hardened runtime**：自签名证书没有 team 可以 pin，
`--timestamp` 又需要 Apple 的 TSA。

```sh
make sign
```

条目名已经是 `OP_ITEM_REF` 的默认值，不需要额外传参。**换证书会让 macOS 忘记已授予的
自动化与文件夹授权**，所以不要轻易更换；确实要换时用 `make signing-cert` 重新生成。

`make package` 产出 `.build/dist/NuonuoChuuby-<版本>.dmg`：左边是应用，右边是 `Applications` 链接，
中间一个箭头。

要分发给别人，接收方需要解除隔离（Homebrew Tap 中的 Cask 安装脚本会自动完成这一步）：

```sh
xattr -dr com.apple.quarantine /Applications/NuonuoChuuby.app
```

自签名证书**无法通过 Gatekeeper**（`spctl` 会拒绝，和 ad-hoc 一样），免费方案就是这样。

为什么不用 ad-hoc、也不用 Developer ID，以及证书身份为什么不能随便换：
见 [Docs/Internal/signing.md](Docs/Internal/signing.md)。

## 命令

| 目标 | 说明 |
| - | - |
| `make manifest` | 从 submodule 重新生成编译进二进制的素材清单 |
| `make build` / `test` | 构建 / 跑测试 |
| `make app` | 拼装 `.app` |
| `make sign` | 签名（见上） |
| `make rerun` | 构建、签名并启动（可带参数）。产物是 `NuonuoChuuby-Dev.app`，bundle id 是 `com.balthild.NuonuoChuuby-Dev`，与正式安装的那份互不干扰 |
| `make package` | 产出分发包（磁盘映像） |
| `make reset-data` | 清空设置与存档 |
| `make clean` | 清理构建产物与生成的素材清单 |

调试用的启动参数：`--demo-pinch` 会自动演示一次捏脸；`--demo-lick` 会在启动后半秒自动去舔一个桌面图标（用来验证走过去、舔完之后的坠落，不必等她自己饿）。

用 `make rerun`（或 `open`）来启动：只有经 LaunchServices 启动，macOS 才会正常呈现授权请求。

## 数据位置

```
~/Library/Application Support/NuonuoChuuby/
├── settings.json          用户设置
├── life-state.json        生活状态存档
├── assets/<commit>/       首次启动下载的素材
└── activity.log           本机日志（8 MB 轮转）
```

## 已知限制与后续

- 只实现了糯糯；菲比啾比、双宠共存、配对互动未实现。
- 桌面图标位置优先读真实坐标（需辅助功能授权）；未授权时降级为近似值。
- 窗口捣蛋（踢、藏帽、撕裂窗口）未实现；所需辅助功能与屏幕录制两项权限均可接受，目前只是功能本身尚未开工。

更完整的内部待办、未测与未验证项见 [Docs/Internal/todo.md](Docs/Internal/todo.md)。

## 对项目的许可协议的补充说明

本节的正式文本见 [`NOTICE`](NOTICE)（英文）。以下是为了便于阅读而提供的中文版：它是在 `LICENSE` 所授予的许可之外额外授予的一项许可，`LICENSE` 全文保持不变；两者若有冲突，以对使用者更宽松的解释为准。

原项目的代码基于 PolyForm Noncommercial 1.0.0 许可协议分发。这不是一个自由软件许可协议，它不允许把作品以及其衍生作品用于商业用途。由于移植的过程大量参考了原项目的代码，较难把直接衍生自原项目的部分与独立实现的部分精确地分离开来，因此我把该项目的代码也置于 PolyForm Noncommercial 1.0.0 许可协议下。

然而，我还要在此给予一项额外的许可：对于由我在本项目中独立完成、我对其享有完全的著作权的代码，即使你出于商业目的以任何方式（运行、复制、修改、分发等）使用，我也决不会对你采取任何著作权上的法律行动。由于我没有预先提供明确的界限来区分本项目的自由部分和采用 PolyForm Noncommercial 1.0.0 许可协议的部分，你自己有义务去保证你所使用的那部分代码不衍生自原项目中的代码或其衍生代码，而是只衍生自在本项目独立完成的代码。否则，我无法决定原项目作者是否会对你采取任何行动，我也无权替他们向你授予任何权利。我以自己的良心（这个词在某些司法管辖区可能不会被承认是一个具有法律效力的正式声明，但在法律所允许的范围内，它应当被以最大程度地对用户宽容的方式去理解）起誓，在我所能控制之处，我会以著作权上最宽容的态度——就像我对待我的其他所有自由软件作品的用户那样——对待获取这个项目的代码副本的一切人。

这份说明不适用于任何非代码的素材，包括但不仅限于角色形象、图像、音频、视频等。这些素材的权利应当归相应的第三方所有。
