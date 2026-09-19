#!/usr/bin/env python3
"""Offline JSON pipeline; writes only explicitly selected artifact paths."""

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from physiology_bench.contracts import content_hash, digest, file_hash, load_json, require, validate_dataset
from physiology_bench.approval import create_approval
from physiology_bench.evaluate import evaluate
from physiology_bench.manifests import validate_model
from physiology_bench.promotion import freeze_policy, promotion_decision, sign, utc
from physiology_bench.splits import audit_fit_artifacts, participant_split, purge_overlap


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    split = commands.add_parser("split")
    split.add_argument("--dataset", required=True)
    split.add_argument("--seed", required=True)
    split.add_argument("--external-participant", action="append", default=[])
    purge = commands.add_parser("purge")
    purge.add_argument("--windows", required=True)
    purge.add_argument("--split", required=True)
    purge.add_argument("--embargo-seconds", type=float, default=0)
    score = commands.add_parser("evaluate")
    for name in ("dataset", "baseline", "candidate", "split", "config"):
        score.add_argument("--" + name, required=True)
    score.add_argument("--policy", required=True)
    score.add_argument("--fit-audit", help="Fit audit JSON generated before evaluation")
    score.add_argument("--model-manifest", help="Exact candidate manifest; metadata-only manifests cannot promote")
    score.add_argument("--reference-artifact", action="append", default=[], help="Original reference file whose bytes must match declared SHA-256")
    signer = commands.add_parser("sign")
    signer.add_argument("--payload", required=True)
    signer.add_argument("--key-file", required=True)
    signer.add_argument("--signer", required=True)
    gate = commands.add_parser("promotion-check")
    gate.add_argument("--policy", required=True)
    gate.add_argument("--evaluation", required=True)
    gate.add_argument("--trusted-key-file", required=True)
    approval = commands.add_parser("prepare-approval", help="Create offline signed RPC arguments; never submit or activate")
    for name in ("policy", "evaluation", "trusted-key-file", "feature-registration", "reviewer-approval", "approval-key-file"):
        approval.add_argument("--" + name, required=True)
    check = commands.add_parser("validate-model")
    check.add_argument("--manifest", required=True)
    check.add_argument("--for-execution", action="store_true")
    audit = commands.add_parser("fit-audit")
    audit.add_argument("--artifacts", required=True)
    audit.add_argument("--split", required=True)
    for command in (split, purge, score, signer, gate, approval, check, audit):
        command.add_argument("--output", help="New output file; existing paths are never overwritten")
    args = parser.parse_args(argv)
    try:
        if args.command == "split":
            dataset = validate_dataset(load_json(args.dataset))
            result = participant_split([row["id"] for row in dataset["participants"]], args.seed,
                                       external_ids=tuple(args.external_participant))
        elif args.command == "purge":
            kept, purged = purge_overlap(load_json(args.windows)["windows"], load_json(args.split), args.embargo_seconds)
            result = {"schema_version": 1, "windows": kept, "purged": purged}
        elif args.command == "evaluate":
            started = datetime.now(timezone.utc).isoformat()
            policy = load_json(args.policy)
            dataset, split, config = (load_json(getattr(args, name)) for name in ("dataset", "split", "config"))
            fit_audit = model_manifest = None
            if dataset.get("evidence_kind") == "reference" and config.get("partition") in ("test", "external"):
                freeze_policy(policy)
                require(utc(policy["frozen_at"]) < utc(started), "policy must be frozen before heldout evaluation")
                for key, value in (("dataset_sha256", dataset), ("split_sha256", split), ("config_sha256", config)):
                    require(policy[key] == content_hash(value), f"frozen {key} mismatch before heldout predictions")
                for key in ("feature_manifest_sha256", "algorithm_manifest_sha256"):
                    digest(policy.get(key), key)
                require(args.fit_audit and args.model_manifest,
                        "frozen fit audit and model manifest required before heldout predictions")
                fit_audit = load_json(args.fit_audit)
                model_manifest = validate_model(load_json(args.model_manifest), for_execution=True)
                require(content_hash(model_manifest) == policy["model_manifest_sha256"],
                        "frozen model manifest mismatch before heldout predictions")
                require(content_hash(fit_audit) == policy["fit_audit_sha256"] and
                        fit_audit.get("split_sha256") == policy["split_sha256"] and
                        audit_fit_artifacts(fit_audit.get("artifacts", []), fit_audit.get("split", {})) == fit_audit,
                        "frozen fit audit mismatch before heldout predictions")
            report = evaluate(dataset, load_json(args.baseline), load_json(args.candidate), split, config,
                              verified_reference_hashes=tuple(file_hash(path) for path in args.reference_artifact))
            result = {"schema_version": 1, "evaluation_started_at": started,
                      "evaluation_finished_at": datetime.now(timezone.utc).isoformat(),
                      "policy_sha256": content_hash(policy), "report": report,
                      "feature_manifest_sha256": policy.get("feature_manifest_sha256"),
                      "algorithm_manifest_sha256": policy.get("algorithm_manifest_sha256"),
                      "functional_gates_passed": False,
                      "fit_audit": fit_audit or (load_json(args.fit_audit) if args.fit_audit else None),
                      "model_manifest": model_manifest or (load_json(args.model_manifest) if args.model_manifest else None),
                      "evidence": {}, "resources": {}}
        elif args.command == "fit-audit":
            result = audit_fit_artifacts(load_json(args.artifacts)["artifacts"], load_json(args.split))
        elif args.command == "sign":
            result = sign(load_json(args.payload), Path(args.key_file).read_bytes(), args.signer)
        elif args.command == "promotion-check":
            key = Path(args.trusted_key_file).read_bytes()
            result = promotion_decision(load_json(args.policy), load_json(args.evaluation),
                                        {hashlib.sha256(key).hexdigest(): key})
        elif args.command == "prepare-approval":
            key = Path(args.trusted_key_file).read_bytes()
            result = create_approval(load_json(args.policy), load_json(args.evaluation),
                {hashlib.sha256(key).hexdigest(): key}, load_json(args.feature_registration),
                load_json(args.reviewer_approval), Path(args.approval_key_file).read_bytes())
        else:
            manifest = validate_model(load_json(args.manifest), args.for_execution)
            result = {"valid": True, "manifest_sha256": content_hash(manifest), "operational_status": manifest["operational_status"]}
        encoded = json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n"
        if args.output:
            with Path(args.output).open("x", encoding="utf-8") as output:
                output.write(encoded)
        else:
            sys.stdout.write(encoded)
        return 3 if args.command == "promotion-check" and result["decision"] == "NOT_READY" else 0
    except (ValueError, KeyError, TypeError, AttributeError, OSError) as error:
        print(f"physiology-bench: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
