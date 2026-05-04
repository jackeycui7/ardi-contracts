# AWP JSON-RPC 2.0 API Reference

> **Endpoint**: `POST https://api.awp.sh/v2`
> **Discovery**: `GET https://api.awp.sh/v2` (returns `rpc.discover`)
> **Protocol**: JSON-RPC 2.0 (single and batch requests supported, max batch size: 20)
> **Chain**: Multi-chain (Base 8453, Ethereum 1, Arbitrum 42161, BSC 56). Most methods accept optional `chainId` parameter; omit for default chain.

---

## Request Format

```json
{
  "jsonrpc": "2.0",
  "method": "namespace.method",
  "params": { ... },
  "id": 1
}
```

## Response Format

```json
{
  "jsonrpc": "2.0",
  "result": { ... },
  "id": 1
}
```

## Error Codes

| Code | Meaning |
|------|---------|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32001 | Resource not found |

## Common Parameter Types

| Type | Description | Example |
|------|-------------|---------|
| `address` | 0x-prefixed 40 hex chars (case-insensitive) | `"0xAbC...123"` |
| `worknetId` | Globally unique ID: `(chainId << 64) \| localId` | `"36316036596842561537"` |
| `chainId` | Chain ID integer; omit or 0 for default | `8453` |
| `page` | 1-indexed page number (default 1) | `1` |
| `limit` | Items per page (default 20, max 100) | `50` |

---

## Methods

### stats

#### `stats.global`
Get global protocol statistics across all chains.

**Params**: none

**Response**:
```json
{
  "totalUsers": 1234,
  "totalWorknets": 56,
  "totalStaked": "1000000000000000000000000",
  "totalEmitted": "31600000000000000000000000",
  "chains": 4
}
```

---

### registry

#### `registry.get`
Get all contract addresses and EIP-712 domain info for one chain (default chain if `chainId` omitted).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `chainId` | integer | no | Chain ID; omit for default |

**Response**:
```json
{
  "chainId": 8453,
  "awpRegistry": "0x0000F34Ed3594F54faABbCb2Ec45738DDD1c001A",
  "awpToken": "0x0000A1050AcF9DEA8af9c2E74f0D7CF43f1000A1",
  "awpEmission": "0x3C9cB73f8B81083882c5308Cce4F31f93600EaA9",
  "awpAllocator": "0x0000D6BB5e040E35081b3AaF59DD71b21C9800AA",
  "veAWP": "0x0000b534C63D78212f1BDCc315165852793A00A8",
  "veAWPHelper": "0x0000561EDE5C1Ba0b81cE585964050bEAE730001",
  "awpWorkNet": "0x00000bfbdEf8533E5F3228c9C846522D906100A7",
  "lpManager": "0x00001961b9AcCD86b72DE19Be24FaD6f7c5b00A2",
  "worknetTokenFactory": "0x00000a82b06Ea5b5BdD6003fbfb9602FA531CAFE",
  "dao": "0x00006879f79f3Da189b5D0fF6e58ad0127Cc0DA0",
  "treasury": "0x82562023a053025F3201785160CaE6051efD759e",
  "eip712Domain": {
    "name": "AWPRegistry", "version": "1",
    "chainId": 8453, "verifyingContract": "0x0000F34Ed3594F54faABbCb2Ec45738DDD1c001A"
  },
  "allocatorEip712Domain": {
    "name": "AWPAllocator", "version": "1",
    "chainId": 8453, "verifyingContract": "0x0000D6BB5e040E35081b3AaF59DD71b21C9800AA"
  },
  "daoParams": {
    "votingDelay": "3600", "votingPeriod": "86400",
    "quorumPercent": "4", "proposalThreshold": "200000000000000000000000"
  }
}
```

#### `registry.list`
Get registry for all configured chains (returns array; one entry per chain, same shape as `registry.get`).

**Params**: none

---

### health

#### `health.check`
Basic health check.

**Params**: none

**Response**: `{"status": "ok"}`

