# Pinned iOS Zstandard codec

The package now builds the same upstream Zstandard 1.5.7 C sources on iOS and macOS. Production writes level 1 frames; the prior iOS raw-block writer remains only as a compatibility fixture. Existing saved payloads remain immutable and are replayed byte-for-byte. The wire codec remains `zstd`, and decoded content digests and receipt rules are unchanged. A newly compressed payload can have a different wire digest, which is recorded with its exact manifest as before.

## Provenance and review boundary

- [Official release](https://github.com/facebook/zstd/releases/tag/v1.5.7), commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`.
- Release archive SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`, matched against the upstream release checksum asset.
- `Tools/compression/vendor-zstd.py` verifies the pinned archive and copies 64 unmodified upstream common/compression/decompression source and header files plus the BSD license. Per-file hashes are in `Sources/CNoopZstd/vendor/zstd/provenance.json`.
- The C wrapper admits only levels 1 and 3, checks allocation/error outcomes, clears output parameters on failure, and uses one thread. Legacy codecs, assembly, tracing, dictionaries and worker threads are not enabled. The BSD notice is also copied into the NoopPush resource bundle.
- Review covered provenance, the wrapper, build flags, allocation/error paths, wire compatibility and source integrity. It was **not** an independent complete security audit of the upstream library. Upstream's [security policy](https://github.com/facebook/zstd/security/policy) remains the reporting reference. The absence of published repository advisories is not a claim that no vulnerability exists.

## Reproduction

Run the following from the repository root, keeping output outside the checkout:

```sh
python3 Tools/compression/vendor-zstd.py /path/to/zstd-1.5.7.tar.gz --check
python3 Tools/compression/benchmark.py /external/artifacts/codec
python3 Tools/compression/check-apple-codec.py /external/artifacts/apple-codec
swift test --package-path Packages/NoopPush --scratch-path /external/artifacts/nooppush --jobs 4
npx --yes deno@2.5.6 test --allow-read supabase/functions/tests/zstd_ios_golden_test.ts
```

`--write-goldens` regenerates the checked-in synthetic empty/repetitive/incompressible vectors. Swift uses the pinned decoder and verifies both wire and decoded SHA-256. The server test uses the independent production `fzstd@0.1.1` decoder, including seven-byte streaming input and production frame bounds. Both level 1 and level 3 decode to the same expected content and digest.

## Host measurements

Artifact root: `/Volumes/Untitled/nara-persistent-followup-20260922/compression/`. The machine-readable benchmark records source hashes, host/build, input/wire digests, CPU/wall time and RSS. Measurements used synthetic data only, macOS 26.6.2 arm64, `-O3`, 100 compressions in a separate process for each row. These are host measurements, not iPhone acceptance evidence.

| Synthetic corpus | Level | Wire/input | CPU seconds, 100 iterations | Peak RSS bytes |
| --- | ---: | ---: | ---: | ---: |
| Scalar NDJSON | 1 | 0.0410 | 0.118 | 4,390,912 |
| Scalar NDJSON | 3 | 0.0403 | 0.121 | 5,832,704 |
| Packed waveform | 1 | 0.5760 | 0.349 | 6,586,368 |
| Packed waveform | 3 | 0.4116 | 0.828 | 9,486,336 |
| Incompressible bytes | 1 | 1.00003 | 0.016 | 6,356,992 |
| Incompressible bytes | 3 | 1.00003 | 0.019 | 7,798,784 |

The old iOS raw framing is slightly larger than input. Level 1 is the conservative initial CPU/memory choice. This host result does not establish the best level for every phone or sensor stream. Cross-compilation covers arm64 iOS 17 and arm64 iOS Simulator; it does not prove execution on a phone.

Physical iPhone CPU, RSS, energy, battery, thermal pressure, representative WHOOP payload ratios and level comparisons: `NOT_MEASURED`. Production promotion remains gated on the requested device matrix and full-system measurements. Large-backlog memory behavior also depends on selection/spool admission and is not established by this codec microbenchmark.
