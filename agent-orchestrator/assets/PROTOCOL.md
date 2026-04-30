# Comms 协议

> 单人多角色 / 多 runtime 通用。消息总线 + 角色协作纪律。
> **comms/ 整个不进仓**（纯本地状态），所有归档用 `mv`。

## 目录

```
comms/
├── PROTOCOL.md            # 本文件
├── memory/{role}.md       # 各角色开场指令
├── open/                  # 待处理
├── done/{YYYY-MM}/        # 已归档
└── handoff/               # 溢出件（长内容外链）

.run/
├── watcher.sh
└── comms_{role}_watch.{stamp|lock|pid|log}
```

## 角色

| 角色 | 代号 | 任务前缀 | 协作模式 |
|------|------|---------|---------|
| 产品 | `pm` | `P*` | 协同型：决策交用户拍板 |
| 后端 | `be` | `B*` | 执行型：直接按最优方案干 |
| 前端 | `fe` | `F*` | 执行型：同上 |
| 测试 | `qa` | `Q*` | 协同型：提 bug 不给修法 |
| 广播 | `all` | — | 四角色全扫到 |

**执行型**（be/fe）：除 `change` 外所有消息默认直接干，不等用户 ack；模糊地带发 `question` 给对应角色（不是问用户）。
**协同型**（pm/qa）：决策交用户拍板；qa 提 bug 只写现象/证据/根因，**不给修法 diff**。

## 文件命名

```
YYYYMMDD-HHMM__<from>__<to>__<tag>.md
```

- `from`: 单角色（`pm|be|fe|qa`）
- `to`: 单角色，或多角色用 `-` 连（`be-fe`、`be-fe-qa`），或 `all`
- `tag`: 任务 ID + 动作，禁用 `__`（段分隔符），禁空格，用 `-`；bug 以 `bug-P{0,1,2}-` 开头
- 角色码强制小写

**例**：
- `20260424-1030__qa__be__bug-P0-B1.1-login-crash.md`
- `20260424-1100__pm__be-fe__iter3-scope-adjust.md`
- `20260424-1500__pm__all__freeze-notice.md`

## Watcher Glob

```bash
include: *__*__*${ROLE}*__*.md    # 精准匹配 role 在 to 段（单/多角色皆可）
include: *__*__all__*.md          # 广播
exclude: *__${ROLE}__*__*.md      # 自发消息
```

角色码 `pm/be/fe/qa/all` 互不为子串，所以 `*${ROLE}*` 不会误匹配（已验证 shell glob 回溯行为）。

## Frontmatter

```yaml
---
from: qa
to: be-fe                        # 单 / 多 / all
type: bug                        # delivery|question|bug|verify|ack|notice|change|block
severity: P0                     # 仅 bug：P0|P1|P2
thread: T-B1.1-login-crash       # 可选；同议题所有消息共享，归档时整链 mv
related: [B1.1]
reply_to: 20260424-1030__qa__be__bug-P0-B1.1-login-crash.md   # 可选
created: 2026-04-24 13:30
---
```

## 消息内容硬约束

### Per-type 骨架

| type | 骨架 | 正文上限 |
|------|------|---------|
| `bug` | 现象 / 证据 / 根因定位 / 期望 | ≤ 8 行 |
| `delivery` | 改了什么（≤3 项）/ 联调入口 / 风险 | ≤ 6 行 |
| `question` | 问题（1 行）/ 背景 / 选项 | ≤ 5 行 |
| `verify` | 过/不过 / 证据 | ≤ 3 行 |
| `ack` | 做了什么 / commit / 下一步 | ≤ 3 行 |
| `notice` | 事实 / 影响 / 行动 | ≤ 5 行 |
| `change` | 现状 / 提议 / 影响范围 | ≤ 5 行 |
| `block` | 被谁 / 预计解 | ≤ 2 行 |

- **总字数 ≤ 400 字**（不含 code block）
- **标题 ≤ 20 字**，完成式事实（"B1.1 空库 500 已修"），禁"关于 X 的说明"式废话标题