#### `health.detailed`
Detailed health status including per-chain indexer/keeper state.

**Params**: none

---

### chains

#### `chains.list`
List all supported chains.

**Params**: none

**Response**: Array of `{chainId, name, dex, explorer}`

---

### users

#### `users.list`
List users (paginated, per-chain).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `chainId` | integer | no | Chain ID |
| `page` | integer | no | Page number |
| `limit` | integer | no | Items per page |

#### `users.listGlobal`
List users across all chains (deduplicated).

**Params**: `page`, `limit`

#### `users.count`
Get total user count.

**Params**: `chainId` (optional)

#### `users.get`
Get user details (balance, bound agents, recipient).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | User address |
| `chainId` | integer | no | Chain ID |

#### `users.getPortfolio`
Get full user portfolio (identity, balance, positions, allocations, delegates).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | User address |
| `chainId` | integer | no | Chain ID |

#### `users.getDelegates`
Get agents bound to a user (delegate tree).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | User address |
| `chainId` | integer | no | Chain ID |

---

### address

#### `address.check`
Check address registration status, binding, and recipient.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | Address |
| `chainId` | integer | no | Chain ID |

**Response**:
```json
{
  "address": "0x...",
  "isRegisteredUser": true,
  "isRegisteredAgent": false,
  "boundTo": "0x...",
  "recipient": "0x...",
  "hasDelegate": false
}
```

#### `address.resolveRecipient`
Resolve the effective recipient by walking the bind chain to root (on-chain call).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | Address |
| `chainId` | integer | no | Chain ID for on-chain read |

**Response**: `{"address": "0x...", "resolvedRecipient": "0x..."}`

#### `address.batchResolveRecipients`
Batch resolve recipients (max 500 addresses, on-chain call).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `addresses` | array\<string\> | yes | Address list (max 500) |
| `chainId` | integer | no | Chain ID |

**Response**: Array of `{"address": "0x...", "resolvedRecipient": "0x..."}`

---

### nonce

#### `nonce.get`
Get AWPRegistry EIP-712 nonce (for bind, setRecipient, registerWorknet, grantDelegate, revokeDelegate, unbind).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | Address |
| `chainId` | integer | no | Chain ID |

**Response**: `{"nonce": 42}`

#### `nonce.getStaking`
Get AWPAllocator EIP-712 nonce (for allocateFor, deallocateFor).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | Address |
| `chainId` | integer | no | Chain ID |

**Response**: `{"nonce": 5}`

---

### agents

#### `agents.getByOwner`
Get all agents bound to an owner.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `owner` | string | yes | Owner address |
| `chainId` | integer | no | Chain ID |

#### `agents.getDetail`
Get agent details (owner, bound worknets, allocations).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `agent` | string | yes | Agent address |
| `chainId` | integer | no | Chain ID |

#### `agents.lookup`
Look up agent owner address.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `agent` | string | yes | Agent address |
| `chainId` | integer | no | Chain ID |

**Response**: `{"ownerAddress": "0x..."}`

#### `agents.batchInfo`
Batch query agent info and stake in a worknet (max 100 agents).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `agents` | array\<string\> | yes | Agent addresses (max 100) |
| `worknetId` | string | yes | Worknet ID |
| `chainId` | integer | no | Chain ID |

---

### staking

#### `staking.getBalance`
Get user AWP staking balance (staked/allocated/available).

**Params**: `address` (required), `chainId` (optional)

#### `staking.getUserBalanceGlobal`
Get user staking balance aggregated across all chains.

**Params**: `address` (required)

#### `staking.getPositions`
Get user veAWP positions (per-chain).

**Params**: `address` (required), `chainId` (optional)

#### `staking.getPositionsGlobal`
Get user veAWP positions across all chains.

**Params**: `address` (required)

#### `staking.getAllocations`
Get user stake allocations (paginated).

**Params**: `address` (required), `chainId` (optional), `page`, `limit`

#### `staking.getFrozen`
Get user frozen allocations (deprecated — always returns empty).

