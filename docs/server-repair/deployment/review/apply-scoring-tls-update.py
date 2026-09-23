#!/usr/bin/env python3
"""Approval-gated operator action; dry-run by default. Never prints secret values."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile
from urllib.parse import parse_qsl, unquote, urlsplit

TARGET = '/opt/frwhoop/secrets.env'
CA = '/opt/frwhoop/supabase-prod-ca-2021.crt'
CA_SHA = '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7'
PROJECT = 'sgoyxzcagqyxexmsidtk'
KEY = 'SCORING_DATABASE_URL'
LINE = re.compile(rb'^(\s*(?:export\s+)?SCORING_DATABASE_URL\s*=\s*)([^\r\n]*)(\r?\n)?$')

def require(ok):
    if not ok:
        raise ValueError('configuration validation failed')

def digest(value):
    return hashlib.sha256(value).hexdigest()

def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def private_read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and not info.st_mode & 0o077
                and info.st_uid == os.getuid() and 0 < info.st_size <= 1024 * 1024)
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            return stream.read()
    finally:
        os.close(fd)

def render(update, original):
    require(update.get('schemaVersion') == 1 and update.get('targetPath') == TARGET
            and update.get('key') == KEY and update.get('projectRef') == PROJECT
            and update.get('requiredSSLRootCert') == CA
            and update.get('requiredSSLRootCertSha256') == CA_SHA
            and digest(original) == update.get('expectedOriginalFileSha256'))
    lines = original.splitlines(keepends=True)
    matches = [(i, LINE.fullmatch(line)) for i, line in enumerate(lines)]
    matches = [(i, m) for i, m in matches if m is not None]
    require(len(matches) == 1)
    index, match = matches[0]
    values = shlex.split(match[2].decode(), comments=True, posix=True)
    require(len(values) == 1)
    before = values[0]
    after = update.get('replacementValue')
    require(isinstance(after, str) and not any(c in after for c in '\r\n\x00')
            and digest(before.encode()) == update.get('expectedOriginalValueSha256')
            and digest(after.encode()) == update.get('replacementValueSha256'))
    a, b = [urlsplit(v.removeprefix('jdbc:')) for v in (before, after)]
    require(before.startswith('jdbc:') == after.startswith('jdbc:')
            and a.scheme in ('postgres', 'postgresql') and a.scheme == b.scheme
            and a.netloc == b.netloc and a.path == b.path == '/postgres'
            and not a.fragment and not b.fragment and a.username and a.password)
    require((a.hostname == 'db.' + PROJECT + '.supabase.co' and unquote(a.username) == 'postgres')
            or (a.hostname and a.hostname.endswith('.pooler.supabase.com')
                and unquote(a.username) == 'postgres.' + PROJECT))
    old, new = [parse_qsl(v.query, keep_blank_values=True) for v in (a, b)]
    require(len(dict(old)) == len(old) and len(dict(new)) == len(new))
    old, new = dict(old), dict(new)
    require(old.get('sslmode') == 'require' and 'sslrootcert' not in old and 'ssl' not in old)
    require(new == {**old, 'sslmode': 'verify-full', 'sslrootcert': CA})
    lines[index] = match[1] + shlex.quote(after).encode() + (match[3] or b'')
    result = b''.join(lines)
    require(result != original)
    return result

def replace_checked(target, original, replacement):
    """Caller holds file lock; an exclusive backup precedes atomic replacement."""
    info = target.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o077 and target.read_bytes() == original)
    backup = target.with_name(target.name + '.tls-backup.' + digest(original)[:16])
    fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(original); stream.flush(); os.fsync(stream.fileno())
    # The backup directory entry must be durable before replacing the only live file.
    sync_directory(target.parent)
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix='.scoring-tls-', dir=target.parent)
        os.fchmod(fd, stat.S_IMODE(info.st_mode))
        with os.fdopen(fd, 'wb') as stream:
            stream.write(replacement); stream.flush(); os.fsync(stream.fileno())
        current = target.lstat()
        require((current.st_dev, current.st_ino, current.st_uid, current.st_gid, current.st_mode)
                == (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode)
                and target.read_bytes() == original)
        os.chown(temporary, info.st_uid, info.st_gid)
        os.replace(temporary, target); temporary = None
        sync_directory(target.parent)
        require(target.read_bytes() == replacement)
        return backup
    finally:
        if temporary is not None:
            os.unlink(temporary)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--update', required=True)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    update = json.loads(private_read(args.update))
    ca = Path(CA)
    require(ca.resolve() == ca and stat.S_ISREG(ca.lstat().st_mode)
            and ca.stat().st_size <= 65536 and digest(ca.read_bytes()) == CA_SHA)
    fd = os.open(TARGET, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original = private_read(TARGET)
        replacement = render(update, original)
        result = {'status': 'TLS_UPDATE_REVIEWED_NOT_APPLIED', 'targetPath': TARGET,
                  'oldFileSha256': digest(original), 'newFileSha256': digest(replacement),
                  'changedKeys': [KEY], 'otherConfigurationBytes': 'UNCHANGED'}
        if args.execute:
            backup = replace_checked(Path(TARGET), original, replacement)
            result.update(status='TLS_UPDATE_APPLIED', backupPath=str(backup))
        print(json.dumps(result))
    finally:
        os.close(fd)

if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('NOT_READY: TLS configuration update rejected; no secret diagnostics emitted', file=sys.stderr)
        raise SystemExit(3)
