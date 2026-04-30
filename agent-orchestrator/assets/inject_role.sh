#!/usr/bin/env bash
# PreCompact hook helper：根据当前 tmux pane id 反查 role，
# 注入 memory（项目协作纪律）+ 压缩边界提示（指引 agent re-Read L3 role pack）。
#
# 由 .claude/settings.local.json 的 PreCompact hook 调用：
#   bash .run/inject_role.sh
#
# 设计：
#   - role pack 已部署到 L3 (~/.claude/projects/<slug>/memory/role_<role>.md)，auto-load 索引在 MEMORY.md
#   - 此处不再 cat role pack（每次 5K tokens 太贵）
#   - 改为注入"压缩边界提示" → agent 看到后按 L3 强制加载规则主动 Read role pack
#   - memory 仍 cat（项目证据合同等 cwd-bound 内容）
#
# 依赖：
#   - .run/role_pane_<role>  （orchestrator/solo 启动时写入，pane id 反查）
#   - comms/memory/<role>.md （角色协作纪律 + 项目证据合同）

set -e

# 不在 tmux 里：无 pane id 可查，静默退出
[ -n "$TMUX" ] || exit 0

PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || exit 0

for r in pm be fe qa; do
  if [ "$(cat ".run/role_pane_$r" 2>/dev/null)" = "$PANE" ]; then
    # 1. 注入项目协作纪律（项目证据合同、PM 路由纪律等 cwd-bound 内容）
    [ -f "comms/memory/$r.md" ] && cat "comms/memory/$r.md"

    # 2. 压缩边界提示：让 agent 主动 re-Read L3 role pack
    cat <<EOF

---

**[PreCompact 提示]** 我是 $r 角色。压缩刚刚发生，人格细节可能在摘要里弱化。
按 L3 §角色人格 强制规则，下一条响应前**必须 Read** \`role_$r.md\`（在 ~/.claude/projects/<slug>/memory/）。
EOF
    break
  fi
done