**Params**: `address` (required), `chainId` (optional)

#### `staking.getPending`
Get pending allocation changes (always returns empty array).

**Params**: none

#### `staking.getAgentSubnetStake`
Get agent's stake amount in a specific worknet (cross-chain, no chainId needed).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `agent` | string | yes | Agent address |
| `worknetId` | string | yes | Worknet ID |

**Response**: `{"amount": "1000000000000000000000"}`

#### `staking.getAgentSubnets`
Get all worknets an agent participates in (cross-chain).

**Params**: `agent` (required)

#### `staking.getSubnetTotalStake`
Get worknet total stake across all agents (cross-chain).

**Params**: `worknetId` (required)

**Response**: `{"total": "5000000000000000000000000"}`

#### `staking.getAllocationsByAgentSubnet`
List every staker that allocated to a specific (agent, worknetId), ordered by amount desc. Cross-chain by default; pass `chainId` to restrict to one chain.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `agent` | string | yes | Agent address |
| `worknetId` | string | yes | Worknet ID |
| `chainId` | int | no | If set (>0), restrict to that chain; otherwise cross-chain aggregation |
| `limit` | int | no | Page size (default 20) |
| `offset` | int | no | Page offset (default 0) |

**Response**: array of rows
```json
[
  {
    "chain_id": 8453,
    "user_address": "0x46c0213a02d9571db67d813a4c261cb7716b5d66",
    "amount": "1000000000000000000000",
    "frozen": false
  }
]
```

---

### subnets (worknets)

#### `subnets.list`
List worknets (paginated, optional status filter). `chainId=0` returns all chains.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `status` | string | no | `Pending`, `Active`, `Paused`, `Banned` |
| `chainId` | integer | no | 0 = all chains |
| `page` | integer | no | Page number |
| `limit` | integer | no | Items per page |

#### `subnets.listRanked`
List worknets ranked by total stake.

**Params**: `chainId` (optional), `page`, `limit`

#### `subnets.search`
Search worknets by name or symbol (case-insensitive ILIKE).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `query` | string | yes | Search string (1-100 chars) |
| `chainId` | integer | no | Chain ID |
| `page` | integer | no | Page number |
| `limit` | integer | no | Items per page |

#### `subnets.getByOwner`
Get worknets owned by an address.

**Params**: `owner` (required), `chainId` (optional), `page`, `limit`

#### `subnets.get`
Get worknet details.

**Params**: `worknetId` (required)

#### `subnets.getSkills`
Get worknet skills URI.

**Params**: `worknetId` (required)

#### `subnets.getEarnings`
Get worknet AWP earnings history (paginated).

**Params**: `worknetId` (required), `page`, `limit`

#### `subnets.getAgentInfo`
Get agent staking info in a worknet.

**Params**: `worknetId` (required), `agent` (required)

#### `subnets.listAgents`
List agents in a worknet ranked by stake.

**Params**: `worknetId` (required), `chainId` (optional), `page`, `limit`

---

### emission

#### `emission.getCurrent`
Get current emission data (epoch, daily emission, total weight).

**Params**: `chainId` (optional)

#### `emission.getSchedule`
Get emission projections (30/90/365 day forecasts with decay).

**Params**: `chainId` (optional)

#### `emission.getGlobalSchedule`
Get emission schedule aggregated across all chains.

**Params**: none

#### `emission.listEpochs`
List settled epochs (paginated).

**Params**: `chainId` (optional), `page`, `limit`

#### `emission.getEpochDetail`
Get epoch detail with per-recipient distributions.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `epochId` | integer | yes | Epoch ID |
| `chainId` | integer | no | Chain ID |

---

### tokens

#### `tokens.getAWP`
Get AWP token info (totalSupply, maxSupply, minters).

**Params**: `chainId` (optional)

#### `tokens.getAWPGlobal`
Get AWP token info aggregated across all chains.

**Params**: none

#### `tokens.getWorknetTokenInfo`
Get worknet WorknetToken info (name, symbol, totalSupply, worknetManager).

