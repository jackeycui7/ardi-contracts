# Ardi WorkNet — 设计文档 v8

*AWP WorkNet #3 · Agent Ordinals · 21,000 英文单词铭文 · 猜词 + PoW 挖矿 · LLM 融合*

---

## 1. 核心思路

**Ardi 是 AWP 的 Agent Ordinals。**

21,000 个英文单词，预设在词库中，每个词有固定的 Power 值和一段模糊的谜面。

**铭刻 = 猜词 + 挖矿。** 每 60 秒出 5 道谜题。Agent 先猜出词（AI 智力），然后撞哈希（算力证明）。epoch 结束时，每道题猜对的人里，哈希值最小的那个 mint。

**双重门槛：没有 LLM 猜不了词，没有算力撞不了哈希。** 纯脚本和纯 LLM 都不够，两样都要。

铭文可以融合：持有者带两个铭文去 The Forge（LLM），成功则烧二铸一且 Power 倍增，失败则烧一保一。融合后可继续融合，无限代数。

**铭文持有者获得 $ardi 和 $AWP 的持续空投。**

---

## 2. 设计原则

**1. 猜词 + 挖矿** — 双重门槛。AI 负责猜词，CPU 负责撞哈希。缺一不可。

**2. 比算力不比速度** — 不是谁先提交谁赢，是谁的哈希值最小谁赢。脚本多开没用，总算力不变。

**3. 选择即博弈** — 5 道题选 1 道。难题高 Power 但竞争可能更少，简单题低 Power 但猜对的人多、哈希竞争激烈。

**4. 融合即通缩** — 总量只减不增。每次融合至少烧掉一个。

**5. AI 原生** — 猜词考验推理，融合由 LLM 裁判。全链路 AI 驱动。

**6. 零门槛** — Gasless + OTC 零手续费。算力门槛由 skill 内置矿机自然提供。

---

## 3. 核心参数

| 参数 | 值 |
|---|---|
| 铭文总量 | **21,000**（上限，只减不增） |
| 铭文标准 | ERC-721 |
| 部署链 | BNB Chain |
| 每 agent 上限 | **3 个** |
| 铭文内容 | 预设词库中的英文单词，全小写 |
| Power 数值 | 1-100，预设在词库中 |
| 空投权重 | 按 Power 数值占总 Power 比例 |
| Epoch | 60 秒 |
| 每轮出题 | 5 道 |
| 每 agent 每轮 | 选 1 道，提交 1 次 |
| 胜出规则 | 猜对 + 哈希值最小 |
| 难度调整 | 动态，维持平均 10-30 秒出解 |
| Gas 支付 | **Gasless — 协议方代付** |
| OTC 手续费 | 0% |
| $ardi | ERC-20，10B 总量，12 个月减半 |
| $ardi LP | 1B $ardi + 1M $AWP，永久锁定 |
| AWP 空投 | DAO emission 分配 |

---

## 4. 词库设计

### 4.1 稀有度分层

| 等级 | 数量 | Power 范围 | 谜面难度 | 占比 |
|---|---|---|---|---|
| Common | 12,000 | 1-25 | 简单 | 57% |
| Uncommon | 5,000 | 26-55 | 中等 | 24% |
| Rare | 3,000 | 56-85 | 较难 | 14% |
| Legendary | 1,000 | 86-100 | 很难 | 5% |

### 4.2 词库格式

```json
[
  { "id": 42, "word": "gravity", "power": 78, "rarity": "rare",
    "hint": "what pulls everything down but lifts nothing up, yet without it nothing would stay" },
  { "id": 8901, "word": "echo", "power": 18, "rarity": "common",
    "hint": "a voice that returns but was never invited back" },
  { "id": 20999, "word": "singularity", "power": 97, "rarity": "legendary",
    "hint": "where all lines converge and the rules stop working — mathematicians fear it, physicists chase it" }
]
```

### 4.3 词库安全

- LLM 批量生成，事先固定
- Merkle root 写入合约，防 Coordinator 篡改
- 词库内容不公开，agent 只能看到 hint
- 每轮 5 道题从未 mint 的词中抽取

### 4.4 每轮出题分布

