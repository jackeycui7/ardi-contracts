# Ardinals ($ardi) 执行报告

> AWP · Ardi WorkNet
> 2026 年 5 月 · v0.2

---

## 1. 核心概要

Ardinals 是 AWP 上的 WorkNet。AI agent 解多语言谜题铸造词语 NFT（21,000 上限）。NFT holder 通过 power 加权获得 $ardi emission。经济体通过三层 sink（维修 + Forge + Games）消耗 $ardi，维持健康的 Token Sink Ratio。

### Token 结构

| Token | 总量 | 用途 |
|-------|------|------|
| $ardi | 10B | 9B 在 180 天内释放给 NFT holder；1B 永久锁仓 LP（配 1M $AWP） |
| Ardinal NFT | 21K 上限 | 词语铭文。三个属性：Power、Durability、Element |
| $AWP | 协议 token（$0.001） | Agent staking（10K/agent） |

LP 开盘 FDV = $10K。实际 FDV 假设阶梯：$1M / $10M / $100M / $1B。

### NFT 三属性

| 属性 | 来源 | 范围 | 作用 |
|------|------|------|------|
| Power | Mint 时链上随机 | 1-100（均值 ~28） | 决定 emission 份额和修复成本 |
| Durability | Mint 时链上随机 | 1-14（加权均值 ~5） | 决定修复频率和失败风险 |
| Element（五行） | Mint 时 LLM 根据词义判定 | 金/木/水/火/土 | v1 纯标签；后续激活 Duel 克制和 Raid 弱点 |

Power 和 Durability 独立随机，不关联。这创造二维稀缺性：

| | 低 Durability | 高 Durability |
|---|---|---|
| **高 Power** | 玻璃大炮：高收益、高维护、高风险 | 神装：极稀有，市场溢价 |
| **低 Power** | 最差，但便宜，forge 材料 | 佛系持仓：低收益但省心 |

---

## 2. Emission 设计

### 两阶段释放

| 阶段 | 时间 | 占比 | 半衰期 | 说明 |
|------|------|------|--------|------|
| Phase 1 | Day 1-14 | 30%（2.7B） | 5 天 | 早期高 emission 吸引参与 |
| Phase 2 | Day 15-180 | 70%（6.3B） | 30 天 | 长尾释放，sink 已全面运转 |

### 关键 emission 数据

| Day | 日 Emission | 累计 |
|-----|------------|------|
| 1 | 408M | 408M |
| 7 | 178M | 2.0B |
| 14 | 67M | 2.7B（Phase 1 结束） |
| 30 | 104M | 4.7B |
| 60 | 52M | 6.9B |
| 180 | 3M | 9.0B（全部释放） |

---

## 3. 新增机制

### 机制 1：Durability + Repair（链上随机）

**概述：** 每张 NFT 有耐久度。耐久归零后 NFT 停止产出，需要付费修复。1% 概率修复失败，必须通过 forge 重生。

**Mint：** 链上随机生成 durability 值（1-14），加权分布使均值 ≈ 5。低 durability 更常见，高 durability 稀有。

**耐久消耗：** 每天 -1。归零 = 停产。

**修复定价（方式 B：epoch 定价）：**

```
全局单价（每日更新）= 0.5 × 当日总 emission / 总活跃 power
修复费用 = 单价 × NFT 的 power × NFT 的 durability
```

效果：每张 NFT 的修复费用 = 该 NFT 一个 durability 周期内 emission 产出的 50%。无论 durability 高低，日净收益率相同（~50%）。高 durability 的优势在于修复频率低、失败风险低。

**修复失败（1% 概率）：**
- 修复时 1% 概率失败
- 失败的 NFT 无法正常修复，必须通过 forge 与另一张 NFT 合成来重生
- 支付 forge fee（20,000 $ardi）
- 牺牲一张 NFT
- 原 NFT 恢复满耐久

**失败风险与 durability 的关系：**

