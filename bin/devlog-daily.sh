#!/bin/bash
# 每日开发日志生成器（数据驱动版）
# 数据源：
#   1. Claude session drafts（plugin/scripts/tick 每 30 分钟蒸馏一次）
#   2. WakaTime summaries API
# 输出：$DEVLOG_VAULT_DIR/YYYY-MM-DD.md
# 触发：launchd (定时) / sleepwatcher (合盖)

set -u

# ─── 加载配置 ─────────────────────────────────────────────
CONFIG="$HOME/.devlog/config.sh"
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
else
  echo "missing config $CONFIG (run install.sh first)" >&2
  exit 1
fi

CLAUDE="${DEVLOG_CLAUDE_BIN:?}"
CURL=/usr/bin/curl
OUT_DIR="${DEVLOG_VAULT_DIR:?}"
STATE_DIR="${DEVLOG_STATE_DIR:-$HOME/.devlog}"
LOG="$STATE_DIR/_run.log"
LOOKBACK_DAYS="${DEVLOG_LOOKBACK_DAYS:-14}"
EOD_HOUR="${DEVLOG_EOD_HOUR:-21}"

mkdir -p "$OUT_DIR" "$STATE_DIR"
exec >>"$LOG" 2>&1

# ─── 防并发：mkdir 是原子的，已有则另一实例正在跑 ───────
LOCK="$STATE_DIR/.daily.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "===== $(date -Iseconds) skip (another instance holds $LOCK) ====="
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

echo "===== $(date -Iseconds) start ====="

WAKA_KEY=$(awk -F'= *' '/^api_key/ {print $2}' ~/.wakatime.cfg 2>/dev/null)

# ─── 决定哪些日期需要生成 ──────────────────────────────────
NOW_HOUR=$(date +%H)
TODAY=$(date +%F)
TARGETS=()
for offset in $(seq "$LOOKBACK_DAYS" -1 0); do
  D=$(date -v-"${offset}"d +%F)

  # 强制重写今天的报告（sleepwatcher 等触发 = "今天结束了"，无视小时）
  if [ "$D" = "$TODAY" ] && [ -n "${DEVLOG_FORCE_TODAY:-}" ]; then
    echo "  force regenerate $D (DEVLOG_FORCE_TODAY set)"
    rm -f "$OUT_DIR/$D.md"
    TARGETS+=("$D")
    continue
  fi

  # 已存在就跳过
  if [ -f "$OUT_DIR/$D.md" ]; then continue; fi

  # 今天但还不到 EOD：日子还没结束，跳过
  if [ "$D" = "$TODAY" ] && [ "$NOW_HOUR" -lt "$EOD_HOUR" ]; then
    echo "  skip $D (still in progress, hour=$NOW_HOUR < EOD=$EOD_HOUR)"
    continue
  fi

  TARGETS+=("$D")
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "  nothing to do, all recent days have reports"
  echo "===== $(date -Iseconds) done ====="
  exit 0
fi

echo "  targets: ${TARGETS[*]}"