| Slot | 稀有度 |
|---|---|
| 1 | Common |
| 2 | Common |
| 3 | Uncommon |
| 4 | Uncommon / Rare（70/30） |
| 5 | Rare / Legendary（70/30） |

---

## 5. 猜词 + PoW 挖矿机制

### 5.1 核心流程

```
每 60 秒（1 epoch）：

Coordinator 广播 5 道谜题（hint + rarity + power + difficulty_target）
    │
    ▼
Agent 阅读 5 道题，选 1 道
    │
    ▼
Agent 用 LLM 猜词
    │
    ▼
Agent 本地撞哈希：
    hash(word + agent_address + epoch_id + nonce) < difficulty_target
    不断递增 nonce 直到找到有效哈希
    │
    ▼
Agent 提交：{ puzzle_id, word, nonce, hash }
    │
    ▼
Epoch 结束（55 秒后截止提交）
    │
    ▼
Coordinator 验证所有提交：
    1. 词是否正确
    2. 哈希是否满足难度
    3. 每道题选出哈希值最小的 agent → mint
```

### 5.2 哈希计算

Agent 在 skill 内置矿机中本地运行：

```python
import hashlib

def mine(word: str, agent_address: str, epoch_id: int, difficulty_target: int):
    nonce = 0
    while True:
        data = f"{word}:{agent_address}:{epoch_id}:{nonce}"
        h = hashlib.sha256(data.encode()).hexdigest()
        hash_int = int(h, 16)
        if hash_int < difficulty_target:
            return nonce, h
        nonce += 1
```

### 5.3 胜出规则

**不是比速度，是比哈希值大小。**

每道题在 epoch 结束时：
1. 收集所有提交
2. 过滤：词必须正确 + 哈希必须 < difficulty_target
3. 在有效提交中，**哈希值最小的那个 agent mint**

```
Puzzle #4821-3 "gravity" (rare, power:78)

提交：
  Agent A: word="gravity" hash=0x00003a... ← 最小，胜出
  Agent B: word="gravity" hash=0x0001f2...
  Agent C: word="mass"    hash=0x000001... ← 词错了，无效
  Agent D: word="gravity" hash=0x0042ab...

结果：Agent A mint #42 "gravity" power:78
```

### 5.4 难度调整

动态调整，目标让平均花 10-30 秒撞出有效哈希（单核 CPU）：

```
每 100 轮调整一次：

if avg_valid_submissions_per_puzzle > 20:
    difficulty_target /= 2    // 变难
elif avg_valid_submissions_per_puzzle < 5:
    difficulty_target *= 2    // 变简单
```

初始难度设置为：一台普通 CPU 大约 15 秒能找到一个有效 nonce。

### 5.5 为什么脚本无优势

| 攻击 | 效果 |
|---|---|
| 10,000 个 agent 提交同一道题 | 每个 agent 只有 1/10000 的总算力，找到最小哈希的概率 = 其算力占比 |
| 10,000 个 agent 分散到 5 道题 | 每道题 2,000 个 agent，但每个的算力 = 1 台机器 / 10,000 |
| 1 个正常用户 1 台机器 1 个 agent | 全部算力给 1 道题，找到最小哈希的概率 = 算力占全网该题总算力的比例 |

**总算力不变时，agent 数量越多，每个 agent 的算力越少。** 和 1 个 agent 用全部算力投 1 道题是等价的。脚本多开不产生额外优势。

### 5.6 Sealed 时间

| 场景 | 时间 |
|---|---|
| 理论最快 | 每轮 5 题全被答出，21,000 / 5 = 4,200 轮 = **2.9 天** |
| 预期实际 | ~60% 出题答出率 = **5-8 天** |
| 尾部 | 最后一批 legendary 可能拖更久 |

未答出的题回到池中下一轮继续出。连续 100 轮无人答出的题，Coordinator 可渐进增加 hint 信息。

### 5.7 关键规则

| 规则 | 说明 |
|---|---|
| 每 agent 每轮 | 选 1 道题，提交 1 次 |
| 每 agent 总 mint | 最多 3 个 |
| 提交截止 | epoch 开始后 55 秒 |
| 猜错 | 无惩罚，但浪费了本轮算力 |
| 词对但哈希不够小 | 不 mint，但证明你猜对了（可用于未来声誉系统） |

### 5.8 Coordinator API（挖矿）

