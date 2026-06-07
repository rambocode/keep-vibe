export const meta = {
  name: 'build-keep-vibe',
  description: 'KeepVibe menu bar app: scaffold → 并行模块实现 → 构建集成 → 多路验证 → 审查修复 → git 留档',
  phases: [
    { title: 'Scaffold', detail: '脚手架与契约：Package/Models/Pricing' },
    { title: 'Modules',  detail: '并行模块实现：power/system/claude/codex/views（5 agents）' },
    { title: 'Build',    detail: '构建集成：swift build 迭代至通过 + release' },
    { title: 'Verify',   detail: '多路验证：各自独立真值对账数据正确性' },
    { title: 'Review',   detail: '审查修复：按验证发现定位根因并修复重建' },
    { title: 'Ship',     detail: 'git 留档：init + commit' },
  ],
}

const DIR = '/Users/mike/source/project/ai/keep-vibe'

// ============ 共享契约（精确签名，所有 agent 严格遵守） ============
const CONTRACT = `
项目：macOS 菜单栏 App「KeepVibe」（保持唤醒 + 统计 Claude Code / Codex 用量）。
技术栈：SwiftPM 可执行目标，Swift tools 6.0，platform macOS v14。
入口用 AppKit NSApplication + NSStatusItem + NSPopover(承载 SwiftUI)，NSApp.setActivationPolicy(.accessory) 隐藏 Dock。
源码目录：Sources/KeepVibe/。所有类型同一 module，无需 import 彼此。

=== 脚手架阶段已写入以下文件（其余 agent 按签名实现，不要重写）===

// Models.swift
import Foundation
import Combine
enum AwakeMode: String, CaseIterable { case standard, clamshell }   // 标准防睡 / 合盖也不睡
enum AwakeDuration: Hashable, CaseIterable {                          // 永久 / 1 / 2 / 4 小时
    case forever, hours(Int)
    static var allCases: [AwakeDuration] { [.forever, .hours(1), .hours(2), .hours(4)] }
    var label: String { switch self { case .forever: return "永久"; case .hours(let h): return "\\(h)小时" } }
    var seconds: TimeInterval? { switch self { case .forever: return nil; case .hours(let h): return TimeInterval(h*3600) } }
}
struct SystemStats {
    var uptimeSeconds: TimeInterval = 0
    var cpuPercent: Double = 0
    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    var batteryPercent: Int? = nil
    var batteryCharging: Bool = false
}
struct WindowStat { var tokens: Int = 0; var tokensPerMin: Double = 0; var resetIn: TimeInterval? = nil; var usedFraction: Double = 0 }
struct AgentUsage {
    var todayTokens: Int = 0; var todayCost: Double = 0
    var weekTokens: Int = 0;  var weekCost: Double = 0
    var monthTokens: Int = 0; var monthCost: Double = 0
    var window: WindowStat? = nil
    var activeSessions: Int = 0
    var costIsApprox: Bool = false
}
@MainActor final class AppState: ObservableObject {
    @Published var keepAwake = false
    @Published var mode: AwakeMode = .standard
    @Published var duration: AwakeDuration = .forever
    @Published var awakeRemaining: TimeInterval? = nil
    @Published var system: SystemStats? = nil
    @Published var claude: AgentUsage? = nil
    @Published var codex: AgentUsage? = nil
    @Published var lastUpdated: Date? = nil
    @Published var launchAtLogin = false
}

// Pricing.swift —— 每百万 token 价格
enum Pricing {
    static func claudeCost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double
    static func codexCost(input: Int, cachedInput: Int, output: Int) -> Double
}

=== 其余模块需实现的精确签名 ===

final class KeepAwakeManager {            // KeepAwakeManager.swift（import IOKit.pwr_mgt）
    var isActive: Bool { get }
    var remaining: TimeInterval? { get }
    var onExpire: (() -> Void)?
    func start(mode: AwakeMode, duration: AwakeDuration)
    func stop()
}
enum LaunchAtLogin {                       // LaunchAtLogin.swift（~/Library/LaunchAgents plist）
    static var isEnabled: Bool { get }
    static func set(_ enabled: Bool)
}
enum SystemMonitor { static func sample() -> SystemStats }                 // SystemMonitor.swift
enum ClaudeUsageParser { static func summarize(now: Date) -> AgentUsage }  // ClaudeUsageParser.swift
enum CodexUsageParser  { static func summarize(now: Date) -> AgentUsage }  // CodexUsageParser.swift
struct MenuContentView: View {            // MenuContentView.swift
    @ObservedObject var state: AppState
    var onToggleAwake: (Bool) -> Void
    var onSelectMode: (AwakeMode) -> Void
    var onSelectDuration: (AwakeDuration) -> Void
    var onToggleLaunch: (Bool) -> Void
    var onRefresh: () -> Void
    var onQuit: () -> Void
    var body: some View { /* 见 views 模块 spec */ }
}
// main.swift：顶层 main 启动 NSApplication + AppDelegate（持有 AppState/KeepAwakeManager/NSStatusItem/NSPopover），
//   每 5 秒在后台线程 refresh()（采样系统 + 两个解析器），回主线程写 AppState。
//   另：CommandLine.arguments 含 "--dump" 时，离线打印系统/Claude/Codex 解析结果后 exit(0)（供验证用）。
`

