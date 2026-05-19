# 架构详解

## 进程模型

```
启动顺序：
  1. macOS login → launchd 自启
     ├─ Claude Code（你需要时启动；plugin 随之启用）
     ├─ sleepwatcher daemon（监听 IOKit 睡眠事件）
     └─ com.user.devlog launchd agent（22:00 待命）

运行时事件：
  你和 Claude 写代码
        │
        ├─ 每次工具调用 → Claude Code 触发 PostToolUse hook
        │      ↓
        │   plugin/scripts/tick 异步起进程
        │      ↓
        │   检查节流 (last_tick > TICK_INTERVAL)
        │      ↓
        │   读 transcript jsonl，python 提取 user+assistant text
        │      ↓
        │   claude -p (DEVLOG_TICK_NESTED=1 防递归)
        │      ↓
        │   append ~/.devlog/_drafts/YYYY-MM-DD-<session>.md
        │
        ├─ Mac 进入睡眠 → sleepwatcher 触发 ~/.sleep
        │      ↓
        │   hour ≥ DEVLOG_SLEEP_TRIGGER_HOUR ?
        │      ├─ 是：DEVLOG_FORCE_TODAY=1 bin/devlog-daily.sh &  disown
        │      └─ 否：silently skip
        │
        └─ 22:00 → launchd 触发 (这一刻通常合盖中)
               ↓
            Mac 醒来时 launchd catch-up 补跑
               ↓
            bin/devlog-daily.sh (mkdir lock)
            ├─ 扫过去 LOOKBACK_DAYS 天找"无日报"的日子
            ├─ for each: 读 drafts + 拉 WakaTime → claude -p → 写 vault
            ├─ 清 drafts
            └─ bin/devlog-consolidate.sh (≥KEEP_DAYS 的进长期记忆)
```

## 文件系统布局

```
~/.devlog/                            ← 系统状态目录（不进 vault）
├── config.sh                         ← 用户配置（install.sh 从 config.example.sh 复制）
├── _drafts/                          ← 当日 tick 产物，每个 session 一个
│   └── 2026-05-19-<uuid>.md
├── _state/                           ← 每个 session 的 last-tick 时间戳
│   └── <uuid>
├── _run.log                          ← devlog-daily.sh 日志
├── _tick.log                         ← plugin/scripts/tick 日志
├── _consolidate.log                  ← devlog-consolidate.sh 日志
├── _sleep.log                        ← sleep-trigger.sh 日志
├── _launchd.out / _launchd.err       ← launchd 层日志
└── .daily.lock/                      ← mkdir-lock 防并发

<DEVLOG_VAULT_DIR>/                   ← Obsidian vault 内的目录
├── 2026-05-19.md
├── 2026-05-18.md
├── ... (最近 KEEP_DAYS 天)
└── _长期记忆.md                      ← 蒸馏累积
```

## 防御性设计

### 递归守护
任何脚本调 `claude -p` 前都注入 `DEVLOG_TICK_NESTED=1`。tick 入口检测到这变量立即 exit 0。否则：

```
tick → claude -p (新 session) → 新 session 调工具 → 触发 PostToolUse → tick → claude -p → ...
                                                                                 ↑
                                                                             4 分钟 70 个 draft
```

### 并发锁
`devlog-daily.sh` 用 `mkdir $STATE_DIR/.daily.lock` 当锁（POSIX 原子）。两个 daily 同时被触发时，第二个会立刻退出。否则两个并行写同一个 `.md` 文件，互相 truncate 出 0 字节文件。

### 失败兜底
- claude -p 返回非零或空输出：写"原始数据 fallback" 文件（带 draft + WakaTime JSON 全部原始内容）
- WakaTime API 挂：用空数据继续，日报会显示"未记录"
- transcript 不存在或不可读：tick 静默退出，不影响 hook 链

### 数据完整性
- 蒸馏成功才删原日记（rc=0 && file -s 才删）
- 日报成功才清 drafts
- 长期记忆 prepend 而非 overwrite，保留历史

## 性能 / 成本

| 操作 | 频率 | 单次成本（Claude API） |
|------|------|----------------------|
| tick | 16/工作日 | ~$0.01 |
| 日终合成 | 1/天 | ~$0.05-0.20 |
| 蒸馏 | 每 N 天一次 | ~$0.05 |

**总计**：$0.20-0.50/工作日，约 $5-10/月。

可优化：
- 改 `DEVLOG_TICK_INTERVAL=3600`（1 小时）减半
- tick 用更便宜的模型（wrapper script 加 `--model claude-haiku`）
- 不要 WakaTime（删 `~/.wakatime.cfg` 即可），节省 API 调用

## macOS-specific 依赖

| 用了什么 | 替代方案（其他平台） |
|---------|---------------------|
| `launchctl` | Linux: systemd; Windows: schtasks |
| `sleepwatcher` | Linux: systemd-sleep hooks; Windows: powercfg 事件 |
| `~/Library/LaunchAgents` | 平台无关位置即可 |
| `date -v-Nd` (BSD) | Linux GNU date: `date -d "-N days"` |

scripts 没用其他 macOS-only 特性。改 `date -v` 调用就能跨平台。

## 安全考量

- `~/.wakatime.cfg` 包含明文 API key → `chmod 600`
- `~/.devlog/config.sh` 包含 vault 路径（不敏感，但建议 600）
- `.gitignore` 排除运行时数据和真实 config
- transcript 含你和 Claude 的全部对话 → 会被部分送 Claude API 蒸馏（信任边界没变化）
- 不会上报任何东西到第三方（除 WakaTime + Anthropic API）
