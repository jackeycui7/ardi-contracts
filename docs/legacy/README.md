# legacy/ — historical design docs

These three files capture earlier Ardi design iterations. They are kept
for reference (commit messages link back to them) but **do not describe
the live system**:

- `ardi_worknet_design_v8(1).md` — Pre-v3 worknet design draft. The
  bond-escrow model, mock-AWP token, and per-day Merkle settlement
  flow described here were superseded by V3 (live AWPAllocator
  eligibility checks, EmissionDistributor for rewards). Keep the
  threat-model section if you want — the contract surface is wrong.
- `ardi_execution_plan.md` — V1/V2 deployment plan. Mainnet launch
  followed `MAINNET_DEPLOY_V31_RUNBOOK.md` (one level up) instead.
- `rpc-reference.md` — Pre-v3.1 RPC payload schema (snake_case).
  Current shapes are camelCase; see live coord at `api.ardinals.com`
  or the typed structs in `coord-rs/crates/ardi-api/src/routes/`.

**For the current system**, read these instead:

| Want to know about | Read |
|---|---|
| Live contract surface (V3 + V3.1) | `../../src/v3/*.sol` source + `../MAINNET_DEPLOY_V31_RUNBOOK.md` |
| Coord HTTP API contract | `coord-rs/crates/ardi-api/src/routes/*.rs` |
| Phase 1 vs Phase 2 features | `coord-rs/OPERATIONS.md` |
| Skill ↔ contract integration | `ardi-skill-rs/SKILL.md` |
