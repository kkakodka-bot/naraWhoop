"""Read kernel whole-tree counters only for this process's dedicated cgroup-v2 scope."""

import os
from pathlib import Path, PurePosixPath
import re
import sys

from .contracts import Abstain


def membership_path(membership, mountinfo):
    groups = [line[3:] for line in membership.splitlines() if line.startswith("0::")]
    if len(groups) != 1 or not groups[0].startswith("/") or ".." in PurePosixPath(groups[0]).parts:
        raise Abstain("process_cgroup_v2_membership_invalid")
    group = PurePosixPath(groups[0]); matches = []; mounts = []
    unescape = lambda value: re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), value)
    for line in mountinfo.splitlines():
        fields = line.split()
        if "-" not in fields:
            continue
        separator = fields.index("-")
        if separator < 6 or len(fields) <= separator + 1:
            continue
        root = PurePosixPath(unescape(fields[3])); mount = Path(unescape(fields[4]))
        mounts.append((fields[0], fields[1], mount))
        if fields[separator + 1] == "cgroup2" and root.is_absolute() and mount.is_absolute() and group.is_relative_to(root):
            matches.append((fields[0], mount, mount / str(group.relative_to(root))))
    if len(matches) != 1:
        raise Abstain("process_cgroup_v2_mount_ambiguous_or_missing")
    selected_id, selected_mount, expected = matches[0]
    parents = {mount_id: parent_id for mount_id, parent_id, _ in mounts}
    ancestry = set(); ancestor = selected_id
    while ancestor in parents and ancestor not in ancestry:
        ancestry.add(ancestor); ancestor = parents[ancestor]
    for mount_id, _, mount in mounts:
        if mount_id not in ancestry and (expected.is_relative_to(mount) or mount.is_relative_to(expected)):
            raise Abstain("process_cgroup_scope_shadowed_by_mount")
    return expected.resolve()


def bounded_text(path):
    with path.open() as stream:
        value = stream.read(65537)
    if len(value) > 65536:
        raise Abstain("process_cgroup_file_limit")
    return value


class CgroupProcessAccounting:
    def __init__(self, path):
        if not sys.platform.startswith("linux"):
            raise Abstain("process_cgroup_linux_required")
        self.path = Path(path).resolve()
        self.identity = None
        self.snapshot()

    def snapshot(self):
        expected = membership_path(bounded_text(Path("/proc/self/cgroup")), bounded_text(Path("/proc/self/mountinfo")))
        if self.path != expected:
            raise Abstain("process_cgroup_not_current_membership")
        identity = (self.path.stat().st_dev, self.path.stat().st_ino)
        if self.identity is not None and identity != self.identity:
            raise Abstain("process_cgroup_identity_changed")
        self.identity = identity
        pids = set(); directories = 0
        def walk_error(error):
            raise Abstain("process_cgroup_scope_unreadable") from error

        for directory, subdirectories, _ in os.walk(self.path, onerror=walk_error):
            directories += 1
            if directories > 64:
                raise Abstain("process_cgroup_scope_limit")
            subdirectories[:] = sorted(subdirectories)
            tokens = bounded_text(Path(directory) / "cgroup.procs").split()
            if any(not token.isdecimal() for token in tokens):
                raise Abstain("process_cgroup_pid_inventory_invalid")
            pids.update(map(int, tokens))
        # Snapshot only between invocations, after all model descendants have exited.
        if pids != {os.getpid()}:
            raise Abstain("process_cgroup_not_dedicated_or_descendant_survived")
        cpu = {}
        for line in bounded_text(self.path / "cpu.stat").splitlines():
            parts = line.split()
            if len(parts) != 2 or parts[0] in cpu or not parts[1].isdecimal() or len(parts[1]) > 20 or int(parts[1]) >= 2**64:
                raise Abstain("process_cgroup_cpu_counter_invalid")
            cpu[parts[0]] = int(parts[1])
        peak = bounded_text(self.path / "memory.peak").strip()
        if "usage_usec" not in cpu or not peak.isdecimal() or len(peak) > 20 or not 0 < int(peak) < 2**64:
            raise Abstain("process_cgroup_counters_unavailable")
        return {"cpu_usage_usec": cpu["usage_usec"], "memory_peak_bytes": int(peak)}


def difference(before, after):
    if after["cpu_usage_usec"] < before["cpu_usage_usec"] or after["memory_peak_bytes"] < before["memory_peak_bytes"]:
        raise Abstain("process_cgroup_counter_reset")
    return {"cpu_seconds": (after["cpu_usage_usec"] - before["cpu_usage_usec"]) / 1_000_000,
            "memory_peak_bytes": after["memory_peak_bytes"]}