// ============ 数据源真实结构 + 硬规则（喂给解析器，避免踩坑） ============
const DATA_NOTES = `
【Claude jsonl】~/.claude/projects/**/*.jsonl，每行一个 JSON，只统计 type=="assistant" 且含 message.usage 的行：
  timestamp(ISO8601 UTC) · message.model(含 opus/sonnet/haiku) · message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens} · sessionId
  按 (message.id 或 requestId) 去重；展示 token = input+output+cache_creation+cache_read；成本 = Pricing.claudeCost(...)。

【Codex jsonl】~/.codex/sessions/**/*.jsonl，只统计 type=="event_msg" 且 payload.type=="token_count" 的事件：
  用 payload.info.last_token_usage（本回合增量）累加，避免重复；展示 token 累加其 total_tokens；
  成本 = Pricing.codexCost(input=input_tokens, cachedInput=cached_input_tokens, output=output_tokens+reasoning_output_tokens)，costIsApprox=true，window=nil。

【时间分桶——硬规则，必须照做（否则数据出错）】
  1) 今日/本周/本月三个桶各自【独立】判断 if ts>=startX，【禁止】用 if 本月{ if 本周{ if 今日 }} 嵌套——
     嵌套在跨月那一周（本周一落在上个月）会把该日数据漏出「本周」，导致本周偏小。
  2) 本周起点固定【周一】：var cal=Calendar.current; cal.firstWeekday=2; 从今天 00:00 回退
     (weekday - firstWeekday + 7)%7 天。【禁止】用 dateComponents([.yearForWeekOfYear,.weekOfYear])——
     它依赖 locale 的 firstWeekday（美式=周日），周日当天会让「本周==今日」。
  3) 本地时区；活跃会话=该会话最后相关事件 timestamp 在最近 5 分钟内；
     性能：按文件 mtime<now-35天 跳过，逐行流式读取（Claude~1020、Codex~531 个文件）。

【Claude 5h 窗口】参考图：5h窗口 27.7M / 271.3k tok/min / 剩 3:16:25 / 橙色进度条。
  assistant 事件按时间排序，以「首条或距上条>5h 间隔后的首条」为块起点、每块 5 小时；取含 now 的当前块。
  window.tokens=块内总 token；resetIn=blockStart+5h-now（clamp>=0）；usedFraction=(5h-resetIn)/5h；
  tokensPerMin=tokens / max(1, (now-blockStart)/60)。
`

// ===================== Phase 1：Scaffold =====================
phase('Scaffold')
const scaffold = await agent(
`为 macOS 菜单栏 App 搭脚手架。工作目录：${DIR}。
创建并写入（内容严格按契约，可直接编译）：
1) Package.swift —— swift-tools-version:6.0；name "KeepVibe"；platforms [.macOS(.v14)]；一个 .executableTarget(name:"KeepVibe", path:"Sources/KeepVibe")。
2) Sources/KeepVibe/Models.swift —— 逐字照契约里的 Models 代码。
3) Sources/KeepVibe/Pricing.swift —— claudeCost：model 含 opus→(15,75,cacheWrite18.75,cacheRead1.5)；含 sonnet→(3,15,3.75,0.30)；含 haiku→(0.80,4,1.00,0.08)；默认 sonnet。codexCost：非缓存 input=max(0,input-cachedInput) 按 $1.25/M、cachedInput $0.125/M、output $10/M。单位每百万 token。
4) .gitignore（忽略 .build/ 与 *.xcodeproj）、README.md（中文：用途/构建 \`swift build -c release\`/运行/功能点）。
完整契约：\n${CONTRACT}
只写上述文件，不要建其他源文件，不要 swift build。一行中文总结。`,
  { label: 'scaffold', phase: 'Scaffold' }
)
log('Scaffold 完成：' + String(scaffold).slice(0, 140))

