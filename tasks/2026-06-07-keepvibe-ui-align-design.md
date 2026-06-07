# KeepVibe 菜单栏 UI 对齐设计稿（2026-06-07）

仅改 `Sources/KeepVibe/MenuContentView.swift`，不动数据/业务逻辑。

## 任务项

- [x] 1. `KeepAwakeCard`：移除 `if state.keepAwake` 包裹，pills 始终显示；去掉"模式/时长"标签；去掉关闭态降透明；咖啡杯图标改深色
- [x] 2. `ProgressRow` 改单行内联条（CPU/内存 标签+条+数值同行）；内存条改绿色
- [x] 3. 底栏移出卡片：开机自启居中 + 上下分隔线 + 刷新/退出，置于窗口背景
- [x] 4. 背景配色：硬编码暖米白窗口色 + 略浅卡片色；加 `.preferredColorScheme(.light)`
- [x] 5. Claude/Codex：今日单行；本周/本月 token+金额同行
- [x] 6. 面板宽度 320 → 340

## 验证

- [x] `swift build -c release` 编译干净（2.11s，无新增错误）
- [x] `.build/release/KeepVibe --dump` 数据正常（系统状态/Claude/Codex 均有输出）
- [x] 实机展开面板对照设计稿（用户截图确认：字体清晰、配色层次、单行布局、popover 不溢出，均符合）

## 追加修复（迭代）

- 背景设反 → 交换 window/card 取值（窗口更浅、卡片略深）。
- 默认未显示全部 → 先移除 ScrollView；再因内容高于屏幕溢出，改为「自测量内容高度 + 限高 min(内容, 屏幕可视高-24)」：放得下全显示、放不下才滚动。
- 字体发虚 → `main.swift` 给 NSPopover 设 `appearance = .aqua`，移除 SwiftUI `.preferredColorScheme(.light)`；副文字色加深为暖灰 `(0.38,0.36,0.32)`。
- 多屏位置乱窜 → `togglePopover` 弹出前 `NSApp.activate(ignoringOtherApps:)` + `makeKey()`，锚定状态栏图标所在屏。
- `ContentHeightKey.defaultValue` 需为 `let`（Swift 6 并发安全）。

## 执行结果

- 全部改动集中在 `Sources/KeepVibe/MenuContentView.swift`，`main.swift`/`Models.swift`/parser 未动。
- release 构建通过，`--dump` 数据解析正常。
- 已启动新构建，菜单栏咖啡杯图标待用户点击验证视觉效果。
- 暖米白为硬编码 + `.preferredColorScheme(.light)`，深色模式下也将显示暖调（符合用户"照搬设计稿"选择）。

## 遗留 / 待微调

- 暖米白 `windowBackground`/`cardBackground` 为初值，可对照设计稿微调饱和度/明度。
- pills 精确视觉（track 颜色、圆角）可按实机观感再调。
