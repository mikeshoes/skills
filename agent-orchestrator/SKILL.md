---
name: agent-orchestrator
description: Claude Code 场景下 comms 协议的总入口。两种模式合一 —— (1) solo：单角色启动器，在当前 session bootstrap comms 协议 + 武装 Monitor + 输出简报；(2) orchestrator：tmux 多 pane 编排，当前 pane 当 PM，用 start/add/status/stop 管 be/fe/qa 子 pane。整个 skill 目录自包含（assets/ 含 PROTOCOL / memory 模板 / watcher.sh / orchestrator.sh），无外部依赖。在用户输入 `/agent-orchestrator <verb> [args...]` 时调用。
version: 0.1.0
---

# Agent Orchestrator

一个 skill，两种模式：

- **solo mode** —— 单角色 bootstrap + 武装 Monitor + 简报（= 原 agent-watcher）
- **orchestrator mode** —— 在 tmux 里当前 pane 当 PM，spawn be/fe/qa 子 pane，每个子 pane 自动 `/agent-orchestrator solo <role>`

整个 `agent-orchestrator/` 目录（含 `assets/`）拷到任何 Claude Code 项目就能用，无需其他 skill 配套。

## 何时用

| 用户输入 | 模式 | 行为 |
|---|---|---|
| `/agent-orchestrator solo <role>` | solo | 当前 session 作为 role 跑：bootstrap + Monitor + 简报 |
| `/agent-orchestrator` | orch | 只起 pm（当前 pane），不 spawn 其他 |
| `/agent-orchestrator be fe qa` | orch | pm + spawn 3 个新 pane（tiled） |
| `/agent-orchestrator be fe` | orch | pm + 2 个新 pane |
| `/agent-orchestrator add qa` | orch | 事后补加 |
| `/agent-orchestrator status` | orch | 所有角色在线状态 |
| `/agent-orchestrator stop` | orch | 停所有非 pm |
| `/agent-orchestrator stop fe` | orch | 只停 fe |

角色码合法集：`pm` / `be` / `fe` / `qa`。`solo` 可以接任一；`start`（默认）的额外 roles 必须 ∈ {be, fe, qa}（pm 是当前 pane 隐含）。

## 角色三维定义

| role | ROLE_NAME | TASK_PREFIX | DUTY | BOUNDARY | COLLAB_MODE |
|---|---|---|---|---|---|
| `pm` | 产品 | `P` | 维护 `iteration-plan.md`；调度优先级；验收 `delivery`；处理 `change`；写 `notice` | 不直接改 fe/be/qa 代码；不改接口契约文档；任何范围/契约变更必须等用户同意 | 协同型 |
| `be` | 后端 | `B` | 实现 B* 任务；维护接口契约文档；修 `to: be` 的 bug | 不改前端目录代码；不改 qa 测试；不改 `iteration-plan.md`（走 `change`） | 执行型 |
| `fe` | 前端 | `F` | 实现 F* 任务；维护 mock 对齐；修 `to: fe` 的 bug | 不改后端目录代码；不改接口契约文档（走 `change`） | 执行型 |
| `qa` | 测试 | `Q` | 跑测试；提 bug（含现象/证据/根因定位）；验证修复；巡检回归 | **白盒可读源码，但 bug 只写现象/证据/根因——不给修法 diff** | 协同型 |

## 模式分发（步骤 A）

从 args 取第一个 token：

- `solo` → 走 **Solo Mode** 步骤（下一个 token 是 role）
- `add` / `status` / `stop` → 走 **Orchestrator Mode 子命令**（见下）
- 其余情况（空 / 纯 roles 列表） → 走 **Orchestrator Mode start**（当前 pane = pm，其余 roles spawn 到新 pane）

## 通用：定位 skill assets（步骤 B，两模式共用）

```bash
for d in .claude/skills/agent-orchestrator ~/.claude/skills/agent-orchestrator; do
  [ -d "$d/assets" ] && SKILL_DIR="$d" && break
done
```

找不到 → 报"agent-orchestrator skill 未完整安装，缺 assets/"，停。

---

# Solo Mode 步骤

（用户直接 `/agent-orchestrator solo <role>`，或被 orchestrator spawn 的新 pane 自动触发。等价于原 agent-watcher。）

### S1. 解析 role