### 格式硬禁

- ❌ markdown 表格（对照数据才允许，≤ 4 行）
- ❌ heading 深于 `##`
- ❌ bullet 超过 5 项
- ❌ 单个 code block 超过 10 行
- ❌ 冗余连接词：`综上所述` / `据此判断` / `值得一提的是` / `不难看出` / `这里需要注意` / `从上面可以看出`
- ❌ 铺垫背景——第一句必须是事实或结论
- ❌ 复述 `reply_to` 内容——`reply_to` 是链接不是副本

### 溢出外链

code / 日志 > 10 行、bullet > 5 项、表格 > 4 行、详细说明 / 设计稿  
→ 存 `comms/handoff/{YYYYMMDD}-{slug}.md`，消息里一行引用：

```
详见 comms/handoff/20260424-B3.21-design.md
```

`handoff/` 也不进仓，常驻本地，iter 收尾时手动清理。

## 消息处理决策表

| type | severity | 对应 `{ROLE}` | 动作 |
|------|---------|-------------|------|
| `bug` | `P0` | 是 | **立刻停手头事**，按协作模式处理 |
| `bug` | `P1` | 是 | 处理完当前小任务后修 |
| `bug` | `P2` | 是 | 累积，与下一任务合并修 |
| `delivery` | — | 是 | 联调（执行型）/ 验收（pm 协同） |
| `question` | — | 是 | 默认自答；纯需求决策性问题转用户 |
| `change` | — | 是 | **必须等用户同意** |
| `verify` | — | 是 | qa 通过 → 归档整链；失败 → 升级新 bug |
| `ack` | — | 是 | 摘要；配合归档父链 |
| `notice` | — | 是 / `all` | 摘要 |
| `block` | — | 是 | `iteration-plan.md` 任务行加 ⏸️ 链接 |
| 任何 | — | 不是你的 `to` | 不处理 |

## 归档规则（链条末端原则）

**核心**：消息链 X→Y，归档人默认是 **Y 在确认履行完毕时一次性 mv 整链**。中间方不抢移。

| 消息 type | 归档人 | 时机 | 范围 |
|---|---|---|---|
| `bug` | **qa** | 验证通过后 | 原 bug + 所有 ack + verify 整链 |
| `bug` 验失败 | 不归档 | qa 升级新 bug | 原链全留 open |
| `delivery` | **下游联调方** | 发 verify/ack 时 | 整链 |
| `question` | **提问方** | 收到满意答复 | 整链 |
| `change` | **发起方** | 用户批准并落地后 | 整链 |
| `notice` / 广播 | **发送方** | iter 收尾清理自己发的 | 自己发的 |
| `block` | **被阻塞 task owner**（be/fe） | 解除阻塞后 | 整链 |

**多角色 `to` 消息**：发起方在**所有 to 列表角色都已回复**后 mv；或发起方判断议题履行完毕时 mv。

**有 `thread` 字段的**：mv 时用 `grep -l "thread: T-xxx" comms/open/*.md` 找齐整线程一次性 mv。

**命令**：用普通 `mv` 不用 `git mv`（comms/ 不进仓）。

### 自归档（发送方主动扫）

watcher glob 排除自发消息（`! *__{ROLE}__*__*.md`）—— **发送方不会被通知到自己发的**。
当本角色是某条消息的归档人（按上表，比如 `change` 发起方、`block` 解除方、`notice` 发送方），必须**主动扫 + 判断时机**。

**找自己发的**：
```bash
ls comms/open/*__{ROLE}__*__*.md 2>/dev/null
# 或用 helper（自动按 age 排序 + 标可归档）：
bash .run/list-my-open.sh {ROLE}
```

**自归档触发信号**（per type）：

