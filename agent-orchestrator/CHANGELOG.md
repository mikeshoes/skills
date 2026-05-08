# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `critique` verb（**可选功能 + 多轮讨论**）：PM 召唤 critic 角色做对抗性评审，**多轮讨论 → PM 拍板结案**。critic 跑第三方 anthropic-compatible endpoint（`claude -p` headless + `ANTHROPIC_BASE_URL` 切换），有完整 Claude Code 工具（Read/Write/Bash/Glob/Grep）
- 多轮流程：v1 review → PM 在文件末尾追加 `## PM 回应 v1`（`状态: 继续讨论` / `结案-X`）→ 重跑 critique 进 v2 复盘 → ... → PM 写 `结案-X` 触发自动归档
- 三种 target 形态：`auto` / `north-star` / `<file>`
- 终局判定：`状态: 结案-坚持原方案` + critic 最新轮总评 critical → 自动写 escalate notice 到 `comms/open/`
- 软限 5 轮：≥ 5 轮在 prompt 加提醒"是否问题定义本身需要重写"，不阻断
- `role_critic.md` 人格包：反向思考、可证伪要求、立场被论据驱动而非自尊驱动（被 PM 论据说服时撤回反对是好 critic 标志），续轮 v2+ 输出契约（接受/坚持/立场更新/总评变化）
- 通用配置（env，全部可选）：`CRITIQUE_BASE_URL` / `CRITIQUE_API_KEY` / `CRITIQUE_MODEL`，DeepSeek 默认 fallback（`DEEPSEEK_API_KEY` 即用）
- **未配置 provider 时**：critique 输出 warning + exit 0，不阻断 solo / orchestrator 等其他模式

### Changed
- **be/fe spawn 默认进 `acceptEdits` 权限模式 + 项目级 dev allow 列表**（避开 auto 模式的全局 opt-in 写入坑）：
  - acceptEdits 自动 ack 文件操作 + 简单 fs bash
  - `install_config.py` 在项目 `.claude/settings.local.json` 写永久 dev allow 列表（`git:*` / `npm:*` / `python:*` / `pytest:*` 等 17 项），覆盖 be/fe 常见 dev 命令
  - 永久 allow 不随 revoke 移除（跟 deny 一样常驻）
  - **零全局写入**：acceptEdits 无 opt-in 机制，跟 auto 不同
  - `AGENT_PANE_PERMISSION` env 可改默认（候选 `default` / `acceptEdits` / `bypassPermissions` / `auto`）
- qa 强制 `--permission-mode default`（避免继承用户全局 `defaultMode`）；`AGENT_QA_PERMISSION` env 可改
- `install_config.py` 同时写永久 deny 列表（`sudo` / `git push --force` / `-f`）

### Removed
- **be/fe 默认 auto 模式** —— auto 的 opt-in 接受会被 Claude Code 写入 `~/.claude/settings.json` 全局，污染其他项目。改为 acceptEdits + 项目级 allow 列表方案

## [0.1.0] - 2026-04-30

Initial public release.

### Added
- Solo mode: bootstrap a single role (`pm` / `be` / `fe` / `qa`) in the current Claude Code session, with watcher armed and briefing emitted
- Orchestrator mode: tmux multi-pane spawn with PM as the controlling pane (`start` / `add` / `status` / `stop`)
- File-based comms message bus with strict per-type formatting, length caps, and chain-end archive rules
- Per-pane refcount-based permission install/revoke (`install_config.py`) with `mkdir`-based concurrency lock
- PreCompact hook that re-injects role memory and prompts persona re-load after context compaction
- L3 memory auto-load of comms protocol core (cwd-bound via slug)
- Orphan holder GC for crashed panes (cross-checked against `tmux list-panes`)
- 4 role persona packs (PM / BE / FE / QA) with belief sets, golden questions, push-back posture, and trust scaffolding
- `list-my-open.sh` self-archive helper for self-sent messages
- pytest suite covering hook merge, permission lifecycle, holder refcount, GC, and L3 memory merge
- GitHub Actions CI: pytest + shellcheck

[0.1.0]: https://github.com/<you>/agent-orchestrator/releases/tag/v0.1.0
