# Prompt 设计说明

这套系统有三处用到 LLM prompt，理念都不同，特此记录。

## 1. plugin/scripts/tick — 30 分钟蒸馏

**目标**：把过去 30 分钟的对话蒸馏成 2-4 行 bullet，给晚间整合用，不是给人读的最终态。

**关键约束**：
- 时间戳必须用 bash 注入的 `$TIME`，禁止 Claude 自己编（v0.1 踩坑：模型瞎填 22:30 而当时是 16:48）
- 没料就允许写"无显著进展"——比强行编故事好
- 不要长 prose，只要 bullet
- 单引号 vs 双引号要小心：`'...'"$TIME"'...'` 才能让 bash 注入

## 2. bin/devlog-daily.sh — 日终合成

**目标**：让三个月后的自己**30 秒能扫读，2 分钟能读懂**。

**结构强约束**（7 段）：
1. frontmatter（机器可读，Dataview 用）
2. 标题
3. TL;DR callout（< 30 字）
4. 主线（2-5 条，每条 problem/process/conclusion 三件套）
5. 数据卡片（WakaTime 量化）
6. 收获 / 踩坑（只放跨场景非显然的）
7. 折叠区（如果有）

**核心理念**："不依赖 git，因为 git 只是 artifact，不是 process knowledge"——这句话直接写进 prompt。

**踩坑**：早期 prompt 没明示"段落要短"，模型出长 prose；加了"每段最多 3-4 句"立刻见效。

## 3. bin/devlog-consolidate.sh — 长期记忆蒸馏

**目标**：把 14 天前的日记**压到 15-20% 体量**，只保留"12 个月后仍有价值"的内容。

**严格筛选规则**：
- 反复踩的坑：必须**跨多天 / 多场景**才放
- 决策：别记 minor cleanup
- 不放 commit hash（12 月后无意义）
- 每条教训必须带"为什么"和"怎么避免"

**目标读者**：未来的你，1 年后回顾"3 月份在搞什么"。

---

## 模型选择建议

默认用 `claude` CLI（哪个模型由 Claude Code 配置决定）。对 tick 这种小任务，Haiku 已经够用；对日终合成和长期蒸馏，Sonnet/Opus 输出更可读。

如果你想固定特定模型，改 `DEVLOG_CLAUDE_BIN` 调一个带 `--model` 参数的 wrapper script。

## 调 prompt 的建议

改完任何 prompt 后想立刻看效果：

```bash
# 清掉 5/18 重生
rm <vault>/代码日记/2026-05-18.md
DEVLOG_FORCE_TODAY=  ~/bin/devlog-daily.sh  # 不带 FORCE_TODAY，让它走 LOOKBACK 补 5/18
```

或更猛：临时把 `DEVLOG_LOOKBACK_DAYS` 拉到 30，删几个日子的 .md，让脚本批量重生。
