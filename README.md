# 糯糯啾比（NuonuoChuuby）

《啾糯桌宠》（JiuNuoDesktopPet）的 macOS 重写版。原项目是 C#/WPF 的 Windows 桌宠；本项目用 Swift 重写，面向 macOS。

**当前阶段：只实现「糯糯」。「菲比啾比」的窗口捣蛋、双宠共存、配对互动留待后续版本。**

## 快速开始

```sh
git submodule update --init     # 取上游素材仓库
make assets                     # 把运行时素材复制进资源目录
make run                        # 构建、打包、签名并启动
```

`make help` 列出全部目标。

## 目录

| 路径                                  | 内容                                    |
| ------------------------------------- | --------------------------------------- |
| `Sources/NuonuoChuuby/`               | 可执行目标，只负责 `NSApplication` 引导 |
| `Sources/NuonuoChuubyCore/`           | 全部逻辑与界面                          |
| `Sources/NuonuoChuubyCore/Resources/` | 素材目录（内容不提交）与素材清单        |
| `Tests/`                              | swift-testing 测试                      |
| `App/Info.plist`                      | 打包时补上版本号                        |
| `Tools/`                              | 素材播种/清单、签名、证书脚本           |
| `Makefile`                            | 格式化、构建、测试、打包、签名          |
| `Vendor/JiuNuoDesktopPet/`            | 上游素材仓库（submodule）               |

代码按子系统分目录：`App` `Sprite` `Physics` `Life` `Voice` `Dialogue` `Cheek` `World` `Meal` `System` `Asset` `Settings`。

## 素材

角色形象与录音的**再分发授权尚未明确**（见上游 `ASSET_RIGHTS.md`）。因此本项目：

- 仓库里**不包含任何素材字节**，只提交 `asset-manifest.json`（一个路径清单）与 submodule 指针；
- 开发期用 `make assets` 从 submodule 复制；
- 发布版**首次启动时**按清单从上游下载到
  `~/Library/Application Support/NuonuoChuuby/assets/<commit>/`。
  清单固定了 commit，所以换了 pin 才会重新下载。

这样做感染性与原 Windows 版相同，但不会通过本仓库再分发素材。

## macOS 上的行为差异

原项目依赖 Win32，有些能力在 macOS 上没有等价物，这里如实说明取舍：

| 能力                           | Windows                                                              | macOS                                                                                                                                                                                                                                                                                                                        |
| ------------------------------ | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 窗口地形（站在窗口上）         | `EnumWindows` + Win32 style 位                                       | `CGWindowListCopyWindowInfo`，**无需任何权限**（bounds 不需要屏幕录制）；被别的窗口盖住的那段窗沿不可站立                                                                                                                                                                                                                    |
| 窗口最大化顶飞                 | 最大化时把桌宠顶飞（专门的反弹规则）                                 | **已移除**：没有专门的反弹判定。窗口最大化只是让窗沿快速上移，是否被甩出只取决于通用的「单 tick 位移超过阈值」释放规则                                                                                                                                                                                                       |
| 窗口容器（把桌宠放进窗口内部） | 拖进窗口内部松手即被关住，保留惯性、受重力，并相对移动的四壁碰撞弹跳 | 已实现（`WindowEnclosurePhysics`）。**入场更严格**：要求**整个身体**都在窗口内，原版只要求身体中心；容量不足时只有「窗口被改小」或「桌宠被调大」能让她出来                                                                                                                                                                   |
| 容器被更前置的窗口盖住         | 无处理：桌宠始终置顶，被盖住时看起来像悬空站在看不见的窗口里         | **她是被抱着的窗口的上一层，而 macOS 不允许把自己合成在两个普通窗口之间**（它们都在 CGWindowLevel 0）。取舍：被盖住超过 0.6 s 就不再算那个盒子 —— 盖住她的窗口若装得下她（与拖拽入场同一判据），她就**改由那个窗口抱着**；装不下才放下她（`EnclosureCovered`）。部分遮挡不做像素级遮罩 —— 那需要逐窗捕获，代价与滞后都不值得 |
| 窗口侧撞                       | 窗口左右边缘扫过身体时，按撞击方向和窗口速度施加抛飞冲量             | 已实现（`WindowSideCollisionPolicy`），阈值与原版一致。窗口矩形按 **10 Hz** 采样（原版 16.7 Hz）：这是边速的测量基准，不能沿用 2 Hz 地形图的节奏                                                                                                                                                                             |
| 删除文件进食                   | 回收站 `$I*` 元数据 + 桌面 ListView 跨进程读取                       | FSEvents 监听桌面/下载目录，与 `~/.Trash` 新增项按文件名比对；`rm` 删除的文件等一小段窗口后也接受                                                                                                                                                                                                                            |
| 桌面图标位置                   | 跨进程读取 ListView 真实坐标                                         | 通过**辅助功能**读取 Finder 桌面图标真实坐标（见 `DesktopIconIndex`）；未授予辅助功能时**降级**为 Finder 默认布局近似（见 `DesktopIconGrid`）                                                                                                                                                                                |
| 全局按键（Delete）             | `WH_KEYBOARD_LL` 钩子                                                | **不做**：FSEvents 已覆盖删除检测，按键钩子只是冗余的提前量；权限本身不是障碍                                                                                                                                                                                                                                                |
| 开机自启                       | 注册表 Run 键                                                        | `osascript` 登录项（自签名证书下 `SMAppService` 不可用），按路径匹配                                                                                                                                                                                                                                                         |
| 菲比窗口捣蛋                   | 移动真实窗口                                                         | **未实现**（整个功能尚未开工）；需要辅助功能 + 屏幕录制，两项权限均可接受                                                                                                                                                                                                                                                    |

