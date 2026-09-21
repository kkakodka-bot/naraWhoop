#!/usr/bin/env python3
"""Run bounded read-only SQL against the configured hosted scorer project without URI output."""
import os
import subprocess
import sys
from urllib.parse import parse_qsl, unquote, urlsplit


def connection_environment(database, endpoint):
    url = urlsplit(database.removeprefix('jdbc:'))
    rest = urlsplit(endpoint)
    if rest.scheme != 'https' or rest.username or rest.password or rest.query or rest.fragment or rest.path != '/rest/v1':
        raise ValueError('hosted PostgREST endpoint required')
    if not rest.hostname or not rest.hostname.endswith('.supabase.co'):
        raise ValueError('hosted project reference required')
    project = rest.hostname.removesuffix('.supabase.co')
    if url.scheme not in ('postgres', 'postgresql') or not url.hostname or not url.username or url.fragment:
        raise ValueError('database URI required')
    username = unquote(url.username)
    direct = url.hostname == 'db.' + project + '.supabase.co'
    pooler = url.hostname.endswith('.pooler.supabase.com') or url.hostname == 'pooler.supabase.com'
    if not (direct or (pooler and username.endswith('.' + project))):
        raise ValueError('database and REST project differ')
    options = dict(parse_qsl(url.query, keep_blank_values=True))
    sslmode = options.get('sslmode', 'verify-full')
    if sslmode not in ('require', 'verify-ca', 'verify-full'):
        raise ValueError('encrypted hosted database connection required')
    return dict(PGHOST=url.hostname, PGPORT=str(url.port or 5432), PGUSER=username,
                PGPASSWORD=unquote(url.password or ''), PGDATABASE=unquote(url.path.removeprefix('/')) or 'postgres',
                PGSSLMODE=sslmode, PGCONNECT_TIMEOUT='10', PGAPPNAME='scoring-readonly-diagnostics',
                PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10000 -c lock_timeout=3000')


def main():
    fields = connection_environment(os.environ['SCORING_DATABASE_URL'], os.environ['SCORING_SUPABASE_URL'])
    env = os.environ.copy()
    env.update(fields)
    command = ['docker', 'run', '--rm', '-i']
    for name in fields:
        command.extend(['--env', name])
    command.extend(['postgres:17-alpine', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At', '-f', '-'])
    query = sys.stdin.buffer.read(256 * 1024 + 1)
    if not query or len(query) > 256 * 1024:
        raise ValueError('bounded SQL input required')
    result = subprocess.run(command, input=query, env=env, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('hosted read-only query failed')
    sys.stdout.buffer.write(result.stdout)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('NOT_READY: hosted read-only query or project binding failed', file=sys.stderr)
        sys.exit(3)
