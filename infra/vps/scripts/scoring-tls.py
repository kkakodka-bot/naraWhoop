"""Pinned public trust for the hosted diagnostic client; never disables hostname checks."""
import hashlib
from pathlib import Path
import stat

CA_PATH = '/opt/frwhoop/supabase-prod-ca-2021.crt'
CA_SHA256 = '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7'


def verified_root_mounts(root):
    if root == 'system':
        return []
    if root != CA_PATH:
        raise ValueError('unreviewed database trust path')
    path = Path(root)
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or path.resolve() != path or metadata.st_size > 65536:
        raise ValueError('database trust file is not a bounded canonical regular file')
    if hashlib.sha256(path.read_bytes()).hexdigest() != CA_SHA256:
        raise ValueError('database trust bytes differ from the pinned public CA')
    return ['--mount', f'type=bind,src={root},dst={root},readonly']
