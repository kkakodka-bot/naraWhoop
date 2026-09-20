#!/usr/bin/env python3
"""Mechanically refresh source digests only. Never change activation, rights or qualification."""
from hashlib import sha256
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scoring-service/inference"))
from physiology_inference.contracts import implementation_hash

adapter_hash = implementation_hash()
policy = "models/policies/physiology-shadow-quality-2.json"
policy_hash = sha256((root / policy).read_bytes()).hexdigest()
for path in sorted((root / "models/manifests").glob("*.json")):
    if path.name == "model-manifest.schema.json":
        continue
    value = json.loads(path.read_text())
    value["preprocessing_sha256"] = sha256((root / value["preprocessing_source"]).read_bytes()).hexdigest()
    value["adapter_sha256"] = adapter_hash
    value["implementation"]["implementation_sha256"] = adapter_hash
    value["quality_policy_sha256"] = policy_hash
    value["quality_policy_source"] = policy
    value["quality_policy_version"] = "physiology-shadow-quality-2"
    path.write_text(json.dumps(value, indent=2) + "\n")
print(adapter_hash)
