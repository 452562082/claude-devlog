#!/bin/bash
# claude-devlog 配置（被 bin/ 下所有脚本 source）
# 安装时 install.sh 会把这份复制成 ~/.devlog/config.sh，再让你按需修改

# ─── 必填：Obsidian vault 里"代码日记"目录的绝对路径 ────────────
# 例：
#   $HOME/Documents/Obsidian/MyVault/代码日记
#   $HOME/Library/CloudStorage/GoogleDrive-xxx@gmail.com/我的云端硬盘/mybrain/代码日记
DEVLOG_VAULT_DIR="$HOME/Documents/Obsidian/MyVault/代码日记"

# ─── 必填：claude CLI 路径（which claude 可查）──────────────────
DEVLOG_CLAUDE_BIN="$(which claude 2>/dev/null || echo $HOME/.local/bin/claude)"

# ─── 可选：覆盖默认参数 ────────────────────────────────────────

# 短期保留天数（超过会被蒸馏进 _长期记忆.md）
DEVLOG_KEEP_DAYS=14

# 回扫窗口（每次跑检查多少天的"缺失日报"）
DEVLOG_LOOKBACK_DAYS=14

# 一天的结束时刻（小时，24h 制）；之前算"在进行中"，之后才会写当天的日报
DEVLOG_EOD_HOUR=21

# Claude session 抓取频率（秒）
DEVLOG_TICK_INTERVAL=1800

# 合成成功后 drafts 归档保留天数；保留窗口内删了日记重跑会基于归档复现
DEVLOG_DRAFT_ARCHIVE_DAYS=30

# ─── 数据/状态目录（一般不用改）────────────────────────────────
DEVLOG_STATE_DIR="$HOME/.devlog"
