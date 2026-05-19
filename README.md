# claude-devlog

> 让 Claude Code 把每天的"工作过程知识"自动写成开发日记，并随时间蒸馏成长期记忆。

用 **Claude Code plugin hooks** 持续抓 session 上下文（你在想什么、纠结什么、放弃什么）+ **WakaTime API** 拿量化数据（时长、项目分布、AI 用量），每晚合成一份结构化、可扫读、可 Dataview 查询的 Markdown 日记，存进 Obsidian vault。

> 单用户的个人工具，不是 SaaS。设计目标是放进 `~/.devlog/` 跑着，不打扰，遗忘式记忆。

---

## 数据流

```
┌─────────────────────────────────────────────┐
│  你和 Claude Code 写代码                    │
└───────────────────┬─────────────────────────┘
                    │
       ┌────────────┴────────────┐
       ▼                         ▼
  PostToolUse                 WakaTime
  / Stop hook                 IDE plugin
       │                         │
       ▼                         ▼
  plugin/scripts/            wakatime.com
  tick (30min 节流,           (你的账户)
   防递归)                       │
       │                         │
       ▼                         │
  ~/.devlog/_drafts/             │
   YYYY-MM-DD-<session>.md       │
       │                         │
       └────────────┬────────────┘
                    ▼  (21:00 launchd / 合盖 sleepwatcher)
            bin/devlog-daily.sh
            ├─ 读 _drafts/*
            ├─ 拉 WakaTime summaries API
            ├─ 喂 claude -p（只写正文，frontmatter+数据卡片由脚本拼）
            └─ 写 <vault>/YYYY-MM-DD.md
                    │
                    ▼  (顺带触发)
            bin/devlog-consolidate.sh
            └─ ≥14 天的老日记 → <vault>/_长期记忆.md
```

## 组件清单

| 文件 | 角色 |
|------|------|
| `plugin/` | Claude Code 插件（PostToolUse / Stop / SessionEnd hooks） |
| `bin/devlog-daily.sh` | 每日合成主脚本 |
| `bin/devlog-consolidate.sh` | 长期记忆蒸馏脚本 |
| `bin/sleep-trigger.sh` | sleepwatcher 钩子（合盖触发） |
| `launchd/com.user.devlog.plist` | 22:00 定时调度（macOS launchd） |
| `config.example.sh` | 配置模板，install 时复制到 `~/.devlog/config.sh` |
| `install.sh` | 幂等安装器 |

## 三类输出文件

```
<DEVLOG_VAULT_DIR>/                  ← Obsidian vault 里的目录
├── 2026-05-19.md                    ← 当日日记（frontmatter + TL;DR + 主题 + 数据卡片）
├── 2026-05-18.md
├── ... 最近 14 天 ...
└── _长期记忆.md                     ← 超过 14 天的明细蒸馏到这里
```

## 日记结构

每份日记长这样：

```yaml
---
date: 2026-05-19
total_minutes: 184                   # WakaTime 算出
projects: [ai_demo, devlog-plugin]   # 当日涉及的项目
languages: [Bash, Markdown, Go]
type: devlog
---

# 2026-05-19 开发日记

> [!tldr] 一句话总结
> self-test 卡 120s 一路挖到三层根因，顺手给 install 链补 timeout 护栏。

## 主题 1：精炼的问题名

**问题/动机**：今天为什么搞这个。
**过程**：试了什么、想了什么、踩了什么。
**结论/选择**：最终选什么、放弃什么、留什么 follow-up。

> [!note]- 细节
> - 涉及的文件、决策点

---

## 主题 2：...

> [!abstract] 数据
> - **时长**：3 小时 4 分
> - **项目**：proj1 (58%), proj2 (8%)
> - **AI**：50 prompts, 988M input tokens, $0.41

> [!tip] 值得记住的
> - 跨场景的非显然教训
```

`type: devlog` + frontmatter 让 Obsidian Dataview 插件能直接查询：

````markdown
```dataview
TABLE total_minutes / 60 AS "小时", join(projects) AS "项目"
FROM "代码日记"
WHERE type = "devlog"
SORT date DESC
```
````

## 安装

### 前置依赖

