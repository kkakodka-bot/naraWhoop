# Shared repair acceptance ledger

[acceptance.json](acceptance.json) is the single authoritative machine-readable ledger. This Markdown table is its human-readable view. Source, synthetic, local integration, deployed, physical, reference and load evidence are separate; PASS at one tier does not pass another. Original problem: **OPEN**.

Common base: `76f2d70f621de91268e295ebcb6c6da29162991f`. Server branch `repair/vps-server-20260922`; BLE branch `repair/ble-sync-20260922` is still at the common base. The exact supplied [shared contract](02_SHARED_CONTRACT.md) and verified [pack receipt](recovery-pack-receipt.json) are now available.

Chat A owns acquisition/local durability/lifecycle/mobile auth/transport. Chat B owns schema/queues/results/native result consumers and combined release. Coordinate shared-file changes. Current B boundary edits are CloudAuthClient compare-and-clear and Android foreground/pause notification to the result reader; neither grants capture execution time. Preserve local commit before BLE ACK and exact verified-indexed identity before cloud retention release. Async remains off.

| Gate | Evidence tier | Status | Observed result / remaining work |
|---|---|---|---|
| shared_base | source | PASS | Both histories retained; all supplied pack hashes match; unrelated dirty checkout preserved |
| real_incident_trace | deployed_read_only | PASS | Accepted/indexed batch still has projection debt; selected-v1 queue pending with no compatible hosted consumer; physical capture/cache/render unmeasured |
| intake_and_migrations | local_integration | PASS | Local intake7 steps and fresh/populated/wrapped predecessor chains passed; later source revalidation remains required |
| computed_synthetic_chain | local_integration | PASS | Sleep179.98333333333332min/RHR53/efficiency100%; separate from real recording; final-source rerun pending |
| raw_native_focused | local_integration | PASS | Raw70/Swift43/Android37 passed on9b; broader suite subsequently found optional raw-lane isolation defect being fixed |
| zero_inference_source | local_integration | PASS | Swift35/Android4 passed on9b; physical exports and final source rerun separate |
| full_server_suite | local_integration | FAIL | First full run: analytics1106/0fail/5reference skips; service585/2fail. Raw optional-object failure needs fix; concurrent Swift source edit invalidated corpus. Rerun after freeze |
| producer_parity | source | FAIL | Canonical history-family wiring and several live/session producers remain incomplete; explicit missingness is not hardware exclusion |
| combined_ble_source | source | NOT_MEASURED | BLE worktree exists at common base; no subsequent BLE implementation integrated |
| matched_artifacts | source | NOT_MEASURED | 9b intake OCI verified; final freeze/build in progress; no transfer of prior source receipts |
| deployment | deployed | NOT_MEASURED | No approval requested/granted, no production mutation |
| real_phone_readback | physical | NOT_MEASURED | No candidate installed or actual phone readback observed |
| locked_4h | physical | NOT_MEASURED | Not performed |
| soak_24h | physical | NOT_MEASURED | Not performed |
| soak_72h | physical | NOT_MEASURED | Not performed |
| target_capacity | load | NOT_MEASURED | Idle4CPU/7.755GiB snapshot only; prior1000-owner scalar run does not pass or establish capacity |
| reference_qualification | scientific_reference | NOT_MEASURED | No newly qualified adapter/model/SpO2 or calibration |

Exact commands, source bindings, hashes, latency criteria and checkpoint states are in the JSON ledger. No production deployment, registry publication, model promotion, phone reset/installation or main merge is authorized by this ledger.