```
# 当前轮次谜题
GET /api/v1/quiz/current
Response: {
  "epoch": 4821,
  "difficulty_target": "0x00000fffffffffffffffffffffffffff...",
  "submit_deadline": "2026-04-20T12:00:55Z",
  "puzzles": [
    { "puzzle_id": "p-4821-1", "hint": "...", "rarity": "common", "power": 18 },
    { "puzzle_id": "p-4821-2", "hint": "...", "rarity": "uncommon", "power": 42 },
    { "puzzle_id": "p-4821-3", "hint": "...", "rarity": "rare", "power": 78 },
    { "puzzle_id": "p-4821-4", "hint": "...", "rarity": "uncommon", "power": 38 },
    { "puzzle_id": "p-4821-5", "hint": "...", "rarity": "legendary", "power": 97 }
  ]
}

# 提交答案 + PoW
POST /api/v1/quiz/submit
Request: {
  "puzzle_id": "p-4821-3",
  "word": "gravity",
  "nonce": 284719,
  "hash": "0x00003a...",
  "agent_address": "0x..."
}

Response（已接收，等待 epoch 结束比较）:
{
  "accepted": true,
  "word_correct": true,
  "hash_valid": true,
  "status": "PENDING_EPOCH_END",
  "your_hash": "0x00003a...",
  "current_best_hash": "0x00001b...",
  "submissions_this_puzzle": 14
}

# Epoch 结果
GET /api/v1/quiz/result/:epoch_id
Response: {
  "epoch": 4821,
  "results": [
    { "puzzle_id": "p-4821-1", "word": "echo", "winner": "0xab...12",
      "winning_hash": "0x00001b...", "total_valid_submissions": 23, "minted_token_id": 8342 },
    { "puzzle_id": "p-4821-3", "word": "gravity", "winner": "0x3f...a2",
      "winning_hash": "0x00000f...", "total_valid_submissions": 8, "minted_token_id": 8343 },
    { "puzzle_id": "p-4821-5", "word": null, "winner": null,
      "reason": "NO_CORRECT_ANSWER", "returns_to_pool": true }
  ]
}
```

### 5.9 合约函数

```solidity
function inscribe(
    uint256 wordId,
    string calldata word,
    uint256 power,
    uint256 nonce,
    bytes32 miningHash,
    bytes calldata coordinatorSignature
) external {
    require(!sealed,                                        "SEALED");
    require(awp.isRegisteredAgent(msg.sender),              "NOT_AGENT");
    require(agentMintCount[msg.sender] < 3,                 "AGENT_MAX_REACHED");
    require(!wordMinted[wordId],                            "ALREADY_MINTED");

    // Coordinator 签名验证（确认该 agent 在该 epoch 猜对词 + 哈希最小）
    bytes32 sigHash = keccak256(abi.encodePacked(
        wordId, word, power, msg.sender, nonce, miningHash
    ));
    require(_verifySignature(sigHash, coordinatorSignature), "INVALID_SIGNATURE");

    // --- 执行 ---
    wordMinted[wordId] = true;
    agentMintCount[msg.sender]++;
    totalInscribed++;

    uint256 tokenId = totalInscribed;
    inscriptions[tokenId] = Inscription({
        word: word,
        power: power,
        inscriber: msg.sender,
        timestamp: block.timestamp,
        generation: 0,
        parents: new uint256[](0),
        miningHash: miningHash
    });

    _safeMint(msg.sender, tokenId);
    emit Inscribed(msg.sender, tokenId, word, power, miningHash);

    if (totalInscribed >= 21_000) _seal();
}
```

### 5.10 Skill 内置矿机

Ardi skill 内置矿机模块，agent 安装 skill 后自动具备挖矿能力：

```
[Ardi Miner] Epoch #4821 — 5 puzzles available

Analyzing puzzles...
  #1 ○ common  pw:18  — "a voice that returns..." → guessing...
  #2 ◐ uncommon pw:42  — "the invisible hand..." → guessing...
  #3 ⭐ rare    pw:78  — "what pulls everything..." → guessing...
  #4 ◐ uncommon pw:38  — "not a wall, not a door..." → guessing...
  #5 💎 legend  pw:97  — "where all lines converge..." → guessing...

Selected: #3 (rare, power:78)
LLM guess: "gravity"

Mining... difficulty: 0x00000fff...
  nonce: 0-10000... no valid hash
  nonce: 10001-20000... no valid hash
  nonce: 20001-30000... found! nonce=28471 hash=0x00003a...

Submitting: word="gravity" nonce=28471 hash=0x00003a...
Status: PENDING — waiting for epoch end (12s remaining)
```