- macOS（launchd + sleepwatcher 是 macOS-specific；Linux 需要自己改 systemd timer）
- [Claude Code](https://claude.com/claude-code)
- Obsidian（或任何能读 Markdown 的工具）
- 一个 Obsidian vault（建议放 Google Drive/iCloud/Syncthing 自动同步）
- `sleepwatcher`（可选，合盖触发用）：`brew install sleepwatcher`
- WakaTime 账户（可选，要时长数据的话）

### 安装步骤

```bash
git clone https://github.com/YOUR/claude-devlog.git ~/go/src/claude-devlog
cd ~/go/src/claude-devlog
./install.sh
```

`install.sh` 会：
1. 复制 `config.example.sh` 到 `~/.devlog/config.sh`（首次安装）
2. 软链 `bin/*.sh` 到 `~/bin/`
3. 软链 `bin/sleep-trigger.sh` 到 `~/.sleep`
4. 渲染 plist 到 `~/Library/LaunchAgents/com.user.devlog.plist` 并 load
5. 检测 sleepwatcher 状态并提示
6. 注册 Claude Code plugin（marketplace + install）

### 配置

编辑 `~/.devlog/config.sh`，至少填两项：

```bash
DEVLOG_VAULT_DIR="$HOME/Documents/Obsidian/MyVault/代码日记"
DEVLOG_CLAUDE_BIN="$HOME/.local/bin/claude"
```

其他参数（`DEVLOG_KEEP_DAYS`、`DEVLOG_EOD_HOUR` 等）有合理默认，按需调。

### WakaTime（可选但推荐）

1. 注册 wakatime.com，从 https://wakatime.com/api-key 拿 key
2. 写 `~/.wakatime.cfg`：
   ```ini
   [settings]
   api_key = waka_xxxxxxxx
   api_url = https://api.wakatime.com/api/v1
   ```
3. 在 IDE 装 WakaTime 插件指向同一 key

脚本会自动从 `~/.wakatime.cfg` 读 key 调 summaries API。

### sleepwatcher（推荐）

```bash
brew install sleepwatcher
brew services start sleepwatcher
```

合盖时（hour ≥ `DEVLOG_SLEEP_TRIGGER_HOUR`，默认 17）自动触发当天日记生成。

---

## 触发时机

| 触发源 | 行为 |
|--------|------|
| **sleepwatcher 合盖** | hour ≥ 17 → 强制生成今天的日记（最准） |
| **launchd 22:00** | 准点跑；通常被合盖错过，但醒来时 launchd 会自动补跑 |
| **第二天开盖** | launchd catch-up 补齐过去 14 天里"缺失但有数据"的日子 |
| **手动** | `DEVLOG_FORCE_TODAY=1 ~/bin/devlog-daily.sh` |

## 常用命令

```bash
# 立刻跑一次日报（不必等到合盖）
DEVLOG_FORCE_TODAY=1 ~/bin/devlog-daily.sh

# 立刻跑一次蒸馏
~/bin/devlog-consolidate.sh

# 看运行日志
tail -f ~/.devlog/_run.log
tail -f ~/.devlog/_tick.log

# 看 launchd 任务状态
launchctl list | grep com.user.devlog

# 暂停整套系统
launchctl unload ~/Library/LaunchAgents/com.user.devlog.plist
brew services stop sleepwatcher

# 卸载 Claude plugin
claude plugin uninstall devlog@claude-devlog
claude plugin marketplace remove claude-devlog
```

## 设计要点 / FAQ

### 多个 Claude session 同时跑会冲突吗？

每个 session 各自 tick 独立 state file，draft 文件名带 session_id 不冲突。`devlog-daily.sh` 加了 mkdir-lock 防并发。

### 数据隐私？

- 所有 draft / 日记都在你本地（vault 同步到 cloud 看你怎么配 Obsidian）
- Claude session 内容会经过 Claude API 蒸馏（你已经在用 Claude Code 了，这是原有信任范围内）
- WakaTime 数据会上 wakatime.com（不想要就别配，跳过这一层）
- API key 只在 `~/.wakatime.cfg`，repo 已 `.gitignore` 防误推

### Obsidian 必需吗？

不需要。日记就是普通 Markdown，任何文本编辑器都能看。Obsidian + Dataview 是为了把 frontmatter 做成查询，可有可无。

### Linux/Windows 怎么办？

- Linux：把 `launchd plist` 换成 systemd timer，`sleepwatcher` 换成 `systemd-suspend.target` 钩子或 [acpi-events](https://wiki.archlinux.org/title/Acpid)
- Windows：scheduled task + `psm` 监听 lid event；scripts 本身基于 bash + python3，wsl/git bash 应该能跑

---

## License

MIT