// ===================== Phase 2：Modules（5 agents 并行）=====================
phase('Modules')
const MODULES = [
  {
    label: 'impl:power',
    spec: `实现两个文件：
A) Sources/KeepVibe/KeepAwakeManager.swift（import IOKit.pwr_mgt）：standard 用 kIOPMAssertionTypePreventUserIdleSystemSleep；clamshell（合盖也不睡）用 kIOPMAssertionTypePreventSystemSleep 并注释「仅接通电源时对合盖生效」。存 IOPMAssertionID，stop() 时 Release。duration=.hours(n) 用主线程 Timer 倒计时，到点 stop()+主线程 onExpire?()；remaining 返回剩余秒；重复 start 先释放旧断言。
B) Sources/KeepVibe/LaunchAtLogin.swift：~/Library/LaunchAgents/com.keepvibe.launcher.plist。isEnabled=plist 是否存在；set(true) 写 plist(Label,ProgramArguments=[当前可执行绝对路径],RunAtLoad=true) 后 launchctl load -w；set(false) launchctl unload 后删 plist；失败 try? 静默。可执行路径 Bundle.main.executablePath ?? CommandLine.arguments[0] 绝对化。`,
  },
  {
    label: 'impl:system',
    spec: `实现 Sources/KeepVibe/SystemMonitor.swift —— enum SystemMonitor { static func sample() -> SystemStats }。
uptime：sysctl KERN_BOOTTIME 求 now-boot。
cpu：host_processor_info(PROCESSOR_CPU_LOAD_INFO) 各核 tick，static 存上次快照算两次差值总占用%，首次返回瞬时近似或 0，vm_deallocate 释放。
内存：host_statistics64(HOST_VM_INFO64)，已用=(active+wired+compressed)*页大小（页大小用 getpagesize()，勿用 vm_kernel_page_size——Swift6 并发不安全），total=ProcessInfo.physicalMemory。
电池：import IOKit.ps；IOPSCopyPowerSourcesInfo/List，读 kIOPSCurrentCapacityKey/kIOPSMaxCapacityKey/kIOPSPowerSourceStateKey/kIOPSIsChargingKey；无电池 batteryPercent=nil。`,
  },
  {
    label: 'impl:claude',
    spec: `实现 Sources/KeepVibe/ClaudeUsageParser.swift —— enum ClaudeUsageParser { static func summarize(now: Date) -> AgentUsage }。
扫描 ~/.claude/projects 下 *.jsonl（FileManager.enumerator，mtime<now-35天 跳过），逐行 JSONSerialization，只处理 type=="assistant" 且 message.usage 存在的行，按 (message.id 或 requestId) 去重。
今日/本周/本月分桶与成本、5h 窗口、activeSessions（按 sessionId）。务必遵守 DATA_NOTES 的【时间分桶硬规则】与【5h 窗口】算法：\n${DATA_NOTES}`,
  },
  {
    label: 'impl:codex',
    spec: `实现 Sources/KeepVibe/CodexUsageParser.swift —— enum CodexUsageParser { static func summarize(now: Date) -> AgentUsage }。
扫描 ~/.codex/sessions 下 *.jsonl（mtime<now-35天 跳过），只处理 type=="event_msg" 且 payload.type=="token_count"，用 last_token_usage 增量累加。
今日/本周/本月分桶、成本(codexCost, costIsApprox=true)、activeSessions、window=nil。务必遵守 DATA_NOTES 的【时间分桶硬规则】：\n${DATA_NOTES}`,
  },
  {
    label: 'impl:views',
    spec: `实现两个文件：
A) Sources/KeepVibe/MenuContentView.swift —— SwiftUI struct MenuContentView（见契约签名），严格还原参考图（宽约 320，浅色卡片、圆角分组、SF Symbols）：
   顶部 咖啡杯图标+「保持唤醒」+右侧 Toggle(onToggleAwake)；
   其下（keepAwake 开启才高亮可用）：两段「标准防睡/合盖也不睡」(onSelectMode 选中蓝底)、四段「永久/1/2/4小时」(onSelectDuration 选中蓝底)，有 awakeRemaining 显示倒计时；
   「系统状态」卡片：开机时长(X小时Y分)、CPU(绿条+%)、内存(条+"19.5 GB / 36.0 GB")、电池(%；充电加闪电)，state.system 为 nil 显示 "—"；
   「Claude Code」卡片(sparkles 橙)：今日大号 token+右侧 $；时钟「5h 窗口」+token+右侧 "271.3k tok/min"；橙色进度条(usedFraction)+右侧 "剩 H:MM:SS"；下两列 本周/本月 token+灰 $；底部 activeSessions==0→「无活跃会话」否则「N 个活跃会话」；
   「Codex」卡片(</> 蓝)：今日 token+右侧 ≈$（costIsApprox 加 ≈），本周/本月两列(≈$)，底部活跃会话；
   底部「开机自启」+Toggle(onToggleLaunch)；最底行 左「刷新」(arrow.clockwise,onRefresh)+"更新于 N秒前"，右「退出」(power,onQuit)。
   token 友好显示 >=1e6→"X.XM"、>=1e3→"X.Xk"；金额 "$X.XX"。配色：蓝强调/绿系统条/橙 Claude 条。
B) Sources/KeepVibe/main.swift —— @MainActor AppDelegate(持有 AppState/KeepAwakeManager/NSStatusItem/NSPopover)。
   applicationDidFinishLaunching：建 NSStatusItem(button.image="cup.and.saucer.fill")，点击切换 .transient NSPopover(NSHostingController(MenuContentView(...)))；
   回调按契约接 KeepAwakeManager.start/stop、LaunchAtLogin.set、refresh、NSApp.terminate；onExpire 主线程置 keepAwake=false；
   refresh()：Task.detached 调 SystemMonitor.sample()/ClaudeUsageParser.summarize(now:)/CodexUsageParser.summarize(now:)，await MainActor.run 写入 state 与 lastUpdated=Date()、awakeRemaining；启动即刷新一次 + Timer 每 5 秒；启动读 LaunchAtLogin.isEnabled。
   顶层 main：NSApplication.shared + delegate + setActivationPolicy(.accessory) + run()（不要 @main）。
   并在顶层 run() 之前加 --dump 分支：CommandLine.arguments.contains("--dump") 时同步打印系统/Claude/Codex 解析结果并 exit(0)。`,
  },
]
const impl = await parallel(MODULES.map(m => () =>
  agent(
`你在实现 macOS 菜单栏 App「KeepVibe」的模块。工作目录：${DIR}。脚手架已写好 Package/Models/Pricing（直接用，勿改）。
【完整契约】\n${CONTRACT}
【你的任务】${m.spec}
要求：与契约签名对齐、能编译；涉及 UI/AppState 标 @MainActor 或在主线程；只写指派给你的文件，勿改他人文件，勿 swift build。一行中文总结。`,
    { label: m.label, phase: 'Modules' }
  )
))
log('Modules 完成：' + impl.filter(Boolean).length + '/' + MODULES.length)

