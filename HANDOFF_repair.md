# Shared recovery handoff

**Pre-canary update:**8d173cde artifacts are retained as exact historical identity evidence, not an approved candidate. Independent review reproduced unguarded Oura local inference; isolated repair `b164672310d1a3aaa6988532bdecea99b1e96bdc` passes its actual callback/reference tests. One-owner/device intake+baseline admission is also being implemented with additive migration128. Both changes require new integration, tests and matched builds before approval.

The original incident remains **OPEN**. The combined BLE/VPS release source is `8d173cdeae3c8af1aee31ff89b927a6b8c05632f`, tree `b51ce51ff82e0ba8b6df0f0ab772342258c086b2`, on `repair/vps-server-20260922`. It merges VPS `92c337a3168ed224bebfabc271fd4b5dd355b256` and BLE `e2cb1f8ab15d302f07f416b8d017ae4b33003ac3` from reviewed common base `76f2d70f621de91268e295ebcb6c6da29162991f`.

- [Server repair and deployment boundary](HANDOFF_server_repair.md).
- [BLE implementation and limitations](HANDOFF_ble_repair.md).
- [Exact shared contract](docs/server-repair/02_SHARED_CONTRACT.md).
- [Single authoritative acceptance ledger](docs/server-repair/acceptance.json) and [readable view](docs/server-repair/ACCEPTANCE_LEDGER.md).

This evidence-only branch `repair/combined-evidence-20260922` records tests and artifacts for that exact release SHA; its documentation commit is not a replacement executable release. Artifact root: `/Volumes/Untitled/server-repair-release-8d173cdeae3c8af1aee31ff89b927a6b8c05632f`.

No production deployment, registry publication, phone installation/reset, model promotion or main merge is authorized. Physical readback, four locked hours, 24/72-hour soaks and target-VPS capacity are not measured. Remaining supported producer and acquisition engineering is tracked separately from access, approval and elapsed-time gates.