从第二个 token 取；strip + lowercase；校验 ∈ {pm, be, fe, qa}。

### S2. Bootstrap（幂等）

```bash
PROJECT_ROOT=$(pwd)
mkdir -p comms/open comms/done comms/handoff comms/memory .run
```

协议文件 **存在不覆盖**：

| 目标 | 源 | 存在时 |
|---|---|---|
| `comms/PROTOCOL.md` | `{SKILL_DIR}/assets/PROTOCOL.md` | 跳（尊重用户自定义） |
| `comms/memory/{ROLE}.md` | `{SKILL_DIR}/assets/memory_template.md` + 占位符替换（用步骤 A 的三维表） | 跳 |

`.run/watcher.sh` **每次覆盖**：

```bash
sed "s|__PROJECT_ROOT__|$PROJECT_ROOT|g" "{SKILL_DIR}/assets/watcher.sh" > .run/watcher.sh
chmod +x .run/watcher.sh
```

`.gitignore` 补三行（幂等）：

```
comms/
.run/
.claude/
```

**安装 PreCompact hook + 临时 Bash permissions**（幂等，登记 per-pane holder）：

```bash
python3 "{SKILL_DIR}/assets/install_config.py" install
```

会 merge 到 `.claude/settings.local.json`：
- `hooks.PreCompact` 永久添加（命令本身只 cat memory，安全）
- `permissions.allow` 加 14 条 bootstrap 期间的 bash 命令（mkdir/touch/sed/cat/tmux/...）—— **临时**，由后续步骤 S10 撤销
- 已有 `permissions` / `hooks` 项不动
- `.run/perms_holders/<pane_id>` 登记本 pane 占坑；同 pane 多次 install 幂等；顺手 GC 已死 pane 留下的孤儿 holder（cross-check `tmux list-panes`）

**第一次跑无法避免一次"允许 python3 install_config.py 吗？"的 prompt**——它本身就是装 perm 的入口；之后所有 bootstrap bash 都被 perm 覆盖静默通过。

**tmux pane 登记**（当前 pane 属于哪个 role，PreCompact hook 靠这个反查）：

```bash
if [ -n "$TMUX" ]; then
  tmux display-message -p '#{pane_id}' > ".run/role_pane_${ROLE}" 2>/dev/null || true
fi
```

**部署 inject_role.sh**（PreCompact hook 调它注入 memory + role pack）：

```bash
cp "{SKILL_DIR}/assets/inject_role.sh" .run/inject_role.sh
chmod +x .run/inject_role.sh
```

**部署 list-my-open.sh**（自归档辅助，每个角色按需 `bash .run/list-my-open.sh <role>` 列自己发的 open 消息）：

```bash
sed "s|__PROJECT_ROOT__|$PROJECT_ROOT|g" "{SKILL_DIR}/assets/list-my-open.sh" > .run/list-my-open.sh
chmod +x .run/list-my-open.sh
```

memory 占位符替换：`{ROLE}` / `{ROLE_NAME}` / `{TASK_PREFIX}` / `{ROLE_DUTY}` / `{ROLE_BOUNDARY}` / `{ROLE_COLLAB_MODE}` / `{COLLAB_MODE}`（查"角色三维定义"表）。

**Read 角色人格能力包**（注入 agent 思维方式 —— 8 节信条 + 沟通契约）：

```
Read {SKILL_DIR}/assets/role_{ROLE}.md
```

人格 = agent 的思考底色（信条 / 黄金问题 / push back 姿态 / trust scaffolding）。Read 后 agent 立即以该角色视角思考所有后续输入。

**Trust scaffolding 校准提示**（首次 bootstrap 才提，已有 memory 跳过）：

如果 `comms/memory/{ROLE}.md` 是首次创建（步骤 2 标 `[新建]`）→ 在简报末尾追加一段：

```
ℹ️ Trust scaffolding 校准

role pack 给的 trust scaffolding 是通用版（"我接受真机录屏 / commit + trace ID"等）。
项目特定证据合同建议你（用户）跟 {ROLE_NAME} 校准一下：

  本项目实际能提供的证据是什么？
  - 比如：项目无 trace 系统 → 降级为 "commit hash + iOS 真机录屏"
  - 比如：QA 不在团队 → 验证证据由 PM 兜底

确认后写到 comms/memory/{ROLE}.md 末尾的 「项目证据合同」 段。
（不校准也能跑，但 trust 不达标可能 verify 阻塞。）
```

