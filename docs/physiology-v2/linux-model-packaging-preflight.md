# Linux model packaging preflight

Date: 2026-09-19. This is pre-integration functional packaging evidence, not an exact-final-head image, production activation, reference validation or VPS qualification.

## Completed

- Downloaded/built all 33 exact-version CPython 3.11/Linux x86_64 CPU wheels, including the source-only ANTLR Python runtime wheel, using the pinned public Python image.
- Built the offline bundle with verified wav2sleep source, released checkpoint/config, license notice, exact wheel SHA-256 requirements and complete file inventory.
- Installed the bundle with `--no-index --no-deps --require-hashes` in a network-disabled Linuxamd64 container; `pip check` reported no broken requirements.
- Executed the actual released checkpoint twice on 20 synthetic 30-second PPG epochs. Outputs repeated exactly within this Linux environment, and a false observed-mask sample abstained.
- Found and repaired a packaging defect: setuptools includes nested vendored `.dist-info/METADATA`; wheel identity must use the single top-level distribution metadata. Regression coverage was added.

Identities:

| Artifact | Identity |
|---|---|
| Runtime implementation | `73e1a2ec1174429abbbaa1ac9e4159873e8930a863954b07bfe28020c1a69dbb` |
| Offline bundle manifest | `fd2110d1c5ffbaf634961697f7eda3c439e34b3e5ee270526830ac98cf06e6b6` |
| Python Linuxamd64 base | `python:3.11-slim-bookworm@sha256:4b4c524dc3dce996864e030c7bd9c6b0e517597189fee48f48e05b499442444b` |
| Python interpreter | 3.11.16 |
| Released checkpoint | `ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc` |
| Released config | `b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509` |
| Linux synthetic output | `c9e5b563c01e22fe39a6341761c118b7e8ce93a9d305b358bdd707adeabdc006` |

The Linux smoke container was network-disabled and capped at one CPU, 2 GiB memory and 128 processes. It ran under QEMU x86_64 on the local arm64 Colima VM. NNPACK reported unsupported emulated hardware and used the available CPU path. Two model calls took 13.217 seconds wall and 12.562 seconds process CPU, with reported peak process RSS 617,861,120 bytes. These are synthetic emulated-host diagnostics, not overnight throughput, native VPS performance, whole-service memory or acceptance thresholds. macOS and Linux output hashes differ; no cross-platform byte-equivalence claim is made.

## Initial local combined-image attempt

The actual `scoring-service/Dockerfile.model` build was attempted with the verified bundle. It pulled the pinned JDK/JRE/Python images, downloaded Gradle 8.7 and reached `:analytics-kernel:compileKotlin`. It was deliberately cancelled with SIGINT/exit 130 when the shared local Docker VM became heavily unresponsive. The VM reported 6,198,034,432 bytes RAM and a 30 GiB filesystem with 96% used/about 1.2 GiB available during the attempt. This is an incomplete resource-constrained local build, **not a demonstrated compiler error**. No finished combined-image ID, JVM-in-image execution or deployment is claimed.

The JVM build recipe restricts active processors and Gradle workers to one. Its dedicated ignore file excludes unrelated repository content, local credentials and generated build directories. Repeat the combined build after final integration on a host with sufficient disk/CPU headroom; then run the actual worker/environment checks. Do not resize or prune shared infrastructure implicitly.

## Native VPS continuation

Restored deploy-key SSH allowed the complete combined image to build on the actual native Linux x86_64 VPS, from committed source `fa7fe6b1f0161011a9481cb52630ec5586b52cb0`. Image digest: `sha256:a11e74e0909935516b91bd2fe38e0c0a1f867a7cf6a9711987fd1142905476c0`. Its JVM manifest export matched that commit's recorded manifests byte for byte. The separate BuildKit instance was capped at one CPU/3 GiB, then stopped before probes. This supersedes the earlier missing-image/access blocker, not the original local failure record.

The first network-disabled, read-only-root, numeric-UID probe uncovered a real packaging defect that the root build-time import check did not exercise: upstream Numba's cached decorator could not find a writable cache location. All twelve attempted records across four frozen cases failed before inference, without OOM. A scoped writable-cache diagnostic then executed the actual checkpoint successfully under the same non-root/read-only restrictions. The candidate repairs production and probe child environments with private per-job cache directories; it does not make checkpoint/source directories writable or inherit credentials. All twelve repaired-image records subsequently passed, including eight-hour synthetic inputs at concurrency one and two. The [VPS resource report](vps-resource-report.md) and exact-head handoff distinguish the failed initial image, repaired-image measurements and final integration rerun identities.

## Reproduction and retained evidence

External scratch: `/Volumes/Untitled/physiology-build/pr21-linux-bundle.mTSKYI/`.

Retained: `wheelhouse/`, `bundle/`, `bundle-build.log`, `wheels-container.log`, `image-build.log`, `linux-smoke.log`, `linux-smoke.json`. The complete wheel and bundled-file hashes are in `bundle/bundle-manifest.json` and `bundle/requirements.lock`. Downloaded checkpoint/source locations are listed in the learned-model report.

Core commands (the local Docker VM did not mount `/Volumes`, so the actual run used `docker cp` for container inputs/outputs):

```sh
python -m pip wheel --wheel-dir /artifacts/wheelhouse --extra-index-url https://download.pytorch.org/whl/cpu --no-deps -r /source/requirements-wav2sleep-linux-amd64.lock
python -m physiology_inference.bundle build --source /reviewed/wav2sleep --checkpoint-root /reviewed/checkpoint --wheelhouse /reviewed/linux-wheels --output /new/bundle
python -m physiology_inference.bundle verify --root /opt/physiology
python -m pip install --no-cache-dir --no-index --no-deps --require-hashes --find-links=/opt/physiology/wheelhouse -r /opt/physiology/requirements.lock
python -m pip check
python -m physiology_inference.checkpoint_smoke --checkpoint-root /opt/physiology/assets --epochs 20 --output /tmp/linux-smoke.json
docker buildx build --platform linux/amd64 --load --build-context model_bundle=/new/bundle --file scoring-service/Dockerfile.model --tag physiology-pr21-model:preflight --progress plain .
```

Both exact temporary containers were removed after all unique evidence/artifacts were copied externally: `physiology-pr21-wheels-mtskyi` and `physiology-pr21-linux-smoke-mtskyi`. They are reproducible from the pinned image, recipe and retained bundle/wheels. No user containers/images or global Docker caches were pruned. No physiology activation, canonical output, infrastructure deployment or approval record was created.