// ===================== Phase 3：Build =====================
phase('Build')
const BUILD_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    buildSucceeded: { type: 'boolean' },
    iterations: { type: 'integer' },
    binaryPath: { type: 'string' },
    fixesApplied: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['buildSucceeded', 'iterations', 'summary'],
}
const build = await agent(
`把 Swift 包「KeepVibe」构建到通过。工作目录：${DIR}。
1) swift build 2>&1；有错就读相关文件针对性修复（跨文件签名不一致、Swift6 并发/Sendable、IOKit/Mach API、可选解包、ISO8601 等），循环最多 12 次至 exit 0；改动最小、不破坏契约/UI。
2) 成功后 swift build -c release，产出 .build/release/KeepVibe。
3) 冒烟：( .build/release/KeepVibe & ); sleep 3; pgrep -f KeepVibe && kill 之，确认不崩溃。
返回结构化结果。`,
  { label: 'build', phase: 'Build', schema: BUILD_SCHEMA }
)
log('Build：' + (build?.buildSucceeded ? '通过' : '未通过') + ' / ' + (build?.iterations ?? '?') + ' 次迭代')

// ===================== Phase 4：Verify（多路验证，并行）=====================
phase('Verify')
const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    path: { type: 'string' },
    passed: { type: 'boolean' },
    method: { type: 'string' },
    expected: { type: 'string' },
    actual: { type: 'string' },
    discrepancy: { type: 'string' },
  },
  required: ['path', 'passed', 'method', 'discrepancy'],
}
const dumpHint = `先 cd ${DIR} && ./.build/release/KeepVibe --dump 2>&1 取程序输出；再用 python3 独立从原始 jsonl 重算真值；两者对比（允许因运行间隔产生的实时写入造成 <2% 漂移）。`
const VERIFIERS = [
  { label: 'verify:claude-buckets', path: 'Claude 今日/本周/本月',
    spec: `验证 Claude 的今日/本周/本月 token 分桶。${dumpHint} 重点核对：本周应≥今日、本月应≥本周；今天是周日时，若本周==今日即为 bug（本周起点应为周一）。python 用 weekday() 以周一为起点、三个桶独立判断。给出 expected/actual/是否通过。` },
  { label: 'verify:claude-window', path: 'Claude 5h 窗口',
    spec: `验证 Claude 5h 窗口：tokens / tok/min / resetIn / usedFraction 是否自洽（resetIn∈[0,5h]，usedFraction≈(5h-resetIn)/5h，tok/min≈tokens/已过分钟）。${dumpHint} 用 python 复算当前 5h 块。` },
  { label: 'verify:codex-buckets', path: 'Codex 今日/本周/本月',
    spec: `验证 Codex 今日/本周/本月（同样检查本周以周一为起点、三桶独立）。${dumpHint} python 累加 token_count 事件的 last_token_usage.total_tokens 按本地时区分桶。` },
  { label: 'verify:system', path: '系统状态',
    spec: `验证系统状态合理性：内存 total≈sysctl hw.memsize、电池% 与 pmset -g batt 一致、开机时长≈uptime、CPU%∈[0,100]。${dumpHint} 用 sysctl/pmset/uptime 对比。` },
  { label: 'verify:pricing', path: '成本计算',
    spec: `抽查成本：取若干条 Claude usage 行手算 claudeCost（opus 15/75、cacheWrite=cache_creation@18.75、cacheRead=cache_read@1.5），与按比例推得的 --dump 今日成本量级一致即可。核对 Codex codexCost 非缓存 input=max(0,input-cached)。报告偏差。` },
]
const verify = await parallel(VERIFIERS.map(v => () =>
  agent(
`你是「多路验证」中的一路，独立验证 KeepVibe 的一个数据路径，不要修复代码、只判定与报告。工作目录：${DIR}。
${v.spec}
返回结构化结果（path="${v.path}"）。`,
    { label: v.label, phase: 'Verify', schema: VERIFY_SCHEMA }
  )
))
const failures = verify.filter(Boolean).filter(v => !v.passed)
log('Verify：' + (verify.filter(Boolean).length - failures.length) + ' 通过 / ' + failures.length + ' 不通过')