memory 已存在则跳过此提示。

### S3. git pull（仅 git repo）

```bash
[ -d .git ] && git pull --ff-only 2>&1 | tail -5
```

失败（冲突/未提交变更）→ 告知用户先解决后重调；不 stash、不 reset。

### S4. 加载 deferred tools

```
ToolSearch select:Monitor,TaskList,ScheduleWakeup
```

`Monitor` 不可用（非 Claude Code runtime）→ 报错"solo 模式依赖 Monitor 工具，当前 runtime 不支持；请手动 `bash .run/watcher.sh <role>` 起 watcher"，停。

### S5. stamp + 一次扫

```bash
touch .run/comms_{ROLE}_watch.stamp
```

**顺序关键**：touch 必在 Glob 之前，关掉漏抓窗口。

Glob：
- `comms/open/*__*__*{ROLE}*__*.md`
- `comms/open/*__*__all__*.md`

记录文件元信息（时间、from、tag、severity）。**不 Read 消息正文**——简报只列元信息。

### S6. 武装 Monitor

调 `Monitor` 工具：
- `description`: `comms/open {ROLE} 消息监听`
- `persistent`: `true`
- `timeout_ms`: `3600000`
- `command`: `bash .run/watcher.sh {ROLE}`

失败：
- `ABORT: 已有 watcher` → `TaskList` 找老 task，提示 `TaskStop <id>`，**不要删 lock 文件**
- watcher.sh 不存在 → 回 S2 重新 bootstrap

### S7. 读 iteration-plan（可选）

```bash
[ -f iteration-plan.md ] || echo "无 iteration-plan.md"
```

存在 → Grep `^\| {TASK_PREFIX}[0-9]+\.[0-9]+ `：`✅` 不列；`⏸️` 标 [⏸️]；其他列（最多 10 条，`⏸️` 优先）。

### S8. 输出简报

```
✅ {ROLE}（{ROLE_NAME}）已就位（solo mode）
🔧 Bootstrap：PROTOCOL.md [跳/新建] · memory/{ROLE}.md [跳/新建] · watcher.sh [刷新]
✅ Monitor 已武装（task <id>）

🎯 职责：{DUTY}
🚫 边界：{BOUNDARY}
🤝 协作：{COLLAB_MODE}

📨 comms/open 待办（{N} 条）：
- [P0] 20260424-1030  qa→{ROLE}  bug-B1.1-slug
- [—]  20260424-1100  pm→all    scope-adjust

📋 iteration-plan 我的进行中（{TASK_PREFIX}*）：
- {TASK_PREFIX}1.4 [⏸️] {标题}
- {TASK_PREFIX}1.6 {标题}

➡️ L2 兜底心跳（可选）：
/loop 扫 comms/open 处理 {ROLE} 消息（见 comms/PROTOCOL.md）

⚠️ {ROLE_REMINDER}
```

### S9. 上线通知 PM（仅 role != pm）

简报输出后，立即写一条最简 `notice` 到 `comms/open`，让 PM 的 Monitor watcher 立刻扫到：

```bash
if [ "$ROLE" != "pm" ]; then
  TS=$(date +%Y%m%d-%H%M)
  PID=$(cat .run/comms_${ROLE}_watch.pid 2>/dev/null || echo "?")
  OPEN_N=$(ls comms/open/*__*__*${ROLE}*__*.md 2>/dev/null | wc -l | tr -d ' ')
  SYS=$(bash .run/orchestrator.sh status 2>/dev/null | tail -1 || echo "orchestrator 未启用")
  cat > "comms/open/${TS}__${ROLE}__pm__${ROLE}-online.md" <<EOF
---
from: ${ROLE}
to: pm
type: notice
created: $(date +"%Y-%m-%d %H:%M")
---

# ${ROLE} online

watcher PID ${PID}；open ${ROLE} 待办 ${OPEN_N} 条。
系统：${SYS}
EOF
fi
```

**效果**：PM pane 的 Monitor 几秒内扫到此文件，在下一轮响应里告知 PM「be online / fe online / ...」+ 当前系统状态快照。PM 看过后按 `notice` 处理（摘要 + mv 到 done；或累积几条一起看）。

