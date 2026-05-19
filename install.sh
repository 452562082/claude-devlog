#!/bin/bash
# claude-devlog 安装器
# 把 repo 内的脚本和配置 wire 到系统该在的位置
# 幂等：可重复跑

set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.devlog"
CONFIG_FILE="$CONFIG_DIR/config.sh"

echo "claude-devlog installer"
echo "  repo:   $REPO_DIR"
echo "  config: $CONFIG_FILE"
echo ""

# ─── 1. 初始化配置文件 ─────────────────────────────────────
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
  cp "$REPO_DIR/config.example.sh" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo "✓ created $CONFIG_FILE (from config.example.sh)"
  echo "  → 编辑这个文件填入 DEVLOG_VAULT_DIR 等"
  NEED_EDIT=1
else
  echo "✓ $CONFIG_FILE already exists, keeping"
fi

# ─── 2. 把 bin/ 下脚本软链到 ~/bin ─────────────────────────
mkdir -p "$HOME/bin"
for script in devlog-daily.sh devlog-consolidate.sh; do
  src="$REPO_DIR/bin/$script"
  dst="$HOME/bin/$script"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    echo "✓ $dst → $src (already linked)"
  else
    [ -e "$dst" ] && mv "$dst" "$dst.bak.$(date +%s)"
    ln -s "$src" "$dst"
    echo "✓ linked $dst → $src"
  fi
done

# ─── 3. sleep-trigger.sh → ~/.sleep ────────────────────────
SLEEP_TARGET="$REPO_DIR/bin/sleep-trigger.sh"
if [ -L "$HOME/.sleep" ] && [ "$(readlink "$HOME/.sleep")" = "$SLEEP_TARGET" ]; then
  echo "✓ ~/.sleep → already linked"
else
  [ -e "$HOME/.sleep" ] && mv "$HOME/.sleep" "$HOME/.sleep.bak.$(date +%s)"
  ln -s "$SLEEP_TARGET" "$HOME/.sleep"
  echo "✓ linked ~/.sleep → $SLEEP_TARGET"
fi

# ─── 4. launchd plist 渲染并安装 ────────────────────────────
PLIST_SRC="$REPO_DIR/launchd/com.user.devlog.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.user.devlog.plist"
mkdir -p "$(dirname "$PLIST_DST")"

# 模板里的 __HOME__ 替换成真实 $HOME
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
echo "✓ rendered + installed $PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"
echo "✓ launchd reloaded"

# ─── 5. sleepwatcher（合盖触发） ───────────────────────────
if ! command -v sleepwatcher >/dev/null 2>&1; then
  echo "ℹ sleepwatcher 未装；如要合盖即触发日报，跑：brew install sleepwatcher && brew services start sleepwatcher"
else
  if ! brew services list 2>/dev/null | grep -q "^sleepwatcher.*started"; then
    echo "ℹ sleepwatcher 已装但未启动：brew services start sleepwatcher"
  else
    echo "✓ sleepwatcher running"
  fi
fi

# ─── 6. 注册 Claude Code plugin ────────────────────────────
if command -v claude >/dev/null 2>&1; then
  if ! claude plugin marketplace list 2>/dev/null | grep -q "claude-devlog"; then
    claude plugin marketplace add "$REPO_DIR/plugin" 2>&1 | tail -1 || true
  else
    claude plugin marketplace update claude-devlog 2>&1 | tail -1 || true
  fi
  if ! claude plugin list 2>/dev/null | grep -q "devlog@claude-devlog"; then
    claude plugin install devlog@claude-devlog 2>&1 | tail -1 || true
  else
    echo "✓ devlog@claude-devlog already installed"
  fi
else
  echo "ℹ claude CLI 不在 PATH，跳过 plugin 注册；以后手动："
  echo "    claude plugin marketplace add $REPO_DIR/plugin"
  echo "    claude plugin install devlog@claude-devlog"
fi

# ─── 7. 收尾提示 ───────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────"
echo "✓ 安装完毕"
echo ""
if [ "${NEED_EDIT:-0}" = "1" ]; then
  echo "⚠ 必须编辑 $CONFIG_FILE 填入 DEVLOG_VAULT_DIR 和 DEVLOG_CLAUDE_BIN，否则脚本不会跑"
fi
echo ""
echo "常用命令："
echo "  立即跑一次日报：  DEVLOG_FORCE_TODAY=1 ~/bin/devlog-daily.sh"
echo "  立即跑一次蒸馏：  ~/bin/devlog-consolidate.sh"
echo "  看运行日志：      tail -f ~/.devlog/_run.log"
echo "  看 tick 日志：    tail -f ~/.devlog/_tick.log"
echo "  停 launchd：      launchctl unload ~/Library/LaunchAgents/com.user.devlog.plist"