首次使用删除文件进食时，macOS 会弹出**桌面/下载目录访问权限**请求 —— 这是系统 TCC 授权，不是证书问题。

应用还会请求**辅助功能**权限，用于读取桌面图标的真实位置（见上表）。这是**软依赖**：
拒绝或不授权时会自动降级为布局近似，其余功能不受影响。

## 构建与签名

`.app` 由 Makefile 手工拼装，不使用 Xcode 工程，也不需要 Xcode 工具链。

签名用自维护证书（`Tools/create-signing-cert.sh` 生成，存在 1Password 里），
**关闭 hardened runtime**：自签名证书没有 team 可以 pin，`--timestamp` 又需要 Apple 的 TSA。

```sh
make sign SIGN_IDENTITY=auto SIGNING_SOURCE=op OP_ITEM_REF="CalendarShouter Signing"
```

开发期先复用 CalendarShouter 的证书；之后可为本项目单独生成一个
（`make signing-cert`，然后把 `OP_ITEM_REF` 指向新条目）。**换证书会让 macOS 忘记已授予的
自动化与文件夹授权**，所以换一次就好。

`make package` 产出 `.build/dist/NuonuoChuuby-<版本>.zip`。

要分发给别人，receiving 方需要解除隔离：

```sh
xattr -dr com.apple.quarantine /Applications/NuonuoChuuby.app
```

自签名证书**无法通过 Gatekeeper**（`spctl` 会拒绝，和 ad-hoc 一样），免费方案就是这一步。

## 命令

| 目标                  | 说明                               |
| --------------------- | ---------------------------------- |
| `make assets`         | 从 submodule 播种素材              |
| `make manifest`       | 重新生成素材清单（换 pin 时）      |
| `make build` / `test` | 构建 / 跑测试                      |
| `make app`            | 拼装 `.app`                        |
| `make sign`           | 签名（见上）                       |
| `make run` / `rerun`  | 构建、签名并启动；`rerun` 可带参数 |
| `make package`        | 产出分发包                         |
| `make reset-data`     | 清空设置与存档                     |
| `make clean`          | 清理构建产物与素材副本             |

调试用的启动参数：`--demo-pinch` 会自动演示一次捏脸。

用 `make run`（或 `open`）来启动：只有经 LaunchServices 启动，macOS 才会正常呈现授权请求。

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
- 尚未生成 App 图标（`Info.plist` 已引用 `AppIcon`）。