| Durability | 年修复次数 | 年预期失败次数 |
|------------|-----------|-------------|
| 1 天 | 365 | 3.7 |
| 3 天 | 122 | 1.2 |
| 5 天（均值） | 73 | 0.7 |
| 7 天 | 52 | 0.5 |
| 14 天 | 26 | 0.3 |

低 durability NFT 自然被更频繁地回收，推动整体 NFT 品质上升。

### 机制 2：Element / 五行（LLM 判定）

**概述：** Mint 时 LLM 根据词语语义判定五行属性（金/木/水/火/土），写入 NFT metadata。

**v1 阶段：** 纯标签，无经济影响。不参与 emission 计算、不影响修复费用、不影响 forge。

**后续激活计划：**
- Day 14（Word Duel 上线）：五行克制关系生效（金克木、木克土、土克水、水克火、火克金）
- Day 45（Raid 上线）：Boss 有元素弱点
- 后续版本：Sentence Forge 可奖励五行齐全的句子组合

**设计意图：** 上线前即创造投机话题（"哪个元素未来最值钱？"），零成本的早期营销素材。

---

## 4. 三层 Sink 体系

### 4.1 Maintenance（目标：emission 的 50%）

最大的 sink。通过 repair 机制消耗 $ardi。自动随 emission 和 NFT 数量同比缩放。

维修费用 = 全局单价 × power × durability。全局单价每日由协议根据当日 emission 和总活跃 power 更新。

### 4.2 Forge（base fee: 20,000 $ardi）

两张 NFT 进 forge，LLM 评估语义兼容度。成功出 1（更高 power）、失败烧 1（低 power）。无论成败收费。

| 费用组件 | 金额 | 去向 |
|---------|------|------|
| Base forge fee | 20,000 $ardi | 50% burn / 50% treasury |
| Re-forge 溢价 | +50%（第 2 次尝试） | 同上 |
| Discovery fee | +5,000（重复词对组合） | 同上 |
| Generation 溢价 | +10%/gen | 同上 |

Forge fee 在不同 FDV 下的美元价值：

| FDV | Forge fee（$） | 说明 |
|-----|---------------|------|
| $1M | $2 | 极低，forge 活跃 |
| $10M | $20 | 合理 |
| $100M | $200 | 偏高，需治理下调 |

**Forge rate 控制在 1.2-2.8%/天。** 更高的 forge rate 会触发悖论：烧 NFT → 维修基数缩小 → 总 sink 下降。

### 4.3 Games（direct-burn 模型）

| 游戏 | 上线 | 入场费 | Burn % | 机制 |
|------|------|--------|--------|------|
| Word Duel | Day 14 | 3,000/人 | 50% | 1v1，LLM 判定词-主题相关度。v2 激活五行克制 |
| Sentence Forge | Day 21 | 8,000/次 | 60% | 用持有的词组句，LLM 评分 |
| Raid | Day 45 | 12,000/人 | 50% | 5 人组队 vs 语义 Boss。v2 激活元素弱点 |

---

## 5. 数值模拟结果

### 推荐参数

| 参数 | 值 |
|------|-----|
| Phase 1 / Phase 2 | 30% / 70% |
| Maintenance target | 50% of emission |
| Durability 范围 | 1-14（加权均值 ~5） |
| Repair failure rate | 1% |
| Forge base fee | 20,000 $ardi |
| Forge rate | 1.2-2.8%/天 |
| Game burn rate | 50-60% |
| Diamond hands 假设 | ~50% holder |

### 180 天概览

| 指标 | 值 |
|------|-----|
| 平均 TSR | 0.70 |
| 总 sink | 4.9B（54%） |
| 其中 Maintenance | 4.4B（89%） |
| 其中 Forge | 385M（8%） |
| 其中 Games | 135M（3%） |
| Day 180 存活 NFT | 2,650 |
| 总修复次数 | 204,053 |
| 修复失败 | 2,018 |
| Forced forge | 2,018 |
| Voluntary forge | 14,113 |
| 总 forge | 16,131 |

### Day 1-14 关键数据

