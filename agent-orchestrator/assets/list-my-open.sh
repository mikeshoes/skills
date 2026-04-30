#!/usr/bin/env bash
# 列出当前角色发的 comms/open 消息 —— 用于自归档判断
#
# 用法: bash .run/list-my-open.sh <role>
#   role ∈ {pm, be, fe, qa}
#
# 输出每行：age(h)  type  thread  filename  [flag]
# flag: [>48h] 提示已超时，可考虑归档（按 PROTOCOL §自归档触发信号判断）

set -e

ROLE="${1:-}"
if ! echo "pm be fe qa" | grep -qw "$ROLE"; then
  echo "Usage: $0 <pm|be|fe|qa>" >&2
  exit 1
fi

PROJECT_ROOT="__PROJECT_ROOT__"
cd "$PROJECT_ROOT"

now=$(date +%s)

echo "$ROLE 自发的 comms/open 消息（按 age 升序）："
echo "  age   type        thread                file                                   flag"
echo "  ---   ----        ------                ----                                   ----"

found=0
# 用临时文件收集，方便排序
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for f in comms/open/*__${ROLE}__*__*.md; do
  [ -f "$f" ] || continue
  found=1
  ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
  age_h=$(( (now - ts) / 3600 ))
  thread=$(grep -m1 '^thread:' "$f" 2>/dev/null | awk '{print $2}')
  type=$(grep -m1 '^type:' "$f" 2>/dev/null | awk '{print $2}')
  flag=""
  [ "$age_h" -gt 48 ] && flag="[>48h]"
  printf "%6d  %-10s  %-20s  %-38s  %s\n" \
    "$age_h" "${type:-?}" "${thread:-—}" "$(basename "$f")" "$flag" >> "$tmp"
done

if [ "$found" = 0 ]; then
  echo "  （无）"
else
  sort -n "$tmp"
fi
