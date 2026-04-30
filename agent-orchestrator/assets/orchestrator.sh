#!/usr/bin/env bash
# agent-orchestrator —— 单 PM + 多角色 tmux 编排
#
# 用法（从 PM claude session 内部被 skill 调起）：
#   orchestrator.sh start [be] [fe] [qa]
#   orchestrator.sh add <role>
#   orchestrator.sh status
#   orchestrator.sh stop [role]

set -e

PROJECT_ROOT="__PROJECT_ROOT__"
cd "$PROJECT_ROOT"
mkdir -p .run

CONF=".run/orchestrator.conf"
VALID_NONPM="be fe qa"

# ---------- 工具 ----------

require_tmux() {
  if [ -z "$TMUX" ]; then
    cat >&2 <<EOF
ERROR: 不在 tmux 里。orchestrator 必须在 tmux 会话里跑。
请先退出当前 claude（Ctrl-D 或 /exit），然后：
  tmux new-session 'claude'
再在 claude 里重新触发 /agent-orchestrator。
EOF
    exit 1
  fi
}

is_valid_nonpm() { echo "$VALID_NONPM" | grep -qw "$1"; }

role_pid_live() {
  local pid
  pid=$(cat ".run/comms_$1_watch.pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

role_ready() { [ -f ".run/role_ready_$1" ]; }

role_pane_alive() {
  local pane
  pane=$(cat ".run/role_pane_$1" 2>/dev/null)
  [ -n "$pane" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane"
}

read_conf() { [ -f "$CONF" ] && . "$CONF"; }

# 自适应布局，PM 永远占主导：
#   2/3 panes → main-vertical（PM 左 60%，subs 右堆叠）
#   4+ panes  → main-horizontal（PM 上 60% 高，subs 底部横排，避免右侧挤）
apply_layout() {
  local count
  count=$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -le 1 ] && return
  if [ "$count" -le 3 ]; then
    tmux select-layout -t "$SESSION" main-vertical >/dev/null 2>&1 || true
    tmux resize-pane -t "$PM_PANE" -x 60% 2>/dev/null || true
  else
    tmux select-layout -t "$SESSION" main-horizontal >/dev/null 2>&1 || true
    tmux resize-pane -t "$PM_PANE" -y 60% 2>/dev/null || true
  fi
}

save_conf() {
  cat > "$CONF" <<EOF
SESSION=$SESSION
PM_PANE=$PM_PANE
EXPECTED="$EXPECTED"
EOF
}

# ---------- spawn ----------

spawn_role() {
  local role="$1"
  # -P 打印新 pane id；-d 不切焦
  local new_pane=$(tmux split-window -t "$SESSION" -P -F '#{pane_id}' -d 'claude')
  echo "$new_pane" > ".run/role_pane_$role"

  # 设 pane title 为大写 role 名（PM/BE/FE/QA）—— 用户 tmux pane-border-format 含 #{pane_title} 时显示
  tmux select-pane -t "$new_pane" -T "$(echo "$role" | tr '[:lower:]' '[:upper:]')"

  # 等 claude TUI 就绪——心跳 + 捕获 pane 看到提示符
  local ready=0
  for _ in 1 2 3 4 5 6; do
    sleep 2
    local out=$(tmux capture-pane -t "$new_pane" -p 2>/dev/null | tail -3)
    if echo "$out" | grep -qE '>|claude'; then
      ready=1; break
    fi
  done
  [ "$ready" = 0 ] && sleep 3  # 最后兜底

  tmux send-keys -t "$new_pane" "/agent-orchestrator solo $role" Enter
  apply_layout
}

# ---------- commands ----------

do_start() {
  require_tmux
  [ -f "$CONF" ] && { echo "ERROR: orchestrator 已启动（$CONF 存在）；用 'add' 加角色或 'stop' 全停" >&2; exit 1; }

  SESSION=$(tmux display-message -p '#{session_name}')
  PM_PANE=$(tmux display-message -p '#{pane_id}')
  EXPECTED="pm"
  echo "$PM_PANE" > .run/role_pane_pm
  touch .run/role_ready_pm  # pm 即本 session，立即 ready
  tmux select-pane -t "$PM_PANE" -T "PM"  # pane title

  for role in "$@"; do
    if ! is_valid_nonpm "$role"; then
      echo "跳过非法角色 '$role'（应为 be/fe/qa）" >&2
      continue
    fi
    spawn_role "$role"
    EXPECTED="$EXPECTED $role"
  done

  save_conf

  echo "✅ orchestrator 启动：session=$SESSION · pm=$PM_PANE"
  echo "已 spawn：$(echo "$EXPECTED" | sed 's/pm //')"
  echo "切换 pane：Ctrl-b o  或  Ctrl-b 数字"
  echo "查状态：bash .run/orchestrator.sh status"
}

do_add() {
  require_tmux
  [ ! -f "$CONF" ] && { echo "ERROR: orchestrator 未启动；请先 start" >&2; exit 1; }
  local role="$1"
  [ -z "$role" ] && { echo "ERROR: add 需要角色参数" >&2; exit 1; }
  ! is_valid_nonpm "$role" && { echo "ERROR: 非法角色 '$role'（应为 be/fe/qa）" >&2; exit 1; }

  read_conf
  echo " $EXPECTED " | grep -qw "$role" && { echo "ERROR: $role 已在 EXPECTED 里" >&2; exit 1; }

  spawn_role "$role"
  EXPECTED="$EXPECTED $role"
  save_conf
  echo "✅ $role 已 spawn"
}

do_status() {
  if [ ! -f "$CONF" ]; then echo "orchestrator 未启动"; return; fi
  read_conf

  printf "%-4s %-8s %-8s %s\n" "role" "pane" "pid" "status"
  local all_online=1
  for role in $EXPECTED; do
    local pane=$(cat ".run/role_pane_$role" 2>/dev/null || echo "-")
    local pid=$(cat ".run/comms_${role}_watch.pid" 2>/dev/null || echo "-")
    local status
    if [ "$role" = "pm" ]; then
      status="online (当前 pane)"
    else
      if role_ready "$role" && role_pid_live "$role"; then
        status="online"
      elif role_pane_alive "$role"; then
        status="starting"; all_online=0
      else
        status="offline"; all_online=0
      fi
    fi
    printf "%-4s %-8s %-8s %s\n" "$role" "$pane" "$pid" "$status"
  done

  echo ""
  echo "EXPECTED：$EXPECTED"
  if [ "$all_online" = 1 ]; then
    echo "🎉 所有预期角色 online"
  else
    echo "⏳ 等待角色就绪（starting 的 pane 可 Ctrl-b 数字 切过去看进度）"
  fi
}

stop_role() {
  local role="$1"
  local pane=$(cat ".run/role_pane_$role" 2>/dev/null)
  local pid=$(cat ".run/comms_${role}_watch.pid" 2>/dev/null)

  if [ -n "$pane" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane"; then
    tmux send-keys -t "$pane" '/exit' Enter 2>/dev/null || true
    sleep 2
    tmux kill-pane -t "$pane" 2>/dev/null || true
  fi
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true

  rm -f ".run/role_ready_$role" ".run/role_pane_$role"
  # comms_${role}_watch.pid 由 watcher 自己 trap 清理；保险起见清一下
  rm -f ".run/comms_${role}_watch.pid" ".run/comms_${role}_watch.lock.d" 2>/dev/null || true
  rm -rf ".run/comms_${role}_watch.lock.d" 2>/dev/null || true
}

do_stop() {
  [ ! -f "$CONF" ] && { echo "orchestrator 未启动"; return; }
  read_conf
  local target="$1"

  if [ -z "$target" ]; then
    local new_expected="pm"
    for role in $EXPECTED; do
      [ "$role" = "pm" ] && continue
      stop_role "$role"
    done
    EXPECTED="$new_expected"
    save_conf
    apply_layout
    echo "✅ 所有非 pm 角色已停；pm pane 保留"
    return
  fi

  if [ "$target" = "pm" ]; then
    echo "ERROR: 不能 stop pm（是你当前 session）；要整个关闭请 tmux kill-session" >&2
    exit 1
  fi
  ! is_valid_nonpm "$target" && { echo "ERROR: 非法角色 '$target'" >&2; exit 1; }
  ! echo " $EXPECTED " | grep -qw "$target" && { echo "ERROR: $target 不在 EXPECTED 里" >&2; exit 1; }

  stop_role "$target"
  EXPECTED=$(echo "$EXPECTED" | sed "s/\\b$target\\b//; s/  */ /g; s/^ \\| $//g")
  save_conf
  apply_layout
  echo "✅ $target 已停"
}

usage() {
  cat <<EOF
用法：
  orchestrator.sh start [be] [fe] [qa]
  orchestrator.sh add <role>
  orchestrator.sh status
  orchestrator.sh stop [role]
EOF
}

cmd="$1"; shift || true
case "$cmd" in
  start)  do_start "$@" ;;
  add)    do_add "$@" ;;
  status) do_status ;;
  stop)   do_stop "$@" ;;
  *)      usage; exit 1 ;;
esac
