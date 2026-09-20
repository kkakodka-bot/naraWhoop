"""Capture and verify an observed interpreter/package environment; capture never qualifies it."""

import argparse
from hashlib import sha256
import importlib.metadata as metadata
from importlib.machinery import EXTENSION_SUFFIXES, PathFinder
from importlib.util import find_spec
import json
import os
from pathlib import Path
import platform
import re
import sys
import sysconfig

from .contracts import Abstain, canonical_hash

MODEL_DISTRIBUTIONS = {
    "feature-sleep-learner": ("numpy",), "rrest": ("numpy", "scipy"),
    "correncoder": ("numpy", "torch"),
    "wav2sleep-cardiorespiratory": ("numpy", "torch", "huggingface-hub", "hydra-core", "pandas", "pyarrow",
                                    "pyedflib", "omegaconf", "numba", "setuptools", "PyYAML", "tqdm"),
    "rr-estimation": ("numpy", "tensorflow", "evidential-deep-learning"),
    "neurokit2": ("numpy", "scipy", "pandas", "matplotlib", "PyWavelets", "scikit-learn", "requests", "setuptools"),
    "walch-sleep-classifiers": ("numpy", "scipy", "pandas", "scikit-learn"),
    "sleepecg": ("numpy", "scipy", "sleepecg"),
}
RUNTIME_DISTRIBUTIONS = ("packaging",)


def normalized(name):
    return re.sub(r"[-_.]+", "-", name).lower()


class HashBudget:
    def __init__(self):
        self.files = 0
        self.bytes = 0

    def file(self, path):
        path = Path(path)
        self.files += 1; self.bytes += path.stat().st_size
        if self.files > 100000 or self.bytes > 2 * 1024**3:
            raise Abstain("environment_hash_budget_exceeded")
        digest = sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024**2), b""):
                digest.update(block)
        return digest.hexdigest()


def interpreter_fingerprint(budget):
    root = Path(sysconfig.get_path("stdlib"))
    files = {}
    for directory, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in ("site-packages", "__pycache__", ".git"))
        for name in sorted(names):
            path = Path(directory) / name
            if path.suffix in (".py", ".so", ".dylib", ".pyd"):
                files[str(path.relative_to(root))] = budget.file(path)
    return {"implementation": platform.python_implementation(), "version": platform.python_version(),
            "cache_tag": sys.implementation.cache_tag, "executable_sha256": budget.file(Path(sys.executable).resolve()),
            "stdlib_sha256": canonical_hash(files)}


def package_closure(roots):
    if not roots:
        return {}
    from packaging.requirements import Requirement
    available = {}
    for distribution in metadata.distributions():
        name = distribution.metadata.get("Name")
        if name:
            available.setdefault(normalized(name), []).append(distribution)
    result = {}; pending = list(roots)
    while pending:
        name = normalized(pending.pop())
        if name in result:
            continue
        candidates = available.get(name, [])
        # Duplicate stale dist-info is not silently treated as an exact version lock.
        locations = {str(distribution.locate_file("")) + ":" + distribution.version for distribution in candidates}
        if len(locations) != 1:
            raise Abstain("environment_distribution_missing_or_ambiguous:" + name)
        distribution = candidates[0]
        result[name] = distribution
        for raw in distribution.requires or []:
            requirement = Requirement(raw)
            if requirement.marker is None or requirement.marker.evaluate({"extra": ""}):
                pending.append(requirement.name)
    return result


def import_origins(distributions):
    """Resolve roots without importing model code; reject lookup outside inventoried files."""
    owned_files = set(); root_directories = {}; roots = set()
    for distribution in distributions.values():
        for entry in distribution.files or []:
            parts = entry.parts
            if not parts or parts[0] in (".", "..", "__pycache__"):
                continue
            path = Path(distribution.locate_file(entry)).resolve()
            owned_files.add(path)
            if len(parts) > 1 and parts[0].isidentifier() and (str(entry).endswith(".py") or any(str(entry).endswith(s) for s in EXTENSION_SUFFIXES)):
                root = parts[0]
                roots.add(root)
                root_directories.setdefault(root, set()).add(Path(distribution.locate_file(root)).resolve())
            elif len(parts) == 1:
                suffix = next((s for s in (".py", *EXTENSION_SUFFIXES) if str(entry).endswith(s)), None)
                root = str(entry)[:-len(suffix)] if suffix else ""
                if root.isidentifier():
                    roots.add(root)

    def checked(root, origin, locations):
        if origin is not None and Path(origin).resolve() not in owned_files:
            raise Abstain("environment_import_origin_not_in_inventory:" + root)
        paths = sorted(str(Path(path).resolve()) for path in (locations or []))
        if any(Path(path) not in root_directories.get(root, set()) for path in paths):
            raise Abstain("environment_import_path_not_in_inventory:" + root)
        if origin is None and not paths:
            raise Abstain("environment_import_root_unresolved:" + root)
        return {"origin": str(Path(origin).resolve()) if origin is not None else None, "package_paths": paths}

    result = []
    for root in sorted(roots):
        selected = find_spec(root)
        lookup = PathFinder.find_spec(root, sys.path)
        if selected is None or lookup is None:
            raise Abstain("environment_import_root_unresolved:" + root)
        selected_origin = checked(root, selected.origin, selected.submodule_search_locations)
        lookup_origin = checked(root, lookup.origin, lookup.submodule_search_locations)
        loaded = sys.modules.get(root)
        if loaded is not None:
            loaded_origin = checked(root, getattr(loaded, "__file__", None), getattr(loaded, "__path__", None))
            if loaded_origin != selected_origin:
                raise Abstain("environment_loaded_import_mismatch:" + root)
        result.append({"module": root, "selected": selected_origin, "path_lookup": lookup_origin})
    return result


