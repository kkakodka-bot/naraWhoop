# Physiology v2 candidate evidence

Start with [the iOS/server production-candidate report](production-candidate.md). It distinguishes implemented code, acquisition readiness, reference validation, deployment, and canonical promotion.

- [Independent integration audit](production-candidate-independent-audit.md)
- [Reference accuracy and retained-coverage status](reference-validation-production-candidate.md)
- [Learned models, checkpoint execution and input availability](learned-model-production-candidate.md)
- [Immutable candidate algorithm manifests](candidate-algorithm-manifests.json)
- [Linux offline packaging preflight](linux-model-packaging-preflight.md)
- [Isolated model queue and deployment contract](model-execution-production-candidate.md)
- [Actual-VPS resource status](vps-resource-report.md)
- [Receiver motion/orientation provenance](motion-input-provenance.md)
- [HRV policy](hrv.md), [sleep policy](sleep-production-candidate.md), [respiration policy](respiration-production-candidate.md)

Earlier verification, audit, upload-repair and deployment reports are historical evidence for their stated commits and environments. They do not qualify this candidate or transfer device, reference, deployment, or canonical acceptance to a later head. The exact-head verification script records the tested commit outside the checkout; the final PR handoff identifies those artifacts.
