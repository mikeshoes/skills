# agent-orchestrator

[![CI](https://github.com/mikeshoes/skills/actions/workflows/ci.yml/badge.svg)](https://github.com/mikeshoes/skills/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](CHANGELOG.md)

> Multi-role (PM/BE/FE/QA) tmux orchestration for Claude Code, built on a file-based comms protocol that keeps every message tight, archived, and auditable.

[English](#english) · [中文](#中文)

---

## English

- [What it does](#what-it-does)
- [Why it exists](#why-it-exists)
- [Demo](#demo)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [First run](#first-run)
- [Commands](#commands)
- [Message format](#message-format)
- [Project layout](#project-layout)
- [Files this skill creates](#files-this-skill-creates)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [When NOT to use it](#when-not-to-use-it)
- [Documentation](#documentation)
- [License](#license)

### What it does

Run a Claude Code session as a **PM** that can spawn `be` / `fe` / `qa` agents in adjacent tmux panes. Each pane is its own Claude Code session with a distinct role, memory, and watcher.

Roles coordinate by writing one Markdown file per message into `comms/open/`. Every message has:

- A typed envelope (`bug`, `delivery`, `verify`, `ack`, `change`, `notice`, `question`, `block`)
- A length cap (≤ 400 chars body, per-type line limits)
- A named archive owner (the chain-end role moves the whole thread to `done/` once resolved)

The result: PR-level discipline (specs, bugs, verifies, sign-offs) for any project worked on by a Claude Code agent team.

### Why it exists

Single-context Claude sessions blur roles — the agent that built the API also tests it; the agent that wrote the spec also implements it. This skill enforces separation: **each pane is one role**, with its own memory, watcher, and persona pack. Compaction and context drift no longer collapse roles into a single "helpful generalist."

### Demo

`/agent-orchestrator be fe qa` — PM on top, BE/FE/QA along the bottom (main-horizontal layout, auto-applied at 4+ panes):

![4-pane tmux layout](docs/pane_4.png)

`/agent-orchestrator be qa` — vertical split with PM on the left, sub-roles stacked on the right (auto-applied at 2-3 panes):

![3-pane tmux layout](docs/pane_3.png)

### How it works

Four pillars:

#### 1. Roles and persona packs

| Role | Code | Task prefix | Mode | Duty |
|------|------|-------------|------|------|
| Product manager | `pm` | `P*` | Collaborative (defers to user) | Owns `iteration-plan.md`, schedules priority, accepts deliveries |
| Backend | `be` | `B*` | Executive (acts on best judgment) | Implements `B*` tasks, owns interface contracts |
| Frontend | `fe` | `F*` | Executive | Implements `F*` tasks, maintains mock alignment |
| QA | `qa` | `Q*` | Collaborative | Reports bugs (symptom + evidence + root-cause); never writes the fix |

Each role gets a **persona pack** (`assets/role_<role>.md`) loaded on bootstrap: beliefs, golden questions, push-back posture, trust scaffolding. The persona is what makes "PM" think differently from "BE" — not just a label.

#### 2. Comms message bus

Messages are filenames. The format `YYYYMMDD-HHMM__<from>__<to>__<tag>.md` makes everything inspectable from `ls`. The watcher's job is just to notice new files.

Eight message types, each with a strict skeleton — see [Message format](#message-format) below.

Archive happens at the **chain end**: whoever closes the loop (e.g., QA after a `verify` passes) moves the whole thread to `comms/done/<YYYY-MM>/`. Middle parties don't archive.

#### 3. Watcher + Monitor

Each role's pane runs `bash .run/watcher.sh <role>`, polling `comms/open/` every 5 seconds for files matching the role's glob and newer than the role's stamp file. Claude Code's `Monitor` tool runs the watcher as a background task; new messages appear as events in the Claude session.

The watcher uses an `mkdir`-based mutex (cross-platform — macOS has no `flock`) so two watchers for the same role can't fight over the stamp.

#### 4. PreCompact hook + L3 memory

Two pieces glue role identity to Claude Code's lifecycle:

- **L3 memory** (`~/.claude/projects/<cwd-slug>/memory/MEMORY.md`) — auto-loaded by Claude Code into every session in that cwd. The installer merges the comms protocol core into it (idempotent, marker-bound block).
- **PreCompact hook** — fires before context compaction. It looks up the current pane's role, cats `comms/memory/<role>.md` (project-specific evidence contract) into the conversation, and prompts the agent to re-`Read` its persona pack. Without this, role identity gets summarized away after a few compactions.

### Prerequisites

- Claude Code (recent version with `Monitor` and `ToolSearch` tools)
- `tmux` 3.0+
- `python3` 3.8+
- `bash` 4+ (macOS users: `brew install bash`)
- macOS or Linux

### Install

The skill lives inside the [mikeshoes/skills](https://github.com/mikeshoes/skills) monorepo. Symlink the skill folder into your Claude Code skills dir so `git pull` keeps it updated:

```bash
git clone git@github.com:mikeshoes/skills.git ~/code/skills
ln -s ~/code/skills/agent-orchestrator ~/.claude/skills/agent-orchestrator
```

Or per-project:

```bash
ln -s ~/code/skills/agent-orchestrator <your-project>/.claude/skills/agent-orchestrator
```

Verify by starting Claude Code and typing `/agent-orchestrator` — you should see the help/dispatch prompt.

### First run

```bash
# 1. Open a tmux session running Claude Code
cd ~/your-project
tmux new-session -s pm 'claude'

# 2. Inside the new Claude session, spawn the team:
/agent-orchestrator be fe qa

# 3. Wait ~10s for sub-panes to bootstrap, then:
/agent-orchestrator status
# Expected:
#   pm  %0  -      online (current pane)
#   be  %3  12345  online
#   fe  %4  12346  online
#   qa  %5  12347  online
```

What happens behind the scenes:

1. PM bootstraps itself (writes `comms/memory/pm.md`, starts its watcher, arms `Monitor`)
2. PM spawns 3 tmux panes, each running `claude` with `/agent-orchestrator solo <role>` queued
3. Each sub-role bootstraps itself, registers its pane id in `.run/role_pane_<role>`, and writes a `<role>-online` notice to `comms/open/`
4. PM's watcher picks up the online notices and reports the team is ready

Files created in your project: `comms/`, `.run/`, `.claude/settings.local.json` (only the skill's keys).
Files created in your home dir: `~/.claude/projects/<cwd-slug>/memory/{MEMORY.md,role_*.md}`.

### Commands

#### Solo mode (single-pane bootstrap)

| Input | Effect |
|---|---|
| `/agent-orchestrator solo pm` | Bootstrap current session as PM |
| `/agent-orchestrator solo be` | as BE |
| `/agent-orchestrator solo fe` | as FE |
| `/agent-orchestrator solo qa` | as QA |

#### Orchestrator mode (multi-pane, requires tmux)

| Input | Effect |
|---|---|
| `/agent-orchestrator` | PM only (current pane bootstraps) |
| `/agent-orchestrator be fe qa` | PM + 3 sub-roles |
| `/agent-orchestrator be fe` | PM + 2 sub-roles |
| `/agent-orchestrator add qa` | Add a sub-role to an already-running orchestrator |
| `/agent-orchestrator status` | Show online state of all roles |
| `/agent-orchestrator stop fe` | Stop one sub-role (PM stays) |
| `/agent-orchestrator stop` | Stop all sub-roles (PM stays) |

To fully shut down (including PM): `tmux kill-session`.

#### `status` output

```
role pane     pid    status
---- ----     ---    ------
pm   %0       -      online (current pane)
be   %3       12345  online
fe   %4       12346  starting
qa   %5       -      offline
```

- **online** — pane alive + watcher PID alive + ready sentinel present
- **starting** — pane alive but bootstrap not finished (claude TUI still booting)
- **offline** — pane dead or never spawned

### Message format

#### Filename

`YYYYMMDD-HHMM__<from>__<to>__<tag>.md`

- `from`: single role (`pm` / `be` / `fe` / `qa`)
- `to`: single role, multi-role joined with `-` (e.g. `be-fe`), or `all`
- `tag`: task ID + verb; no `__`, no spaces, dash-separated; bug tags must start with `bug-P{0,1,2}-`

Examples:

```
20260424-1030__qa__be__bug-P0-B1.1-login-crash.md
20260424-1100__pm__be-fe__iter3-scope-adjust.md
20260424-1500__pm__all__freeze-notice.md
```

#### Frontmatter

```yaml
---
from: qa
to: be
type: bug                  # delivery|question|bug|verify|ack|notice|change|block
severity: P0               # bug only: P0|P1|P2
thread: T-B1.1-login-crash # optional, links related messages
related: [B1.1]
reply_to: <prior filename> # optional, when this is a follow-up
created: 2026-04-24 13:30
---
```

#### Length caps

| type | skeleton | max body lines |
|---|---|---|
| `bug` | symptom / evidence / root-cause / expected | 8 |
| `delivery` | what changed (≤3 items) / how to test / risk | 6 |
| `question` | question / context / options | 5 |
| `verify` | pass-or-fail / evidence | 3 |
| `ack` | what was done / commit / next step | 3 |
| `notice` | fact / impact / action | 5 |
| `change` | current / proposed / impact | 5 |
| `block` | blocked-by / ETA | 2 |

Total body ≤ 400 chars (excluding code blocks). Overflow → `comms/handoff/<date>-<slug>.md` with a one-line link from the message.

#### Example chain: bug → ack → verify

QA reports a P0:

````markdown
---
from: qa
to: be
type: bug
severity: P0
thread: T-B1.1-login-crash
related: [B1.1]
created: 2026-04-24 10:30
---

# B1.1 empty-DB errors/items 500

**Symptom**: GET /api/progress/errors/items returns 500 after login.
**Evidence**: `{"detail": "FileNotFoundError: errors/grammar.md"}`
**Root cause**: handler doesn't check file existence.
**Expected**: empty DB returns four empty arrays.
````

BE acks after fixing:

````markdown
---
from: be
to: qa
type: ack
thread: T-B1.1-login-crash
reply_to: 20260424-1030__qa__be__bug-P0-B1.1-login-crash.md
created: 2026-04-24 13:30
---

# B1.1 fixed

`app/api/progress.py:42` — added file-exists guard. Commit `a3f21b9`. Please verify.
````

QA verifies and closes the chain:

````markdown
---
from: qa
to: be
type: verify
thread: T-B1.1-login-crash
reply_to: 20260424-1330__be__qa__B1.1-ack.md
created: 2026-04-24 14:00
---

# B1.1 verified

Empty DB returns four empty arrays. Confirmed.
````

QA then `mv`'s all three files (and any other `thread: T-B1.1-login-crash` messages) to `comms/done/2026-04/`. The chain is closed.

### Project layout

```
your-project/
├── .claude/settings.local.json    # PreCompact hook + temp permissions (auto-managed)
├── .run/                          # runtime state: watcher pids, locks, holders
├── comms/
│   ├── open/      # pending messages (YYYYMMDD-HHMM__from__to__tag.md)
│   ├── done/      # archived (by month)
│   ├── handoff/   # overflow content (long logs, design docs)
│   └── memory/    # per-role onboarding instructions
└── iteration-plan.md              # task tracker (PM-owned, optional)
```

`.run/`, `comms/`, `.claude/` are runtime-only — the skill auto-adds them to your project `.gitignore`.

### Files this skill creates

**In your project:**

- `comms/{open,done,handoff,memory}/` — message bus state
- `.run/` — watcher pids, locks, holders, helper scripts (`watcher.sh`, `inject_role.sh`, `list-my-open.sh`, `orchestrator.sh`)
- `.claude/settings.local.json` — adds `hooks.PreCompact` (permanent) and `permissions.allow` (temporary, removed on revoke)

**In your home dir:**

- `~/.claude/projects/<cwd-slug>/memory/MEMORY.md` — auto-loaded protocol core (marker-bound, idempotent)
- `~/.claude/projects/<cwd-slug>/memory/role_{pm,be,fe,qa}.md` — persona packs (lazy-loaded by agents)

The skill **never** touches `~/.claude/CLAUDE.md` or `~/.claude/settings.json` (your global config is safe).

### Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `ABORT: 已有 watcher` | Stale lock from a previous crash | `TaskList` to find the old task → `TaskStop <id>`, then re-run skill |
| Sub-pane never goes online | Claude TUI didn't boot in 12s, or hit a permission prompt | tmux switch to that pane (`Ctrl-b <number>`), check, manually run `/agent-orchestrator solo <role>` |
| No new messages detected | Watcher died | Re-run `/agent-orchestrator solo <role>` (will restart watcher) |
| Permissions prompt every command | Bootstrap perms got revoked while watcher still alive | `python3 ~/.claude/skills/agent-orchestrator/assets/install_config.py install` |
| `comms/open/` piling up | Roles not archiving on chain-end | Each role: `bash .run/list-my-open.sh <role>` to see own messages, then `mv` resolved threads |
| Stale perm holders in settings | Crashed pane left a holder file | `python3 .../install_config.py gc` to clean orphans |
| Wrong role activated on hook | Pane → role lookup failed | Verify `.run/role_pane_<role>` matches `tmux display-message -p '#{pane_id}'` |

For the full failure table, see [SKILL.md](SKILL.md) (`## 失败处理速查`).

### FAQ

**Do I need `iteration-plan.md`?**
No. PM works without it; the briefing just won't show "iteration in progress" tasks.

**Can I add custom roles beyond pm/be/fe/qa?**
Not without forking — the role set is hard-coded. But persona packs are easy to customize: edit `assets/role_<role>.md` to fit your team's voice.

**What if I'm not in tmux?**
Solo mode (`/agent-orchestrator solo <role>`) works fine without tmux. Orchestrator mode requires tmux because it spawns panes.

**Does the PreCompact hook leak permissions?**
The hook command is `[ -f .run/inject_role.sh ] && bash .run/inject_role.sh` — it only `cat`s memory files into the prompt, no privilege escalation. Bootstrap permissions (`Bash(mkdir:*)` etc.) are temporary and revoked when the watcher exits.

**Compatible with other Claude Code skills?**
Yes. agent-orchestrator only manages its own keys in `.claude/settings.local.json` (deep-merge, never overwrites). Other skills can write their own keys.

**Do messages survive across sessions?**
Yes. `comms/` files are plain Markdown on disk, persisted independently of any Claude session.

**How do I fully clean up after the skill?**
1. `tmux kill-session` to stop all panes
2. `rm -rf comms/ .run/` in your project
3. Remove the skill's keys from `.claude/settings.local.json` (or just delete the file)
4. Optionally: `rm -rf ~/.claude/projects/<cwd-slug>/memory/`

**Can I use solo mode in CI / non-interactive contexts?**
No. Solo mode requires the `Monitor` tool, which is a Claude Code interactive feature.

### When NOT to use it

- Solo coding tasks that don't need role separation
- Outside tmux (orchestrator mode requires tmux; solo mode works without)
- Projects where you don't want generated state in `comms/` and `.run/`
- CI / non-interactive workflows

### Documentation

- [SKILL.md](SKILL.md) — full command reference and dispatch logic
- [assets/PROTOCOL.md](assets/PROTOCOL.md) — message format, archive rules, escalation, stalled threads
- [assets/protocol_core.md](assets/protocol_core.md) — auto-loaded into Claude Code L3 memory
- [assets/role_*.md](assets/) — per-role persona packs (beliefs, golden questions, push-back posture, trust scaffolding)
- [CHANGELOG.md](CHANGELOG.md) — version history

### License

MIT — see [LICENSE](LICENSE).

---

## 中文

[英文版](#english)

### 是什么

让一个 Claude Code session 当 **PM**，在 tmux 同级 pane 里 spawn `be` / `fe` / `qa` agent。每个 pane 是独立的 Claude Code session，有自己的角色、memory、watcher。

各角色靠在 `comms/open/` 写 markdown 文件交流。每条消息：

- 有 type 信封（`bug` / `delivery` / `verify` / `ack` / `change` / `notice` / `question` / `block`）
- 有长度上限（正文 ≤ 400 字 + per-type 行数上限）
- 有归档责任人（链条末端方在闭环后 mv 整链到 `done/`）

效果：在任何 Claude Code agent team 参与的项目里都能拿到 PR 级纪律（spec / bug / verify / 验收）。

### 为什么

单 context 的 Claude 角色容易糊——"实现接口的 agent 也来测它"，"写 spec 的 agent 也来实现"。这个 skill 强制隔离：**每个 pane 一个角色**，独立 memory + 独立 watcher + 独立人格包，让压缩和漂移之后角色不退化成"通用 helpful 助手"。

### Demo

`/agent-orchestrator be fe qa` —— PM 在上，BE/FE/QA 在下（main-horizontal 布局，4+ pane 自动应用）：

![4-pane 布局](docs/pane_4.png)

`/agent-orchestrator be qa` —— PM 在左竖排，sub 角色在右堆叠（main-vertical 布局，2-3 pane 自动应用）：

![3-pane 布局](docs/pane_3.png)

### 工作原理

四根支柱：

#### 1. 角色 + 人格包

| 角色 | 代号 | 任务前缀 | 模式 | 职责 |
|---|---|---|---|---|
| 产品 | `pm` | `P*` | 协同型（决策交用户） | 维护 `iteration-plan.md`，调度优先级，验收 delivery |
| 后端 | `be` | `B*` | 执行型（按最优方案干） | 实现 `B*` 任务，维护接口契约 |
| 前端 | `fe` | `F*` | 执行型 | 实现 `F*` 任务，对齐 mock |
| 测试 | `qa` | `Q*` | 协同型 | 提 bug（现象 + 证据 + 根因），不写修法 |

每个角色启动时加载**人格包**（`assets/role_<role>.md`）：信条 / 黄金问题 / push back 姿态 / trust scaffolding。这是 PM 跟 BE 思考方式不同的真正原因——而不只是个名字标签。

#### 2. Comms 消息总线

消息就是文件名。`YYYYMMDD-HHMM__<from>__<to>__<tag>.md` 这格式让 `ls` 一眼看清。watcher 的工作就是发现新文件。

8 种 type，每种有强制骨架——见下面的[消息格式](#消息格式)。

归档发生在**链条末端**：闭环的人（比如 QA 在 verify 通过后）一次性把整 thread mv 到 `comms/done/<YYYY-MM>/`。中间方不抢移。

#### 3. Watcher + Monitor

每个角色 pane 跑 `bash .run/watcher.sh <role>`，每 5 秒扫一次 `comms/open/`，找匹配本角色 glob 且 stamp 之后的新文件。Claude Code 的 `Monitor` 工具把 watcher 当后台任务跑；新消息以事件形式出现在 Claude session 里。

watcher 用 `mkdir` 原子锁（跨平台——macOS 没 `flock`）防同角色多 watcher 抢 stamp。

#### 4. PreCompact 钩子 + L3 memory

两块东西把角色身份钉在 Claude Code 生命周期里：

- **L3 memory**（`~/.claude/projects/<cwd-slug>/memory/MEMORY.md`）—— Claude Code 自动加载到该 cwd 下每次 session。安装时 merge 协议核心进去（幂等，标记块隔离）
- **PreCompact 钩子**——压缩前触发。它根据当前 pane id 反查角色，cat `comms/memory/<role>.md`（项目特定的证据合同）注入到对话，再提示 agent re-`Read` 自己的人格包。没这个钩子，角色身份在几次压缩之后就被摘要冲淡了

### 前置依赖

- Claude Code（含 `Monitor` / `ToolSearch` 工具的近期版本）
- `tmux` 3.0+
- `python3` 3.8+
- `bash` 4+（macOS：`brew install bash`）
- macOS 或 Linux

### 安装

本 skill 在 [mikeshoes/skills](https://github.com/mikeshoes/skills) 这个 monorepo 里。clone 后软链到 Claude Code skills 目录，这样 `git pull` 就自动更新：

```bash
git clone git@github.com:mikeshoes/skills.git ~/code/skills
ln -s ~/code/skills/agent-orchestrator ~/.claude/skills/agent-orchestrator
```

或单项目：

```bash
ln -s ~/code/skills/agent-orchestrator <项目根>/.claude/skills/agent-orchestrator
```

启动 Claude Code 后输入 `/agent-orchestrator` 验证是否加载成功。

### 第一次跑

```bash
# 1. 起 tmux，在里面跑 Claude Code
cd ~/your-project
tmux new-session -s pm 'claude'

# 2. 在新 Claude session 里 spawn 整个团队
/agent-orchestrator be fe qa

# 3. 等 ~10s 让 sub pane 自启动，然后：
/agent-orchestrator status
# 期望：
#   pm  %0  -      online (当前 pane)
#   be  %3  12345  online
#   fe  %4  12346  online
#   qa  %5  12347  online
```

幕后做了什么：

1. PM 自启动（写 `comms/memory/pm.md`、起 watcher、武装 `Monitor`）
2. PM spawn 3 个 tmux pane，各跑 `claude` 并自动输入 `/agent-orchestrator solo <role>`
3. 每个 sub 角色自启动，登记 pane id 到 `.run/role_pane_<role>`，并往 `comms/open/` 写一条 `<role>-online` notice
4. PM 的 watcher 扫到 online notice，告知用户团队已就位

### 命令

#### Solo 模式（单 pane bootstrap）

| 输入 | 效果 |
|---|---|
| `/agent-orchestrator solo pm` | 当前 session bootstrap 成 PM |
| `/agent-orchestrator solo be` | 成 BE |
| `/agent-orchestrator solo fe` | 成 FE |
| `/agent-orchestrator solo qa` | 成 QA |

#### Orchestrator 模式（多 pane，需 tmux）

| 输入 | 效果 |
|---|---|
| `/agent-orchestrator` | 只起 PM（当前 pane bootstrap） |
| `/agent-orchestrator be fe qa` | PM + 3 个 sub 角色 |
| `/agent-orchestrator be fe` | PM + 2 个 sub 角色 |
| `/agent-orchestrator add qa` | 已运行的 orchestrator 补加角色 |
| `/agent-orchestrator status` | 查所有角色在线状态 |
| `/agent-orchestrator stop fe` | 停单角色（PM 保留） |
| `/agent-orchestrator stop` | 停所有 sub 角色（PM 保留） |

彻底关闭（含 PM）：`tmux kill-session`。

#### `status` 输出

```
role pane     pid    status
---- ----     ---    ------
pm   %0       -      online (当前 pane)
be   %3       12345  online
fe   %4       12346  starting
qa   %5       -      offline
```

- **online** —— pane 活 + watcher PID 活 + ready sentinel 在
- **starting** —— pane 活但 bootstrap 没完（claude TUI 还在启动）
- **offline** —— pane 死或从未 spawn

### 消息格式

#### 文件名

`YYYYMMDD-HHMM__<from>__<to>__<tag>.md`

- `from`：单角色（`pm` / `be` / `fe` / `qa`）
- `to`：单角色 / 多角色用 `-` 连（如 `be-fe`） / `all`
- `tag`：任务 ID + 动作；不含 `__`、不含空格、用 `-` 连；bug 的 tag 必须以 `bug-P{0,1,2}-` 开头

例：

```
20260424-1030__qa__be__bug-P0-B1.1-login-crash.md
20260424-1100__pm__be-fe__iter3-scope-adjust.md
20260424-1500__pm__all__freeze-notice.md
```

#### Frontmatter

```yaml
---
from: qa
to: be
type: bug                  # delivery|question|bug|verify|ack|notice|change|block
severity: P0               # 仅 bug：P0|P1|P2
thread: T-B1.1-login-crash # 可选，关联同议题消息
related: [B1.1]
reply_to: <原消息 filename> # 可选，是 follow-up 时填
created: 2026-04-24 13:30
---
```

#### 长度上限

| type | 骨架 | 正文行数上限 |
|---|---|---|
| `bug` | 现象 / 证据 / 根因 / 期望 | 8 |
| `delivery` | 改了什么（≤3 项） / 联调入口 / 风险 | 6 |
| `question` | 问题 / 背景 / 选项 | 5 |
| `verify` | 过/不过 / 证据 | 3 |
| `ack` | 做了什么 / commit / 下一步 | 3 |
| `notice` | 事实 / 影响 / 行动 | 5 |
| `change` | 现状 / 提议 / 影响范围 | 5 |
| `block` | 被谁阻塞 / 预计解 | 2 |

总正文 ≤ 400 字（不含 code block）。溢出 → `comms/handoff/<日期>-<slug>.md`，消息里只放一行链接。

#### 例：bug → ack → verify 链

QA 报 P0：

````markdown
---
from: qa
to: be
type: bug
severity: P0
thread: T-B1.1-login-crash
related: [B1.1]
created: 2026-04-24 10:30
---

# B1.1 空库 errors/items 500

**现象**：登录后 GET /api/progress/errors/items 返回 500。
**证据**：`{"detail": "FileNotFoundError: errors/grammar.md"}`
**根因定位**：接口入口未判文件存在性。
**期望**：空库返回四个空数组。
````

BE 修完回 ack：

````markdown
---
from: be
to: qa
type: ack
thread: T-B1.1-login-crash
reply_to: 20260424-1030__qa__be__bug-P0-B1.1-login-crash.md
created: 2026-04-24 13:30
---

# B1.1 已修

`app/api/progress.py:42` 加了文件存在判空。Commit `a3f21b9`。请验证。
````

QA 验证并闭环：

````markdown
---
from: qa
to: be
type: verify
thread: T-B1.1-login-crash
reply_to: 20260424-1330__be__qa__B1.1-ack.md
created: 2026-04-24 14:00
---

# B1.1 验证通过

空库返回四空数组确认。
````

QA 此时一次性 `mv` 这三条文件（外加 thread 内任何其他消息）到 `comms/done/2026-04/`。链条闭环。

### 项目目录结构

```
your-project/
├── .claude/settings.local.json    # PreCompact 钩子 + 临时 permissions（自动管理）
├── .run/                          # 运行时状态：watcher pid / lock / holder
├── comms/
│   ├── open/      # 待处理消息（YYYYMMDD-HHMM__from__to__tag.md）
│   ├── done/      # 已归档（按月）
│   ├── handoff/   # 溢出件（长日志 / 设计稿）
│   └── memory/    # 各角色开场指令
└── iteration-plan.md              # 任务跟踪（PM 拥有，可选）
```

`.run/`、`comms/`、`.claude/` 是运行时产物——skill 自动加到项目 `.gitignore`。

### Skill 创建的文件

**项目里：**

- `comms/{open,done,handoff,memory}/` —— 消息总线状态
- `.run/` —— watcher pid / lock / holder / 辅助脚本（`watcher.sh` / `inject_role.sh` / `list-my-open.sh` / `orchestrator.sh`）
- `.claude/settings.local.json` —— 加 `hooks.PreCompact`（永久）和 `permissions.allow`（临时，revoke 时移除）

**家目录里：**

- `~/.claude/projects/<cwd-slug>/memory/MEMORY.md` —— 自动加载的协议核心（标记块隔离，幂等）
- `~/.claude/projects/<cwd-slug>/memory/role_{pm,be,fe,qa}.md` —— 人格包（agent 按需加载）

skill **从不**碰 `~/.claude/CLAUDE.md` 或 `~/.claude/settings.json`（你的全局配置安全）。

### 排障

| 症状 | 诊断 | 修法 |
|---|---|---|
| `ABORT: 已有 watcher` | 之前 crash 留下死锁 | `TaskList` 找老 task → `TaskStop <id>`，重新跑 skill |
| sub pane 一直不 online | claude TUI 12s 没起来 / 卡 permission prompt | tmux 切到该 pane（`Ctrl-b 数字`）查看，手动 `/agent-orchestrator solo <role>` |
| 没收到新消息 | watcher 死了 | 重跑 `/agent-orchestrator solo <role>`（会重启 watcher） |
| 每条命令都弹权限 | bootstrap perm 被 revoke 了但 watcher 还活 | `python3 ~/.claude/skills/agent-orchestrator/assets/install_config.py install` |
| `comms/open/` 堆积 | 各角色没按链条末端归档 | 各角色：`bash .run/list-my-open.sh <role>` 看自己的消息，`mv` 已闭环的 thread |
| settings 里有陈尸 holder | 崩溃的 pane 留下 holder 文件 | `python3 .../install_config.py gc` 清孤儿 |
| 钩子激活的角色不对 | pane → role 反查失败 | 查 `.run/role_pane_<role>` 是否对得上 `tmux display-message -p '#{pane_id}'` |

完整失败处理表见 [SKILL.md](SKILL.md) 的 `## 失败处理速查`。

### FAQ

**一定要有 `iteration-plan.md` 吗？**
不需要。PM 没它也能跑；只是简报里不会列"进行中的迭代任务"。

**能加 pm/be/fe/qa 之外的自定义角色吗？**
不 fork 不行——角色集是硬编码的。但人格包易改：编辑 `assets/role_<role>.md` 适配你的团队风格。

**不在 tmux 里能用吗？**
Solo 模式（`/agent-orchestrator solo <role>`）不需要 tmux。Orchestrator 模式必须，因为要 spawn pane。

**PreCompact 钩子有权限风险吗？**
钩子命令是 `[ -f .run/inject_role.sh ] && bash .run/inject_role.sh`——只 `cat` memory 文件到 prompt，不 escalate 权限。Bootstrap permissions（`Bash(mkdir:*)` 等）是临时的，watcher 退出时撤销。

**跟其他 Claude Code skill 兼容吗？**
兼容。agent-orchestrator 只管自己在 `.claude/settings.local.json` 里的字段（深度合并，不覆盖）。其他 skill 可以写自己的字段。

**消息能跨 session 留存吗？**
能。`comms/` 文件就是磁盘上的 markdown，独立于任何 Claude session 持久化。

**完全卸载怎么做？**
1. `tmux kill-session` 停所有 pane
2. 项目里 `rm -rf comms/ .run/`
3. 删掉 `.claude/settings.local.json` 里 skill 装的字段（或整文件）
4. 可选：`rm -rf ~/.claude/projects/<cwd-slug>/memory/`

**Solo 模式能在 CI 里跑吗？**
不能。Solo 依赖 `Monitor` 工具，那是 Claude Code 交互式特性。

### 不适合的场景

- 单人单角色编码任务
- 不在 tmux 里跑（orchestrator 必须；solo 可不要）
- 不想项目里多出 `comms/` 和 `.run/` 的项目
- CI / 非交互式工作流

### 文档

- [SKILL.md](SKILL.md) —— 完整命令和分发逻辑
- [assets/PROTOCOL.md](assets/PROTOCOL.md) —— 消息格式 / 归档规则 / Escalation / Stalled Thread
- [assets/protocol_core.md](assets/protocol_core.md) —— 自动加载到 Claude Code L3 memory
- [assets/role_*.md](assets/) —— 各角色人格能力包（信条 / 黄金问题 / push back 姿态 / trust scaffolding）
- [CHANGELOG.md](CHANGELOG.md) —— 版本历史

### 许可证

MIT —— 见 [LICENSE](LICENSE)。