---

## 6. 融合机制

### 6.1 概念

持有者带自己的两个铭文去 The Forge（Coordinator + LLM）融合。

**成功**：烧掉两个，铸造一个新铭文。新词由 LLM 创造，Power = 两旧之和 × 倍率。

**失败**：烧掉 Power 较低的，保留另一个。

**同一地址必须持有两个铭文。** 每 agent 最多 mint 3 个，想更多需要 OTC 买。

**融合后可继续融合**，无限代数。

### 6.2 流程

```
持有者（拥有 #42 "fire" pw:67 和 #108 "water" pw:45）
    │
    ▼
提交融合请求 → Coordinator 调 LLM
    │
    ▼
LLM: compatibility 0.85, suggested: "steam"
成功率: 20% + 0.85 × 50% = 62.5%
    │
    ├─ 成功 → burn 两个, mint "steam" power:(67+45)×3.0=336
    └─ 失败 → burn #108 (pw 低), 保留 #42
```

### 6.3 成功率 & Power 倍率

```
success_rate = 20% + compatibility × 50%
范围：20% — 70%
```

| compatibility | 成功率 | Power 倍率 |
|---|---|---|
| < 0.3 | 20-35% | 1.5x |
| 0.3-0.6 | 35-50% | 2.0x |
| 0.6-0.8 | 50-60% | 2.5x |
| > 0.8 | 60-70% | 3.0x |

同一对词结果永久缓存，temperature=0。

### 6.4 融合后铭文

```solidity
struct Inscription {
    string word;
    uint256 power;
    address inscriber;
    uint256 timestamp;
    uint256 generation;     // 0=原始, 1=一次融合...
    uint256[] parents;      // 父铭文 tokenId
    bytes32 miningHash;     // 原始铭文有，融合产物为 0x0
}
```

融合产物 tokenId 从 21,001 起。可追溯完整融合树。

### 6.5 通缩

每次融合净减少 1 个（成功：-2+1=-1，失败：-1）。

### 6.6 限制

| 限制 | 值 |
|---|---|
| 持有要求 | 同一地址持有两个铭文 |
| 冷却期 | 24 小时 |
| 费用 | Gasless |

### 6.7 合约函数

```solidity
function fuse(
    uint256 tokenIdA,
    uint256 tokenIdB,
    string calldata newWord,
    uint256 newPower,
    bool success,
    bytes calldata coordinatorSignature
) external {
    require(ownerOf(tokenIdA) == msg.sender, "NOT_OWNER_A");
    require(ownerOf(tokenIdB) == msg.sender, "NOT_OWNER_B");
    require(tokenIdA != tokenIdB, "SAME_TOKEN");

    bytes32 hash = keccak256(abi.encodePacked(
        tokenIdA, tokenIdB, newWord, newPower, success, fusionNonce
    ));
    require(_verifySignature(hash, coordinatorSignature), "INVALID_SIGNATURE");
    fusionNonce++;

    if (success) {
        _burn(tokenIdA);
        _burn(tokenIdB);
        fusionCount++;
        uint256 newTokenId = 21_000 + fusionCount;

        uint256[] memory parents = new uint256[](2);
        parents[0] = tokenIdA;
        parents[1] = tokenIdB;

        uint256 gen = max(
            inscriptions[tokenIdA].generation,
            inscriptions[tokenIdB].generation
        ) + 1;

        inscriptions[newTokenId] = Inscription({
            word: newWord, power: newPower, inscriber: msg.sender,
            timestamp: block.timestamp, generation: gen, parents: parents,
            miningHash: bytes32(0)
        });

        _safeMint(msg.sender, newTokenId);
        emit Fused(tokenIdA, tokenIdB, newTokenId, newWord, newPower, gen);
    } else {
        uint256 burnId = inscriptions[tokenIdA].power <= inscriptions[tokenIdB].power
            ? tokenIdA : tokenIdB;
        _burn(burnId);
        emit FusionFailed(tokenIdA, tokenIdB, burnId);
    }
}
```

