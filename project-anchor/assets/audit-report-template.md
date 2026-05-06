# 漂移巡检报告 — {YYYY-MM-DD HH:MM}

> 由 `/project-anchor audit` 生成。

## 信号汇总

| # | 信号 | 数据 | 状态 |
|---|---|---|---|
| 1 | change 累积（自上次 audit） | {N} 条（open {M} / done {K}）| 🟢 / 🟡 / 🔴 |
| 2 | north-star 引用频率（30 天）| {N} 文件 | 🟢 / 🟡 / 🔴 |
| 3 | decisions log 新鲜度 | {N} 天 | 🟢 / 🟡 / 🔴 |
| 4 | iteration-plan 偏移 | {N} 行 diff | 🟢 / 🟡 / 🔴 |

## 判定

{触发的警告列表}

例：
- 🔴 累积 8 条 change 但 north-star 决策日志近 6 个月无新增 → **疑似未识别 pivot**
- 🟡 north-star 30 天内仅 1 处引用 → 可能集体漂

## 建议动作

1. {具体下一步动作 1}
2. {具体下一步动作 2}

下次巡检建议：跑过本次建议动作后立即重测 / 3 个 iter 后 / 累积 ≥ 3 条新 change 时

---

*生成时间：{YYYY-MM-DD HH:MM}*
