export const meta = {
  name: 'keep-vibe-verify-ship',
  description: 'KeepVibe 续接：在已构建通过的现有代码上 → 多路验证 → 审查修复 → git 留档',
  phases: [
    { title: 'Verify', detail: '多路验证：各自独立真值对账数据正确性（5 路并行）' },
    { title: 'Review', detail: '审查修复：按验证发现定位根因并修复重建' },
    { title: 'Ship',   detail: 'git 留档：init + commit' },
  ],
}

const DIR = '/Users/mike/source/project/ai/keep-vibe'

// ===================== Phase 1：Verify（多路验证，并行）=====================
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
const dumpHint = `先确认已构建：cd ${DIR} && swift build -c release >/dev/null 2>&1；取程序输出 ./.build/release/KeepVibe --dump 2>&1；再用 python3 独立从原始 jsonl 重算真值；两者对比（允许因运行间隔的实时写入造成 <2% 漂移，不算失败）。`
const VERIFIERS = [
  { label: 'verify:claude-buckets', path: 'Claude 今日/本周/本月',
    spec: `验证 Claude 的今日/本周/本月 token 分桶。${dumpHint} 重点：本周应≥今日、本月应≥本周；今天是周日时若本周==今日即为 bug（本周起点应为周一）。python 用 weekday() 以周一为周起点、三桶【独立】判断、本地时区。给出 expected/actual。` },
  { label: 'verify:claude-window', path: 'Claude 5h 窗口',
    spec: `验证 Claude 5h 窗口自洽性：resetIn∈[0,5h]，usedFraction≈(5h-resetIn)/5h，tok/min≈tokens/已过分钟。${dumpHint} python 复算当前 5h 块。` },
  { label: 'verify:codex-buckets', path: 'Codex 今日/本周/本月',
    spec: `验证 Codex 今日/本周/本月（同样检查本周以周一为起点、三桶独立）。${dumpHint} python 累加 token_count 事件 last_token_usage.total_tokens 按本地时区分桶。` },
  { label: 'verify:system', path: '系统状态',
    spec: `验证系统状态合理性：内存 total≈sysctl hw.memsize、电池% 与 pmset -g batt 接近、开机时长≈uptime、CPU%∈[0,100]。${dumpHint}` },
  { label: 'verify:pricing', path: '成本计算',
    spec: `抽查成本：取若干 Claude usage 行手算 claudeCost(opus 15/75、cacheWrite=cache_creation@18.75、cacheRead=cache_read@1.5)，与 --dump 今日成本量级一致即可；核对 Codex codexCost 非缓存 input=max(0,input-cached)。报告偏差。` },
]
const verify = await parallel(VERIFIERS.map(v => () =>
  agent(
`你是「多路验证」中的一路，独立验证 KeepVibe 的一个数据路径，不要修复代码、只判定与报告。工作目录：${DIR}。
${v.spec}
返回结构化结果（path="${v.path}"）。`,
    { label: v.label, phase: 'Verify', schema: VERIFY_SCHEMA }
  )
))
const ok = verify.filter(Boolean)
const failures = ok.filter(v => !v.passed)
log('Verify：' + (ok.length - failures.length) + ' 通过 / ' + failures.length + ' 不通过')

// ===================== Phase 2：Review（审查修复）=====================
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
【多路验证发现】\n${JSON.stringify(ok, null, 2)}
任务：
1) 对每个 passed=false 的路径，定位 Swift 源码根因并修复（典型：周分桶用了 locale firstWeekday 或嵌套桶——改成 firstWeekday=2 周一 + 三桶独立判断）。
2) 即使全部通过，也做一轮轻量审查：消除明显的 Swift6 并发警告、资源泄漏、可选强解包风险（改动最小，不破坏行为与 UI）。
3) swift build -c release 重建；再 ./.build/release/KeepVibe --dump 自检数据已修正。
返回结构化结果。`,
  { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA }
)
log('Review：' + (review?.rebuildOk ? '重建通过' : '重建失败') + '，修复 ' + (review?.fixesApplied?.length ?? 0) + ' 项')

// ===================== Phase 3：Ship（git 留档）=====================
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
1) 若非 git 仓库则 git init（默认分支 main）；设置最小 user.name/email 若缺省（可用 git -c 临时传）。
2) 确认 .gitignore 已忽略 .build/；git add -A。
3) git commit，提交信息用中文，标题如「feat: KeepVibe 菜单栏防睡 + Claude/Codex 用量统计」，正文简述功能与本次验证/修复要点。
4) git log --oneline -1 取 hash；git ls-files | wc -l 取跟踪文件数。
返回结构化结果。`,
  { label: 'ship', phase: 'Ship', schema: SHIP_SCHEMA }
)

return {
  verify: ok,
  verifyFailures: failures.length,
  review,
  ship,
}
