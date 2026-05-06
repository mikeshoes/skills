---
name: project-anchor
description: 防项目漂移的锚 + 漂移巡检 + pivot ceremony。三个动作：init 建 north-star.md；audit 跑漂移巡检；pivot 走变更礼仪。配合 agent-orchestrator 的 comms 协议使用，也能独立运行。
version: 0.1.0
---

# Project Anchor

防漂移的最小机制集，3 个动作：

| 用户输入 | 行为 |
|---|---|
| `/project-anchor init` | 项目根建 `north-star.md`（原始决策 + 决策日志）|
| `/project-anchor audit` | 跑漂移巡检，输出报告（4 类信号 → 警告 / 健康判定）|
| `/project-anchor pivot` | 走 pivot ceremony，4 条件验证 + 写 change 消息 + 追加决策日志 |
| `/project-anchor` | 输出当前状态 + 帮助 |

## 设计前提

- **north-star** 是项目的不动点："我们为什么做这个"
- 任何重大变化必须从 north-star 推出，OR 显式更新 north-star（pivot）
- 漂移 = 实际产出与 north-star 之间的偏离；audit 是定期度量
- 跟 agent-orchestrator 共用 `comms/` 协议但**不强依赖**——standalone 也能用

## 命令分发（步骤 A）

第一个 token：

- `init` → Init 步骤
- `audit` → Audit 步骤
- `pivot` → Pivot 步骤
- 空 / 其他 → 输出帮助 + 当前状态摘要

## 定位 skill assets（步骤 B，三模式共用）

```bash
for d in .claude/skills/project-anchor ~/.claude/skills/project-anchor; do
  [ -d "$d/assets" ] && SKILL_DIR="$d" && break
done
```

找不到 → 报"project-anchor skill 未完整安装"，停。

---

# Init 模式步骤

### I1. 检查是否已有 north-star

```bash
[ -f north-star.md ] && echo "EXISTS" || echo "NEW"
```

- 已存在 → 输出"north-star.md 已存在；要修订请用 `/project-anchor pivot`，要重建请先删除文件"，停
- 不存在 → 进 I2

### I2. 拷贝模板

```bash
sed "s|__GENERATED_AT__|$(date +'%Y-%m-%d')|g" \
  "{SKILL_DIR}/assets/north-star-template.md" > north-star.md
```

### I3. 输出引导

```
✅ 已生成 north-star.md（项目根）

下一步：填 5 个空白——

  - 解决谁的什么问题：[具体 persona] 的 [具体痛点]
  - 不做：[≥ 3 个明确排除项]
  - 成功 = [≤ 3 个可量化指标]
  - 反失败信号：[看到这些应该停]
  - 放弃信号：[什么情况让我们重新评估甚至关掉]

填法注意：
  - "用户希望" / "更好的体验" 是占位符，不是答案——继续追问到具体行为
  - 成功指标含形容词（"流畅"、"易用"）→ 翻成数字（"60s 完成首屏" / "NPS ≥ 30"）
  - "不做" 至少 3 条；少于 3 条说明范围还没收敛
  - 填完 git commit 一份，作为 t=0 基准

后续任何修订必须走 /project-anchor pivot——不要直接编辑「当前 north-star」节。
```

---

# Audit 模式步骤

### A1. 检查前提

```bash
[ -f north-star.md ] || { echo "north-star.md 不存在；先 /project-anchor init" >&2; exit 1; }
HAS_GIT=$([ -d .git ] && echo y || echo n)
HAS_COMMS=$([ -d comms ] && echo y || echo n)
```

无 git → iteration-plan diff 信号降级
无 `comms/` → change 累积信号降级；只跑 north-star 静态信号

### A2. 收集 drift signals（v0.1 共 4 类）

**信号 1：change 累积数**（依赖 `comms/`）

```bash
if [ "$HAS_COMMS" = y ]; then
  CHANGE_OPEN=$(ls comms/open/*__*__*__change-*.md 2>/dev/null | wc -l | tr -d ' ')
  CHANGE_DONE=$(ls comms/done/*/*__*__*__change-*.md 2>/dev/null | wc -l | tr -d ' ')
  CHANGE_TOTAL=$((CHANGE_OPEN + CHANGE_DONE))
fi
```

**信号 2：north-star 引用频率（过去 30 天）**

```bash
NS_REFS=$(find . -name "*.md" -mtime -30 \
  -not -path "./comms/done/*" -not -path "./.git/*" -not -path "./node_modules/*" \
  -exec grep -l "north-star" {} \; 2>/dev/null | wc -l | tr -d ' ')
```

**信号 3：decisions log 新鲜度**

```bash
LAST_LOG=$(grep -E "^### [0-9]{4}-[0-9]{2}-[0-9]{2}" north-star.md | tail -1 | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}")
if [ -n "$LAST_LOG" ]; then
  # macOS 和 Linux date 命令不同
  LAST_TS=$(date -j -f "%Y-%m-%d" "$LAST_LOG" +%s 2>/dev/null || date -d "$LAST_LOG" +%s 2>/dev/null)
  DAYS_SINCE=$(( ( $(date +%s) - LAST_TS ) / 86400 ))
else
  DAYS_SINCE="∞"  # 还没任何 entry
fi
```

**信号 4：iteration-plan 漂移**（依赖 git）

