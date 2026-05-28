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
for script in devlog-daily.sh; do
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

# ─── 3. 注册 Claude Code plugin ────────────────────────────
# 插件的 hooks 既负责 30 分钟抓 session 片段，也负责会话结束时触发
# 日终合成（devlog-daily.sh）。因为 hook 跑在 Claude Code 会话里，
# 进程继承终端的磁盘访问权限，能写 Obsidian vault 而不弹 macOS TCC
# 授权框——所以触发完全靠插件，不再需要 launchd / sleepwatcher。
if command -v claude >/dev/null 2>&1; then
  if ! claude plugin marketplace list 2>/dev/null | grep -q "claude-devlog"; then
    claude plugin marketplace add "$REPO_DIR/plugin" 2>&1 | tail -1 || true
  else
    claude plugin marketplace update claude-devlog 2>&1 | tail -1 || true
  fi
  # 重装以确保 plugin cache 同步 repo 最新脚本（install 是拷贝不是软链）
  claude plugin uninstall devlog@claude-devlog >/dev/null 2>&1 || true
  claude plugin install devlog@claude-devlog 2>&1 | tail -1 || true
  echo "✓ devlog@claude-devlog 已安装/更新"
else
  echo "ℹ claude CLI 不在 PATH，跳过 plugin 注册；以后手动："
  echo "    claude plugin marketplace add $REPO_DIR/plugin"
  echo "    claude plugin install devlog@claude-devlog"
fi

# ─── 4. 收尾提示 ───────────────────────────────────────────
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
echo "  看运行日志：      tail -f ~/.devlog/_run.log"
echo "  看 tick 日志：    tail -f ~/.devlog/_tick.log"
echo "  暂停整套系统：    claude plugin uninstall devlog@claude-devlog"
