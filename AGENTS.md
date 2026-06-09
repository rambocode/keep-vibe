# Repository Guidelines

## Project Structure & Module Organization

KeepVibe is a Swift Package Manager macOS menu bar app. Main application code lives in `Sources/KeepVibe/`, with the entry point in `main.swift`. UI code is in `MenuContentView.swift`; power management, system sampling, launch-at-login, pricing, and usage-log scanning are split into focused Swift files. Bundled app resources live in `Sources/KeepVibe/Resources/`. Tests live in `Tests/KeepVibeTests/`. User-facing assets are under `assets/`, build scripts under `scripts/`, and packaged release outputs under `dist/`.

## Build, Test, and Development Commands

- `swift build`: build a debug binary for local iteration.
- `swift build -c release`: build the optimized release binary.
- `swift test`: run the XCTest suite.
- `.build/release/KeepVibe --dump`: print system and AI usage stats for verification.
- `./scripts/build-macos-app.sh`: create the local `.app`, `.zip`, and `.dmg` artifacts.

Run commands from the repository root.

## Coding Style & Naming Conventions

Use Swift 6 style with 4-space indentation. Prefer small, single-purpose types and files. Name types with `UpperCamelCase` (`UsageLogScanner`, `KeepAwakeManager`) and functions/properties with `lowerCamelCase` (`summarizeAll`, `refreshPending`). Keep comments concise and useful, especially around macOS APIs, timers, file scanning, and power-management behavior. Avoid broad refactors when a narrow change solves the issue.

## Testing Guidelines

Tests use XCTest via the `KeepVibeTests` target. Add regression tests for parser, cache, date-boundary, and state-management changes. Test names should describe behavior, for example `testInitialScanAndAppendReuseCache`. Prefer temporary directories and fixture JSONL data over real `~/.claude` or `~/.codex` logs. Always run `swift test` before considering code changes complete.

## Commit & Pull Request Guidelines

History follows Conventional Commits, usually with Chinese descriptions, for example `perf: 增量缓存 AI 用量日志扫描` or `fix: 修复刷新并发覆盖导致会话数与用量显示回退`. Keep each commit focused on one intent. When creating annotated tags, write a tag message that summarizes the changed files and what changed in each area. Pull requests should include a short summary, verification commands, and screenshots or `--dump` output when UI or usage statistics change. Do not include generated build outputs unless the release workflow explicitly requires them.

## Security & Configuration Tips

KeepVibe reads local logs from `~/.claude/projects/` and `~/.codex/sessions/`; never commit private logs or cache files. The usage cache is stored under `~/Library/Application Support/KeepVibe/`. Treat packaged artifacts in `dist/` and generated assets as release outputs, not source changes by default.
