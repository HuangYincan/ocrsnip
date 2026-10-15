# ocrsnip

📷 **macOS 菜单栏截图工具** — 快捷键框选屏幕区域,自动识别文字或将截图置顶显示。

```bash
⌘⇧2  →  框选区域  →  自动 OCR  →  ⌘V 粘贴
⌘⇧3  →  框选区域  →  截图置顶  →  拖动；悬停后滚轮缩放
```

## 安装

1. 从 [Releases](https://github.com/HuangYincan/ocrsnip/releases) 下载 `ocrsnip.dmg`
2. 双击打开,将 `ocrsnip.app` 拖入 **Applications** 文件夹
3. 首次打开需授权: **系统设置 → 隐私与安全性 → 辅助功能 + 屏幕录制**（授权后请完全退出再打开；之后不应再反复弹窗）。菜单栏打开「开机自启」后，若系统要求确认，请在 **系统设置 → 通用 → 登录项** 中允许 ocrsnip。

GitHub 构建尚未使用 Apple Developer ID 签名和公证。从 v0.2.2 起，发布流程会对完整应用做 ad-hoc 签名，并在发布前校验 DMG 内的应用，校验失败会停止发布。首次打开仍可能被 Gatekeeper 阻止。确认来源是本项目后，先尝试打开一次，再到 **系统设置 → 隐私与安全性 → 仍要打开** 放行。

### 提示“已损坏，无法打开”

已确认 v0.2.1 的发布包遗漏了完整 `.app` 签名，导致签名校验失败。若已从本项目 Releases 下载并拖入 Applications，可在终端修复该应用的签名：

```bash
codesign --force --sign - --identifier com.acc.ocrsnip /Applications/ocrsnip.app
codesign --verify --deep --strict --verbose=2 /Applications/ocrsnip.app
```

校验通过后重新打开，并按上面的“仍要打开”步骤放行。若仍无法打开，且确认下载来源可信，可仅移除该应用的下载隔离标记后重试：

```bash
xattr -dr com.apple.quarantine /Applications/ocrsnip.app
open /Applications/ocrsnip.app
```

这不会关闭系统全局 Gatekeeper。重新签名后，辅助功能和屏幕录制权限可能需要重新授权。

### 能框选，但置顶图是黑块、OCR 没有结果

先检查屏幕录制权限。更新或重新签名后，旧权限记录可能仍绑定旧签名，即使系统设置中的开关看起来已开启，也无法读取屏幕内容。将「系统设置 → 隐私与安全性 → 屏幕与系统音频录制（或屏幕录制）」中的 ocrsnip 关闭再开启，然后完全退出并重新打开应用。若仍无效，移除旧条目，再用“+”添加 `/Applications/ocrsnip.app` 并开启权限。

截图和框选前会检查屏幕录制权限，未授权时停止本次捕获，并显示「请求授权」及「打开系统设置」按钮。只有点击「请求授权」才发起系统授权，期间不会显示框选遮罩；授权并重启后再次按快捷键即可截图。已授权时不重复请求。OCR 仅在识别到文字且成功写入剪贴板后播放完成声音；没有声音不一定是快捷键或音频故障。

本地开发请用 `zsh scripts/build.sh` 打包。脚本会用固定的 `ocrsnip Developer` 证书签名，辅助功能和屏幕录制授权会跟着证书走，而不是跟着每次编译变化的 ad-hoc CDHash。首次签名时钥匙串会询问是否允许 `codesign` 使用该证书；不要把这张开发证书当成信任锚。若旧脚本曾把证书的 ACL 开放给任意 `codesign`，请在钥匙串删除 “ocrsnip Developer” 后设 `OCRSNIP_RESET_DEV_CERT=1` 再构建。从 GitHub 下载的 ad-hoc 签名构建每换一个二进制仍可能再问一次。对外分发请用 Apple Developer ID 签名并公证。

## 使用

| 操作 | 效果 |
|------|------|
| 按 **⌘⇧2** | 鼠标变成十字准星,框选区域并 OCR，文字写入剪贴板 |
| 按 **⌘⇧3** | 框选区域,截图窗口置顶显示,可自由拖动 |
| 鼠标悬停置顶截图后滚轮 | 以指针位置为锚点缩放该截图 |
| 按 **Esc** 或 **双击** 置顶截图 | 关闭该截图 |
| 菜单栏 **📷** 图标 | 可手动触发、关闭全部置顶截图、开关开机自启或退出 |
| 菜单栏 **开机自启** | 登录 macOS 时自动打开 ocrsnip（勾选即开） |

OCR 识别期间菜单栏显示 ⏳；听到快门声表示文字已写入剪贴板并读回确认，此时可按 ⌘V 粘贴。写入失败会自动重试，最多 3 次。未识别到文字或失败时仅显示通知，不播放完成提示音。

> 注意：⌘⇧3 是 macOS 自带的全屏截图快捷键。程序会通过辅助功能事件监听拦截 ⌘⇧2 / ⌘⇧3；如果没有响应，请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 ocrsnip，并完全退出后重新打开。若不允许辅助功能，也可以关闭系统自带的 ⌘⇧3，此时会回退到 Carbon 热键。

| 层 | 技术 |
|---|---|
| 语言 | Swift 6 |
| OCR 引擎 | Apple Vision (VNRecognizeTextRequest) |
| 截图 | ScreenCaptureKit（macOS 15.2+）/ screencapture 回退 |
| 界面 | 菜单栏图标 (NSStatusItem) |
| 热键 | CGEventTap（全局 ⌘⇧2 / ⌘⇧3）+ Carbon 回退 |
| 大小 | ~125KB,零依赖 |

## 构建

```bash
zsh scripts/build.sh
open dist/ocrsnip.app
```

本地日常开发不要用 `codesign --sign -`（ad-hoc）。那种签名的 designated requirement 是当前文件的 CDHash，每编译一次系统都当成新应用，辅助功能和屏幕录制会重新询问。发布流程在未配置 Developer ID 时使用 ad-hoc 签名，保证应用包完整性；这不等于 Apple 公证。

```bash
swiftc ScreenCaptureStrategy.swift OCRClipboard.swift LaunchAtLogin.swift main.swift -o ocrsnip \
    -framework AppKit -framework Vision -framework Carbon \
    -framework ScreenCaptureKit -framework ApplicationServices \
    -framework ServiceManagement
```

上面这条只生成裸二进制，调试可以，日常请走 `scripts/build.sh`。

运行 OCR 回归测试：`zsh scripts/test-ocr.sh`。加 `--integration` 可测试真实 Vision 识别及独立的 macOS 测试剪贴板，不改动日常剪贴板。

## 许可

MIT