---

## 7. Token 经济

### 7.1 $ardi Token

| 参数 | 值 |
|---|---|
| 符号 | $ardi |
| 标准 | ERC-20 |
| 链 | BNB Chain |
| 总量 | 10,000,000,000 |
| Emission | 12 个月减半 |
| 初始 LP | 1B $ardi + 1M $AWP，永久锁定 |

### 7.2 Emission

| 年份 | 日释放量 | 累计 |
|------|----------|------|
| 1 | 13,698,630 | 5B |
| 2 | 6,849,315 | 7.5B |
| 3 | 3,424,658 | 8.75B |
| 4 | 1,712,329 | 9.375B |

### 7.3 分配

| 池子 | 比例 | Year 1 日释放 |
|---|---|---|
| 铭文持有者 | 80% | 10,958,904 |
| Owner | 10% | 1,369,863 |
| 融合奖励池 | 10% | 1,369,863 |

空投权重 = `power_i / Σ power_all`。

AWP 空投独立，DAO 投票分配，同样按 Power 权重。

---

## 8. 架构

```
Agent + Skill 内置矿机
  │
  │ 获取谜题 / LLM 猜词 / 本地撞哈希 / 提交答案 / 请求融合
  ▼
Coordinator
  ├── 词库管理（21,000 词 + hint + power）
  ├── 出题引擎（每 60 秒抽 5 题）
  ├── PoW 验证（检查哈希 + 比最小值）
  ├── 难度调整（每 100 轮）
  ├── 融合评估（调 LLM）
  ├── 签名（EIP-712）
  ├── Gas Relay（代付）
  └── 空投计算 + Merkle tree
  │
  ▼
BNB Chain
  └── Ardi.sol（ERC-721 + OTC + 空投分配器）
```

---

## 9. OTC 市场

合约内实现，零手续费。

```solidity
function list(uint256 tokenId, uint256 priceInBnb) external;
function unlist(uint256 tokenId) external;
function buy(uint256 tokenId) external payable; // 100% 归卖家
```

融合需要两个铭文 → 驱动 OTC 购买。

---

## 10. Gas 策略：Gasless

| 操作 | Gas | 成本 | 付款方 |
|---|---|---|---|
| inscribe() | ~200,000 | ~$0.40 | 协议方 |
| fuse() | ~250,000 | ~$0.50 | 协议方 |
| list/buy | ~120,000 | ~$0.25 | 协议方 |
| claim() | ~60,000 | ~$0.12 | 协议方 |

铭刻阶段：21,000 × $0.40 = **~$8,400**（一次性）。
日常运营：**~$5-20/天**。
Owner 10% emission 覆盖全部成本。

---

## 11. 防刷策略

| 层 | 机制 | 效果 |
|---|---|---|
| PoW | 撞哈希需要真实算力 | 10,000 个 agent 分摊算力 = 每个 1/10,000，无优势 |
| AWP 协议层 | 1 钱包 = 1 agent | 身份绑定 |
| Ardi 合约层 | 每 agent 最多 3 个 | 限制囤积 |
| 猜词层 | 必须猜对才能挖 | 需要 LLM 能力 |
| 时间层 | 每轮 1 次提交，60 秒 epoch | 限制频率 |

**脚本 10,000 agent 攻击分析：**

| 因素 | 正常用户（1 agent, 1 台机器） | 脚本（10,000 agent, 1 台机器） |
|---|---|---|
| 每 agent 算力 | 100% | 0.01% |
| 每轮覆盖题数 | 1 道 | 5 道（但每道分到 2,000 agent） |
| 每道题最小哈希概率 | 算力 / 该题总算力 | 同左（总算力不变） |
| 注册成本 | 1 × AWP 注册 | 10,000 × AWP 注册 |

**结论：多开 agent 不增加总挖矿效率。** 1 台机器的算力是固定的，分给 10,000 个 agent 和给 1 个 agent 的总哈希产出相同。唯一优势是覆盖更多题目，但这被"每题最小哈希胜出"抵消了——每个 agent 分到的算力更少，找到最小哈希的概率更低。

---

## 12. 网站设计

### 12.1 主页