def capture(model_id, additional_distributions=(), external_executables=None):
    if model_id not in MODEL_DISTRIBUTIONS:
        raise Abstain("environment_model_unknown")
    budget = HashBudget()
    packages = []
    distributions = package_closure((*RUNTIME_DISTRIBUTIONS, *MODEL_DISTRIBUTIONS[model_id], *additional_distributions))
    origins = import_origins(distributions)
    for name, distribution in sorted(distributions.items()):
        if not distribution.files:
            raise Abstain("environment_distribution_file_inventory_missing:" + name)
        inventory = {}
        for entry in sorted(distribution.files, key=str):
            if str(entry).endswith((".pyc", ".pyo")) or "__pycache__" in entry.parts:
                continue
            path = Path(distribution.locate_file(entry))
            if not path.is_file():
                raise Abstain("environment_distribution_file_missing:" + name)
            inventory[str(entry)] = budget.file(path)
        packages.append({"name": name, "version": distribution.version, "content_sha256": canonical_hash(inventory)})
    executables = {name: {"sha256": budget.file(Path(path).resolve())}
                   for name, path in sorted((external_executables or {}).items())}
    if model_id == "rrest" and "octave" not in executables:
        raise Abstain("environment_octave_identity_required")
    return {"schema_version": 1, "model_id": model_id, "qualification_status": "unqualified_observed_environment",
            "python": interpreter_fingerprint(budget),
            "platform": {"system": platform.system(), "machine": platform.machine(),
                         "platform_tag": sysconfig.get_platform(), "libc": list(platform.libc_ver())},
            "packages": packages, "import_origins": origins, "external_executables": executables,
            "limitations": "Observed installed bytes, not wheel-origin verification, legal review or actual-VPS qualification."}


def verify(manifest, model_id, review, external_executables=None):
    if not isinstance(review, dict) or review.get("status") != "reviewed_for_shadow" or any(
            not isinstance(review.get(key), str) or not review[key].strip() for key in ("identifier", "evidence")):
        raise Abstain("environment_review_required")
    if manifest.get("schema_version") != 1 or manifest.get("model_id") != model_id or manifest.get("qualification_status") != "qualified_shadow_environment":
        raise Abstain("qualified_environment_manifest_required")
    packages = manifest.get("packages")
    if not isinstance(packages, list) or len(packages) > 500 or any(not isinstance(p, dict) or not isinstance(p.get("name"), str) for p in packages):
        raise Abstain("environment_package_inventory_invalid")
    names = [normalized(p["name"]) for p in packages]
    if len(names) != len(set(names)) or not set(map(normalized, (*RUNTIME_DISTRIBUTIONS, *MODEL_DISTRIBUTIONS.get(model_id, ())))).issubset(names):
        raise Abstain("environment_required_packages_missing")
    actual = capture(model_id, names, external_executables)
    if any(manifest.get(key) != actual[key] for key in ("python", "platform", "packages", "import_origins", "external_executables")):
        raise Abstain("runtime_environment_mismatch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, choices=sorted(MODEL_DISTRIBUTIONS))
    parser.add_argument("--distribution", action="append", default=[])
    parser.add_argument("--octave-executable"); parser.add_argument("--output")
    args = parser.parse_args()
    try:
        result = capture(args.model, args.distribution, {"octave": args.octave_executable} if args.octave_executable else None)
        encoded = json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n"
        if args.output:
            with Path(args.output).open("x") as stream:
                stream.write(encoded)
        else:
            print(encoded, end="")
        return 0
    except (ValueError, OSError, ImportError) as error:
        print(f"environment-capture: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
