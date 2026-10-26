# 签名：为什么自维护一个自签名证书

## 前提

个人应用、自写自用、不经商店分发。**没有 Apple 开发者账号，也不打算为此付费。**
一次性 TCC 授权提示完全可以接受 —— 「减少授权提示」从来不是本项目的设计目标
（见 `README.md` 的构建与签名一节）。

## 结论

用**自签名证书**签名（`Tools/create-signing-cert.sh` 生成，私钥存在 1Password），
`make` 的默认身份是 `SIGN_IDENTITY=auto`。既不用 ad-hoc，也不用 Developer ID。

## 为什么不用 ad-hoc

ad-hoc 签名的 designated requirement 是 **cdhash**，而 cdhash 每次重建都会变。
后果是每次 `make rerun` 之后：

- Accessibility / Automation 授权**失效**；
- 系统设置里的开关仍显示为开，但它绑在**上一个签名**上，**无法重新授予** ——
  应用静默失去 AX，看起来像「AX 坏了」。

这是本项目最容易浪费一整天的坑：`make run SIGN_IDENTITY=-` 会静默降级到布局近似
（桌面图标位置退化成网格估计），而且没有任何提示。

## 为什么不用 Developer ID

- 需要付费账号；本项目不分发、不上架。
- **免费方案都过不了 Gatekeeper**：`spctl -a -vvv -t exec` 对自签名与 ad-hoc
  一视同仁地拒绝。唯一让别的机器第一次能打开的办法是
  `xattr -dr com.apple.quarantine <app>`。
- Developer ID + 公证买的是**分发体验**（别人双击就能开），对一个自用应用没有价值。

## 自签名带来的关键性质（整个方案唯一的实质理由）

codesign 给自签名产物生成的 designated requirement 是
**`identifier "<bundle id>" and certificate root = H"<证书 SHA-1>"`**，**不是 cdhash**。
所以只要**证书不变、bundle id 不变**：

- 重新构建、重新签名之后，已授予的 TCC 授权**继续有效**；
- 不需要每次重建都重新授权。

由此得到两条纪律：

1. **不要随便替换证书。** 换一次就等于让所有已授予的授权失效一次。
   （目前默认 `OP_ITEM_REF` 指向另一个项目的证书 `CalendarShouter Signing`，
   是为了共用同一个稳定身份；将来为本项目单独建证书时，**只换这一次**。）
2. **证书有效期签 100 年**：让用户重新授权的是**替换证书**，不是到期。

## 实现细节：为什么是脚本而不是 Makefile 内联

`Tools/sign-app.sh` 从 1Password 取 `.p12`，导入一个**临时 keychain**，签完删除。
这些步骤都是必需的，不是风格：

- `codesign` **找不到**不在搜索列表里的 keychain 中的身份 ——
  只给 `--keychain` 参数不够（已验证），必须把临时 keychain 加进
  `security list-keychains`。
- `security list-keychains -d user -s` 会**替换整个搜索列表**，所以必须先保存，
  并在 `EXIT HUP INT TERM` 的 trap 里恢复，同时删除临时 keychain ——
  否则一次失败的签名会永久改坏用户的搜索列表。
- `security import` 之后还要 `set-key-partition-list -S apple-tool:,apple:,codesign:`，
  否则 codesign 不被允许使用刚导入的私钥。
- 自签名证书**不受信任**，所以 `security find-identity -v` **不会**列出它；
  指纹要直接用 `security find-certificate -a -Z` 读。
- 先签包内嵌套的 Mach-O，再签 bundle；**不要用 `--deep`**。

## 关掉的选项，以及为什么

- **hardened runtime 关闭**：它约束的是「被公证、有 team 的签名」；自签名没有 team 可钉。
  开启既不会让应用更可分发，也不会带来运行期保护。
- **不用 `--timestamp`**：需要 Apple 的 TSA，自签名没有必要（离线时还会失败）。
- **没有 entitlements 文件**：不开硬化运行时就不需要。
  注意手动重新签名时**不带 `--entitlements` 会丢掉已有的**；
  `get-task-allow` 由 Xcode 注入，codesign 自己不会加。

## 代价（已接受）

- **`SMAppService.mainApp` 登录项不可用**（需要 Team ID）→ 用 `osascript`
  System Events 兜底。登录项必须**按路径**匹配：它的名字是应用的本地化显示名，
  删除后会重编号，所以要倒序遍历索引。
- **嵌入的 XPC service 不会向 launchd 注册**。
- 若日后要存 keychain 条目，分区会是 `cdhash:…`，每次重建都会提示；
  只有真 Team ID 能结束这件事（目前不使用 keychain）。
- 从 zip 解压的副本首次启动需要一次 `xattr -dr com.apple.quarantine`。

## 启动方式也受它影响

**只有经 LaunchServices 启动（`open` / `make run` / `make rerun`），macOS 才会正常呈现
授权请求。** 直接 exec `Contents/MacOS/NuonuoChuuby` 不会弹 TCC 提示，
即使在调试器里也一样。