**Params**: `worknetId` (required)

#### `tokens.getWorknetTokenPrice`
Get worknet WorknetToken price (from LP pool, cached in Redis).

**Params**: `worknetId` (required)

---

### governance

#### `governance.listProposals`
List governance proposals (per-chain, paginated, optional status filter).

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `status` | string | no | `Active`, `Canceled`, `Defeated`, `Succeeded`, `Queued`, `Expired`, `Executed` |
| `chainId` | integer | no | Chain ID |
| `page` | integer | no | Page number |
| `limit` | integer | no | Items per page |

#### `governance.listAllProposals`
List proposals across all chains.

**Params**: `status` (optional), `page`, `limit`

#### `governance.getProposal`
Get proposal details.

**Params**: `proposalId` (required), `chainId` (optional)

#### `governance.getTreasury`
Get Treasury contract address.

**Params**: none

**Response**: `{"treasuryAddress": "0x82562023a053025F3201785160CaE6051efD759e"}`

#### `governance.listGrouped`
List proposals grouped by `proposalId` across all chains (same proposal mirrored to multiple chains is merged into one row).

**Params**: `page` (optional), `limit` (optional)

#### `governance.listByStatusGrouped`
Cross-chain merged proposals filtered by status (`Active`/`Queued`/`Executed`/etc.).

**Params**: `status` (required), `page`, `limit`

#### `governance.getActive`
Quick: cross-chain merged Active proposals.

**Params**: `page` (optional), `limit` (optional)

#### `governance.getStats`
Aggregate DAO statistics: total proposals/voters/proposers, byStatus breakdown, pass rate.

**Params**: none

#### `governance.getTimeline`
Full lifecycle timeline of a proposal (Created/VotingStarted/VotingEnded/Queued/Executed/Canceled).

**Params**: `proposalId` (required), `chainId` (optional)

#### `governance.decodeProposalActions`
Decode proposal calldata using known contract ABIs; returns human-readable actions.

**Params**: `proposalId` (required), `chainId` (optional)

#### `governance.getQuorumProgress`
Real-time quorum progress for a proposal: current vs required quorum, will-pass projection.

**Params**: `proposalId` (required), `chainId` (optional)

#### `governance.getEligibleTokens`
List user's veAWP NFTs annotated with eligibility / hasVoted / votingPower for a specific proposal.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | User address |
| `proposalId` | string | yes | Proposal ID |
| `chainId` | integer | no | Chain ID |

#### `governance.getUserVoteHistory`
All votes by a user across all chains and proposals (paginated, joined with proposal context).

**Params**: `voter` (required), `page`, `limit`

#### `governance.getUserProposals`
All proposals submitted by a user across all chains.

**Params**: `proposer` (required), `page`, `limit`

#### `governance.getApprovedProposers`
List currently-approved proposers (whitelist that bypasses the 200K AWP threshold).

**Params**: `chainId` (optional)

#### `governance.isApprovedProposer`
Check if an address is currently in the approved-proposer whitelist.

**Params**: `address` (required), `chainId` (optional)

#### `governance.getVoterPower`
A voter's power for a specific proposal (historical if voted, current eligible otherwise).

**Params**: `proposalId` (required), `voter` (required), `chainId` (optional)

#### `governance.getVotingPower`
Aggregate voting power for a user; optional `proposalId` filters by eligibility.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `address` | string | yes | User address |
| `proposalId` | string | no | If given, only count tokens eligible for that proposal |
| `chainId` | integer | no | Chain ID |

#### `governance.getVoterVotesGlobal`
Cross-chain: all of a voter's votes on a proposal across chains, plus aggregate weight per support type.

**Params**: `proposalId` (required), `voter` (required)

#### `governance.listProposalVotesGlobal`
Cross-chain: list votes on a proposal across all chains. If `grouped=true`, aggregates per voter.

