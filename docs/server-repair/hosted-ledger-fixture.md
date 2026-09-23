# Hosted predecessor ledger fixture

`scoring-service/service/src/test/resources/hosted_ledger_predecessor_20260923.json` preserves the exact **110 native ledger rows** and **117 full source identities/hashes** from the read-only hosted capture taken on 2026-09-23. It also retains the earlier release's motion-migration supersession attestation. The fixture records both source evidence hashes; its validator independently pins the native and full-identity fingerprints.

The native timestamp ledger cannot be reconstructed from distinct source timestamps:

- `20260918234000_motion_evidence_provenance.sql` remains in the full-identity ledger with its original source hash and `superseded_in_hosted_schema` attestation. There is no corresponding native timestamp row.
- Native timestamp `20260918040000` is named `rr_packet_provenance`. Both full source identities remain, including `production_projection_debt`; a lexicographic first-name selection loses the native identity.
- The recorded native names have no `.sql` suffix. Full source identities retain their complete filenames.

The former hosted-upgrade runner generated **111 native rows**, appended `.sql` to every native name, and selected the wrong collision name. Its before/after comparison proved preservation of that generated surrogate, not fidelity to the deployed native ledger. Earlier 128- and 129-migration receipts using this algorithm remain historical evidence of local schema/data preservation. Their claims about the exact deployed native predecessor are superseded by the corrected fixture run; original artifacts must not be erased or relabeled.

The corrected runner verifies the reconstructed 117-entry full-identity ledger against the frozen capture before inserting the native fixture. Insertion requires an empty disposable native ledger; it never deletes, updates or overwrites applied history. Every production migration wrapper is bound to the frozen 110 rows independently of the just-observed local ledger. Two transactional negative probes add the missing native timestamp or change the collision name; both must be rejected specifically by `frwhoop_native_ledger_drift` and roll back. The normal forward upgrade then preserves all native rows byte-for-byte in the ordered JSON receipts.

Run locally:

```sh
node --test scoring-service/scripts/hosted-ledger-fixture.test.mjs
DOCKER_CONTEXT=colima-frwhoop-integration TMPDIR=/private/tmp \
  bash scoring-service/scripts/test-physiology-migration-chain.sh hosted-upgrade
```

The database uses the runner's pinned Supabase PostgreSQL image with no network access. This validates an exact deployed **ledger** predecessor on a locally replayed source schema with synthetic preserved data. It does not establish that every pre-existing hosted DDL object or production data shape is identical, authorize deployment, or prove phone continuity or VPS capacity.
