#!/usr/bin/env bash
# critique.sh —— PM 召唤 critic 子进程做对抗性评审（多轮讨论 → PM 拍板）
#
# 用法（从 PM session 内被 SKILL 调起）：
#   critique.sh                       # auto: critic 自己挑最值得评的一份
#   critique.sh north-star            # 评 north-star.md 当前节
#   critique.sh path/to/spec.md       # 评指定文件
#
# 多轮流程：
#   开局轮：critic 写 v1 review 5 段 → PM 在文件末尾追加 "## PM 回应 v1"
#   续  轮：PM 写"状态: 继续讨论" → 重跑 critique → critic 追加复盘 vN
#   终  局：PM 写"状态: 结案-{接受|坚持原方案|修改spec}" → 自动归档
#           结案-坚持原方案 + critic 最新总评 critical → 自动写 escalate notice
#
# 软限 5 轮（仅提示，不阻断）

set -e

# ---------- 自定位 ----------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SKILL_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
PROJECT_ROOT="$(pwd)"

PROMPT_TPL="$SKILL_DIR/assets/critique-prompt.md"
ROLE_PACK="$SKILL_DIR/assets/role_critic.md"

# ---------- 前置检查 ----------

[ -f "$PROMPT_TPL" ] || { echo "ERROR: 找不到 $PROMPT_TPL" >&2; exit 1; }
[ -f "$ROLE_PACK" ]  || { echo "ERROR: 找不到 $ROLE_PACK" >&2; exit 1; }

command -v claude >/dev/null 2>&1 || {
  cat >&2 <<'EOF'
⚠️  跳过 critique —— claude CLI 不在 PATH

critique 依赖 claude CLI 起 headless 子进程。当前环境找不到 claude 命令，
跳过对抗性评审。其他 skill 功能（solo/orchestrator）不受影响。
EOF
  exit 0
}

# ---------- 配置解析（通用化） ----------

BASE_URL="${CRITIQUE_BASE_URL:-https://api.deepseek.com/anthropic}"
API_KEY="${CRITIQUE_API_KEY:-${DEEPSEEK_API_KEY:-}}"
MODEL="${CRITIQUE_MODEL:-deepseek-v4-pro}"

if [ -z "$API_KEY" ]; then
  cat >&2 <<'EOF'
⚠️  跳过 critique —— 未配置对抗性评审 provider

critique 是 agent-orchestrator 的可选功能。要启用，二选一：

  方式 A（用 DeepSeek，最简）：
    export DEEPSEEK_API_KEY="<your deepseek key>"

  方式 B（自定义 provider，需 anthropic 协议兼容 + 支持 tool_use）：
    export CRITIQUE_BASE_URL="https://your-proxy/anthropic"
    export CRITIQUE_API_KEY="<your key>"
    export CRITIQUE_MODEL="<model id>"

任一组配置后重跑 /agent-orchestrator critique 即可启用。
未配置时 solo / orchestrator / status / stop 等功能不受影响。
EOF
  exit 0
fi

if [ ! -f "$PROJECT_ROOT/north-star.md" ]; then
  echo "⚠️ 未发现 north-star.md —— critic 评审会缺少锚点；建议先 /project-anchor init" >&2
fi

# ---------- 参数解析 ----------

TARGET_ARG="${1:-auto}"

case "$TARGET_ARG" in
  auto)
    KIND="auto"; TARGET=""; DESC="auto-pick"; SLUG="auto"
    ;;
  north-star)
    if [ ! -f "$PROJECT_ROOT/north-star.md" ]; then
      echo "ERROR: target=north-star 但 north-star.md 不存在" >&2
      exit 1
    fi
    KIND="north-star"; TARGET="north-star.md"; DESC="north-star.md"; SLUG="north-star"
    ;;
  *)
    if [ ! -f "$PROJECT_ROOT/$TARGET_ARG" ] && [ ! -f "$TARGET_ARG" ]; then
      echo "ERROR: target 文件不存在：$TARGET_ARG" >&2
      exit 1
    fi
    KIND="file"
    if [ -f "$PROJECT_ROOT/$TARGET_ARG" ]; then
      TARGET="$TARGET_ARG"
    else
      TARGET="$(realpath --relative-to="$PROJECT_ROOT" "$TARGET_ARG" 2>/dev/null || echo "$TARGET_ARG")"
    fi
    DESC="$(basename "$TARGET")"
    SLUG="$(basename "$TARGET" .md | tr '[:upper:] /' '[:lower:]--' | tr -cd 'a-z0-9-' | head -c 40)"
    [ -z "$SLUG" ] && SLUG="unknown"
    ;;
