#!/bin/bash
# 长期记忆蒸馏：把 ≥KEEP_DAYS 天前的代码日记压缩成"12 个月后仍有价值"的摘要
# prepend 到 vault 的 _长期记忆.md，蒸馏成功后删原文件

set -u

CONFIG="$HOME/.devlog/config.sh"
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
else
  echo "missing config $CONFIG" >&2
  exit 1
fi

CLAUDE="${DEVLOG_CLAUDE_BIN:?}"
VAULT="${DEVLOG_VAULT_DIR:?}"
LONGTERM="$VAULT/_长期记忆.md"
STATE_DIR="${DEVLOG_STATE_DIR:-$HOME/.devlog}"
LOG="$STATE_DIR/_consolidate.log"
KEEP_DAYS="${DEVLOG_KEEP_DAYS:-14}"

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "===== $(date -Iseconds) consolidate start ====="

CUTOFF=$(date -v-"${KEEP_DAYS}"d +%F)
echo "  cutoff: $CUTOFF (older files will be consolidated)"

# 收集过期 YYYY-MM-DD.md（跳过 _ 开头的特殊文件）
OLD_FILES=()
for f in "$VAULT"/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .md)
  [[ "$base" == _* ]] && continue
  [[ ! "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && continue
  if [[ "$base" < "$CUTOFF" ]]; then
    OLD_FILES+=("$f")
  fi
done

if [ ${#OLD_FILES[@]} -eq 0 ]; then
  echo "  nothing to consolidate"
  echo "===== $(date -Iseconds) done ====="
  exit 0
fi

IFS=$'\n' OLD_FILES=($(printf '%s\n' "${OLD_FILES[@]}" | sort))
unset IFS

echo "  found ${#OLD_FILES[@]} old files:"
for f in "${OLD_FILES[@]}"; do echo "    $(basename "$f")"; done

DATE_START=$(basename "${OLD_FILES[0]}" .md)
DATE_END=$(basename "${OLD_FILES[$((${#OLD_FILES[@]}-1))]}" .md)
TODAY=$(date +%F)

INPUT_FILE=$(mktemp)
for f in "${OLD_FILES[@]}"; do
  echo "===== FILE: $(basename "$f") ====="
  cat "$f"
  echo ""
done > "$INPUT_FILE"

INPUT_SIZE=$(wc -c < "$INPUT_FILE")
echo "  input size: ${INPUT_SIZE} bytes"

PROMPT='你是个长期记忆助手。下面是这位开发者从 '"$DATE_START"' 到 '"$DATE_END"' 的所有开发日记（每篇是一天）。把它们蒸馏成一份**只保留 12 个月后仍有价值的内容**的简短摘要。

# 输出格式（严格）

第 1 行从 `## ` 开始，下面固定 5 小节。不要 frontmatter，不要外层代码块。

## '"$DATE_START"' ~ '"$DATE_END"'（蒸馏于 '"$TODAY"'）

**主线**：3-5 句 prose，这段时间在主要忙什么、推进到哪一步、有什么主线收束。

**项目时间分布**：bullet list，主要项目 + 大致工作天数。

**反复踩的坑 / 长期教训**：bullet list。**严格筛选**：
- 必须是**跨多天 / 多场景**出现的模式
- 必须**非显而易见**
- 每条 1-2 句，**必须带"为什么"和"怎么避免"**

**关键决策 / 架构动作**：bullet list。重要的设计选择、技术债清理、工具引入。

**值得标记的事件**：bullet list，日期 + 一句话。

# 硬性约束

1. 整份摘要不超过原始日记总长的 20%
2. 主线段落必须 prose
3. 不写每天做了什么——长期记忆要的是模式、教训、决策
4. 不放小修小补
5. 输出从 `## ` 开始

下面是这段时间的所有日记：

'"$(cat "$INPUT_FILE")"

DIGEST=$(mktemp)
echo "$PROMPT" | DEVLOG_TICK_NESTED=1 "$CLAUDE" -p --output-format=text > "$DIGEST" 2>>"$LOG"
rc=$?

if [ $rc -ne 0 ] || [ ! -s "$DIGEST" ]; then
  echo "  ✗ claude failed (rc=$rc), keeping originals"
  rm -f "$INPUT_FILE" "$DIGEST"
  echo "===== $(date -Iseconds) done (failed) ====="
  exit 1
fi

DIGEST_SIZE=$(wc -c <"$DIGEST")
echo "  digest size: $DIGEST_SIZE bytes (ratio: $((DIGEST_SIZE * 100 / INPUT_SIZE))%)"

# Prepend 到长期记忆文件（保留 # 标题）
if [ -f "$LONGTERM" ]; then
  TMP=$(mktemp)
  {
    head -1 "$LONGTERM"
    echo ""
    cat "$DIGEST"
    echo ""
    tail -n +2 "$LONGTERM"
  } > "$TMP"
  mv "$TMP" "$LONGTERM"
else
  {
    echo "# 长期记忆"
    echo ""
    cat "$DIGEST"
  } > "$LONGTERM"
fi

echo "  ✓ prepended digest to $LONGTERM"

for f in "${OLD_FILES[@]}"; do
  rm "$f"
  echo "    removed $(basename "$f")"
done

rm -f "$INPUT_FILE" "$DIGEST"
echo "  ✓ consolidated ${#OLD_FILES[@]} files"
echo "===== $(date -Iseconds) done ====="
