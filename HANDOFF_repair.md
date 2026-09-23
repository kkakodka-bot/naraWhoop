# Shared recovery handoff

The original incident remains **OPEN**. Start with [HANDOFF_server_repair.md](HANDOFF_server_repair.md) for implemented code, tested boundaries and deployment limits.

- Reviewed common base: `76f2d70f621de91268e295ebcb6c6da29162991f`.
- Shared contract: [02_SHARED_CONTRACT.md](docs/server-repair/02_SHARED_CONTRACT.md).
- One authoritative acceptance ledger: [acceptance.json](docs/server-repair/acceptance.json); [readable view](docs/server-repair/ACCEPTANCE_LEDGER.md).
- BLE branch: `repair/ble-sync-20260922` at the common base; the user has assigned its implementation to this team; changes are being diagnosed and are not yet integrated.
- Server branch: `repair/vps-server-20260922`; exact candidate and artifact receipts are recorded in the server handoff.

No production deployment, phone installation/reset, model promotion or main merge is authorized by this handoff. Physical readback, four locked hours, 24/72-hour soaks and target-VPS capacity are not measured. Supported producer parity remains implementation work, separately tracked from access and elapsed-time gates.
