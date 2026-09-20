#!/usr/bin/env python3
"""Read only the IP/port literals; never source a file containing login passwords."""
import ipaddress
from pathlib import Path
import re
import shlex
import sys


def target(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        match = re.match(r"^\s*(?:export\s+)?(DROPLET_IP|SSH_PORT)\s*=\s*(.*)$", line)
        if match:
            tokens = shlex.split(match[2], comments=True)
            if len(tokens) != 1 or match[1] in values:
                raise ValueError("ambiguous deployment target")
            values[match[1]] = tokens[0]
    address = str(ipaddress.ip_address(values.get("DROPLET_IP", "")))
    if values.get("SSH_PORT", "22") != "22":
        raise ValueError("deployment SSH is restricted to port 22")
    return address + "|22"


if __name__ == "__main__":
    try:
        print(target(sys.argv[1]))
    except (OSError, ValueError):
        sys.exit("Invalid deployment IP/port configuration")
