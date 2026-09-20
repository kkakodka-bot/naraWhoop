"""Versioned evaluation signatures and explicit fail-closed promotion checks."""

from __future__ import annotations

import hashlib
import hmac
from datetime import datetime

from .contracts import canonical_bytes, content_hash, digest, identifier, number, require
from .manifests import validate_model
from .splits import audit_fit_artifacts

COMMON_ROLES = {"primary_improvement", "coverage_noninferiority", "subgroup_regression", "resource_budget"}
ROLES = COMMON_ROLES | {"wake_noninferiority", "end_to_end_detection"}
FAMILY_PATHS = {"sleep": "stages", "hrv": "numeric/rmssd_ms", "respiration": "numeric/respiratory_rate_bpm"}


def utc(value: str) -> datetime:
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError) as error:
        raise ValueError("ISO-8601 UTC timestamp required") from error
    require(result.tzinfo is not None and result.utcoffset().total_seconds() == 0, "timestamp must be UTC")
    return result


def sign(payload: dict, secret: bytes, signer: str) -> dict:
    require(len(secret) >= 32, "signing key must contain at least 32 secret bytes")
    identifier(signer, "signer")
    envelope = {"schema_version": 1, "payload": payload, "signature": {"algorithm": "HMAC-SHA256",
                "signer": signer, "key_id": hashlib.sha256(secret).hexdigest()}}
    envelope["signature"]["hex"] = hmac.new(secret, canonical_bytes(envelope), hashlib.sha256).hexdigest()
    return envelope


def verify(envelope: dict, trusted_keys: dict[str, bytes]) -> dict:
    require(envelope.get("schema_version") == 1 and isinstance(envelope.get("payload"), dict), "invalid signed envelope")
    signature = envelope.get("signature", {})
    require(signature.get("algorithm") == "HMAC-SHA256", "unsupported signature algorithm")
    key = trusted_keys.get(signature.get("key_id"))
    require(key is not None and len(key) >= 32, "untrusted signer key")
    require(hashlib.sha256(key).hexdigest() == signature["key_id"], "trusted-key identity mismatch")
    identifier(signature.get("signer"), "signer")
    signed = {"schema_version": envelope["schema_version"], "payload": envelope["payload"],
              "signature": {name: signature[name] for name in ("algorithm", "signer", "key_id")}}
    expected = hmac.new(key, canonical_bytes(signed), hashlib.sha256).hexdigest()
    require(isinstance(signature.get("hex"), str) and hmac.compare_digest(expected, signature["hex"]),
            "signature mismatch")
    return envelope["payload"]


