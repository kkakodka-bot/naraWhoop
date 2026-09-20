"""Offline human approval artifact for the feature-specific PostgreSQL gate.

No database connection, activation, or selection changes occur here. The evaluation
and reviewer keys have separate roles; HMAC is shared-secret authentication, not
public-key nonrepudiation or a substitute for independent scientific review.
"""

from __future__ import annotations

import hashlib
import hmac
from datetime import datetime, timezone
from uuid import UUID

from .contracts import canonical_bytes, content_hash, digest, identifier, require
from .promotion import promotion_decision, utc, verify


REFERENCE_KINDS = {"hrv": "synchronized_ecg_nn", "sleep": "psg_30s_and_sleep_opportunities",
                   "respiration": "synchronized_respiratory_reference"}


def create_approval(policy_envelope: dict, evaluation_envelope: dict, trusted_evaluation_keys: dict[str, bytes],
                    registration: dict, reviewer_approval: dict, approval_secret: bytes,
                    now: datetime | None = None) -> dict:
    decision = promotion_decision(policy_envelope, evaluation_envelope, trusted_evaluation_keys)
    require(decision["decision"] == "ELIGIBLE_FOR_HUMAN_REVIEW",
            "reference promotion gate not ready: " + "; ".join(decision["reasons"]))
    policy = verify(policy_envelope, trusted_evaluation_keys)
    evaluation = verify(evaluation_envelope, trusted_evaluation_keys)
    require(len(approval_secret) >= 32, "approval key must contain at least 32 secret bytes")
    require(hashlib.sha256(approval_secret).hexdigest() not in trusted_evaluation_keys,
            "reviewer approval must use a separate key from evaluation signing")
    feature = registration.get("feature")
    require(feature in REFERENCE_KINDS and feature == policy["metric_family"], "feature approval mismatch")
    algorithm = identifier(registration.get("algorithm_version"), "algorithm version")
    require(algorithm != "frwhoop-server-1", "legacy identity cannot label a physiology candidate")
    manifest = registration.get("manifest")
    require(isinstance(manifest, dict), "registered feature manifest required")
    text = registration.get("canonical_manifest")
    require(isinstance(text, str) and text == canonical_bytes(manifest).decode("utf-8"),
            "registered canonical manifest bytes mismatch")
    manifest_hash = digest(registration.get("manifest_sha256"), "feature manifest hash")
    require(content_hash(manifest) == manifest_hash, "registered feature manifest digest mismatch")
    algorithm_hash = digest(registration.get("algorithm_manifest_sha256"), "algorithm manifest hash")
    for key in ("algorithm_version", "feature", "checkpoint_sha256", "preprocessing_version",
                "preprocessing_sha256", "quality_policy_version", "quality_policy_sha256"):
        require(registration.get(key) == manifest.get(key), f"registered {key} mismatch")
    model = evaluation["model_manifest"]
    for key in ("preprocessing_sha256", "quality_policy_sha256"):
        require(digest(manifest.get(key), key) == model.get(key), f"evaluated model {key} mismatch")
    for key in ("preprocessing_version", "quality_policy_version"):
        require(identifier(manifest.get(key), key) == model.get(key), f"evaluated model {key} mismatch")
    checkpoint = digest(manifest.get("checkpoint_sha256"), "checkpoint hash")
    if model.get("weights_required"):
        require(checkpoint == model["checkpoint"]["sha256"], "evaluated checkpoint mismatch")
    else:
        require(manifest.get("checkpoint_kind") == "deterministic_source_not_learned_weights"
                and checkpoint == model.get("adapter_sha256"), "deterministic implementation digest mismatch")
    candidate = evaluation["report"].get("prediction_provenance", {}).get("candidate", {})
    require(candidate.get("algorithm_version") == algorithm, "evaluated algorithm identity mismatch")
    require(candidate.get("computation_mode") == manifest.get("mode"), "evaluated computation mode mismatch")
    for key, expected in (("feature_manifest_sha256", manifest_hash), ("algorithm_manifest_sha256", algorithm_hash)):
        require(policy.get(key) == expected and evaluation.get(key) == expected,
                f"{key} was not bound before heldout evaluation")
    require(reviewer_approval.get("schema_version") == 1 and reviewer_approval.get("decision") == "approved",
            "explicit human approval record required")
    reviewer = identifier(reviewer_approval.get("reviewer"), "reviewer")
    approval_id = str(UUID(reviewer_approval.get("approval_id", "")))
    require(approval_id == reviewer_approval["approval_id"], "canonical approval UUID required")
    for key, expected in (("feature", feature), ("algorithm_version", algorithm), ("manifest_sha256", manifest_hash),
                          ("policy_sha256", content_hash(policy)), ("evaluation_sha256", content_hash(evaluation))):
        require(reviewer_approval.get(key) == expected, f"human approval {key} mismatch")
    approved_at = reviewer_approval.get("approved_at")
    require(utc(evaluation["evaluation_finished_at"]) <= utc(approved_at) <= (now or datetime.now(timezone.utc)),
            "approval precedes evaluation completion or is in the future")
    hashes = sorted(set(evaluation["report"]["verified_reference_artifact_sha256"]))
    for value in hashes:
        digest(value, "verified reference artifact hash")
    payload = {"schema_version": 1, "purpose": "physiology_feature_promotion", "approval_id": approval_id,
               "key_id": hashlib.sha256(approval_secret).hexdigest(), "reviewer": reviewer, "decision": "approved",
               "algorithm_version": algorithm, "feature": feature, "manifest_sha256": manifest_hash,
               "algorithm_manifest_sha256": algorithm_hash, "checkpoint_sha256": checkpoint,
               "preprocessing_version": manifest["preprocessing_version"],
               "preprocessing_sha256": manifest["preprocessing_sha256"],
               "quality_policy_version": manifest["quality_policy_version"],
               "quality_policy_sha256": manifest["quality_policy_sha256"],
               "evaluation_sha256": content_hash(evaluation), "policy_sha256": content_hash(policy),
               "reference_artifact_sha256": content_hash({"reference_artifact_sha256": hashes}),
               "reference_artifact_hash_semantics": "sha256_canonical_json_sorted_reference_artifact_sha256_list",
               "reference_kind": REFERENCE_KINDS[feature], "evaluation_partition": evaluation["report"]["partition"],
               "participant_disjoint": True, "functional_gates_passed": True, "promotion_policy_passed": True,
               "policy_frozen_at": policy["frozen_at"], "evaluation_started_at": evaluation["evaluation_started_at"],
               "evaluation_finished_at": evaluation["evaluation_finished_at"], "approved_at": approved_at}
    signed_bytes = canonical_bytes(payload)
    require(len(signed_bytes) <= 32768, "approval payload exceeds database gate limit")
    return {"schema_version": 1, "status": "OFFLINE_APPROVAL_ARTIFACT", "canonical_publication_enabled": False,
            "approval": payload, "rpc": {"function": "register_physiology_promotion", "arguments": {
                "p_payload": signed_bytes.decode("utf-8"),
                "p_signature": hmac.new(approval_secret, signed_bytes, hashlib.sha256).hexdigest()}},
            "note": "No RPC was called. Registration, qualification, opt-in selection and deployment require separate authorization."}
