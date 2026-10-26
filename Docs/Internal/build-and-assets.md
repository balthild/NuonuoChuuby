# 构建与资源

## 资源：jsdelivr + 编译进二进制的 manifest + submodule 硬链接

- **下载源是 jsdelivr。** `AssetManifest.cdnURL(for:)` 由
  `cdnBaseURL = https://cdn.jsdelivr.net/gh/<owner/repo>@<commit>` 拼出；
  `repositorySlug(from:)` 从 `upstream` 解析（去掉 `.git`）。
  **中文路径**（`音效/…`）需要百分号编码 —— 已在真实 CDN 上按固定 commit 验证过 200。
- **manifest 是生成的 Swift 源码、编译进二进制**（`Asset/AssetManifest.swift`，git-ignored，
  由 `make manifest` 生成，`build`/`test` 依赖它）。生成器枚举 **submodule**
  （经 `Tools/asset-files.sh`），**只在内容变化时才重写文件**（`cmp -s`，mtime 稳定 ——
  否则整个模块每次构建都重编译）。生成后 `chmod 644`（`mktemp` 留下 600）。
- **没有 seed 目录，没有 `make assets`，没有 `strip-assets`。**
  `Tools/seed-assets.sh` → `asset-files.sh`（打印 `dest<TAB>source`）+
  `link-assets.sh`（从 submodule 硬链接）。

### `.app` 里资源的路径（踩过）

- 布局是 `Contents/Resources/Assets.bundle/Assets`，通过 **`Bundle.main.resourceURL`** 读取
  （`Asset/BundledAssets.rootURL`）。已验证 390 个文件、与 submodule 同 inode。
- `DEV_ASSETS ?=` 门控：未设（默认，`app`/`package`）= 不带美术资源（release 首次启动下载）；
  `run`/`rerun` 设 `DEV_ASSETS := 1`（目标专用变量，已验证能传到 `app` 前置目标）。
- **`Bundle.main.bundleURL` 是 `.app` 的根目录**；
  **`Bundle.module` 解析到 `Bundle.main.bundleURL/<name>.bundle`，不是 `Contents/Resources`。**
  旧 Makefile 把 SwiftPM 的 bundle 拷进 `Contents/Resources`，而 `Bundle.module` 从不去那里看 ——
  应用其实一直跑在访问器编译进去的绝对路径 `.build/index-build/...` 兜底上。
  **不要「恢复」那份拷贝。** SwiftPM 的资源声明已删除，`.build/**/*.bundle` 从不生成
  （已验证），也省掉了一次 38 MB 的资源重拷。
- **硬链接必须同卷**：临时目录与仓库不同设备时 `ln` 报 Cross-device link。
  测试资源因此放在 `$(BUILD_DIR)/test-assets`（仓库内），不用系统临时目录。
- **已知回归（已接受）**：`AssetManifest.swift` 是 git-ignored，所以**新克隆的仓库
  直接 `swift build` / IDE 编译会失败**，直到任意 `make` 目标重新生成它；`make clean` 也会删掉它。

### 打包体积

`make release` 打包**不带** seed（约 1.3 MB zip）；应用首次启动下载 390 个固定文件。
带 seed 时是 39 MB。

## Makefile：`run`/`rerun` 曾打包过期二进制

`BIN_DIR := $(BUILD_DIR)/$(CONFIG)` 用的是**立即展开**（`:=`），所以在解析时就冻结成
`.build/debug`。给 `rerun` 加 `CONFIG = release` 后，`build` 用 release 编译
（它的配方看得到 CONFIG），而 `app` 继续拷 `.build/debug/NuonuoChuuby` ——
一个改动之前就有的二进制，从此再也不会被重建。
**每一次 `make rerun` 启动的都是那个过期 debug 二进制。**
修法：`BIN_DIR = $(BUILD_DIR)/$(CONFIG)`（递归展开）。

**怎么发现它**：

- `dwarfdump --uuid .build/app/...../NuonuoChuuby` 与 `.build/release/...` 对比；
  跨多次重建 UUID 从不改变 ⇒ 包里的二进制是旧的。
- `make -n rerun | grep 'cp .*NuonuoChuuby'` 显示实际拷贝哪个路径。

**它造成过一整轮错误结论**：加进源码的启动参数开关**完全没有效果**，
于是「开关没差别」被读成「那个属性没用」。
**加任何启动开关后，先确认运行中的二进制确实包含它**（`strings <bundle> | grep <flag>`）。

## 格式化

- dprint 用 `Sources/**/*.swift` 的**白名单**，所以生成的 `AssetManifest.swift`
  要显式加进 `excludes`（它的行超过 100 列；布局由生成器负责）。
- **markdown 不在 dprint 范围内。** README / docs 的表格重排**不是 dprint 干的**，
  是外部 markdown 格式化器（编辑器）。`dprint fmt` 不会碰 markdown ——
  别再把 markdown 的格式变化归因于 dprint。

## 常用目标

`make help` · `manifest` · `icon` · `build` · `test` · `app` · `sign` · `package` ·
`run`/`rerun` · `reset-data` · `clean` · `release`（clean → 资源 → test → package）。

- `make run` / `open` 只用 LaunchServices：TCC 提示需要它。
- `reset-data` 会删除 `~/Library/Application Support/NuonuoChuuby`。

签名相关的一切（为什么自签名、身份为什么不能换、脚本里那些看不出来的步骤）
见 [signing.md](signing.md)。