// ===================== Phase 5：Review（审查修复）=====================
phase('Review')
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    fixesApplied: { type: 'array', items: { type: 'string' } },
    rebuildOk: { type: 'boolean' },
    reverifyOk: { type: 'boolean' },
    summary: { type: 'string' },
  },
  required: ['rebuildOk', 'summary'],
}
const review = await agent(
`你负责审查并修复 KeepVibe。工作目录：${DIR}。
【多路验证发现】\n${JSON.stringify(verify.filter(Boolean), null, 2)}
任务：
1) 对每个 passed=false 的路径，定位 Swift 源码根因并修复（典型：周分桶用了 locale firstWeekday 或嵌套桶——改成 firstWeekday=2 周一 + 三桶独立判断）。
2) 即使全部通过，也做一轮轻量代码审查：消除明显的 Swift6 并发警告、资源泄漏、可选强解包风险。
3) swift build -c release 重建；再 ./.build/release/KeepVibe --dump 自检数据已修正。
返回结构化结果（fixesApplied / rebuildOk / reverifyOk / summary）。`,
  { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA }
)
log('Review：' + (review?.rebuildOk ? '重建通过' : '重建失败') + '，修复 ' + (review?.fixesApplied?.length ?? 0) + ' 项')

// ===================== Phase 6：Ship（git 留档）=====================
phase('Ship')
const SHIP_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    committed: { type: 'boolean' },
    commitHash: { type: 'string' },
    filesTracked: { type: 'integer' },
    summary: { type: 'string' },
  },
  required: ['committed', 'summary'],
}
const ship = await agent(
`把 KeepVibe 留档到 git（仅本地，不要 push、不要建远程）。工作目录：${DIR}。
1) 若非 git 仓库则 git init（默认分支 main）。
2) 确认 .gitignore 已忽略 .build/；git add -A。
3) git commit，提交信息用中文，标题如「feat: KeepVibe 菜单栏防睡 + Claude/Codex 用量统计」，正文简述功能与本次验证/修复要点。
4) git log --oneline -1 取 hash；git ls-files | wc -l 取跟踪文件数。
返回结构化结果。`,
  { label: 'ship', phase: 'Ship', schema: SHIP_SCHEMA }
)

return {
  scaffold: String(scaffold).slice(0, 160),
  modules: MODULES.map((m, i) => ({ module: m.label, ok: !!impl[i] })),
  build,
  verify: verify.filter(Boolean),
  verifyFailures: failures.length,
  review,
  ship,
}
