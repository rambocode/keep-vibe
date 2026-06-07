# Lessons

## 时间分桶（今日/本周/本月）必须独立判断 + 显式周起点
- **现象**：统计「本周」恒等于「今日」，「本月」却正常。
- **根因 1**：用 `if 本月 { if 本周 { if 今日 }}` 嵌套，隐含假设「月起点 ≤ 周起点」。跨月那一周（本周一落在上个月）会导致该日数据被排除出「本周」。
- **根因 2**：`Calendar.dateComponents([.yearForWeekOfYear,.weekOfYear])` 取的周起点依赖 locale 的 `firstWeekday`（美式 = 周日）。周日当天 → 周起点 = 今天 → 本周==今日。
- **规则**：① 多个时间桶各自独立 `if ts >= startX` 判断，不要嵌套包含。② 周起点显式设 `cal.firstWeekday = 2`（周一）并手动从今天 00:00 回退 `(weekday - firstWeekday + 7) % 7` 天，不要依赖 locale。
- **验证**：解析类逻辑务必用独立脚本（Python）对同一数据源跑真值对账，不要只看「能编译、能跑」。
