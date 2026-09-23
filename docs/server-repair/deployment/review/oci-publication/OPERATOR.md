Immutable405 OCI publication preparation — no remote publication has occurred.

Run this helper locally on the reviewed arm64 Docker engine. It copies the already-built Linux/amd64 archives from the final release; it never builds, loads/saves through Docker, changes layers, publishes a multi-platform index, creates a mutable tag, or starts a physiological worker. Publishing the v2 archive is artifact transport, not model promotion or permission to run v2.

The exact aggregate is SHA256 `9a6f857574fa1019f69013ec912cabc54ab0d59b4baaf755e5df8ced493b1b0c`. The helper pins source405, that aggregate, all three archive hashes and selected manifest/config identities. The plan also binds the helper's own hash. `publication-plan.json` SHA256 is `5a9070e0a3ebb9236fa7f1e5f96f5e3d177fa49e1b9b8c3432362ab9711a4941`.

Official Skopeo1.22.3 is pinned to `quay.io/skopeo/stable@sha256:3f276c7780973ede33a7ae4a5f5ac002cb2fd53d6d892f38ab313def3570188d` (the actual Linux/arm64 tool manifest). The public multi-platform index observed during preparation was `sha256:ffc4a6b0a3d2fc4302631a3ef9919768eebc3cafc95350d4bb7d9b1be51231aa`; execution does not use the mutable tag or index. The tool may be acquired anonymously by this exact digest before the run; no existing Docker credentials are read. Tool origin and digest are verified here, not a signature-attestation claim.

The [official installation documentation](https://github.com/podman-container-tools/skopeo/blob/main/install.md) names this container repository. The [copy documentation](https://github.com/podman-container-tools/skopeo/blob/main/docs/skopeo-copy.1.md) defines digest preservation and platform selection; the [transport documentation](https://github.com/containers/image/blob/main/docs/containers-transports.5.md) permits digest-qualified destinations. This helper uses `--preserve-digests`, `--multi-arch=system`, explicit Linux/amd64 source selection, digest-only destinations, and full authenticated download verification. It does not use `--all` or a manifest-format conversion.

Set these nonsecret paths in the operator's shell:

```sh
REPAIR_RELEASE='/Volumes/External SSD/server-repair-release-405ee1b6a6238e7f4c77e2e2f8274d01f524e5f2'
REPAIR_PUBLISHER="$REPAIR_RELEASE/verification/oci-publication"
REPAIR_DOCKER_HOST='unix:///Users/rahulvijayan/.colima/frwhoop-integration/docker.sock'
REPAIR_PUBLISH_STAGE='/Users/rahulvijayan/.cache/frwhoop-oci-publication-405'
```

The shared staging directory must already exist, be canonical, owned by the operator and mode0700. Allow at least1GiB free for bounded temporary archive/download copies. ExternalSSD is not mounted in this Colima profile, so the helper copies exact verified bytes into this existing shared path; it does not alter Colima configuration. Temporary auth/staged files are removed on completion/failure. Public proof files remain in the chosen evidence directory. No original release artifact is changed.

Default offline validation (no Docker process, registry call or credential read):

```sh
python3 "$REPAIR_PUBLISHER/publish-approved-oci.py" \
  --plan "$REPAIR_PUBLISHER/publication-plan.json" \
  --release-root "$REPAIR_RELEASE" \
  --evidence-dir "$REPAIR_PUBLISHER/operator-dry-run"
```

The evidence directory must be new. Missing private account/enrollment credentials, device access and explicit matched deployment/publication approval currently stop the overall plan BEFORE registry, SQL or configuration mutations. Do not infer authorization from the tested helper, an available Docker daemon, or the plan fingerprint. No tokens were fetched during preparation.

Only AFTER that approval covers these exact three repositories/digests and the complete deployment prerequisites, supply a canonical owner-only0600 auth file from the normal authorized GHCR session. It must contain only `auths.ghcr.io.auth` (base64 username:token), with no credential helpers or unrelated registry entries. The helper never prints it or puts its content in argv; it mounts a private temporary copy read-only. Do not put the token in shell history, a command argument, evidence files or this document. Set `REPAIR_GHCR_AUTH_FILE` to that private file PATH, then the concrete approved mutation would be:

```sh
python3 "$REPAIR_PUBLISHER/publish-approved-oci.py" \
  --plan "$REPAIR_PUBLISHER/publication-plan.json" \
  --release-root "$REPAIR_RELEASE" \
  --evidence-dir "$REPAIR_PUBLISHER/approved-registry-publication" \
  --execute \
  --approved-plan-sha256 5a9070e0a3ebb9236fa7f1e5f96f5e3d177fa49e1b9b8c3432362ab9711a4941 \
  --auth-file "$REPAIR_GHCR_AUTH_FILE" \
  --docker-host "$REPAIR_DOCKER_HOST" \
  --docker-staging-dir "$REPAIR_PUBLISH_STAGE"
```

Exact destinations:

- `ghcr.io/kkakodka-bot/frwhoop_v2/baseline@sha256:aa69800d726b3c9d6e0fac617903035d1a39d99c2f2000bc96c0b66e86d17dbe`
- `ghcr.io/kkakodka-bot/frwhoop_v2/physiology@sha256:875e81ef8072cf449475c38d3b22259853ec45c67498b50ef4801a46eae5747e`
- `ghcr.io/kkakodka-bot/frwhoop_v2/intake@sha256:0db2cab4d193034225e6d7f067e4b2beaa368d65785ecb9c73857de131e1030c`

Remote TLS verification is always enabled. The only HTTP exception is the separately flagged disposable-local test, bound to an exact labeled registry container's network namespace and literal127.0.0.1:5000; it cannot receive an auth file. Each copy/verification container is read-only with dropped capabilities, no daemon socket, bounded resources,30-second Docker control timeouts and900-second attached-operation timeout; cleanup removes only its exact created ID. A command failure stops publication and subsequent deployment. Partial immutable uploads may exist after a failure; preserve their receipt and diagnose. Do not convert/rebuild, change a digest, force a tag or proceed to migrations to hide failure.

The final local proof pushed all three archives into a fresh disposable CNCF Distribution registry, read them back through Skopeo and separately fetched the manifest/config/layer bytes through loopback HTTP. All three selected manifests and35 config/layer descriptors retained exact SHA256/size. Source index GETs return404. Digest-only repositories have no tag directory (the registry's tags endpoint returns404 NAME_UNKNOWN while manifest/blob reads return200). This is expected for this local registry implementation. GHCR permission, digest-only publication behavior and eventual pull availability remain UNVERIFIED until approved real execution; the helper will fail if that registry cannot retain the exact manifest. No GHCR authentication request or push occurred.

Both owned disposable registry containers were stopped/removed; all temporary Skopeo containers were removed by exact ID. Local registry data and proof downloads are generated evidence, not a deployed service. The independent review receipt and final transport receipt bind the source, tests and actual byte proof. They do not establish target-VPS operation, phone readback,4h/24h/72h acceptance, or capacity.
