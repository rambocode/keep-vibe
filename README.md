# KeepVibe

macOS 菜单栏工具，提供两大核心功能：

1. **保持唤醒**：通过 IOKit 电源断言防止 Mac 休眠，支持标准模式（阻止系统空闲休眠）和合盖模式（接通电源时合盖不休眠），可设置永久或定时（1/2/4 小时）。
2. **AI 用量统计**：扫描本地日志，统计 Claude Code（`~/.claude/projects/`）和 Codex（`~/.codex/sessions/`）的 token 用量与费用，按今日 / 本周 / 本月维度展示，并显示 Claude 的 5 小时滑动窗口进度。

## 构建

```bash
swift build -c release
```

## 运行

```bash
.build/release/KeepVibe
```

App 以菜单栏形式运行，不占用 Dock 位置（`NSApp.setActivationPolicy(.accessory)`）。

## 功能点

- 菜单栏图标点击展开弹窗（SwiftUI + NSPopover）
- 防睡模式切换：standard / clamshell
- 定时防睡：到期自动停止
- 系统状态面板：CPU 占用、内存使用、电池电量、系统运行时间
- Claude Code 用量：今日/本周/本月 token 及费用，5 小时窗口进度条
- Codex 用量：今日/本周/本月 token 及近似费用
- 开机自动启动（写入 `~/Library/LaunchAgents` plist）
- 平台要求：macOS 14+，Swift 6
