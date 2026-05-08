# Ardinals Forge — 当前数值 (v1, testnet 已跑通)

> 内部对齐稿 — 给 sky / leslie 过目。所有数值都是当前 Sepolia testnet
> `ArdiNFTv4Testnet` 实跑的版本，未来主网上线前可改。
>
> **最后更新**: 2026-05-08
> **基础规格**: leslie v2.1 + sky 修订（element 改 VRF, dur=A+B 不取 max）

---

## 1. 输入与输出

| | 内容 |
|---|---|
| **输入** | 用户拥有的两张 NFT (A + B)，任何状态（含 broken）|
| **费用** | 20,000 aARDI（无论成败都收）|
| **A + B** | **必烧**（无论成败）|
| **成功输出** | 1 张新 NFT，wordId / tokenId ≥ 21,001 |
| **失败输出** | 无（A + B 已烧，fee 已收）|

设计意图：成功路径单 NFT 出，失败路径无补偿，gambling 体验明确。

---

## 2. 相似度评分（链上）

```
matchScore = round( cosine(embeddingA, embeddingB) × 100 )
           ∈ [0, 100]   整数
```

embedding：96 维 int8，存在 sealed `EmbeddingStore` 合约。
原始词由 `all-MiniLM-L6-v2` + PCA 降维生成；合成词的 embedding 由
oracle 算后写回 NFT 合约本地 mapping。

**全部链上跑，可独立验证。** 单次 forge 链上 cosine 多 ~25K gas（Base
上 ~$0.0008），可接受。

---

## 3. 档位（Tier）

```
score   tier      success    mult         crit         specials
─────   ────────  ─────────  ───────────  ──────────  ──────────
81-100  T5 双胞胎   90%       1.2 - 1.4×    —            —
61-80   T4 相似     75%       1.3 - 1.5×    —            —
41-60   T3 相关     55%       1.7 - 2.0×    1% × 1.5     —
21-40   T2 疏远     35%       2.2 - 3.0×    5% × 1.5     —
 0-20   T1 狂野     20%       3.5 - 5.5×   15% × 2.0    Mythic 1% (+20% pwr)
                                                         God Touch 0.1% (element=GOD)
```

边界等距 20，简单直观。

---

## 4. 成功输出公式

| 字段 | 公式 | 状态 |
|---|---|---|
| **newPower** | `(powerA + powerB) × multBps / 10000`<br>Mythic 命中再 × 1.2 | ✅ 锁定 |
| **newMaxDur** | `min(durA + durB, 30)`，至少 1 | ✅ 锁定 (sky 2026-05-08) |
| **newCurDur** | = newMaxDur（满耐久 mint）| ✅ 锁定 |
| **element** | VRF 随机 1-5（metal / wood / water / fire / earth）<br>God Touch 命中：强制 = 6 (god) | ✅ 锁定 |
| **language** | TBD — 当前是 LLM 决定（跟着 newWord 走）| ⏸ 待定 |
| **newWord** | LLM 选词（不能撞库），冲突 8 次后追加后缀保证成功 | ✅ 锁定 |

---

## 5. 期望值（EV）分析

**期望产出 = 成功率 × 期望倍率**，不计 crit/mythic/god：

| Tier | 成功率 | 期望倍率 | EV |
|---|---|---|---|
| T1 | 20% | 4.5× | 0.90 |
| T2 | 35% | 2.6× | 0.91 |
| T3 | 55% | 1.85× | 1.02 |
| T4 | 75% | 1.4× | 1.05 |
| T5 | 90% | 1.3× | **1.17** |

加上 crit / mythic / god 尾部赔率（仅 T1-T3 有 crit）：

| Tier | EV (含尾部) |
|---|---|
| T1 | ~1.05 - 1.10 |
| T2 | ~0.95 |
| T3 | ~1.04 |
| T4 | 1.05 |
| T5 | **1.17** |

**T5 EV 最高、T1 方差最大、中间档接近 break-even**。整体微通胀（power
总量略升），但配合 fee 烧 20K aARDI / 次 + 烧 2 张 NFT，**总价值层面是
通缩**（power 增加但 NFT 数量减半 + token 烧）。

---

## 6. 信任模型 / 决策分割

| 决策 | 来源 | 理由 |
|---|---|---|
| matchScore | **链上 cosine** | 可验证 |
| tier | **链上分桶** | 可验证 |
| success / mult / crit / mythic / godTouch / element | **链上 VRF 推导** | sky 强制：影响价值的不能让 server 决定 |
| newWord | LLM (oracle 签名) | 不影响价值，只是 flavor |
| 词唯一性 | 链上 `wordHashTaken` mapping | 强保证，撞词 revert |

**LLM 只能拼词，不影响经济。** sky 原话："涉及到燃烧 NFT、数值改变，不能让中心化服务器去做。"

---