esac

# ---------- 多轮：解析现有 active 文件 ----------

# 同 slug 在 handoff 里的最新 critique 文件
ACTIVE_FILE=""
ACTIVE_FILE_REL=""
if [ -d "$PROJECT_ROOT/comms/handoff" ]; then
  ACTIVE_FILE=$(ls -t "$PROJECT_ROOT/comms/handoff/critique-"*"-${SLUG}.md" 2>/dev/null | head -1 || true)
fi

# 解析 PM 最新一轮回应的状态：(no_response) / (missing) / 状态字面值
# 兼容: `状态: X` / `- 状态: X` / `**状态**: X` / `状态：X`（中英冒号）
parse_pm_latest_status() {
  local file="$1"
  awk '
    /^## PM 回应 v[0-9]+/ { in_pm=1; pm_status="(missing)"; pm_block_seen=1; next }
    /^## / && !/^## PM 回应/ { in_pm=0 }
    in_pm && /状态.*[：:]/ {
      s=$0
      sub(/^.*状态[^：:]*[：:][ \t]*/, "", s)
      sub(/[ \t]*\**[ \t]*$/, "", s)
      if (s != "") pm_status=s
    }
    END {
      if (pm_block_seen) print pm_status
      else print "(no_response)"
    }
  ' "$file"
}

# 计算最新轮数 N（看 Critic Review v1 / Critic 复盘 vN 段的最大 v）
get_latest_round() {
  local file="$1"
  awk '
    /^## Critic Review v[0-9]+/ {
      match($0, /v[0-9]+/); n=substr($0, RSTART+1, RLENGTH-1)
      if (n+0 > max) max=n+0
    }
    /^## Critic 复盘 v[0-9]+/ {
      match($0, /v[0-9]+/); n=substr($0, RSTART+1, RLENGTH-1)
      if (n+0 > max) max=n+0
    }
    END { print max+0 }
  ' "$file"
}

# 抽最后一段 critic 段（review 或复盘）的总评强度
# 关键：在 "总评:" 后第一次出现的强度词才算（避免被同行 "v1 是 critical" 误抓）
get_latest_critic_verdict() {
  local file="$1"
  awk '
    /^## Critic / { in_critic=1; verdict=""; next }
    /^## PM 回应/ { in_critic=0 }
    in_critic && /总评.*[：:]/ {
      rest=$0
      sub(/.*总评[^：:]*[：:]/, "", rest)
      pc = index(rest, "critical")
      pm_pos = index(rest, "medium")
      pl = index(rest, "low")
      best_pos = 999999; best=""
      if (pc > 0       && pc       < best_pos) { best_pos = pc;       best = "critical" }
      if (pm_pos > 0   && pm_pos   < best_pos) { best_pos = pm_pos;   best = "medium" }
      if (pl > 0       && pl       < best_pos) { best_pos = pl;       best = "low" }
      if (best != "") verdict = best
    }
    END { print verdict }
  ' "$file"
}

MODE="open"
ROUND=1
SOFT_LIMIT_WARNING=""

