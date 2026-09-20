"""Model metadata is not an executable adapter or an approval to load weights."""

from .contracts import digest, identifier, number, require


def validate_model(manifest: dict, for_execution: bool = False) -> dict:
    require(manifest.get("schema_version") == 1, "unsupported model manifest")
    identifier(manifest.get("model_id"), "model id")
    require(manifest.get("publication_mode") == "shadow", "candidate must remain shadow")
    require(manifest.get("canonical_outputs_allowed") is False, "canonical candidate writes forbidden")
    require(manifest.get("operational_status") in ("metadata_only", "adapter_ready", "reference_validation_pending"),
            "unknown operational status")
    code = manifest.get("code", {})
    identifier(code.get("repository"), "code repository")
    revision = code.get("revision")
    require(isinstance(revision, str) and len(revision) == 40 and all(c in "0123456789abcdef" for c in revision),
            "pinned code commit required")
    for kind in ("code", "weights", "training_data"):
        rights = manifest.get("licenses", {}).get(kind, {})
        require(rights.get("status") in ("declared_upstream", "unverified", "reviewed", "not_applicable"),
                f"separate {kind} license status required")
        require("identifier" in rights and "evidence_url" in rights, f"separate {kind} license fields required")
    require(isinstance(manifest.get("input_contract"), dict), "model input contract required")
    require(isinstance(manifest.get("blockers"), list), "model blockers required")
    if for_execution:
        require(manifest["operational_status"] != "metadata_only", "model has metadata only; adapter not operational")
        require(not manifest["blockers"], "model execution blockers remain")
        for kind, rights in manifest["licenses"].items():
            require(rights["status"] in ("reviewed", "not_applicable"), f"{kind} rights not reviewed")
            if rights["status"] == "reviewed":
                for field in ("identifier", "evidence_url"):
                    require(isinstance(rights.get(field), str) and bool(rights[field].strip()),
                            f"{kind} reviewed rights require {field}")
            else:
                require(isinstance(rights.get("reason"), str) and bool(rights["reason"].strip()),
                        f"{kind} not-applicable rights require a reason")
        require(manifest["licenses"]["code"]["status"] == "reviewed", "code rights need explicit review")
        require(manifest.get("dataset_rights_status") == "reviewed", "evaluation dataset rights not reviewed")
        for key in ("preprocessing_sha256", "quality_policy_sha256", "adapter_sha256"):
            digest(manifest.get(key), key)
        if manifest.get("weights_required"):
            require(manifest["licenses"]["weights"]["status"] == "reviewed", "required weights need explicit rights review")
            digest(manifest.get("checkpoint", {}).get("sha256"), "checkpoint SHA-256")
        require(manifest.get("resource_limits", {}).get("maximum_concurrency") == 1,
                "initial unvalidated adapter concurrency must be one")
        limits = manifest["resource_limits"]
        require(isinstance(limits.get("threads"), int) and 0 < limits["threads"] <= 4, "bounded model thread count required")
        require(number(limits.get("timeout_seconds"), "model timeout") > 0, "positive model timeout required")
        require(number(limits.get("maximum_rss_bytes"), "model RSS limit") > 0, "positive model RSS limit required")
        require(number(limits.get("numerical_tolerance"), "numerical tolerance") >= 0, "declared numerical tolerance required")
    return manifest
