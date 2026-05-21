#!/bin/bash
# 每日开发日志生成器（数据驱动版）
# 数据源：
#   1. Claude session drafts（plugin/scripts/tick 每 30 分钟蒸馏一次）
#   2. WakaTime summaries API
# 输出：$DEVLOG_VAULT_DIR/YYYY-MM-DD.md
# 触发：plugin/scripts/tick 退出时的 EXIT trap（也可手动跑）

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

# ─── 防并发：mkdir 原子锁 ────────────────────────────────────
# 锁存在但 mtime >60min = 上个实例崩溃残留（正常 run 几分钟内结束）。
# 不清的话泄漏的锁会让系统永久静默罢工，所以过期就清掉、本次退出，
# 下次触发自然能拿到锁。
LOCK="$STATE_DIR/.daily.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    echo "===== $(date -Iseconds) clearing stale lock (>60min old) ====="
    rmdir "$LOCK" 2>/dev/null || true
  else
    echo "===== $(date -Iseconds) skip (another instance holds $LOCK) ====="
  fi
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

  # 强制重写今天的报告（DEVLOG_FORCE_TODAY=1，无视 EOD 小时）
  if [ "$D" = "$TODAY" ] && [ -n "${DEVLOG_FORCE_TODAY:-}" ]; then
    echo "  force regenerate $D (DEVLOG_FORCE_TODAY set)"
    rm -f "$OUT_DIR/$D.md"
    TARGETS+=("$D")
    continue
  fi

  # 已存在：除非有比日记更新的 draft（那天后来又写了东西），否则跳过
  if [ -f "$OUT_DIR/$D.md" ]; then
    newest_draft=$(ls -t "$STATE_DIR/_drafts/${D}-"*.md 2>/dev/null | head -1)
    if [ -n "$newest_draft" ] && [ "$newest_draft" -nt "$OUT_DIR/$D.md" ]; then
      echo "  regenerate $D (draft 比日记新)"
      rm -f "$OUT_DIR/$D.md"
      TARGETS+=("$D")
    fi
    continue
  fi

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
  local SESSION_DRAFTS
  SESSION_DRAFTS=$(cat "$STATE_DIR/_drafts/${D}-"*.md 2>/dev/null || true)

  # ─── 数据源 2: WakaTime ──────────────────────────────────
  # 注意：用 `-K -` 从 stdin 读 user，避免 key 进 curl 的 argv 被 ps 看到
  local WAKA_DATA=""
  if [ -n "$WAKA_KEY" ]; then
    WAKA_DATA=$(printf 'user = "%s:"\n' "$WAKA_KEY" | $CURL -s --max-time 10 -K - \
      "https://wakatime.com/api/v1/users/current/summaries?start=$D&end=$D")
  fi

  # ─── 脚本侧解析 WakaTime → frontmatter + 数据卡片（防止模型幻觉数字）─
  local TMP_FM TMP_DC WAKA_MINUTES
  TMP_FM=$(mktemp)
  TMP_DC=$(mktemp)
  WAKA_MINUTES=$(WAKA_DATA="${WAKA_DATA:-}" DATE="$D" FM="$TMP_FM" DC="$TMP_DC" python3 <<'PY'
import json, os, sys
waka = os.environ.get('WAKA_DATA', '').strip() or '{}'
date = os.environ['DATE']
fm_path = os.environ['FM']
dc_path = os.environ['DC']

try:
    d = json.loads(waka)
    data = (d.get('data') or [{}])[0]
    gt = data.get('grand_total') or {}
except Exception:
    data, gt = {}, {}

total_minutes = int((gt.get('total_seconds') or 0) // 60)
projects_full = data.get('projects') or []
languages_full = data.get('languages') or []
projects = [p['name'] for p in projects_full[:5]]
languages = [l['name'] for l in languages_full[:5]]

with open(fm_path, 'w', encoding='utf-8') as f:
    f.write('---\n')
    f.write(f'date: {date}\n')
    f.write(f'total_minutes: {total_minutes}\n')
    # json.dumps 保证 YAML 1.2 兼容：含 , [ ] : 的项目名会被引号包裹转义
    f.write(f'projects: {json.dumps(projects, ensure_ascii=False)}\n')
    f.write(f'languages: {json.dumps(languages, ensure_ascii=False)}\n')
    f.write('type: devlog\n')
    f.write('---\n')

hours, mins = total_minutes // 60, total_minutes % 60
duration = f'{hours} 小时 {mins} 分' if total_minutes > 0 else '未记录'
proj_break = '、'.join(f'{p["name"]} ({p["percent"]:.0f}%)' for p in projects_full[:6]) or '未记录'
lang_list = ', '.join(languages) or '未记录'

with open(dc_path, 'w', encoding='utf-8') as f:
    f.write('> [!abstract] 数据\n')
    f.write(f'> - **时长**：{duration}\n')
    f.write(f'> - **项目**：{proj_break}\n')
    f.write(f'> - **语言**：{lang_list}\n')
    if gt.get('ai_prompt_events'):
        events = gt['ai_prompt_events']
        inp_m = (gt.get('ai_input_tokens') or 0) / 10000
        outp_m = (gt.get('ai_output_tokens') or 0) / 10000
        costs = gt.get('ai_agent_costs') or {}
        cost = sum(costs.values()) if costs else 0
        f.write(f'> - **AI**：{events} 次 prompt、{inp_m:.0f} 万 input / {outp_m:.1f} 万 output tokens、${cost:.2f}\n')

print(total_minutes)
PY
)

  # ─── 活动判定：drafts 或 WakaTime ≥ 1 min ─────────────────
  local active=0
  if [ -n "$SESSION_DRAFTS" ]; then
    active=1
  elif [ "${WAKA_MINUTES:-0}" -gt 0 ]; then
    active=1
  fi

  if [ "$active" -eq 0 ]; then
    echo "    no activity on $D (no drafts, no WakaTime time), skip writing"
    rm -f "$TMP_FM" "$TMP_DC"
    return
  fi

  # ─── Claude 只写正文：TL;DR + 主题 + tip（不碰 frontmatter/标题/数据卡片）─
  local PROMPT='你是工程师的私人开发日志助手。基于下方 Claude session 片段（每 30 分钟一次抓的工作精华），写一份**让三个月后的自己能 30 秒扫读、2 分钟读懂**的开发日记**正文**。

# 你的输出范围（关键！）

只输出从 TL;DR callout 开始 → 到 tip callout 为止。**绝对不要**写 frontmatter、标题、数据卡片——这些由脚本侧基于 WakaTime 准确填好了，你写了会被覆盖或重复。

# 阅读体验原则

1. **三层信息密度**：TL;DR 一眼能扫；主题段 1-2 段；细节折叠在 `[!note]-`
2. **段落要短**：每段最多 3-4 句
3. **敢于省略**：碎片里"无显著进展"完全忽略
4. **少即是多**：普通工作日 1-3KB 正文；深坑日 5KB+

# 严格输出结构

> [!tldr] 一句话总结
> （1 句话，最多 30 字，给最强的那条主线）

### <精炼的问题/成果/决策名，10 字内>

**问题/动机**：1 句话，今天为什么搞这个。
**过程**：1-2 句话，试了什么、想了什么、踩了什么。
**结论/选择**：1-2 句话，最终选了什么 / 放弃了什么 / 留了什么 follow-up。

> [!note]- 细节
> - 可选：具体涉及的文件、决策点、放弃的方向

主题 2-5 条，主题之间用 `---` 分隔。

主题命名要具体：
- ✅ "self-test 卡 120s 挖到第三层根因"
- ❌ "性能优化"

正文最末尾（可选，没有就完全省略）：

> [!tip] 值得记住的
> - 1-2 句，**只放真正非显而易见的**

# 硬性禁令

🚫 不要写 frontmatter / `# 标题` / `> [!abstract] 数据` 卡片——脚本拼
🚫 不要凭空编时长、项目占比、token 数——脚本已经基于 WakaTime 准确填了，你只写过程
🚫 不要用 30 个 bullet 堆碎片，按主题归并
🚫 不要写"今天和 Claude 聊了 N 次"这种废话
🚫 不要塞 commit hash
🚫 不要被代码块包裹整个回复

# 现在开始

== Claude session 片段（按时间顺序）==
'"${SESSION_DRAFTS:-（今天没有 Claude session 片段。只写一条 TL;DR + 一句话主题说明"无 session 片段记录，仅 WakaTime 量化数据可参考"，不要凑数。）}"

  local TMP_BODY
  TMP_BODY=$(mktemp)
  # DEVLOG_TICK_NESTED=1 防止下游 claude 触发 devlog plugin tick 递归
  echo "$PROMPT" | DEVLOG_TICK_NESTED=1 "$CLAUDE" -p --output-format=text > "$TMP_BODY" 2>>"$LOG"
  local rc=$?

  # ─── 拼装：frontmatter + 标题 + claude 正文 + 数据卡片 ──
  if [ $rc -eq 0 ] && [ -s "$TMP_BODY" ]; then
    {
      cat "$TMP_FM"
      echo ""
      echo "# $D 开发日记"
      echo ""
      cat "$TMP_BODY"
      echo ""
      echo "---"
      echo ""
      cat "$TMP_DC"
    } > "$OUT"
    # drafts 不动：留在 _drafts/ 供后续重生成，到期由末尾的清理统一删
  else
    echo "    claude failed (rc=$rc) for $D, writing fallback"
    {
      cat "$TMP_FM"
      echo ""
      echo "# $D 开发日记"
      echo ""
      echo "> Claude 总结失败，下面是原始 session 片段："
      echo ""
      echo "${SESSION_DRAFTS:-（无 session 片段）}"
      echo ""
      echo "---"
      echo ""
      cat "$TMP_DC"
    } > "$OUT"
  fi

  rm -f "$TMP_FM" "$TMP_DC" "$TMP_BODY"
  echo "    wrote $OUT ($(wc -c <"$OUT") bytes)"
}

# ─── 逐个生成 ────────────────────────────────────────────
for D in "${TARGETS[@]}"; do
  generate_for_date "$D"
done

echo "===== $(date -Iseconds) done (${#TARGETS[@]} reports) ====="

# ─── 清理过期状态（drafts + tick state，超过 DEVLOG_DRAFT_KEEP_DAYS 天没动过）─
DRAFT_KEEP_DAYS="${DEVLOG_DRAFT_KEEP_DAYS:-30}"
find "$STATE_DIR/_drafts" -type f -name "*.md" -mtime "+$DRAFT_KEEP_DAYS" -delete 2>/dev/null || true
find "$STATE_DIR/_state" -type f -mtime "+$DRAFT_KEEP_DAYS" -delete 2>/dev/null || true

# 顺带跑蒸馏（≥KEEP_DAYS 的老日记进 _长期记忆.md）
if [ -x "$(dirname "$0")/devlog-consolidate.sh" ]; then
  "$(dirname "$0")/devlog-consolidate.sh"
elif [ -x "$HOME/bin/devlog-consolidate.sh" ]; then
  "$HOME/bin/devlog-consolidate.sh"
fi
