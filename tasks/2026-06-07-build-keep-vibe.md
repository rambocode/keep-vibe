# KeepVibe — macOS 防睡 + Agent 用量统计菜单栏应用

> 2026-06-07 · 按参考图完整实现 · 通过 workflow 编排构建

## 目标
一个 macOS 菜单栏（Menu Bar）App，防止电脑自动休眠，并统计 Claude Code / Codex 各 Agent 的用量与运行情况。完全按照参考图功能实现。

## 技术选型
- Swift 6.2 原生：SwiftPM 可执行目标 + AppKit `NSStatusItem` + `NSPopover`(承载 SwiftUI) + `.accessory` 激活策略（隐藏 Dock）
- 防睡：IOKit 电源断言（`IOPMAssertion`）
- 系统监控：sysctl / host_processor_info / host_statistics64 / IOKit.ps
- 用量：解析 `~/.claude/projects/**/*.jsonl` 与 `~/.codex/sessions/**/*.jsonl`

## 功能清单（对照参考图）
- [x] 保持唤醒 总开关
- [x] 模式：标准防睡 / 合盖也不睡（IOKit 电源断言）
- [x] 时长：永久 / 1小时 / 2小时 / 4小时（带倒计时）
- [x] 系统状态：开机时长 / CPU / 内存 / 电池
- [x] Claude Code：今日/本周/本月 token+成本、5h 窗口（tok/min、剩余时间、进度条）、活跃会话
- [x] Codex：今日/本周/本月 token+≈成本、活跃会话
- [x] 开机自启 开关（LaunchAgent）
- [x] 刷新 / 更新于 N 秒前 / 退出

## 文件结构
- `Package.swift` / `Sources/KeepVibe/`：Models, Pricing, KeepAwakeManager, SystemMonitor,
  ClaudeUsageParser, CodexUsageParser, LaunchAtLogin, MenuContentView, main(AppDelegate)

## 执行
- [x] 脚手架与契约（Package/Models/Pricing）
- [x] 并行实现 7 个模块文件
- [x] `swift build` 迭代修复至通过 + release 构建 + 冒烟运行
- [x] 人工验证 UI 与数据正确性（Python 对账）

## 结果
- workflow 编排：9 个 agent，166k tokens，约 3.3 分钟，构建 2 次迭代通过。
- 产物：`.build/release/KeepVibe`（576 KB 原生二进制），冒烟运行无崩溃。
- **构建期修复**：`vm_kernel_page_size`（Swift 6 并发不安全全局变量）→ `getpagesize()`。
- **自查发现并修复的数据 bug（关键）**：
  1. 时间分桶用了嵌套 `本月⊃本周⊃今日`，跨月时本周一落在上月会被漏计 → 改为三桶独立判断。
  2. 本周起点用 `Calendar` 的 locale `firstWeekday`（当前为周日），导致周日当天「本周==今日」→ 固定 `firstWeekday=2`（周一）并手动回退计算。
  - 两个解析器（Claude/Codex）均已修复，Python 对账：本周/本月 922.9M 与真值一致。
- 新增 `--dump` 命令行模式用于离线核对解析数字。

## 遗留
- 3 个 Swift 6 并发 lint 警告（Timer 闭包 actor 隔离 / Sendable 捕获 / CFArray 转型），不影响功能。
- UI 视觉需用户点击菜单栏图标肉眼确认（菜单栏弹窗不便自动截图）。
- 未做代码签名 / .app 打包；如需 Dock 外常驻与系统「登录项」管理可后续封装 .app + SMAppService。
