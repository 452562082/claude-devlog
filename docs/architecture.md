# 架构详解

## 进程模型

devlog 没有常驻进程，也不用任何系统级定时器。一切由 Claude Code 插件 hook 驱动：

```
你和 Claude 写代码
      │
      ├─ 每次工具调用 → Claude Code 触发 PostToolUse / Stop hook
      │  会话结束 → SessionEnd hook
      │      ↓
      │   plugin/scripts/tick 异步起进程
      │      ↓
      │   检查节流 (last_tick > TICK_INTERVAL)；未到 → 退出
      │   （SessionEnd 豁免节流，必跑一次收尾）
      │      ↓
      │   武装 EXIT trap：tick 退出时跑 bin/devlog-daily.sh
      │      ↓
      │   读 transcript jsonl，python 提取 user+assistant text
      │      ↓
      │   claude -p (DEVLOG_TICK_NESTED=1 防递归)
      │      ↓
      │   append ~/.devlog/_drafts/YYYY-MM-DD-<session>.md
      │      ↓
      │   tick 退出 → EXIT trap 触发 ↓
      │
      └─ bin/devlog-daily.sh (mkdir lock 防并发)
         ├─ 扫过去 LOOKBACK_DAYS 天找"无日报"的日子
         ├─ for each: 读 drafts + 拉 WakaTime → claude -p → 写 vault
         ├─ drafts 留在 _drafts/（到期按 DEVLOG_DRAFT_KEEP_DAYS 清理）
         └─ bin/devlog-consolidate.sh (≥KEEP_DAYS 的进长期记忆)
```

`devlog-daily.sh` 幂等：没有缺失日期时几毫秒退出，所以每次 tick 退出都触发它也不费成本。今天的日记过 `DEVLOG_EOD_HOUR` 才生成；过去缺失的日子下次跑时自动补齐。

**为什么不用 launchd / cron**：vault 通常在 `~/Library/CloudStorage/`（macOS TCC 保护目录）。launchd / cron 起的进程没有"有磁盘访问权限的祖先"，写 vault 会反复弹授权框。tick 由 Claude Code 触发，进程继承终端的磁盘访问权限，写 vault 不弹框。

## 文件系统布局

```
~/.devlog/                            ← 系统状态目录（不进 vault）
├── config.sh                         ← 用户配置（install.sh 从 config.example.sh 复制）
├── _drafts/                          ← tick 产物，每个 session 一个；保留 N 天后清理
│   └── 2026-05-19-<uuid>.md
├── _state/                           ← 每 session 的 tick 时间戳 + 空白日标记
│   ├── <uuid>                         ← 上次成功蒸馏的时刻（slice 起点）
│   ├── <uuid>.attempt                 ← 上次尝试 tick 的时刻（节流依据）
│   └── .empty-YYYY-MM-DD              ← 已确认无活动的过去日期（不再探测）
├── _run.log                          ← devlog-daily.sh 日志
├── _tick.log                         ← plugin/scripts/tick 日志
├── _consolidate.log                  ← devlog-consolidate.sh 日志
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
                                                                          draft 指数级暴增
```

### 并发锁
`devlog-daily.sh` 用 `mkdir $STATE_DIR/.daily.lock` 当锁（POSIX 原子）。多个 daily 同时被触发时，只有抢到锁的跑，其余立刻退出——否则并行写同一个 `.md` 会互相 truncate 出 0 字节文件。锁若残留超过 60 分钟（正常 run 几分钟内结束），视为上个实例崩溃残留，自动清掉，避免泄漏的锁让系统永久静默罢工。

### 失败兜底
- tick 的 `claude -p` 失败：不前进 slice 起点（内容下次重试不丢），但更新 attempt 时间戳（仍按 `TICK_INTERVAL` 节流，不会每次工具调用都疯狂重试）
- daily.sh 的 `claude -p` 失败：写降级版日记（frontmatter + 原始 draft 片段 + 数据卡片），不丢数据
- WakaTime API 挂：用空数据继续，日报量化部分显示"未记录"
- transcript 不存在或不可读：tick 静默退出，不影响 hook 链

### 数据完整性
- drafts 合成后留在 `_drafts/`，过 `DEVLOG_DRAFT_KEEP_DAYS` 天才清——删了日记可基于留存的 draft 重生成
- 日记已存在但有更新的 draft → 自动重新生成，不丢当天后续的工作
- 蒸馏成功才删原日记（rc=0 且产物非空才删）
- 长期记忆 prepend 而非 overwrite，保留历史

## 性能 / 成本

每次 tick 是一次小 claude 调用。tick 退出触发 `devlog-daily.sh`，但它幂等——没有缺失或过期的日期时几毫秒退出、不调 claude。真正花钱的只有：

| 操作 | 何时 | 单次成本（约） |
|------|------|---------------|
| tick 抓片段 | 工作中每 ~30min | 小（输入/输出各几百 token） |
| 日终合成 | 当天日记首次生成，及之后有新 draft 时重生成 | 中 |
| 长期记忆蒸馏 | 每天一篇老日记跨过 14 天线 | 中 |

典型工作日合计几毛钱量级——具体随工作时长和模型价格浮动。

省钱开关：
- `DEVLOG_TICK_INTERVAL` 调大（如 3600 = 1 小时）→ 抓得少、重生成也少
- tick 套 wrapper 加 `--model claude-haiku` 用更便宜的模型
- 不配 WakaTime（删 `~/.wakatime.cfg`）→ 省掉量化数据那一路调用

## 跨平台

触发靠 Claude Code 插件 hook，不依赖 launchd / sleepwatcher 等 macOS 特性。唯一的平台相关点：

| 用了什么 | 替代方案（其他平台） |
|---------|---------------------|
| `date -v-Nd` (BSD) | Linux GNU date: `date -d "-N days"` |

改掉 `date -v` 调用即可在 Linux / WSL 上跑。

## 安全考量

- `~/.wakatime.cfg` 包含明文 API key → `chmod 600`
- `~/.devlog/config.sh` 包含 vault 路径（不敏感，但建议 600）
- `.gitignore` 排除运行时数据和真实 config
- transcript 含你和 Claude 的全部对话 → 会被部分送 Claude API 蒸馏（信任边界没变化）
- 不会上报任何东西到第三方（除 WakaTime + Anthropic API）
