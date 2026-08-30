# Mini Dock Toggle

一款轻量级 macOS 菜单栏工具，为 Dock 应用增加“单击呼出／再次单击最小化”功能。

## 功能

- 单击 Dock 中的应用图标：呼出并置前窗口。
- 应用已经在前台时再次单击：最小化窗口。
- 支持微信、浏览器、访达等允许辅助功能控制的应用。
- 菜单栏“设置…”可选择“全部窗口”或“当前窗口”模式。

## 安装与运行

当前仓库提供源码，适合个人使用和测试。构建需要 macOS 13 或更高版本，以及 Xcode Command Line Tools。

```zsh
./src/toggle-dock-demo/scripts/build-app.sh
open "outputs/UniversalDockToggle-v1.6.app"
```

首次运行后，打开“系统设置 → 隐私与安全性 → 辅助功能”，添加并启用 `UniversalDockToggle-v1.6.app`，然后重新启动应用。

## 注意事项

- 通过 macOS 辅助功能 API 控制窗口，不修改目标应用代码。
- 重建或更换签名后，可能需要重新授予辅助功能权限。
- 当前为本地 ad-hoc 签名版本，仅适合个人测试；对外分发需要 Developer ID 签名和 Apple 公证。
- 个别应用或特殊窗口可能不提供可操作的辅助功能接口。

## 目录

- `src/toggle-dock-demo/Sources/ToggleDockDemo/main.swift`：主程序
- `src/toggle-dock-demo/scripts/build-app.sh`：构建脚本
- `docs/ToggleDockDemo说明.md`：详细说明

本项目目前用于个人学习和测试，尚未附带开源许可证。