if [ -n "$ACTIVE_FILE" ] && [ -f "$ACTIVE_FILE" ]; then
  ACTIVE_FILE_REL="$(realpath --relative-to="$PROJECT_ROOT" "$ACTIVE_FILE" 2>/dev/null \
                    || echo "${ACTIVE_FILE#$PROJECT_ROOT/}")"
  PM_STATUS=$(parse_pm_latest_status "$ACTIVE_FILE")
  PREV_ROUND=$(get_latest_round "$ACTIVE_FILE")

  case "$PM_STATUS" in
    *结案-接受*|*结案-坚持原方案*|*结案-修改spec*)
      # ---------- 终局：归档 + 可能 escalate ----------
      DONE_DIR_REL="comms/done/$(date +%Y-%m)/critique-resolved"
      mkdir -p "$PROJECT_ROOT/$DONE_DIR_REL"
      DONE_PATH="$PROJECT_ROOT/$DONE_DIR_REL/$(basename "$ACTIVE_FILE")"
      mv "$ACTIVE_FILE" "$DONE_PATH"

      ESCALATED=""
      if [[ "$PM_STATUS" == *坚持原方案* ]]; then
        VERDICT=$(get_latest_critic_verdict "$DONE_PATH")
        if [ "$VERDICT" = "critical" ]; then
          NOTICE_TS="$(date +%Y%m%d-%H%M)"
          NOTICE="comms/open/${NOTICE_TS}__critic__pm__escalate-${SLUG}.md"
          NOTICE_ABS="$PROJECT_ROOT/$NOTICE"

          ESC_BODY=$(awk '
            /^## Critic / { in_critic=1; capture=0 }
            /^## PM 回应/ { in_critic=0; capture=0 }
            in_critic && /^### Escalate 论据/ { capture=1; print; next }
            capture && /^### / && !/^### Escalate 论据/ { capture=0 }
            capture { print }
          ' "$DONE_PATH")

          cat > "$NOTICE_ABS" <<EOF
---
from: critic
to: pm
type: notice
created: $(date +"%Y-%m-%d %H:%M")
---

# ESCALATE: PM 坚持原方案 + critic 仍 critical

- target: \`$TARGET_ARG\`
- 讨论全文: \`$DONE_DIR_REL/$(basename "$ACTIVE_FILE")\`
- 总轮数: $PREV_ROUND
- model: $MODEL

PM 在多轮讨论后选择"结案-坚持原方案"，但 critic 最新轮总评仍为 critical。
请用户拍板：是否接受 critic 反对、或确认 PM 决策。

${ESC_BODY:-（critic 未填 Escalate 论据段，请看讨论全文）}
EOF
          ESCALATED="$NOTICE"
        fi
      fi

      echo "✅ 讨论已结案（$PREV_ROUND 轮，状态：$PM_STATUS）"
      echo "   归档：$DONE_DIR_REL/$(basename "$ACTIVE_FILE")"
      [ -n "$ESCALATED" ] && {
        echo ""
        echo "⚠️ PM 坚持原方案 + critic 仍 critical → 已写 escalate notice"
        echo "   notice: $ESCALATED"
        echo "   PM 的 watcher 会扫到，请把这条带到下一轮跟用户确认"
      }
      echo ""
      echo "如需对同一 target 开新讨论，请在 target 修改后重跑 /agent-orchestrator critique $TARGET_ARG"
      exit 0
      ;;

    *继续讨论*)
      MODE="continue"
      ROUND=$((PREV_ROUND + 1))
      ;;

    "(no_response)"|"(missing)"|*)
      cat >&2 <<EOF
ℹ️ 上一轮 critique 还未结案，PM 尚未写有效回应：
   active: $ACTIVE_FILE_REL
   PM 最新回应状态：$PM_STATUS

请在文件末尾追加：

   ## PM 回应 v${PREV_ROUND}
   状态: [继续讨论 | 结案-接受 | 结案-坚持原方案 | 结案-修改spec]
   反驳: ...（论据 / 接受理由 / 澄清）

写完后重跑 /agent-orchestrator critique $TARGET_ARG 即可：
   - "继续讨论"    → critic 进 v$((PREV_ROUND + 1)) 复盘
   - "结案-*"      → 自动归档（坚持原方案 + 仍 critical 时写 escalate notice）
EOF
      exit 0
      ;;
  esac
fi

# 软限 5 轮提示
if [ "$ROUND" -ge 5 ]; then
  SOFT_LIMIT_WARNING="⚠️  本次是第 $ROUND 轮 —— 讨论已多轮未收敛。
请考虑：是否其实问题定义本身需要重写（重新开局而非续轮）？
或 PM 直接写 \"状态: 结案-坚持原方案\" + critic 仍 critical 触发用户拍板。
本轮仍可继续，但建议在复盘里给出明确的"再讨论一轮的预期产出"。"
fi

# ---------- 输出路径准备 ----------

TS="$(date +%Y%m%d-%H%M)"
mkdir -p "$PROJECT_ROOT/comms/handoff" "$PROJECT_ROOT/comms/open"

if [ "$MODE" = "continue" ]; then
  # 续轮：直接覆写 active 文件（critic 自己保留全部历史 + 追加新段）
  OUTPUT="$ACTIVE_FILE_REL"
else
  OUTPUT="comms/handoff/critique-${TS}-${SLUG}.md"
fi
OUTPUT_ABS="$PROJECT_ROOT/$OUTPUT"

# ---------- 渲染 prompt 模板 ----------

RENDERED="$(mktemp -t critique-prompt.XXXXXX.md)"
trap 'rm -f "$RENDERED"' EXIT

awk -v skill_dir="$SKILL_DIR" \
    -v target_kind="$KIND" \
    -v target="$TARGET" \
    -v ts="$TS" \
    -v project_root="$PROJECT_ROOT" \
    -v output="$OUTPUT" \
    -v target_desc="$DESC" \
    -v mode="$MODE" \
    -v round="$ROUND" \
    -v active_file="${ACTIVE_FILE_REL:-(none)}" \
    -v soft_limit="$SOFT_LIMIT_WARNING" \
    '{
      gsub(/__SKILL_DIR__/, skill_dir);
      gsub(/__TARGET_KIND__/, target_kind);
      gsub(/__TARGET__/, target);
      gsub(/__TS__/, ts);
      gsub(/__PROJECT_ROOT__/, project_root);
      gsub(/__OUTPUT__/, output);
      gsub(/__TARGET_DESC__/, target_desc);
      gsub(/__MODE__/, mode);
      gsub(/__ROUND__/, round);
      gsub(/__ACTIVE_FILE__/, active_file);
      gsub(/__SOFT_LIMIT_WARNING__/, soft_limit);
      print;
    }' "$PROMPT_TPL" > "$RENDERED"

# ---------- 召唤 critic 子进程 ----------

if [ "$MODE" = "continue" ]; then
  echo "🪞 召唤 critic 续轮 v$ROUND（model: $MODEL, target: $DESC）..."
  echo "   覆写 active 文件 → $OUTPUT"
else
  echo "🪞 召唤 critic 开局 v1（model: $MODEL, target: $DESC）..."
  echo "   review 输出 → $OUTPUT"
fi
[ -n "$SOFT_LIMIT_WARNING" ] && echo "$SOFT_LIMIT_WARNING"
echo ""

mkdir -p "$PROJECT_ROOT/.run"
LOG_OUT="$PROJECT_ROOT/.run/critique-${TS}.log"
LOG_ERR="$PROJECT_ROOT/.run/critique-${TS}.err"

(
  cd "$PROJECT_ROOT"
  ANTHROPIC_BASE_URL="$BASE_URL" \
  ANTHROPIC_AUTH_TOKEN="$API_KEY" \
  claude --model "$MODEL" \
         --allowedTools "Read,Write,Bash,Glob,Grep" \
         --output-format text \
         --print \
    < "$RENDERED" \
    > "$LOG_OUT" 2> "$LOG_ERR"
) || {
  echo "❌ critic 子进程失败（exit=$?）" >&2
  echo "   stderr ($LOG_ERR，前 20 行)：" >&2
  head -20 "$LOG_ERR" >&2 || true
  exit 1
}

# ---------- 验证 ----------

if [ ! -s "$OUTPUT_ABS" ]; then
  echo "❌ critic 未写出 review 文件 → $OUTPUT" >&2
  echo "   子进程 stdout（最后 30 行，可能含原因）：" >&2
  tail -30 "$LOG_OUT" >&2 || true
  echo "   stderr 路径：$LOG_ERR" >&2
  exit 1
fi

# 续轮额外验证：新轮段确实写进去了
if [ "$MODE" = "continue" ]; then
  if ! grep -qE "^## Critic 复盘 v${ROUND}" "$OUTPUT_ABS"; then
    echo "⚠️ critic 似乎未写出 v$ROUND 复盘段 —— 文件可能被覆盖坏了" >&2
    echo "   请检查 $OUTPUT" >&2
    # 不阻断；让 PM 自己判
  fi
fi

rm -f "$LOG_OUT" "$LOG_ERR"

# ---------- 输出给 PM 的简报 ----------

echo ""
if [ "$MODE" = "continue" ]; then
  echo "✅ Critic 复盘 v$ROUND 已落"
else
  echo "✅ Critic Review v1 已落"
fi
echo "   文件: $OUTPUT"
echo "   model: $MODEL"

cat <<EOF

📋 PM 下一步：
   1) 看完最新 critic 段（$([ "$MODE" = continue ] && echo "## Critic 复盘 v$ROUND" || echo "## Critic Review v1")）
   2) 在文件末尾追加：

      ## PM 回应 v$ROUND
      状态: [继续讨论 | 结案-接受 | 结案-坚持原方案 | 结案-修改spec]
      反驳: ...（论据 / 接受理由 / 澄清；引用要可定位）

   3) 重跑 /agent-orchestrator critique $TARGET_ARG：
      - "继续讨论"    → critic 进 v$((ROUND + 1)) 复盘
      - "结案-*"      → 自动归档到 comms/done/$(date +%Y-%m)/critique-resolved/
                       （坚持原方案 + critic 仍 critical → 写 escalate notice）
EOF