# ─── 为单个日期生成报告 ────────────────────────────────────
generate_for_date() {
  local D=$1
  local OUT="$OUT_DIR/$D.md"

  echo "  -> generating $D"

  # ─── 数据源 1: Claude session drafts ─────────────────────
  local SESSION_DRAFTS=""
  if [ -d "$STATE_DIR/_drafts" ]; then
    SESSION_DRAFTS=$(cat "$STATE_DIR/_drafts/${D}-"*.md 2>/dev/null || true)
  fi

  # ─── 数据源 2: WakaTime ──────────────────────────────────
  local WAKA_DATA=""
  if [ -n "$WAKA_KEY" ]; then
    WAKA_DATA=$($CURL -s --max-time 10 -u "$WAKA_KEY:" \
      "https://wakatime.com/api/v1/users/current/summaries?start=$D&end=$D")
  fi

  # ─── 活动判定：drafts 或 WakaTime > 60s ─────────────────
  local active=0
  if [ -n "$SESSION_DRAFTS" ]; then
    active=1
  fi
  if [ "$active" -eq 0 ] && [ -n "$WAKA_DATA" ]; then
    local waka_seconds
    waka_seconds=$(echo "$WAKA_DATA" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(d.get('cumulative_total',{}).get('seconds',0)))
except: print(0)
" 2>/dev/null)
    [ "${waka_seconds:-0}" -gt 60 ] && active=1
  fi

  if [ "$active" -eq 0 ]; then
    echo "    no activity on $D (no drafts, no WakaTime time), skip writing"
    return
  fi

  local PROMPT='你是工程师的私人开发日志助手。读完下方提供的 Claude session 片段（每 30 分钟一次抓的工作精华）和 WakaTime 量化数据，写一份**让三个月后的自己能 30 秒扫读、2 分钟读懂**的开发日记。

# 核心理念

日记记的是 **"今天我在想什么、纠结什么、决定了什么、放弃了什么"**——这些都在 Claude session 片段里。WakaTime 给量化（时长/语言/项目占比）。**不依赖 git，因为 git 只是 artifact，不是 process knowledge**。

# 阅读体验原则

1. **三层信息密度**：第一层一眼能扫（TL;DR + 主题标题），第二层 1-2 段可读（每个主题的问题/根因/解法），第三层细节折叠
2. **段落要短**：每段最多 3-4 句，超过就拆
3. **善用 Obsidian 原生组件**：callout、加粗、分隔线
4. **敢于省略**：碎片里反复出现的"无显著进展"完全忽略；不重要不写
5. **少即是多**：普通工作日 1-3KB 足够；深坑日才 5KB+

# 严格输出结构

## 1. Frontmatter（不要 yaml 代码块包裹）

---
date: '"$D"'
total_minutes: <WakaTime grand_total.total_seconds / 60，整数，没有就 0>
projects: [<从 session 片段 + WakaTime 推断出的当日项目名>]
languages: [<WakaTime languages 前 5>]
type: devlog
---

## 2. 标题
# '"$D"' 开发日记

## 3. TL;DR — 用 tldr callout 包裹

> [!tldr] 一句话总结
> （1 句话，最多 30 字，给最强的那条主线）

## 4. 主线（2-5 条，每条独立小节）

每条用以下模板：

### <精炼的问题/成果/决策名，10 字内>

**问题/动机**：1 句话，今天为什么搞这个。
**过程**：1-2 句话，试了什么、想了什么、踩了什么。
**结论/选择**：1-2 句话，最终选了什么 / 放弃了什么 / 留了什么 follow-up。

> [!note]- 细节
> - 可选：列具体涉及的文件、决策点、放弃的方向

主题之间用 `---` 分隔。

## 5. 数据卡片（用 callout）

> [!abstract] 数据
> - **时长**：WakaTime X 小时 Y 分（0 就写"未记录"）
> - **项目**：proj1, proj2
> - **语言**：Go, TypeScript, ...
> - **AI**：N 次 prompt、X 万 input / Y 万 output tokens、$Z（如果 WakaTime 给了 ai_* 字段）

## 6. 收获 / 踩坑（可选，没有就整节省略）

> [!tip] 值得记住的
> - 1-2 句，**只放真正非显而易见的**
> （没有就别凑数）

# 硬性禁令

🚫 不要用 30 个 bullet 堆碎片，要按主题归并
🚫 不要写"今天和 Claude 聊了 N 次"这种废话
🚫 不要在主线里塞 commit hash
🚫 不要把"无显著进展"那种碎片也写进日记
🚫 不要 `## 收获 / 踩坑` 下面再嵌套 `### 收获 / 踩坑`
🚫 不要被代码块包裹整个回复，frontmatter 不要 `` ```yaml ``

# 现在开始

下面是今天的真实数据：

== Claude session 片段（每 30 分钟一次的工作精华，按时间顺序）==
'"${SESSION_DRAFTS:-（今天没有 Claude session 片段，请仅依据 WakaTime 数据写一份轻量数据卡 + 简短说明）}"'

== WakaTime ('"$D"') ==
'"$WAKA_DATA"

  # DEVLOG_TICK_NESTED=1 防止下游 claude 触发 devlog plugin tick 递归
  echo "$PROMPT" | DEVLOG_TICK_NESTED=1 "$CLAUDE" -p --output-format=text > "$OUT" 2>>"$LOG"
  local rc=$?

  # 成功生成后清掉当日 drafts
  if [ $rc -eq 0 ] && [ -s "$OUT" ]; then
    rm -f "$STATE_DIR/_drafts/${D}-"*.md 2>/dev/null
  fi

  if [ $rc -ne 0 ] || [ ! -s "$OUT" ]; then
    echo "    claude failed (rc=$rc) for $D, writing raw fallback"
    cat > "$OUT" <<EOF
# 开发日志 — $D

> Claude 总结失败，下面是原始 Claude session 片段：

$SESSION_DRAFTS

> WakaTime 当日数据：

\`\`\`json
$WAKA_DATA
\`\`\`
EOF
  fi
  echo "    wrote $OUT ($(wc -c <"$OUT") bytes)"
}

# ─── 逐个生成 ────────────────────────────────────────────
for D in "${TARGETS[@]}"; do
  generate_for_date "$D"
done

echo "===== $(date -Iseconds) done (${#TARGETS[@]} reports) ====="

# 顺带跑蒸馏（≥KEEP_DAYS 的老日记进 _长期记忆.md）
if [ -x "$(dirname "$0")/devlog-consolidate.sh" ]; then
  "$(dirname "$0")/devlog-consolidate.sh"
elif [ -x "$HOME/bin/devlog-consolidate.sh" ]; then
  "$HOME/bin/devlog-consolidate.sh"
fi
