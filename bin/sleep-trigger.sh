#!/bin/bash
# 由 sleepwatcher 在 Mac 进入睡眠时调用
# 只在"晚归"睡眠（>= DEVLOG_SLEEP_TRIGGER_HOUR）触发日报
# 安装路径：~/.sleep (symlink to here 或直接 cp)

CONFIG="$HOME/.devlog/config.sh"
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

THRESHOLD="${DEVLOG_SLEEP_TRIGGER_HOUR:-17}"
STATE_DIR="${DEVLOG_STATE_DIR:-$HOME/.devlog}"
LOG="$STATE_DIR/_sleep.log"
mkdir -p "$STATE_DIR"

hour=$(date +%H)
echo "===== $(date -Iseconds) sleep event, hour=$hour =====" >> "$LOG"

if [ "$hour" -lt "$THRESHOLD" ]; then
  echo "  skip (not end-of-day, hour < $THRESHOLD)" >> "$LOG"
  exit 0
fi

DAILY="$(dirname "$0")/devlog-daily.sh"
[ -x "$DAILY" ] || DAILY="$HOME/bin/devlog-daily.sh"

if [ -x "$DAILY" ]; then
  echo "  triggering $DAILY with DEVLOG_FORCE_TODAY=1" >> "$LOG"
  DEVLOG_FORCE_TODAY=1 "$DAILY" &
  disown
fi
exit 0
