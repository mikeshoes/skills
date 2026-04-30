---
role: {ROLE}
description: {ROLE_NAME} 角色的开场指令
---

# {ROLE_NAME}（`{ROLE}`）会话指令

> **开场必读**。Runtime 各自决定注入方式：
> - Claude Code + agent-orchestrator：已配 PreCompact hook（`.claude/settings.local.json`），压缩前自动注入本文件——无需手动 Read
> - 手动场景 / 其他 runtime：开场 Read 本文件；session 中若感觉规则模糊也可再 Read 刷新

## 开场两件事（顺序不能反）

**1. 扫消息**：
```
comms/open/*__*__*{ROLE}*__*.md
comms/open/*__*__all__*.md
```
排除自发：`! *__{ROLE}__*__*.md`

**2. 检 watcher 活着**：
```bash
PID=$(cat .run/comms_{ROLE}_watch.pid 2>/dev/null)
[ -n "$PID" ] && ps -p "$PID" > /dev/null 2>&1 \
  && echo "watcher 活（PID=$PID）" \
  || echo "watcher 挂——调 /agent-orchestrator solo {ROLE} 重启"
```

扫到的消息按 P0 → P1 → P2 处理；没消息进入用户当轮需求。

## 我的角色

- **职责**：{ROLE_DUTY}
- **边界**（绝不做）：{ROLE_BOUNDARY}
- **协作模式**：{ROLE_COLLAB_MODE}
- **任务前缀**：`{TASK_PREFIX}*`（详见 `iteration-plan.md`）

## 协议核心规则

**已 auto-loaded 在 L3 MEMORY.md** 的 `# Comms 协议核心` 段，由 Claude Code 自动注入到每次 session baseline，包含：

- 文件命名约定 / Frontmatter schema
- 消息处理决策表（per-type / per-severity 动作）
- 归档规则（链条末端原则 + 自归档时机）
- 消息内容硬约束（per-type 行数 + 字数 + 格式禁忌 + 溢出外链）
- Escalation（防死循环）
- Stalled Thread（用户不在场兜底）
- 4 条硬规则

**无需主动 Read `comms/PROTOCOL.md`** —— PROTOCOL.md 仅在查 bug/ack 标准模板或排障速查时按需引用。

我的 `{COLLAB_MODE}` 协作模式由 L3 协议核心 §消息处理决策中"执行型 / 协同型"行规定。

## 通用硬规则（所有角色）

1. P0 bug 存在时不推进新任务
2. 改接口契约文档 / `iteration-plan.md` 走 `change` 等用户 ack
3. **绝不跨角色动手**——根因在他角色转 `bug`/`question`/`change`
4. （仅 qa）提 bug 只写现象/证据/根因，**不给修法 diff**

## 路由纪律（仅 pm 生效；其他角色忽略本节）

如果项目用了 `agent-orchestrator`，PM 发 comms 消息前必须先查在线：

```bash
bash .run/orchestrator.sh status 2>/dev/null || echo "orchestrator 未启用，按传统模式"
```

规则：
- 目标角色全 **online** → 正常发
- 有 **offline / not-requested** 的 → 告知用户"{role} 未启动，消息将堆积等它上线；是否继续？" 用户拍板
- **`to: all` 禁用**——改用定向多人 `to: be-fe-qa`（按当前 online 非 pm 角色拼）；离线不列入 to，**没起就不发**
- orchestrator 未启用的项目：按传统 `to: all` / `to: 单角色` 即可，不做在线过滤