def freeze_policy(policy: dict) -> dict:
    require(policy.get("schema_version") == 1 and policy.get("status") == "frozen", "policy is not frozen")
    identifier(policy.get("policy_id"), "policy_id")
    utc(policy.get("frozen_at"))
    require(policy.get("metric_family") in ("sleep", "hrv", "respiration"), "feature-specific metric family required")
    family = policy["metric_family"]
    memory_metric = policy.get("memory_resource_metric", "maximum_rss_bytes")
    require(memory_metric in ("maximum_rss_bytes", "process_tree_memory_peak_bytes"), "explicit supported memory resource metric required")
    metric_path = FAMILY_PATHS[family]
    for key in ("dataset_sha256", "split_sha256", "config_sha256", "model_manifest_sha256", "fit_audit_sha256"):
        digest(policy.get(key), key)
    require(isinstance(policy.get("minimum_participants"), int) and policy["minimum_participants"] > 1,
            "prespecified participant budget required")
    criteria = policy.get("criteria", [])
    required_roles = COMMON_ROLES | ({"wake_noninferiority", "end_to_end_detection"} if policy["metric_family"] == "sleep" else set())
    require(required_roles <= {row.get("role") for row in criteria}, "policy lacks mandatory improvement/noninferiority/resource criteria")
    require(isinstance(policy.get("required_subgroups"), list) and bool(policy["required_subgroups"]),
            "intended-use subgroup plan required")
    for subgroup in policy["required_subgroups"]:
        identifier(subgroup, "required subgroup")
        require("/" not in subgroup, "slash not supported in subgroup policy paths")
    for row in criteria:
        require(row.get("role") in ROLES and row.get("operator") in ("<=", ">="), "invalid criterion")
        identifier(row.get("path"), "criterion path")
        number(row.get("limit"), "criterion limit")
        path = row["path"]
        if row["role"] == "primary_improvement":
            primary = {"sleep": "report/stages/common/candidate_minus_baseline_kappa",
                       "hrv": "report/numeric/rmssd_ms/common/candidate_minus_baseline_mae",
                       "respiration": "report/numeric/respiratory_rate_bpm/common/candidate_minus_baseline_mae"}
            require(path == primary[policy["metric_family"]], "primary improvement must compare the feature's paired common-reference errors/scores")
            require((path.endswith("candidate_minus_baseline_mae") and row["operator"] == "<=" and row["limit"] < 0)
                    or (path.endswith("candidate_minus_baseline_kappa") and row["operator"] == ">=" and row["limit"] > 0),
                    "primary budget must require strict improvement, not equality or degradation")
        elif row["role"] == "wake_noninferiority":
            require(family == "sleep" and path == "report/stages/native/candidate_minus_baseline_wake_specificity_all_reference"
                    and row["operator"] == ">=", "wake noninferiority must compare full-reference wake specificity")
        elif row["role"] == "coverage_noninferiority":
            require(path == f"report/{metric_path}/native/candidate_minus_baseline_accepted_coverage"
                    and row["operator"] == ">=", "coverage noninferiority must compare the feature's native accepted coverage")
        elif row["role"] == "subgroup_regression":
            suffixes = ("common/candidate_minus_baseline_kappa", "native/candidate_minus_baseline_accepted_coverage",
                        "native/candidate_minus_baseline_wake_specificity_all_reference") if family == "sleep" else (
                        "common/candidate_minus_baseline_mae", "native/candidate_minus_baseline_accepted_coverage")
            require(path in {f"report/subgroups/{group}/{metric_path}/{suffix}"
                             for group in policy["required_subgroups"] for suffix in suffixes},
                    "subgroup criterion must compare the feature's prespecified subgroup outputs")
            require((path.endswith("candidate_minus_baseline_mae") and row["operator"] == "<=" and row["limit"] >= 0)
                    or (path.endswith(("candidate_minus_baseline_kappa", "candidate_minus_baseline_accepted_coverage",
                                       "candidate_minus_baseline_wake_specificity_all_reference"))
                        and row["operator"] == ">=" and row["limit"] <= 0), "subgroup regression budget has wrong direction")
        elif row["role"] == "end_to_end_detection":
            require(family == "sleep" and ((path == "report/detection/candidate/recall" and row["operator"] == ">=" and row["limit"] > 0)
                    or (path == "report/detection/candidate/false_episodes_per_24h" and row["operator"] == "<=" and row["limit"] >= 0)),
                    "end-to-end criteria must bound annotated episode recall/false episodes")
        else:
            expected = {"resources/p95_latency_ms": "<=", f"resources/{memory_metric}": "<=",
                        "resources/cpu_seconds_per_record": "<=", "resources/records_per_hour": ">="}
            require(path in expected and row["operator"] == expected[path] and row["limit"] > 0,
                    "resource budget must bound actual latency, prespecified memory metric, CPU or throughput")
    for subgroup in policy["required_subgroups"]:
        require(any(row["role"] == "subgroup_regression" and row["path"].startswith(f"report/subgroups/{subgroup}/")
                    for row in criteria), f"subgroup lacks regression budget: {subgroup}")
    require({"resources/p95_latency_ms", f"resources/{memory_metric}", "resources/cpu_seconds_per_record", "resources/records_per_hour"}
            <= {row["path"] for row in criteria if row["role"] == "resource_budget"}, "all target resource budgets required")
    if policy["metric_family"] == "sleep":
        require({"report/detection/candidate/recall", "report/detection/candidate/false_episodes_per_24h"}
                <= {row["path"] for row in criteria if row["role"] == "end_to_end_detection"},
                "sleep requires both end-to-end detection recall and false-episode budgets")
    require(isinstance(policy.get("minimum_subgroup_participants"), int) and policy["minimum_subgroup_participants"] > 1,
            "prespecified subgroup participant budget required")
    require(policy.get("requires_locked_phone_soak") is True and policy.get("requires_actual_target_resources") is True,
            "hardware/resource evidence gates cannot be disabled")
    return policy