**不写 notice 的例外**：
- `role == pm`：pm 不通知自己
- `comms/memory/pm.md` 不存在：说明 PM 还没 bootstrap 过，写了也没人收；跳过
- 项目根无 `.run/` 目录：bootstrap 尚未完成；跳过

### S10. 撤销 bootstrap permissions（safety，必做）

solo 流程到此结束 —— **立即撤销** S2 装的临时 bash perm，把 `.claude/settings.local.json` 还原到调用前状态：

```bash
python3 "{SKILL_DIR}/assets/install_config.py" revoke
```

- 删掉本 pane 的 holder 文件；扫尸顺手把已死 pane 的孤儿 holder 也清了
- 无任何活 holder 时才真正移除 perm（多 pane 并发时由最后 revoke 的那个 pane 触发）
- 还有其他 holder → 输出"⏳ 还有 N 个 holder 活着，暂不移除 permissions"
- **PreCompact hook 永久保留**（无权限风险）
- `watcher.sh` 的 exit trap 也会兜底调一次 `revoke <PANE_ID>`（幂等），兜 crash / Ctrl-C / tmux kill-pane 场景

撤销后效果：bash 命令恢复正常 prompt 行为。下次 `/agent-orchestrator` 触发会重新 install→revoke 一次性循环。

**手动扫尸**（排错/复原用，不删自己）：

```bash
python3 "{SKILL_DIR}/assets/install_config.py" gc
```

只清孤儿 holder；全清光则顺手移除 perms。

#### ROLE_REMINDER 表

| role | 文案 |
|---|---|
| `pm` | PM 与用户协同决策；不动代码；任何范围/契约变更等用户同意 |
| `be` | bug/delivery/question 默认**直接按最优方案干，不等 ack**；不动前端目录；只 `change` 必等用户同意 |
| `fe` | 同 be；不动后端目录；后端接口疑问发 `question` 给 be（**不是问用户**） |
| `qa` | 与用户协同；提 bug 只报现象/证据/根因，**不给修法 diff** |

---

# Orchestrator Mode 步骤

（用户 `/agent-orchestrator [roles...]` 或 `add/status/stop`。分发到 `assets/orchestrator.sh` 执行。）

### O1. 安置 orchestrator.sh + 装 PreCompact hook

**每次都覆盖 `.run/orchestrator.sh`**（保证 PROJECT_ROOT 是当前 cwd）：

```bash
PROJECT_ROOT=$(pwd)
mkdir -p .run
sed "s|__PROJECT_ROOT__|$PROJECT_ROOT|g" "{SKILL_DIR}/assets/orchestrator.sh" > .run/orchestrator.sh
chmod +x .run/orchestrator.sh
```

**安装 hook + 临时 perms**（幂等，登记 PM pane 的 holder）：

```bash
python3 "{SKILL_DIR}/assets/install_config.py" install
```

（solo S2 也会装；orchestrator 模式 PM 直接进时由这里保证 perm 在 spawn 前落地，让后续 `bash .run/orchestrator.sh` 等命令静默通过；最终 O5 撤销。PM pane 上多次 install 是同一 holder 文件 touch，幂等无重复计数）

### O2. 检查 tmux 前提

`[ -z "$TMUX" ]` → 输出指引并停：

```
❌ 当前 claude 不在 tmux 里跑，无法 spawn 子 pane。

请：
  1. 在当前 claude 输入 /exit 或 Ctrl-D 退出
  2. 在终端执行：tmux new-session 'claude'
  3. 新 claude 里重新输入 /agent-orchestrator
```

### O3. 分发到脚本

| verb | 脚本命令 |
|---|---|
| （空或纯 roles） | `bash .run/orchestrator.sh start [roles...]` |
| `add <role>` | `bash .run/orchestrator.sh add <role>` |
| `status` | `bash .run/orchestrator.sh status` |
| `stop [role]` | `bash .run/orchestrator.sh stop [role]` |

### O4. 当前 pane 进入 solo pm（仅 start / add 动作后）

