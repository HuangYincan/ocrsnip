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

本地开发请用 `zsh scripts/build.sh` 打包。脚本会用固定的 `ocrsnip Developer` 证书签名，辅助功能和屏幕录制授权会跟着证书走，而不是跟着每次编译变化的 ad-hoc CDHash。首次签名时钥匙串会询问是否允许 `codesign` 使用该证书；不要把这张开发证书当成信任锚。若旧脚本曾把证书的 ACL 开放给任意 `codesign`，请在钥匙串删除 “ocrsnip Developer” 后设 `OCRSNIP_RESET_DEV_CERT=1` 再构建。从 GitHub 下载的未签名构建每换一个二进制仍可能再问一次。对外分发请用 Apple Developer ID 签名并公证。

## 使用

| 操作 | 效果 |
|------|------|
| 按 **⌘⇧2** | 鼠标变成十字准星,框选区域并 OCR，文字写入剪贴板 |
| 按 **⌘⇧3** | 框选区域,截图窗口置顶显示,可自由拖动 |
| 鼠标悬停置顶截图后滚轮 | 以指针位置为锚点缩放该截图 |
| 按 **Esc** 或 **双击** 置顶截图 | 关闭该截图 |
| 菜单栏 **📷** 图标 | 可手动触发、关闭全部置顶截图、开关开机自启或退出 |
| 菜单栏 **开机自启** | 登录 macOS 时自动打开 ocrsnip（勾选即开） |

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

不要用 `codesign --sign -`（ad-hoc）。那种签名的 designated requirement 是当前文件的 CDHash，每编译一次系统都当成新应用，辅助功能和屏幕录制会重新询问。

```bash
swiftc ScreenCaptureStrategy.swift OCRClipboard.swift LaunchAtLogin.swift main.swift -o ocrsnip \
    -framework AppKit -framework Vision -framework Carbon \
    -framework ScreenCaptureKit -framework ApplicationServices \
    -framework ServiceManagement
```

上面这条只生成裸二进制，调试可以，日常请走 `scripts/build.sh`。

## 许可

MIT