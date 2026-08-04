# ocrsnip

📷 **macOS 菜单栏截图 OCR 工具** — 快捷键框选屏幕区域,自动识别文字并写入剪贴板。

```bash
⌘⇧2  →  框选区域  →  自动 OCR  →  ⌘V 粘贴
```

## 安装

1. 从 [Releases](https://github.com/acccccan/ocrsnip/releases) 下载 `ocrsnip.dmg`
2. 双击打开,将 `ocrsnip.app` 拖入 **Applications** 文件夹
3. 首次打开需授权: **系统设置 → 隐私与安全性 → 辅助功能 + 屏幕录制**

## 使用

| 操作 | 效果 |
|------|------|
| 按 **⌘⇧2** | 鼠标变成十字准星,框选区域 |
| 松开鼠标 | 自动识别,文字写入剪贴板 |
| 右上角通知 | 显示识别结果预览 |
| 菜单栏 **📷** 图标 | 可手动触发或退出 |

## 技术栈

| 层 | 技术 |
|---|---|
| 语言 | Swift 6 |
| OCR 引擎 | Apple Vision (VNRecognizeTextRequest) |
| 截图 | screencapture (macOS 内置) |
| 界面 | 菜单栏图标 (NSStatusItem) |
| 热键 | Carbon Event Manager (全局 ⌘⇧2) |
| 大小 | ~125KB,零依赖 |

## 构建

```bash
swiftc main.swift -o ocrsnip -framework AppKit -framework Vision -framework Carbon
```

## 许可

MIT