| 自发消息 | 归档触发 |
|---|---|
| `notice` spec-review-request（pm） | spec finalize 后（用户批准 + parse-into-tasks 完成） |
| `notice` iter-kickoff / iter-retro（pm） | iter 启动 / 关闭签字后 |
| `notice` 仲裁决议（pm） | 决议被两方落实（看到 follow-up ack） |
| `notice` to:all 广播变更 | 信息传递完成（一般 24-48h） |
| `change` | 用户批准 + 落地后（契约文档 / iter-plan 已改） |
| `block` | 被阻塞 task 摘掉 ⏸️ 后 |
| 任何带 `thread` 字段的自发消息 | thread 闭环时（链条末端方 mv 整链时一并带走，不需要单独清） |

**推荐扫描节点**：
- 每次 spec finalize / iter 节点切换 / change 落地 后 —— 主动 ls 一遍自己的 open 消息
- `/loop` 心跳里 —— 扫 age > 48h 的自发消息
- 看到上表任一触发信号 —— 立即 mv 对应链

## 硬规则

1. **P0 bug 存在时不推进新任务**
2. **改接口契约文档 / `iteration-plan.md`** 一律走 `change` 等用户 ack
3. **绝不跨角色动手**——根因若在他角色那，一律转 `bug`/`question`/`change`，不直接改别人代码/契约/文档/配置
4. **QA 提 bug 只写现象/证据/根因定位，不给修法 diff**——白盒测试允许读源码，但具体改法由 be/fe 自决
5. **处理闭环按链条末端原则归档**（见上节）

## Escalation（防死循环）

同一 thread 内同一议题来回 ≥ 2 轮（A→B→A→B）仍未收敛 → 自动进入 **escalation**：

- **执行型**（be/fe）→ 发 `question to: pm` 拉论据，列两方立场 + 各自证据
- **协同型**（pm/qa）→ 整合论据 → ask 用户拍板
- 触发 escalation 后**禁止再发同议题的反驳消息**——避免变 5 轮 ping-pong

判定信号：
- 同两方在同一 thread 各发 ≥ 2 条 reply（不含 ack/notice）
- 论点重复、证据未新增

## Stalled Thread（用户不在场兜底）

escalation 触发后，用户 ≥ 24h 未回 → thread 进入 **stalled**：

- 在 `comms/handoff/stalled-threads.md` 追加一行：`{thread_id} | {触发时间} | {等待用户决定的内容}`
- PM `/loop` 心跳扫 stalled → 列"等用户回复"清单
- 用户回应后 PM 心跳清条目

不解决根本问题（用户必须回），但让"等"显式可见——避免 dev 误以为"被忽略"或"默认通过"。

## 模板（两个核心）

### qa 提 P0 bug

```markdown
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
```

### be 修完回 ack

```markdown
---
from: be
to: qa
type: ack
thread: T-B1.1-login-crash
related: [B1.1]
reply_to: 20260424-1030__qa__be__bug-P0-B1.1-login-crash.md
created: 2026-04-24 13:30
---

# B1.1 已修

改 app/api/progress.py:42 加文件存在判空。Commit a3f21b9。请验证。
```

### qa 验证通过

```markdown
---
from: qa
to: be
type: verify
thread: T-B1.1-login-crash
related: [B1.1]
reply_to: 20260424-1330__be__qa__B1.1-ack.md
created: 2026-04-24 14:00
---

# B1.1 验证通过

空库返回四空数组确认。
```

qa 此时一次性 `mv` 这三条（+ 任何 thread 内其他消息）到 `comms/done/2026-04/`。

## 排障速查

| 症状 | 检查 | 修法 |
|---|---|---|
| 没收到新消息 | watcher 活吗 `ps -p $(cat .run/comms_{ROLE}_watch.pid)` | 挂了重启 watcher |
| 扫到 stamp 丢 | `ls -l .run/comms_{ROLE}_watch.stamp` | 不存在 `touch` 重建 |
| watcher 静默失败 | `.run/watcher_{ROLE}.log` | find 报错都在这 |
| `ABORT: 已有 watcher` | `cat .run/comms_{ROLE}_watch.pid` | `kill $(cat …pid)` 后重启 |
| open/ 堆积 | `ls comms/open/ \| wc -l` | 按"链条末端"补归档 |
