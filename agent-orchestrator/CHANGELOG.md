# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
