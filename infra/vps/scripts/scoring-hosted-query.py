#!/usr/bin/env python3
"""Run bounded read-only SQL against the configured hosted scorer project without URI output."""
import os
import importlib.util
from pathlib import Path
import subprocess
import sys
from urllib.parse import parse_qsl, unquote, urlsplit

tls_spec = importlib.util.spec_from_file_location('scoring_tls', Path(__file__).with_name('scoring-tls.py'))
tls = importlib.util.module_from_spec(tls_spec)
tls_spec.loader.exec_module(tls)


POSTGRES_CLIENT = {
    'SCORING_POSTGRES_CLIENT_IMAGE': 'docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3',
    'SCORING_POSTGRES_CLIENT_CONFIG_DIGEST': 'sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537',
    'SCORING_POSTGRES_CLIENT_PLATFORM': 'linux/amd64',
    'SCORING_POSTGRES_CLIENT_VERSION': '17.11-alpine3.24',
}


def postgres_client(environment):
    if any(environment.get(name) != expected for name, expected in POSTGRES_CLIENT.items()):
        raise ValueError('reviewed PostgreSQL client identity required')
    return environment['SCORING_POSTGRES_CLIENT_IMAGE']


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
    pairs = parse_qsl(url.query, keep_blank_values=True) if url.query else []
    if len({name for name, _ in pairs}) != len(pairs):
        raise ValueError('duplicate database URI option')
    options = dict(pairs)
    if options.get('sslmode') != 'verify-full' or 'ssl' in options:
        raise ValueError('verified hosted database connection required')
    tls.verified_root_mounts(options.get('sslrootcert'))
    return dict(PGHOST=url.hostname, PGPORT=str(url.port or 5432), PGUSER=username,
                PGPASSWORD=unquote(url.password or ''), PGDATABASE=unquote(url.path.removeprefix('/')) or 'postgres',
                PGSSLMODE='verify-full', PGSSLROOTCERT=options['sslrootcert'], PGCONNECT_TIMEOUT='10', PGAPPNAME='scoring-readonly-diagnostics',
                PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10000 -c lock_timeout=3000')


def main():
    client_image = postgres_client(os.environ)
    fields = connection_environment(os.environ['SCORING_DATABASE_URL'], os.environ['SCORING_SUPABASE_URL'])
    env = {name: os.environ[name] for name in ('PATH', 'HOME', 'DOCKER_CONFIG', 'DOCKER_HOST', 'XDG_RUNTIME_DIR')
           if name in os.environ}
    env.update(fields)
    command = ['docker', 'run', '--rm', '-i']
    command.extend(tls.verified_root_mounts(fields['PGSSLROOTCERT']))
    for name in fields:
        command.extend(['--env', name])
    command.extend([client_image, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At', '-f', '-'])
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