def lookup(value: dict, path: str):
    current = value
    for part in path.split("/"):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def qualified_participants(report: dict, family: str, minimum: int, assignments: dict, partition: str,
                           allowed: set[str], scope: str) -> set[str]:
    common = lookup(report, FAMILY_PATHS[family] + "/common") or {}
    participants = common.get("participants", [])
    require(isinstance(participants, list) and all(isinstance(pid, str) for pid in participants),
            f"{scope}: qualified participant identities missing")
    require(len(set(participants)) == len(participants) and common.get("participant_n") == len(participants)
            and len(participants) >= minimum, f"{scope}: qualified feature participant budget not met")
    require(set(participants) <= allowed and all(assignments.get(pid) == partition for pid in participants),
            f"{scope}: qualified participants are not in the heldout partition")
    interval = common.get("kappa_difference_participant_ci" if family == "sleep" else "mae_difference_participant_ci", {})
    require(interval.get("participant_n") == len(participants) and interval.get("unit") == "participant"
            and isinstance(interval.get("replicates"), int) and interval["replicates"] >= 10
            and isinstance(interval.get("defined_replicates"), int)
            and 0 < interval["defined_replicates"] <= interval["replicates"],
            f"{scope}: paired participant uncertainty unavailable")
    require(number(interval.get("lower"), "paired uncertainty lower") <= number(interval.get("upper"), "paired uncertainty upper"),
            f"{scope}: paired participant uncertainty invalid")
    return set(participants)


