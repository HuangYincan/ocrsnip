# 应用内更新

ocrsnip 从 v0.3.0 起使用 Sparkle 2.10.0。默认每天检查一次，用户也可以手动检查或关闭自动检查。默认先提示用户，再下载、安装和重新打开应用；不需要卸载。安装过程由 Sparkle 的独立辅助程序完成，应用退出后替换原有 `.app`。

更新源为本仓库最新正式 GitHub Release 中的 `appcast.xml`。每个 Release 需同时包含 `ocrsnip.dmg`、`ocrsnip-<版本>.zip` 和 `appcast.xml`。预发布版本不会成为此稳定更新源。

## 首次发布前配置

更新签名密钥与 macOS 应用代码签名证书是两套独立身份：

- **Sparkle Ed25519 密钥**验证更新索引和 ZIP 是否来自维护者。应用中只保存公钥；私钥保存在钥匙串或 GitHub Actions secret 中。
- **应用代码签名证书**用于 macOS 身份、Gatekeeper 和权限记录。保持同一证书有助于沿用屏幕录制/辅助功能授权。本地和 CI 统一使用 `signing/ocrsnip.cer` 对应的固定自签名证书，缺失时停止构建。自签名不等于 Apple Developer ID 公证，首次安装仍需手动放行；旧版切换到该证书需重新授权一次。

此工作区已创建专用钥匙串账户 `com.acc.ocrsnip` 的 Sparkle 密钥，并把匹配的公钥写入 `Info.plist`。不要在每次构建或发布时重新生成密钥。私钥不在仓库中；在安全位置备份钥匙串密钥，丢失后现有客户端将无法验证后续更新。

固定应用证书的 SHA-1 指纹为 `D06C5EEEED999D097308418B55C1CA68F8040E84`。公开证书可以提交，私钥不能提交。不要删除证书后自动重建，也不要用同名新证书替代；名称相同不代表身份相同。

维护者明确批准后，运行以下命令将三项发布凭据保存为 **HuangYincan/ocrsnip** 仓库的加密 Actions secrets：

```zsh
zsh scripts/configure-release-secrets.sh
```

- `MACOS_SIGNING_P12`：仅导出与仓库公开证书匹配的 ocrsnip 证书及私钥，使用随机密码加密。
- `MACOS_SIGNING_PASSWORD`：该加密导出的密码。
- `SPARKLE_PRIVATE_KEY`：Sparkle 更新签名私钥。

脚本不会导出钥匙串中的其他应用身份，也不会输出密钥；临时私密文件使用 0600 权限并在结束时删除。CI 只导入到临时钥匙串，完成后删除，不需要更改证书信任设置。获准使用这些 secrets 的工作流可以签署 ocrsnip 发布，因此应保护仓库及工作流修改权限。

缺少任一 secret 时 CI 会在构建前明确失败。应用、框架和更新辅助程序必须全部匹配固定证书。ZIP 的 Ed25519 签名还会用应用嵌入的公钥独立验证。


## 发布新版本

1. 修改 `Info.plist` 的 `CFBundleShortVersionString`，并递增整数 `CFBundleVersion`。Sparkle 用后者比较版本。
2. 运行 OCR 回归测试和构建。提交变更后推送与显示版本相同的标签，例如 `v0.3.0`。
3. GitHub Actions 构建完整应用、生成并签名 ZIP 和 appcast、测试更新检查及篡改拒绝、打包和验证 DMG，最后一次性发布三个资源。

不要手工修改已签名的 `appcast.xml`。修改内容后必须重新生成签名。不要覆盖既有版本的 ZIP；发新版本并递增构建号。首次启用更新器仍需用户覆盖安装 v0.3.0，以后可在应用内完成更新。

若只有 CI 配置失败且尚未生成 Release，可修复主分支工作流后执行 `gh workflow run build-release.yml --ref main -f release_tag=v0.3.0`。它使用修正后的工作流检出原标签构建，不需要移动版本标签。临时签名钥匙串必须加入 CI 用户的搜索列表：`codesign --keychain` 本身不会将该钥匙串用于证书链查找。

本地构建和签名更新包（使用钥匙串中的密钥）：

```zsh
zsh scripts/build.sh
zsh scripts/test-signing.sh
zsh scripts/package-update.sh
zsh scripts/test-updates.sh
```

`SPARKLE_PRIVATE_KEY` 可用于 CI 的非交互签名，内容为 Sparkle 导出的密钥。脚本通过标准输入传递，不将它作为命令行参数或写入发布目录。`OCRSNIP_RELEASE_TAG` 若设置，必须与应用版本一致。

## 验证范围

- 构建时校验 Sparkle 下载的 SHA-256，发布前递归校验应用及嵌入框架的代码签名和固定证书指纹。`test-signing.sh` 验证不同二进制的身份一致，并拒绝临时签名和被重新签名的应用。
- 更新包与索引均使用 Ed25519 签名；启用 `SUVerifyUpdateBeforeExtraction` 和 `SURequireSignedFeed`，关闭签名失败超时后放行。
- `test-updates.sh` 默认生成一次性测试密钥和应用副本，不读取发布私钥。在独立测试应用中运行真实 Sparkle，使用仅监听回环地址的临时服务器。测试发现新版本、同版本/更高本地版本不更新、拒绝篡改的索引、处理 404，以及拒绝损坏的 ZIP。它不会更新日常安装的应用或更改其偏好设置。CI 传入应用及已签名更新目录时，还会用正式发布公钥验证同样的流程。
- 正式端到端验收仍需两份已发布版本：从旧版点击「检查更新…」，验证下载、退出、原位安装和重新打开。该步骤涉及真实 Release 与系统 UI，不由本地回归测试代替。

框架许可证随应用放在 `Contents/Resources/Sparkle-LICENSE.txt`。接口和配置依据 Sparkle 官方文档：<https://sparkle-project.org/documentation/>。