```bash
if [ "$HAS_GIT" = y ] && [ -f iteration-plan.md ]; then
  FIRST_HASH=$(git log --diff-filter=A --format=%H -- iteration-plan.md | tail -1)
  [ -n "$FIRST_HASH" ] && PLAN_DIFF_LINES=$(git diff "$FIRST_HASH" HEAD -- iteration-plan.md | wc -l | tr -d ' ')
fi
```

### A3. 判定状态（每信号映射）

| 信号 | 警告条件 | 状态 |
|---|---|---|
| change 累积 ≥ 5 但 decisions log 0 新增 | yes | 🔴 **疑似未识别 pivot** |
| change 累积 = 0 但 iter ≥ 2（看 git commits） | yes | 🟡 可能在偷改 |
| north-star 30 天零引用 | yes | 🔴 **集体漂** |
| decisions log > 90 天无更新 + change 累积 > 0 | yes | 🟡 决策日志没跟上 |
| iteration-plan diff > 200 行 | yes | 🟡 范围漂 |

### A4. 输出报告

```bash
if [ "$HAS_COMMS" = y ]; then
  mkdir -p comms/handoff
  OUTPUT="comms/handoff/drift-audit-$(date +%Y%m%d-%H%M).md"
else
  OUTPUT=/dev/stdout
fi
```

报告内容（参考 `assets/audit-report-template.md` 格式）：
- 信号汇总表
- 判定（哪些警告触发）
- 建议动作

### A5. stdout 摘要给用户

```
🧭 漂移巡检 — {YYYY-MM-DD HH:MM}

⚠️ N 个警告：
- 🔴 累积 8 条 change 但 north-star 6 个月未改 → 疑似未识别 pivot
- 🔴 north-star 30 天内零引用 → 集体漂

✅ 健康：
- decisions log 最近 12 天有更新

详细报告：comms/handoff/drift-audit-{TS}.md（无 comms/ → 上面已 stdout）

建议下一步：
  - /project-anchor pivot 把累积漂移转成显式决策
  - 或回 spec 重新对齐 north-star
```

---

# Pivot 模式步骤

### P1. 检查前提

```bash
[ -f north-star.md ] || { echo "north-star.md 不存在；先 /project-anchor init" >&2; exit 1; }
```

### P2. 验 4 条件（与用户交互）

逐条问，**任一条答不上 → 停**（输出"不满足 pivot 条件，建议继续 iter 或先收集证据"）：

```
🎯 Pivot ceremony — 必须满足全部 4 条件才能改 north-star。

1. 触发证据 ≥ 2 条独立来源是什么？
   （单个 stakeholder "感觉应该改" 不算）

2. 什么证据会让你改回去？（可逆性记录）
   （答不出说明 pivot 不严肃；强制记录）

3. 用户原话引用是什么？
   （PM 转述 "用户同意了" 不算；要原文）

4. 现在是 iter 边界吗？
   （iter 中不许 pivot；除非 P0 + 用户明确开口子）
```

### P3. 收集修改内容

继续问：north-star 哪一条要改？改成什么？为什么？

### P4. 写 change 消息到 comms/open/

参考 `assets/pivot-change-template.md` 格式。文件名：

```bash
TS=$(date +%Y%m%d-%H%M)
SLUG=$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
[ "$HAS_COMMS" = y ] && OUT="comms/open/${TS}__pm__be-fe-qa__pivot-${SLUG}.md"
```

无 `comms/` → 跳过这步，输出"comms/ 未启用，pivot 仅记录到 decisions log"。

### P5. 追加 decisions log 到 north-star.md

**不覆盖原内容**——在 `## 决策日志` 节末尾追加新 entry：

```markdown
### YYYY-MM-DD：{标题}
- **触发证据**：{evidence}
- **旧目标 superseded 原因**：{why}
- **用户原话**：> {user quote}
- **影响范围**：{impact}
- **可逆触发**：{reverse}
```

### P6. 提示用户更新「当前 north-star」节

v0.1 不自动改「当前」节——避免误改。提示用户手动操作：

```
✅ Pivot 已记录

- decisions log 已追加 entry
- change 消息：comms/open/{file}.md（待用户 ack；comms/ 未启用则无）

下一步（你手动）：
  1. 编辑 north-star.md 「当前 north-star」节，把改动写入
  2. 旧版本内容标 "[superseded {date}，见 decisions log]"
  3. git commit north-star.md（关键基准变更值得独立 commit）
```

---

## 失败处理

| 症状 | 处理 |
|---|---|
| `north-star.md` 不存在 | init 自动创建；audit/pivot 报错"先 init" |
| 没 git | audit 中 iteration-plan diff 信号降级，跳过 |
| 没 `comms/` | audit 中 change 信号降级；pivot 跳过 change 消息写入 |
| iter 中走 pivot | 提醒"通常 iter 边界做 pivot；现在改 OK 吗？" 用户确认才继续 |
| north-star.md 格式被破坏 | audit 中 decisions log 信号降级，输出"⚠️ north-star.md 格式异常" |

## 不做的事

- **不替用户填 north-star 内容**——只给模板 + 引导
- **不自动判定 pivot**——必须用户走 ceremony
- **不删旧 north-star / decisions log**——永远追加
- **不强制时机**——audit / pivot 都是用户主动触发，skill 不轮询
- **不改 `~/.claude/CLAUDE.md` / `~/.claude/settings.json`**——全局配置不动
- **不跨边界写 PM 之外 role 的 memory**——pivot 只动 north-star + 发 change
