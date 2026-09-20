#!/usr/bin/env python3
"""Plan, validate, or write pooler loopback bindings without touching credentials/services.

Requires python3-yaml and Docker Compose. Default mode validates a proposed repair in
private temporary files; --write additionally saves checked source edits and backups.
--check validates existing source; --running also checks the live container bindings.
No mode starts/restarts containers, sources .env, or prints rendered configuration.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("FAIL: python3-yaml is required", file=sys.stderr)
    sys.exit(1)


class RepairError(Exception):
    pass


def mapping(node):
    if not isinstance(node, yaml.MappingNode):
        raise RepairError("expected_yaml_mapping")
    result = {}
    for key, value in node.value:
        if not isinstance(key, yaml.ScalarNode) or key.value in result:
            raise RepairError("ambiguous_yaml_mapping")
        result[key.value] = (key, value)
    return result


def scalar(node):
    if not isinstance(node, yaml.ScalarNode):
        raise RepairError("expected_scalar_port_field")
    return node.value


def split_short_port(value):
    parts, start, depth, brackets = [], 0, 0, 0
    for index, char in enumerate(value):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        elif char == "[":
            brackets += 1
        elif char == "]":
            brackets -= 1
        elif char == ":" and depth == 0 and brackets == 0:
            parts.append(value[start:index])
            start = index + 1
    parts.append(value[start:])
    if depth or brackets or len(parts) not in (2, 3):
        raise RepairError("unsupported_short_port_shape")
    return parts


def repaired_ports(node):
    if not isinstance(node, yaml.SequenceNode) or node.tag != "tag:yaml.org,2002:seq":
        raise RepairError("pooler_ports_must_be_sequence")
    result = []
    for item in node.value:
        if isinstance(item, yaml.ScalarNode):
            value = item.value
            if "/" in value:
                value, protocol = value.rsplit("/", 1)
            else:
                protocol = "tcp"
            parts = split_short_port(value)
            port = {"target": parts[-1], "published": parts[-2], "protocol": protocol}
        else:
            if item.tag != "tag:yaml.org,2002:map":
                raise RepairError("unsupported_tagged_port_mapping")
            port = {key: scalar(value) for key, (_, value) in mapping(item).items()}
            if set(port) - {"target", "published", "host_ip", "protocol", "mode", "name", "app_protocol"}:
                raise RepairError("unsupported_long_port_field")
        if str(port.get("target")) not in {"5432", "6543"} or not port.get("published"):
            raise RepairError("unexpected_pooler_target_or_missing_published_port")
        if port.get("protocol", "tcp") != "tcp":
            raise RepairError("pooler_protocol_must_be_tcp")
        port.update(target=int(port["target"]), host_ip="127.0.0.1", protocol="tcp")
        if port not in result:
            result.append(port)
    return result


def patch_source(text, service_name=None):
    # compose() creates nodes only; it never executes YAML object constructors.
    root = mapping(yaml.compose(text))
    services = mapping(root["services"][1]) if "services" in root else {}
    if service_name is None:
        matches = []
        for name, (_, service) in services.items():
            fields = mapping(service)
            container = scalar(fields["container_name"][1]) if "container_name" in fields else None
            if name == "supavisor" or container == "supabase-pooler":
                matches.append(name)
        if len(matches) != 1:
            raise RepairError("expected_one_pooler_service")
        service_name = matches[0]
    if service_name not in services:
        return text, service_name
    service_key, service = services[service_name]
    if service.start_mark.index < service_key.end_mark.index:
        raise RepairError("pooler_service_alias_requires_explicit_mapping")
    fields = mapping(service)
    header_end = service.value[0][0].start_mark.index if service.value else service.end_mark.index
    if any(isinstance(token, yaml.AnchorToken) and service.start_mark.index <= token.start_mark.index < header_end for token in yaml.scan(text)):
        raise RepairError("pooler_service_anchor_requires_explicit_mapping")
    if "ports" not in fields:
        return text, service_name
    key, ports = fields["ports"]
    normalized = repaired_ports(ports)
    # Shared anchors must be expanded by an operator: changing an anchor can also
    # change an unrelated service. Fail before any file is written.
    if ports.start_mark.index < key.end_mark.index:
        raise RepairError("pooler_port_alias_requires_explicit_mapping")
    for token in yaml.scan(text):
        if ports.start_mark.index <= token.start_mark.index < ports.end_mark.index and isinstance(token, (yaml.AnchorToken, yaml.AliasToken)):
            raise RepairError("pooler_port_anchor_requires_explicit_mapping")
    replacement = json.dumps(normalized, separators=(",", ":"))
    if not ports.flow_style:
        replacement += "\n" + " " * ports.end_mark.column
    updated = text[:ports.start_mark.index] + replacement + text[ports.end_mark.index:]
    return updated, service_name


def run_docker(args, stage):
    try:
        result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired):
        raise RepairError(stage) from None
    if result.returncode:
        # Compose diagnostics may contain interpolated credentials; never echo them.
        raise RepairError(stage)
    try:
        return json.loads(result.stdout)
    except (ValueError, TypeError):
        raise RepairError(stage + "_invalid_json") from None


def is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except (ValueError, TypeError):
        return False


def validate_model(model, service_name):
    service = model.get("services", {}).get(service_name)
    if not service or service.get("network_mode") == "host":
        raise RepairError("pooler_service_missing_or_host_network")
    ports = service.get("ports", [])
    if {str(port.get("target")) for port in ports} != {"5432", "6543"}:
        raise RepairError("both_pooler_ports_required")
    if any(not is_loopback(port.get("host_ip")) or port.get("protocol", "tcp") != "tcp" for port in ports):
        raise RepairError("pooler_port_is_not_loopback_tcp")
    studio = model.get("services", {}).get("studio", {})
    if studio.get("network_mode") == "host" or any(
        not is_loopback(port.get("host_ip")) for port in studio.get("ports", [])
    ):
        raise RepairError("studio_requires_separate_loopback_repair")


def validate_running(service_name):
    # The deployed Supabase pooler has a stable container identity. Only inspect
    # network metadata, never environment values or user rows.
    rows = run_docker(["inspect", "--format", '{{json .NetworkSettings.Ports}}', "supabase-pooler"], "pooler_inspect_failed")
    published = {port: bindings for port, bindings in rows.items() if bindings}
    if set(published) != {"5432/tcp", "6543/tcp"}:
        raise RepairError("running_pooler_ports_missing_or_unexpected")
    for bindings in published.values():
        if any(not is_loopback(binding.get("HostIp")) for binding in bindings):
            raise RepairError("running_pooler_port_is_public")


def atomic_write(path, content, mode):
    original_metadata = path.stat()
    descriptor, temporary = tempfile.mkstemp(prefix=".pooler-network-write-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as target:
            temporary_metadata = os.fstat(target.fileno())
            if (temporary_metadata.st_uid, temporary_metadata.st_gid) != (original_metadata.st_uid, original_metadata.st_gid):
                os.fchown(target.fileno(), original_metadata.st_uid, original_metadata.st_gid)
            os.fchmod(target.fileno(), mode)
            target.write(content)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def repair(directory, additional_files=(), write=False, check=False, running=False):
    directory = Path(directory).resolve()
    base = directory / "docker-compose.yml"
    defaults = [directory / name for name in ("docker-compose.override.yml", "docker-compose.override.yaml", "compose.override.yml", "compose.override.yaml")]
    files = [base]
    for path in [*defaults, *(Path(p).absolute() for p in additional_files)]:
        if path.exists() and path not in files:
            files.append(path)
        elif path in [Path(p).absolute() for p in additional_files] and not path.exists():
            raise RepairError("additional_compose_file_missing")
    if any(path.is_symlink() or not path.is_file() for path in files):
        raise RepairError("compose_source_must_be_regular_file")
    original = {path: path.read_bytes() for path in files}
    metadata = {path: path.stat() for path in files}
    proposed = {}
    service_name = None
    for path in files:
        updated, service_name = patch_source(original[path].decode("utf-8"), service_name)
        proposed[path] = original[path] if check else updated.encode("utf-8")
    # Candidates stay outside the live configuration directory even in planning mode.
    with tempfile.TemporaryDirectory(prefix="pooler-network-check-") as temporary:
        candidates = []
        for index, path in enumerate(files):
            candidate = Path(temporary) / (str(index) + ".yaml")
            candidate.write_bytes(proposed[path])
            candidate.chmod(0o600)
            candidates.append(candidate)
        # Explicit -f base omits default overrides. Test that topology independently,
        # then each supplied/default overlay and their complete merge.
        combinations = [[candidates[0]]]
        combinations.extend([candidates[0], overlay] for overlay in candidates[1:])
        if len(candidates) > 2:
            combinations.append(candidates)
        for selected in combinations:
            args = ["compose", "--project-directory", str(directory)]
            for path in selected:
                args.extend(["-f", str(path)])
            model = run_docker([*args, "config", "--format", "json"], "compose_configuration_invalid")
            validate_model(model, service_name)
    if running:
        validate_running(service_name)
    changed = [path for path in files if proposed[path] != original[path]]
    backups = []
    if write:
        if any(path.read_bytes() != original[path] for path in files):
            raise RepairError("compose_source_changed_during_validation")
        backup_paths = {}
        writes_started = False
        try:
            # Complete durable private backups before modifying any source file.
            for path in changed:
                descriptor, backup = tempfile.mkstemp(prefix=path.name + ".network-backup-", dir=path.parent)
                backups.append(backup)
                with os.fdopen(descriptor, "wb") as target:
                    target.write(original[path])
                    target.flush()
                    os.fsync(target.fileno())
                backup_paths[path] = backup
            writes_started = True
            for path in changed:
                atomic_write(path, proposed[path], stat.S_IMODE(metadata[path].st_mode))
        except Exception:
            rollback_failed = False
            if writes_started:
                for path, backup in backup_paths.items():
                    try:
                        backup_metadata = os.stat(backup)
                        if (backup_metadata.st_uid, backup_metadata.st_gid) != (metadata[path].st_uid, metadata[path].st_gid):
                            os.chown(backup, metadata[path].st_uid, metadata[path].st_gid)
                        os.chmod(backup, stat.S_IMODE(metadata[path].st_mode))
                        # Rename existing bytes: rollback must not allocate another
                        # full file when the original failure was disk exhaustion.
                        os.replace(backup, path)
                    except Exception:
                        rollback_failed = True
                        if os.path.exists(backup):
                            os.chmod(backup, 0o600)
            if rollback_failed:
                raise RepairError("configuration_write_failed_rollback_incomplete_backups_retained") from None
            raise RepairError("configuration_write_failed_originals_restored") from None
    return {"mode": "check" if check else "write" if write else "plan", "service": service_name,
            "validated_compose_combinations": len(combinations), "changed_files": [str(p) for p in changed],
            "backups": backups, "running_bindings_checked": running, "containers_restarted": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compose_directory", nargs="?", default="/opt/frwhoop/supabase-docker/docker")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--write", action="store_true")
    modes.add_argument("--check", action="store_true")
    parser.add_argument("--running", action="store_true")
    parser.add_argument("--additional-file", action="append", default=[])
    args = parser.parse_args()
    try:
        print(json.dumps(repair(args.compose_directory, args.additional_file, args.write, args.check, args.running), sort_keys=True))
    except RepairError as error:
        print("FAIL: " + str(error), file=sys.stderr)
        return 1
    except Exception:
        print("FAIL: pooler_network_check_failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