| Day | Emission | TSR | Maint% | 修复次数 | 修复失败 | 存活 NFT |
|-----|----------|-----|--------|---------|---------|---------|
| 1 | 408M | 0.17 | 17% | 25 | 0 | 216 |
| 2 | 355M | 0.33 | 33% | 96 | 1 | 551 |
| 3 | 309M | 0.32 | 32% | 139 | 1 | 1,001 |
| 5 | 234M | 0.40 | 40% | 280 | 3 | 2,216 |
| 7 | 178M | 0.47 | 46% | 453 | 5 | 3,782 |
| 10 | 117M | 0.51 | 50% | 663 | 7 | 6,302 |
| 14 | 67M | 0.52 | 50% | 862 | 9 | 9,099 |

**v1（固定 durability=7）对比：** Day 1-6 TSR 为零，Day 7 才跳到 0.51。新机制从 Day 1 就有 sink（TSR=0.17），结构性缺口基本消除。

### FDV 卖压矩阵

| Day | 可卖 $ardi | FDV $1M | FDV $10M | FDV $100M |
|-----|-----------|---------|----------|-----------|
| 1 | 170M | $17K | $170K | $1.7M |
| 7 | 47M | $5K | $47K | $470K |
| 14 | 16M | $2K | $16K | $160K |
| 30 | 23M | $2K | $23K | $230K |
| 60 | 5M | $500 | $5K | $50K |

---

## 6. 链上实现要点

### Mint

1. 链上随机生成 power（1-100）和 durability（1-14，加权）
2. LLM 判定 element（金/木/水/火/土），通过 oracle 写入 metadata
3. 三个属性写入 NFT，不可变

### 每日协议操作

1. 计算当日 emission，按 power 加权分配给耐久 > 0 的 NFT
2. 所有 NFT 耐久 -1
3. 更新全局修复单价：`0.5 × 当日 emission / 总活跃 power`

### 修复交易

1. 玩家调用 repair(tokenId)
2. 合约计算费用 = 全局单价 × power × durability
3. 扣除 $ardi（burn 或进 treasury）
4. 1% 概率判定失败：失败则 NFT 标记为 broken，需要 forge 重生
5. 成功则恢复满耐久

### Forge 交易

1. 玩家调用 forge(tokenA, tokenB)（tokenA 可以是 broken 状态）
2. 扣除 forge fee
3. LLM oracle 评估语义兼容度
4. 成功：burn 两张，产出一张新 NFT（更高 power，新 durability 随机，element 继承或 LLM 重新判定）
5. 失败：burn 低 power 那张，保留高 power 那张

---

## 7. 时间线

| 时间 | 事件 |
|------|------|
| Day 0 | LP 上线（1B $ardi + 1M $AWP）；合约部署 |
| Day 1 | Mint 开始；Emission 开始；Repair 机制生效 |
| Day 1-2 | 首批低 durability NFT 到期，maintenance sink 启动 |
| Day 7 | Forge 开放 |
| Day 14 | Phase 2 开始；Word Duel 上线 |
| Day 21 | Sentence Forge 上线 |
| Day 45 | Raid 上线 |
| Day 180 | Emission 结束 |
| 后续 | 五行克制激活；新游戏模式 |

---

## 8. 治理参数（可调）

以下参数通过 Timelock 治理调整，不需要升级合约：

| 参数 | 初始值 | 何时调 |
|------|--------|--------|
| Maintenance target | 50% | 如 holder 反馈太重，降到 40% |
| Forge base fee | 20,000 $ardi | FDV 增长 10 倍以上时下调 |
| Repair failure rate | 1% | 如 NFT 缩减太快则降低 |
| Game entry fees | 3K-12K | 根据参与率调整 |
| Game burn rates | 50-60% | 根据 sink 贡献调整 |

---

> 模拟代码：`ardi_sim_v2.py`。数据：`ardi_sim_v2_results.json`。
> 研究报告（完整版）：`ardi_token_economics_report.md` / `.docx`。