orchestrator 脚本只负责**spawn 其他 pane + 记簿**，**不会让当前 pane 自己 bootstrap 成 pm**。所以 start/add 脚本跑完后要**接着执行 Solo Mode S1-S9 for role=pm**，让 pm 真正有：
- `comms/memory/pm.md` 写好
- `.run/watcher.sh` 运行中（Monitor 武装）
- `comms/open/*pm*` 扫一遍

这样 pm 的 Monitor 就能扫到后续 be/fe/qa 的上线 notice。

**例外**：如果 `.run/role_ready_pm` 已存在且 watcher PID 活，说明 pm 已 bootstrap 过，跳过 solo 流程（避免 ToolSearch 重跑 / Monitor 重武装产生 `ABORT: 已有 watcher`）。

### O5. 撤销 PM 这一侧的 install（balance O1）

```bash
python3 "{SKILL_DIR}/assets/install_config.py" revoke
```

PM 的 holder 文件就一个（pane_id 固定），不管 O1 / O4 装了几次都是同一个文件。这里 revoke 把它清掉。sub-pane 各自的 holder 由它们自己的 solo 流程管。

**幂等说明**：O1 和 O4-S2 都调过 install，但触的是同一个 holder；O5 的 revoke 把它清干净。如果 O4 因为"pm 已 bootstrap"跳过了，也没关系——holder 早就在，O5 照样清。最终不会有孤儿。

### O6. 追加回显

start / add 动作后，**追加 PM 路由纪律**：

```
⚠️ PM 路由纪律：

发 comms/open 消息前先 bash .run/orchestrator.sh status 查在线：
- 目标全 online → 正常发
- 有 offline 的 → 告知用户"{role} 未启动，消息将堆积等它上线；是否继续？"
- `to: all` 禁用：改用定向多人 `to: be-fe-qa`（按当前 online 列表拼，离线不列）

命令速查：
  /agent-orchestrator status           # 查角色在线
  /agent-orchestrator add <role>       # 补加角色
  /agent-orchestrator stop <role>      # 停单角色
  /agent-orchestrator stop             # 停所有非 pm
  tmux kill-session                    # 彻底关闭（含 pm）
```

## 在线状态三层判定（脚本内含）

| 状态 | 条件 |
|---|---|
| `online` | `.run/role_ready_{role}` 存在 + watcher PID 活 |
| `starting` | pane 活但上面不齐 |
| `offline` | pane 不活 / 从未 spawn |
| `online (当前 pane)` | pm 专用——orchestrator 在跑即 online |

`role_ready_{role}` sentinel 由 `.run/watcher.sh` 启动时 `touch`、退出 trap 时 `rm` —— 与 watcher 进程生命一致。

---

## 失败处理速查（两模式合并）

| 失败 | 处理 |
|---|---|
| args 缺失/非法 | 问用户 or 报错 |
| SKILL_DIR 找不到 | 报 skill 未完整安装，停 |
| Bootstrap 写失败（权限） | 告知 cwd 不可写 |
| git pull 冲突 | 告知先解决，不 stash/reset |
| Monitor 不可用（solo） | 报错并给手动启动 watcher 指引 |
| 不在 tmux（orch） | 报错 + 退出/重进指引 |
| `ABORT: 已有 watcher` | TaskList 查旧 task → 提示 TaskStop |
| claude 新 pane TUI 起不来 | 脚本 sleep 最多 ~15s；仍不起，tmux 切过去手动输 `/agent-orchestrator solo <role>` |
| iteration-plan 无匹配 | 简报写"无 {TASK_PREFIX}* 任务"，继续 |

## 不做的事

- **不替用户输 /loop** —— 只给引导让用户复制粘
- **不读 comms/open 消息正文** —— 只列元信息
- **不改 iteration-plan.md** —— 只 Grep 读
- **不写用户全局配置**（`~/.claude/CLAUDE.md` / `~/.claude/settings.json`）——但**允许写 cwd-bound L3 memory** `~/.claude/projects/<cwd-slug>/memory/MEMORY.md`：协议核心放这里 auto-load，省掉每次注入
- **不覆盖已存在 `comms/PROTOCOL.md` / `comms/memory/{role}.md`**
- **不 spawn pm** —— pm 是 orchestrator 当前 session 本身
- **不 kill tmux session** —— stop 只停 pane
- **不跨角色动手** —— 简报里也不评论别角色任务
- **同 session ToolSearch 只调一次**
