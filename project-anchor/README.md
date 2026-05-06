# project-anchor

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](CHANGELOG.md)

> 防项目漂移的锚 + 漂移巡检 + pivot ceremony。给 AI 协作项目装一个不动点。

## 是什么

3 个动作的 Claude Code skill：

- **`/project-anchor init`** — 项目根建 `north-star.md`，记录"我们为什么做这个项目"的原始决策
- **`/project-anchor audit`** — 跑漂移巡检，输出 4 类信号 + 警告 / 健康判定
- **`/project-anchor pivot`** — 走 pivot ceremony：4 条件验证 + change 消息 + 追加决策日志

## 为什么需要

每个 iter 看每决策都合理；3 个 iter 累起来已偏到墙外——这就是**漂移**。

漂移检测就是定期把累积偏离暴露出来，逼项目要么对齐 north-star，要么走 pivot 显式承认改了方向。

> 健康项目：一年 pivot 5 次，每次都有完整论据。
> 病态项目：坚持原计划但悄悄漂。

这个 skill 让前者发生、暴露后者。

## 安装

跟 [agent-orchestrator](../agent-orchestrator/) 同 monorepo。symlink 到 Claude Code skills 目录：

```bash
ln -s ~/code/skills/project-anchor ~/.claude/skills/project-anchor
```

## 前提

- **必须**：项目根可写
- **推荐**：git repo（drift audit 用 git history）
- **可选**：`comms/` 目录（来自 agent-orchestrator）—— 有则跑全套；无则跑 lite 版本

## 跟 agent-orchestrator 协作

跟 agent-orchestrator **不强耦合**：

- **配合用** → drift audit 能扫 `comms/` 里 change 消息累积；pivot 自动写 change 到 `comms/open/` 让团队 ack
- **单独用** → drift audit 仍能跑（信号会少几个）；pivot 只更新 decisions log，不发消息

## 4 类 drift signals（v0.1）

| # | 信号 | 检测什么 |
|---|---|---|
| 1 | change 累积数 | `comms/` 里 change 消息累积 vs north-star 决策日志增长 |
| 2 | north-star 引用频率 | 过去 30 天有多少文档引用 north-star |
| 3 | decisions log 新鲜度 | 距上次 decisions log entry 多少天 |
| 4 | iteration-plan 偏移 | 当前 vs 最早 git 版本的行数差异 |

## Pivot ceremony 4 条件

改 north-star 任一条必须**全部满足**：

1. 触发证据 ≥ 2 条独立来源（不是单个 stakeholder 拍脑袋）
2. 可逆性记录（什么证据会让我们改回去）
3. 用户原话引用（不是 PM 转述）
4. 在 iter 边界发生（不许 iter 中改）

## 文件清单

- [SKILL.md](SKILL.md) — 完整命令分发逻辑
- [assets/north-star-template.md](assets/north-star-template.md) — north-star 模板
- [assets/audit-report-template.md](assets/audit-report-template.md) — 巡检报告格式
- [assets/pivot-change-template.md](assets/pivot-change-template.md) — pivot change 消息格式

## License

MIT — see [LICENSE](LICENSE).
