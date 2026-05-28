# claude-devlog

> 让 Claude Code 把每天的"工作过程知识"自动写成开发日记。

用 **Claude Code plugin hooks** 持续抓 session 上下文（你在想什么、纠结什么、放弃什么）+ **WakaTime API** 拿量化数据（时长、项目分布、AI 用量），每天合成一份结构化、可扫读、可 Dataview 查询的 Markdown 日记，存进 Obsidian vault。

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
  PostToolUse / Stop          WakaTime
  / SessionEnd hook           IDE plugin
       │                         │
       ▼                         ▼
  plugin/scripts/tick         wakatime.com
  ├─ 30min 节流抓 session       (你的账户)
  │   片段 → _drafts/             │
  └─ 退出时触发 ↓                 │
       │                         │
       ▼                         │
  bin/devlog-daily.sh ◀──────────┘
  ├─ 读 ~/.devlog/_drafts/*
  ├─ 拉 WakaTime summaries API
  ├─ 喂 claude -p（只写正文，frontmatter+数据卡片由脚本拼）
  ├─ 写 <vault>/YYYY-MM-DD.md
  └─ 顺带清理：删掉 <vault> 里超过 KEEP_DAYS(默认30) 天的老日记
```

> 触发完全靠 Claude Code 插件 hook——hook 进程跑在你的会话里，继承终端的磁盘访问权限，能写 Obsidian vault 而不弹 macOS 权限框。不依赖 launchd / sleepwatcher。

## 组件清单

| 文件 | 角色 |
|------|------|
| `plugin/` | Claude Code 插件：hooks 抓 session 片段 + 触发日终合成 |
| `bin/devlog-daily.sh` | 每日合成主脚本（顺带清理超期老日记） |
| `config.example.sh` | 配置模板，install 时复制到 `~/.devlog/config.sh` |
| `install.sh` | 幂等安装器 |

## 输出文件

```
<DEVLOG_VAULT_DIR>/                  ← Obsidian vault 里的目录
├── 2026-05-19.md                    ← 当日日记（frontmatter + TL;DR + 主题 + 数据卡片）
├── 2026-05-18.md
└── ... 最近 KEEP_DAYS(默认30) 天 ... ← 超期的老日记会被直接删除
```

## 日记结构

每份日记长这样：

```markdown
---
date: 2026-05-19
total_minutes: 184
projects: ["ai_demo", "devlog-plugin"]
languages: ["Bash", "Markdown", "Go"]
type: devlog
---

# 2026-05-19 开发日记

> [!tldr] 一句话总结
> self-test 卡 120s 一路挖到三层根因，顺手给 install 链补 timeout 护栏。

### self-test 卡 120s 挖到第三层根因

**问题/动机**：1 句话，今天为什么搞这个。
**过程**：1-2 句话，试了什么、想了什么、踩了什么。
**结论/选择**：1-2 句话，最终选什么、放弃什么、留什么 follow-up。

> [!note]- 细节
> - 涉及的文件、决策点

---

### <下一个主题>...

> [!tip] 值得记住的
> - 跨场景的非显然教训

---

> [!abstract] 数据
> - **时长**：3 小时 4 分
> - **项目**：ai_demo (58%)、devlog-plugin (8%)
> - **语言**：Bash, Markdown, Go
> - **AI**：50 次 prompt、988 万 input / 6 万 output tokens、$0.41
```

frontmatter / 标题 / 数据卡片由脚本侧直接拼（量化数字全来自 WakaTime，模型碰不到）；`> [!tldr]` 到 `> [!tip]` 之间的正文才是 `claude -p` 写的。

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

- [Claude Code](https://claude.com/claude-code)
- `python3`、`bash`、`curl`（macOS 自带）
- Obsidian（或任何能读 Markdown 的工具）
- 一个 Obsidian vault（建议放 Google Drive/iCloud/Syncthing 自动同步）
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
3. 注册并安装 Claude Code plugin（marketplace add + install）

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

---

## 触发时机

触发完全靠 Claude Code 插件 hook，不需要任何系统级定时器：

| 触发源 | 行为 |
|--------|------|
| **每 ~30min（工作中）** | tick 抓一次 session 片段；顺带跑一次 `devlog-daily.sh` |
| **会话结束（SessionEnd）** | tick 收尾抓一次 + 跑 `devlog-daily.sh` |
| **手动** | `DEVLOG_FORCE_TODAY=1 ~/bin/devlog-daily.sh` |

`devlog-daily.sh` 幂等：今天的日记过 `DEVLOG_EOD_HOUR`（默认 21:00）才生成；过去 14 天里"缺失但有数据"的日子会在下次跑时自动补齐。所以哪怕几天没开 Claude Code，再开时也会一次性补全。

## 常用命令

```bash
# 立刻跑一次日报
DEVLOG_FORCE_TODAY=1 ~/bin/devlog-daily.sh

# 看运行日志
tail -f ~/.devlog/_run.log
tail -f ~/.devlog/_tick.log

# 暂停整套系统（卸载 plugin，hook 不再触发）
claude plugin uninstall devlog@claude-devlog

# 彻底移除
claude plugin marketplace remove claude-devlog
```

## 设计要点 / FAQ

### 多个 Claude session 同时跑会冲突吗？

每个 session 各自 tick 独立 state file，draft 文件名带 session_id 不冲突。多个 session 的 tick 可能同时触发 `devlog-daily.sh`，靠 mkdir-lock 防并发——抢到锁的跑，其余直接跳过。

### 为什么不用 launchd / cron 定时？

vault 通常放在 `~/Library/CloudStorage/`（Google Drive 等），这是 macOS TCC 保护目录。launchd / cron 起的进程没有"有磁盘访问权限的祖先"，写 vault 会弹授权框、且每次都弹。而插件 hook 跑在 Claude Code 会话里，进程继承终端的磁盘访问权限，写 vault 不弹框。代价是日记只在你用 Claude Code 时生成——但这工具记的就是 Claude Code 的活，不用它时本就无可记。

### 数据隐私？

- 所有 draft / 日记都在你本地（vault 同步到 cloud 看你怎么配 Obsidian）
- Claude session 内容会经过 Claude API 蒸馏（你已经在用 Claude Code 了，这是原有信任范围内）
- WakaTime 数据会上 wakatime.com（不想要就别配，跳过这一层）
- API key 只在 `~/.wakatime.cfg`，repo 已 `.gitignore` 防误推

### Obsidian 必需吗？

不需要。日记就是普通 Markdown，任何文本编辑器都能看。Obsidian + Dataview 是为了把 frontmatter 做成查询，可有可无。

### Linux/Windows 怎么办？

触发靠 Claude Code 插件 hook，不依赖任何 macOS 特性，理论上跨平台。脚本本身基于 `bash` + `python3` + `curl`：Linux 直接能跑，Windows 用 WSL / Git Bash 应该也行。`install.sh` 里的软链和 plugin 注册步骤跨平台通用。

---

## License

MIT
