#!/usr/bin/env python3
"""Cross-compile the exact pinned codec sources; this does not execute on an iPhone."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CODEC = ROOT / 'Packages/NoopPush/Sources/CNoopZstd'
parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
args = parser.parse_args()
output = args.output.resolve()
if output == ROOT or ROOT in output.parents:
    raise SystemExit('Keep build artifacts outside the repository')
output.mkdir(parents=True, exist_ok=True)
sources = [CODEC / 'noop_zstd.c'] + sorted((CODEC / 'vendor/zstd/lib').glob('*/*.c'))
results = []
for sdk, target in [('iphoneos', 'arm64-apple-ios17.0'), ('iphonesimulator', 'arm64-apple-ios17.0-simulator')]:
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    destination = output / sdk
    destination.mkdir(exist_ok=True)
    def compile_source(pair):
        index, source = pair
        obj = destination / f'{index:03d}-{source.stem}.o'
        subprocess.run(['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sdk_path,
                        '-O3', '-DNDEBUG', '-DZSTD_DISABLE_ASM=1', '-DZSTD_LEGACY_SUPPORT=0', '-DZSTD_TRACE=0',
                        '-I' + str(CODEC / 'include'), '-I' + str(CODEC / 'vendor/zstd/lib'),
                        '-c', str(source), '-o', str(obj)], check=True)
        return str(obj)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        objects = list(pool.map(compile_source, enumerate(sources)))
    archive = destination / 'libCNoopZstd.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(archive), *objects], check=True)
    results.append(dict(sdk=sdk, target=target, source_count=len(sources),
                        sdk_version=subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], text=True).strip(),
                        archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), execution='NOT_MEASURED'))
manifest = dict(schema_version=1, data='synthetic compile only', results=results,
                sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
(output / 'apple-codec-build.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print(json.dumps(results))