## 7. 费用与销毁（动态公式，k=7 已拍板 2026-05-08）

```
forgeFee = k × dailyEmission / totalActivePower × (Pa + Pb)
         = 7 × 24,000,000 / totalActivePower × (Pa + Pb)
```

语义：**"两张 NFT 的 power 在 7 天里本来能赚的 emission"** 作为合成代价烧掉。

| 项 | 值 |
|---|---|
| **k** | 7 |
| **dailyEmission** | 24,000,000 aARDI（合约外参数 / 配置）|
| **totalActivePower** | 链上读 `totalActivePower()`（含活跃 NFT 总 power）|
| **forgeBurnBps** | 10,000 = 100% 烧到 0xdead |
| 撞词退款 | 已废弃（suffix-fallback 保证成功，无退款路径）|
| 输入 NFT | 无论成败全烧 |

### 当前链上典型 fee（totalActivePower=767K，2026-05-08）

| 配对类型 | Pa+Pb | Fee |
|---|---|---|
| 双低 (20+20) | 40 | 8,756 aARDI |
| 双 median (43+43) | 86 | **18,825** |
| 高配 (100+100) | 200 | 43,782 |
| 怪兽 (300+300) | 600 | 131,346 |

预期日烧 ~1.88M aARDI（按 100 forge/d、avg Pa+Pb=86）= **7.8% 的 emission**。
长期（totalActivePower 涨到 1.9M 时）fee 自动减半，sink 占比保持稳定。

---

## 8. 上限

| 项 | 值 | 备注 |
|---|---|---|
| ORIGINAL_CAP | 21,000 | 原始词库总数 |
| DUR_CAP | 30 | 合成后耐久封顶 |
| MAX_MINTS_PER_AGENT | 5 | 合约层 inscribe 计数；**forge 是否计数 → 待 sky 确认** |
| nextForgedWordId | 21,001+ | 单调递增 |

---

## 9. 可调 vs 不可调

**owner 可在线调：**
- forgeBaseFee（费用）
- forgeBurnBps（烧比）
- forgeOracle 地址

**升级才能改：**
- 5 档边界（20/40/60/80）
- 各档 success / mult / crit 概率
- Mythic / GodTouch 概率与效果
- Element pool（5 选 1）
- DUR_CAP

---

## 10. 待 sky / leslie 拍板

| 题 | 当前默认 | 备选 |
|---|---|---|
| forge 是否计入 MAX_MINTS_PER_AGENT (5)？ | TBD | a) 不计，可无限合 b) 计入，每人 5 张上限 |
| newLanguage 怎么定？ | LLM 跟词走 | a) VRF 二选一 (A.lang / B.lang) b) 固定英语 c) LLM 决定 (现行) |
| forgeBaseFee 是否阶梯？ | 固定 20K | a) 按 max(power) 阶梯 b) 按 sum(power) c) 固定 |
| Mythic +20% 是否再加耐久？ | 仅 +pwr | a) 仅 pwr b) +pwr 且 +1 dur c) +pwr 且回满 dur |
| God Touch 概率 0.1% 合理吗？ | 0.1% | 原始 god 词库占比 0.105%，匹配 |
| 中后期 EV 校准 | 微通胀 | 是否需要 sink 一些 power？|

---

## 11. testnet 实跑数据（截至 2026-05-08）

- Sepolia 部署：`ArdiNFTv4Testnet 0x3F8e…6552`
- 已 fulfill 的 forge：60+ 笔
- 5 个成功合成的新 NFT（21001-21005，pre-upgrade frozen）
- 跑通 case：
  - T5 `fire + flame → blaze`，×1.343
  - T4 `water + ocean`，×1.4
  - T1 `knife + ?`，失败烧
  - 多语言 `比特币 + 以太坊`、日韩语 mix forge
- 已修问题：
  - 撞词阻塞 → 后缀 fallback
  - 二次签名 UX → server-side fulfill
  - forged NFT 无法二次合 → 合约升级 + 本地 embedding map
  - Sepolia RPC 不稳 → 重试 + 链扫 fallback

---

## 12. 主网升级路径

testnet 用 standalone 合约（17,989 字节）；mainnet 必须 surgical clone
保 v322 storage layout（v322 已经 24,572/24,576 字节，4 字节余量）。

升级方式：UUPS upgrade 主网 v322 → v4，**不动用户已有 NFT**。
`fuse()` 函数从未启用，可剥离释放 ~3KB。

主网 v4 还需做的：
- `EmbeddingStore.addForgedWord(hash, embedding)` — 让 forge 词的
  embedding 也走 store，不再依赖 NFT 本地 map
- Chainlink VRF v2.5 集成（替换 testnet 的 MockRandomness）
- Emission distributor wired（forged NFT 自动加入活跃池）
- 完整继承 v322 的 repair / inscribe 行为

主网上线前还需 sky 拍板上面"待定"区的 6 个问题。