**Params**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `proposalId` | string | yes | Proposal ID |
| `grouped` | boolean | no | Group by voter (default false) |
| `page` | integer | no | Page number |
| `limit` | integer | no | Items per page |

---

### Method aliases

The following canonical names are registered as aliases for the older `subnets.*` calls. Both forms work; new code should prefer the `worknets.*` / `staking.*Worknet*` form.

| Alias (canonical) | Maps to |
|---|---|
| `worknets.list` | `subnets.list` |
| `worknets.get` | `subnets.get` |
| `worknets.getSkills` | `subnets.getSkills` |
| `worknets.getEarnings` | `subnets.getEarnings` |
| `worknets.getAgentInfo` | `subnets.getAgentInfo` |
| `worknets.listRanked` | `subnets.listRanked` |
| `worknets.listAgents` | `subnets.listAgents` |
| `worknets.search` | `subnets.search` |
| `worknets.getByOwner` | `subnets.getByOwner` |
| `staking.getAgentWorknetStake` | `staking.getAgentSubnetStake` |
| `staking.getAgentWorknets` | `staking.getAgentSubnets` |
| `staking.getWorknetTotalStake` | `staking.getSubnetTotalStake` |

---

## Batch Request Example

```json
[
  {"jsonrpc": "2.0", "method": "users.get", "params": {"address": "0xAbC..."}, "id": 1},
  {"jsonrpc": "2.0", "method": "staking.getBalance", "params": {"address": "0xAbC..."}, "id": 2},
  {"jsonrpc": "2.0", "method": "emission.getCurrent", "params": {}, "id": 3}
]
```

Batch requests execute concurrently. Max 20 requests per batch.

---

## WebSocket

**Endpoint**: `wss://api.awp.sh/ws/live`

Real-time event stream. Supports optional address-based filtering via `watchAddresses` subscription message.

Events pushed: `UserRegistered`, `Bound`, `Unbound`, `RecipientSet`, `Deposited`, `Withdrawn`, `Allocated`, `Deallocated`, `Reallocated`, `WorknetRegistered`, `WorknetActivated`, `EpochSettled`, `RecipientAWPDistributed`, `AllocationsSubmitted`, etc.

---

## Rate Limits

- Nonce endpoints: configurable via Redis (`ratelimit:config` hash)
- Relay endpoints: 100 req/IP/hour (default)
- Batch agent info: rate limited per IP
- All limits hot-updatable via admin API

---

## Deployed Contract Addresses (identical on Base / Ethereum / Arbitrum; BSC differs for LPManager + WorknetManager because of DEX bytecode)

> Source of truth: `registry.get` / `registry.list` over JSON-RPC. The values below are mirrored from Base mainnet.

| Contract | Address |
|----------|---------|
| AWPToken | `0x0000A1050AcF9DEA8af9c2E74f0D7CF43f1000A1` |
| AWPRegistry (proxy) | `0x0000F34Ed3594F54faABbCb2Ec45738DDD1c001A` |
| AWPEmission (proxy) | `0x3C9cB73f8B81083882c5308Cce4F31f93600EaA9` |
| AWPAllocator (proxy) | `0x0000D6BB5e040E35081b3AaF59DD71b21C9800AA` |
| veAWP | `0x0000b534C63D78212f1BDCc315165852793A00A8` |
| veAWPHelper | `0x0000561EDE5C1Ba0b81cE585964050bEAE730001` |
| AWPWorkNet | `0x00000bfbdEf8533E5F3228c9C846522D906100A7` |
| LPManager | `0x00001961b9AcCD86b72DE19Be24FaD6f7c5b00A2` |
| WorknetTokenFactory | `0x00000a82b06Ea5b5BdD6003fbfb9602FA531CAFE` |
| AWPDAO | `0x00006879f79f3Da189b5D0fF6e58ad0127Cc0DA0` |
| Treasury | `0x82562023a053025F3201785160CaE6051efD759e` |
| Guardian (Safe 3/5) | `0x000002bEfa6A1C99A710862Feb6dB50525dF00A3` |