def promotion_decision(policy_envelope: dict, evaluation_envelope: dict, trusted_keys: dict[str, bytes]) -> dict:
    reasons = []
    try:
        policy = freeze_policy(verify(policy_envelope, trusted_keys))
        manifest = verify(evaluation_envelope, trusted_keys)
        require(manifest.get("schema_version") == 1, "unsupported evaluation manifest")
        require(manifest.get("policy_sha256") == content_hash(policy), "evaluation is not bound to frozen policy")
        require(utc(policy["frozen_at"]) < utc(manifest.get("evaluation_started_at")), "policy frozen after evaluation began")
        report = manifest.get("report", {})
        require(report.get("reference_validation_ready") is True and report.get("evidence_kind") == "reference",
                "real synchronized heldout reference evaluation required")
        require(report.get("partition") in ("test", "external"), "heldout evaluation partition required")
        verified_hashes = report.get("verified_reference_artifact_sha256", [])
        provenance = report.get("reference_provenance", [])
        require(bool(verified_hashes) and bool(provenance), "reference artifact byte verification missing")
        for reference in provenance:
            digest(reference.get("sha256"), "reference artifact hash")
            require(reference["sha256"] in verified_hashes and reference.get("adjudicated") is True
                    and reference.get("synchronization", {}).get("applied") is True,
                    "reference adjudication/alignment/hash verification incomplete")
        for key in ("dataset_sha256", "split_sha256", "config_sha256", "model_manifest_sha256"):
            require(report.get(key) == policy[key], f"policy/report {key} mismatch")
        require(len(report.get("evaluated_participants", [])) >= policy["minimum_participants"], "participant budget not met")
        require(manifest.get("functional_gates_passed") is True, "functional gates not passed")
        model_manifest = validate_model(manifest.get("model_manifest", {}), for_execution=True)
        require(content_hash(model_manifest) == policy["model_manifest_sha256"], "executed model differs from frozen manifest")
        require(report.get("leakage_audit", {}).get("overlap_conflicts") == 0,
                "missing or failed receptive-field leakage audit")
        fit_audit = manifest.get("fit_audit", {})
        require(fit_audit.get("status") == "provenance_passed" and fit_audit.get("split_sha256") == policy["split_sha256"],
                "missing or mismatched training/calibration/selection fit audit")
        require(content_hash(fit_audit) == policy["fit_audit_sha256"], "fit audit differs from frozen policy")
        require(audit_fit_artifacts(fit_audit.get("artifacts", []), fit_audit.get("split", {})) == fit_audit,
                "invalid training/calibration/selection fit audit")
        evaluated = report.get("evaluated_participants", [])
        require(isinstance(evaluated, list) and all(isinstance(pid, str) for pid in evaluated)
                and len(set(evaluated)) == len(evaluated), "invalid evaluated participant identities")
        assignments = fit_audit["split"]["assignments"]
        require(all(assignments.get(pid) == report["partition"] for pid in evaluated),
                "evaluated participant outside heldout partition")
        qualified = qualified_participants(report, policy["metric_family"], policy["minimum_participants"],
                                           assignments, report["partition"], set(evaluated), "overall")
        for gate in ("functional_gate_suite", "locked_phone_soak", "actual_target_resources", "reference_custodian_attestation"):
            evidence = manifest.get("evidence", {}).get(gate, {})
            require(evidence.get("status") == "passed", f"missing {gate}")
            digest(evidence.get("artifact_sha256"), f"{gate} artifact hash")
            identifier(evidence.get("reviewer"), f"{gate} reviewer")
        for subgroup in policy["required_subgroups"]:
            qualified_participants(report.get("subgroups", {}).get(subgroup, {}), policy["metric_family"],
                                   policy["minimum_subgroup_participants"], assignments, report["partition"], qualified, subgroup)
        memory_metric = policy.get("memory_resource_metric", "maximum_rss_bytes")
        require(number(manifest.get("resources", {}).get(memory_metric), "measured memory") > 0, "measured memory must be positive")
        if memory_metric == "process_tree_memory_peak_bytes":
            accounting = manifest.get("resource_accounting", {})
            require(accounting.get("method") == "dedicated_cgroup_v2_process_tree" and
                    accounting.get("memory_semantics") == "kernel_cgroup_lifetime_charged_memory_peak" and
                    accounting.get("dedicated_scope_checked") is True,
                    "prespecified cgroup metric requires dedicated kernel process-tree accounting")
        elif "resource_accounting" in manifest:
            accounting = manifest["resource_accounting"]
            require(isinstance(accounting, dict) and accounting.get("method") == "python_worker_rusage" and
                    accounting.get("memory_semantics") == "single_worker_peak_rss",
                    "RSS budget cannot accept contradictory memory accounting semantics")
        root = {"report": report, "resources": manifest.get("resources", {})}
        for criterion in policy["criteria"]:
            value = lookup(root, criterion["path"])
            if value is None:
                reasons.append(f"missing criterion: {criterion['path']}")
                continue
            number(value, criterion["path"])
            passed = value <= criterion["limit"] if criterion["operator"] == "<=" else value >= criterion["limit"]
            if not passed:
                reasons.append(f"criterion failed: {criterion['path']}")
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        reasons.append(str(error))
    return {"schema_version": 1, "decision": "ELIGIBLE_FOR_HUMAN_REVIEW" if not reasons else "NOT_READY",
            "canonical_publication_enabled": False, "reasons": reasons,
            "note": "This offline decision never changes model selection, cohort consent or production configuration."}
