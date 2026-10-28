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

`make release` 打包**不带** seed（约 1.3 MB dmg）；应用首次启动下载 390 个固定文件。
带 seed 时是 39 MB。

### 分发用磁盘映像（dmg）

布局是常见的左右两栏：app 在左（x=150）、`Applications` 链接在右（x=450），
中间一个箭头画在窗口背景图上。`make package` 调 **nixpkgs 的 `create-dmg`**（1.2.1）生成。

- **不自写脚本。** 排布只能由 Finder 写（图标位置、图标大小、背景图都住在 `.DS_Store` 里，
  没有命令行工具能生成它），所以任何实现都是「建读写镜像 → 挂载 → AppleScript 摆窗口 →
  卸载 → `hdiutil convert`」。`create-dmg` 做的正是这一串，还多做了 `chmod go-w`、
  删 `.fseventsd`、失败时非零退出，而项目已经在 `make` 里用 nix 取 `svu` / `gettext`。
  曾自写过一个 100 行脚本，功能完全重合，已删除。
- **选项必须写在两个位置参数之前。** 它的解析是 `while [[ $1 == -* ]]`，
  遇到第一个非选项就停 —— 放在后面的 `--volname` 会被**静默当成位置参数忽略**，
  卷名退化成输出文件名（实测：`test.dmg` → 卷名 `test`）。所以 Makefile 里所有 flag 在前。
- **它不能覆盖已存在的镜像**（`hdiutil convert` 报「文件已经存在」），失败时还会把
  29 MB 的半成品 `rw.<pid>.<name>.dmg` 留在 `dist/`。`package` 因此先删两者。
- **排布需要终端的 Finder 自动化授权**（首次会弹一次）。被拒绝时它退出 64，
  不会产出一个图标堆在左上角的镜像。打包时 Finder 窗口一闪而过是正常的。
- **背景图是画出来的，不是提交进仓库的图片。** `Tools/dmg-background.swift` 按 Makefile
  里同一套坐标画 600×400 pt 的箭头，写成 2× 位图并标 144 dpi ——
  Finder 按点铺图，1× 图在 Retina 上会糊。改用 CoreGraphics 而非 AppKit 绘图：命令行工具
  没有屏幕，AppKit 会自行猜比例（实测 `NSGraphicsContext(bitmapImageRep:)` 直接返回 nil）。
- **dmg 自己不做签名。** 没有公证时签名改变不了 Gatekeeper 对里面 app 的判断
  （见 [signing.md](signing.md)）。但**里面的 app 必须已签名**：`sign` 失败时
  `package` 会中止，`codesign --verify` 对半成品包报
  「code has no resources but signature indicates they must be present」。
- 换产物格式的连带项在**仓库外**：`balthild/homebrew-tap` 的 `Casks/nuonuo-chuuby.rb`
  里 `url` 必须以 `.dmg` 结尾，否则 cask 找不到下载物。

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

`make help` · `manifest` · `icon` · `build` · `test` · `app` · `sign` · `dmg-background` ·
`package` · `rerun` · `reset-data` · `clean` · `release`（clean → 资源 → test → package）。

- `make run` / `open` 只用 LaunchServices：TCC 提示需要它。
- `reset-data` 会删除 `~/Library/Application Support/NuonuoChuuby`。

签名相关的一切（为什么自签名、身份为什么不能换、脚本里那些看不出来的步骤）
见 [signing.md](signing.md)。
