#!/usr/bin/env bash
# comms watcher 参考实现
# 用法: bash .run/watcher.sh <role>     role ∈ {be, fe, qa, pm}
# 协议: 扫到新文件 stdout 输出 "COMMS_NEW:\n<path>..."
# 完整协议见 comms/PROTOCOL.md
#
# exit trap 会顺手调用 install_config.py revoke 清掉本 pane 的 perms holder
# —— 与主流程 S10 revoke 叠加（幂等），用于兜底 crash / Ctrl-C / tmux kill-pane

set -e

ROLE="$1"
if [ -z "$ROLE" ] || ! echo "be fe qa pm" | grep -qw "$ROLE"; then
  echo "Usage: $0 <be|fe|qa|pm>" >&2
  exit 1
fi

PROJECT_ROOT="__PROJECT_ROOT__"
cd "$PROJECT_ROOT"
mkdir -p comms/open .run

STAMP=".run/comms_${ROLE}_watch.stamp"
LOG=".run/watcher_${ROLE}.log"
LOCKDIR=".run/comms_${ROLE}_watch.lock.d"
PIDFILE=".run/comms_${ROLE}_watch.pid"
READYFILE=".run/role_ready_${ROLE}"

# mkdir 原子锁防同角色多 watcher 互吃 stamp（跨平台，macOS 无 flock）
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # 锁存在——看 PIDFILE 里的进程还活着吗
  OLDPID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    echo "ABORT: 已有 watcher 持有 $LOCKDIR（PID=$OLDPID）" >&2
    exit 1
  fi
  # 僵尸锁，清掉重抢
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" || { echo "ABORT: 抢锁失败 $LOCKDIR" >&2; exit 1; }
fi

echo $$ > "$PIDFILE"
touch "$READYFILE"

# 启动时快照 pane id，trap 时用 —— 即使 tmux pane 已死 env 仍可用
PANE_ID="${TMUX_PANE:-nopane-$$}"

# 动态定位 skill dir（项目级 > 全局级），trap 里用于调 install_config.py
SKILL_DIR=""
for d in "$PROJECT_ROOT/.claude/skills/agent-orchestrator" "$HOME/.claude/skills/agent-orchestrator"; do
  if [ -f "$d/assets/install_config.py" ]; then
    SKILL_DIR="$d"
    break
  fi
done

cleanup() {
  rm -rf "$LOCKDIR" "$PIDFILE" "$READYFILE" "$NEXT" 2>/dev/null
  # 兜底 revoke：精确传 PANE_ID，幂等（holder 已被 S10 删过就 no-op）
  if [ -n "$SKILL_DIR" ]; then
    python3 "$SKILL_DIR/assets/install_config.py" revoke "$PANE_ID" >>"$LOG" 2>&1 || true
  fi
}
trap cleanup EXIT

[ -f "$STAMP" ] || touch "$STAMP"

while true; do
  # 先抢占新时间锚再 find，最后 mv→STAMP；把 find↔touch 漏抓窗口关到 0
  NEXT=$(mktemp ".run/comms_${ROLE}_next.XXXX")
  # glob：*${ROLE}* 捕获单角色 to 和多角色 to（be-fe、fe-qa-pm 等）
  # 角色码互不为子串，无误匹配
  NEW=$(find comms/open -type f \
      \( -name "*__*__*${ROLE}*__*.md" -o -name "*__*__all__*.md" \) \
      ! -name "*__${ROLE}__*__*.md" \
      -newer "$STAMP" 2>>"$LOG")
  if [ -n "$NEW" ]; then
    echo "COMMS_NEW:"
    echo "$NEW"
  fi
  mv "$NEXT" "$STAMP"
  sleep 5
done