```
┌──────────────────────────────────────────────────┐
│  Ardi — Agent Ordinals                           │
│                                                  │
│  21,000 words. Guess to earn. Mine to prove.     │
│                                                  │
│  [ 8,342 / 21,000 minted ]                       │
│  [ ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░ ] 39.7%               │
│                                                  │
│  epoch #4821  difficulty: 0x00000fff...           │
│  network hashrate: ~2.4 MH/s                     │
│  next round in: 23s                              │
│                                                  │
│  [Enter the Mine]  [Enter the Forge]             │
└──────────────────────────────────────────────────┘
```

### 12.2 The Mine

```
┌──────────────────────────────────────────────────┐
│  The Mine — Epoch #4821               23s left   │
│  difficulty: 0x00000fff...                       │
│                                                  │
│  ○ COMMON  pw:18                                 │
│    "a voice that returns but was never           │
│     invited back"                                │
│    [ 23 miners on this puzzle ]                  │
│                                                  │
│  ⭐ RARE  pw:78                                  │
│    "what pulls everything down but lifts         │
│     nothing up"                                  │
│    [ 8 miners on this puzzle ]                   │
│                                                  │
│  💎 LEGENDARY  pw:97                             │
│    "where all lines converge and the rules       │
│     stop working"                                │
│    [ 3 miners on this puzzle ]                   │
│                                                  │
│  your mints: 1/3  |  hashrate: ~120 KH/s        │
└──────────────────────────────────────────────────┘
```

### 12.3 The Forge

```
┌──────────────────────────────────────────────────┐
│  The Forge — Speak to the Oracle                 │
│                                                  │
│  ┌─────────┐       ⚡       ┌─────────┐          │
│  │ "fire"  │               │ "water" │          │
│  │ pw: 67  │               │ pw: 45  │          │
│  └─────────┘               └─────────┘          │
│                                                  │
│  Oracle: "fire and water... I see steam."        │
│  Compatibility: 85%  |  Success: 62.5%           │
│  Win: "steam" pw:336  |  Lose: burn "water"      │
│                                                  │
│  [Fuse]  [Cancel]                                │
└──────────────────────────────────────────────────┘
```

---

## 13. 经济闭环

```
阶段 1：猜词挖矿期（5-8 天）
  每 60 秒出 5 道谜题
  Agent 猜词 + 撞哈希，最小哈希 mint
  每 agent 最多 3 个
  21,000 条 sealed

        │
        ▼

阶段 2：空投 + 融合 + 交易（永久）
  $ardi 按 Power 权重空投
  AWP DAO 投票 → AWP 空投
  OTC 买卖铭文（零手续费）
  The Forge 融合（通缩 + Power 增长）

  飞轮：
    融合需要两个 → 驱动 OTC
    融合烧铭文 → 供应减少
    高 Power → 更多空投 → 更高 OTC 价值
    更高价值 → 更多人融合 → 更多通缩

退出：DEX 卖 $ardi / 卖 $AWP / OTC 卖铭文
```

---

## 14. 发布公告

```
> ardi — agent ordinals

21,000 words. locked in the vault.
each has a riddle. each has a power score.

every 60 seconds, 5 riddles drop.
your agent guesses the word.
then mines a hash to prove it.
smallest hash wins.

no speed advantage. no script advantage.
just intelligence + compute.

3 mints per agent.
after sealed, the forge opens —
fuse two words, the oracle judges.
succeed: power multiplies. fail: one burns.

$ardi and $AWP flow to holders.
daily. by power weight.
supply only goes down.

the mine opens tomorrow.
```

---

## 15. 总结

| 层 | 机制 | 门槛 |
|---|---|---|
| 猜词 | LLM 读谜面猜单词 | AI 推理能力 |
| 挖矿 | SHA256 撞哈希，比最小值 | CPU 算力 |
| 选择 | 5 题选 1，难度/Power 权衡 | 策略判断 |
| 融合 | LLM 判断语义可组合性 | AI + 博弈 |
| 通缩 | 每次融合至少烧 1 个 | 数学保证 |

> guess the word. mine the proof. mint the inscription.
> fuse two words — the oracle decides your fate.
> supply only goes down. power only goes up.
> $ardi and $AWP flow to holders. daily. forever.
