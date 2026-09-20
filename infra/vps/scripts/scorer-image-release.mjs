import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { requireThat, readJSON, reportError, sha } from './sync-evidence-contract.mjs';

const digest = value => typeof value === 'string' && value.length === 71 && /^sha256:[0-9a-f]{64}$/.test(value);
const revision = value => typeof value === 'string' && value.length === 40 && /^[0-9a-f]{40}$/.test(value);
export const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const jsonBytes = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
const platformOK = value => value === 'linux/amd64' || value === 'linux/arm64';
const MAX_FILE = 64 * 1024 * 1024;
const repositoryOK = value => typeof value === 'string' && value.length <= 240 &&
  !/[^\x21-\x7e]/.test(value) &&
  /^[a-z0-9][a-z0-9.-]*(?::[0-9]{1,5})?\/[a-z0-9]+(?:[._-][a-z0-9]+)*(?:\/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$/.test(value);

export function imageReference(value) {
  requireThat(typeof value === 'string' && value.split('@').length === 2, 'digest-qualified image reference required');
  const [repository, id] = value.split('@');
  requireThat(repositoryOK(repository) && digest(id), 'invalid immutable image reference');
  return { repository, digest: id };
}
function relative(value) {
  requireThat(typeof value === 'string' && value.length > 0 && value.length <= 1024 &&
    !value.includes('\\') && !/[\x00-\x1f\x7f]/.test(value) && !path.isAbsolute(value) &&
    value.split('/').every(part => part && part !== '.' && part !== '..'), 'invalid artifact/input path');
  return value;
}
function fileBytes(root, name, limit = MAX_FILE) {
  relative(name);
  const base = fs.realpathSync(root), filename = path.join(base, name);
  let current = base;
  for (const part of name.split('/')) {
    current = path.join(current, part);
    requireThat(!fs.lstatSync(current).isSymbolicLink(), 'artifact/input symlink not permitted');
  }
  const stat = fs.statSync(filename);
  requireThat(stat.isFile() && stat.size <= limit && (stat.mode & 0o444) !== 0, 'artifact/input must be a bounded readable file');
  return fs.readFileSync(filename);
}
function parse(bytes, label) {
  requireThat(bytes.length <= 1024 * 1024, `${label} JSON exceeds 1 MiB`);
  try { return JSON.parse(bytes.toString('utf8')); } catch { requireThat(false, `${label} malformed JSON`); }
}
function writeNew(root, name, bytes, mode = 0o600) {
  relative(name);
  const filename = path.join(root, name);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  const fd = fs.openSync(filename, 'wx', mode);
  try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function finish(root, name, value) {
  // link is no-clobber, unlike rename over an already approved release.
  const temporary = `.pending-${crypto.randomUUID()}.json`;
  writeNew(root, temporary, jsonBytes(value));
  fs.linkSync(path.join(root, temporary), path.join(root, name));
  fs.unlinkSync(path.join(root, temporary));
  const fd = fs.openSync(root, 'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
export function runCommand(program, args, { cwd, input, timeout = 30_000 } = {}) {
  const result = spawnSync(program, args, { cwd, input, timeout, maxBuffer: 4 * 1024 * 1024,
    env: program === 'git' ? { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_NO_LAZY_FETCH: '1', GIT_NO_REPLACE_OBJECTS: '1' } : process.env });
  requireThat(!result.error && !result.signal && result.status === 0, `${program} command failed`);
  return result.stdout;
}
const gitArgs = ['--no-replace-objects', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '-c', 'protocol.allow=never'];
function sourceAllowed(name) {
  if (name.split('/').some(p => /^(?:build|\.git|\.gradle|\.kotlin|\.env.*|.*\.env|local\.properties|secrets?(?:\..*)?|credentials?(?:\..*)?)$/i.test(p))) return false;
  return /^scoring-service\/(?:Dockerfile|gradlew|(?:gradle\.properties|(?:settings|build)\.gradle\.kts)|gradle\/wrapper\/gradle-wrapper\.(?:jar|properties)|(?:service|analytics-kernel)\/build\.gradle\.kts)$/.test(name) ||
    /^scoring-service\/(?:service|analytics-kernel)\/src\/(?:main|test)\/(?:kotlin\/.+\.kt|resources\/.+\.(?:json|txt|csv))$/.test(name) ||
    /^android\/app\/src\/(?:main\/java\/com\/noop\/(?:analytics|protocol|data|testcentre)\/.+\.kt|test\/java\/com\/noop\/analytics\/.+\.kt|test\/resources\/.+\.(?:json|txt|csv))$/.test(name);
}
function inputList(files) {
  requireThat(Array.isArray(files) && files.length > 0 && files.length <= 20_000, 'input inventory required');
  const names = new Set();
  for (const f of files) {
    relative(f?.path);
    requireThat(sourceAllowed(f.path) && sha(f.sha256) && !names.has(f.path), 'invalid or duplicate source inventory');
    names.add(f.path);
  }
  return files.map(f => ({ path: f.path, sha256: f.sha256 })).sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
}
function nativeMatch(native, files) {
  requireThat(native?.schemaVersion === 1 && Array.isArray(native.reports) && native.reports.length > 0, 'native byte-identity evidence required');
  const wanted = inputList(files.filter(f => f.path !== 'scoring-service/Dockerfile'));
  requireThat(JSON.stringify(inputList(native.inputFiles)) === JSON.stringify(wanted), 'native input bytes differ from exported source');
  return hash(jsonBytes(wanted));
}
function artifactReader(root, artifacts) {
  requireThat(Array.isArray(artifacts) && artifacts.length > 0 && artifacts.length <= 128, 'release artifact inventory required');
  const bytes = new Map();
  let total = 0;
  for (const entry of artifacts) {
    relative(entry?.path);
    requireThat(sha(entry.sha256) && !bytes.has(entry.path), 'duplicate/invalid release artifact');
    const content = fileBytes(root, entry.path);
    total += content.length;
    requireThat(total <= 128 * 1024 * 1024, 'release evidence exceeds 128 MiB');
    requireThat(hash(content) === entry.sha256, 'release artifact digest mismatch');
    bytes.set(entry.path, content);
  }
  return name => { requireThat(bytes.has(name), 'release reference has no verified artifact'); return bytes.get(name); };
}
function sourceEvidence(value, read) {
  requireThat(revision(value?.commit) && revision(value.tree) && sha(value.contextSha256) &&
    sha(value.dockerfileSha256) && sha(value.nativeInputSha256), 'invalid source identity');
  const files = parse(read(value.inputManifestArtifact), 'input inventory');
  inputList(files);
  requireThat(files.every(f => Number.isSafeInteger(f.size) && f.size >= 0 && ['100644', '100755'].includes(f.mode)), 'input sizes/modes required');
  requireThat(hash(jsonBytes(files)) === value.contextSha256 &&
    files.find(f => f.path === 'scoring-service/Dockerfile')?.sha256 === value.dockerfileSha256, 'source context digest mismatch');
  const native = parse(read(value.nativeEvidenceArtifact), 'native evidence');
  requireThat(nativeMatch(native, files) === value.nativeInputSha256, 'native byte identity mismatch');
  for (const report of native.reports) requireThat(sha(report?.sha256) && hash(read(report.path)) === report.sha256, 'native report digest mismatch');
  return files;
}
function buildOptions(build) {
  requireThat(platformOK(build?.platform), 'explicit supported platform required');
  imageReference(build.buildImage); imageReference(build.runtimeImage);
}

export function prepare({ repo, commit, output, platform, buildImage, runtimeImage, nativeEvidence }, run = runCommand) {
  requireThat(revision(commit), 'exact lowercase Git commit required');
  buildOptions({ platform, buildImage, runtimeImage });
  const git = (...args) => run('git', [...gitArgs, ...args], { cwd: repo });
  // --local omits config.worktree when extensions.worktreeConfig is enabled.
  // Inspect both effective repository scopes without expanding includes, before
  // source-object access. Do not request --worktree when the extension is off:
  // Git can reject that request in repositories with multiple worktrees.
  const checkedConfigKeys = scope => {
    const keys = git('config', scope, '--no-includes', '--null', '--list', '--name-only').toString().split('\0');
    requireThat(!keys.some(k => /^extensions\.partialclone$|^remote\..*\.promisor$/is.test(k)), 'partial/promisor repositories cannot prepare offline');
    requireThat(!keys.some(k => /^include(?:if\..*)?\.path$/is.test(k)), 'included Git configuration cannot prepare offline');
    return keys;
  };
  const commonKeys = checkedConfigKeys('--local');
  if (commonKeys.includes('extensions.worktreeconfig') &&
    git('config', '--local', '--no-includes', '--type=bool', '--get', 'extensions.worktreeConfig').toString().trim() === 'true') {
    checkedConfigKeys('--worktree');
  }
  // Preserve the offline object-store guards, including for linked worktrees.
  const gitDirectory = path.resolve(repo, git('rev-parse', '--git-common-dir').toString().trim());
  const objects = path.join(gitDirectory, 'objects');
  requireThat(!fs.existsSync(path.join(objects, 'info/alternates')) &&
    !fs.readdirSync(path.join(objects, 'pack')).some(n => n.endsWith('.promisor')), 'alternate/promisor object stores cannot prepare offline');
  requireThat(git('cat-file', '-t', commit).toString().trim() === 'commit', 'selected object is not a local commit');
  const tree = git('rev-parse', `${commit}^{tree}`).toString().trim();
  requireThat(revision(tree), 'invalid source tree');
  const entries = git('ls-tree', '-rz', '--full-tree', commit, '--', 'scoring-service', 'android/app/src').toString().split('\0').filter(Boolean);
  const files = [], blobs = [];
  let sourceBytes = 0;
  for (const entry of entries) {
    const match = /^(\d+) (\w+) ([0-9a-f]{40})\t(.+)$/.exec(entry);
    requireThat(match, 'unsupported Git tree entry');
    const [, mode, type, oid, name] = match;
    if (!sourceAllowed(name)) continue; // Never read excluded blobs, including tracked local configuration.
    relative(name);
    requireThat(type === 'blob' && ['100644', '100755'].includes(mode), 'source symlinks/submodules not permitted');
    const size = Number(git('cat-file', '-s', oid).toString().trim());
    requireThat(Number.isSafeInteger(size) && size >= 0 && size <= 4 * 1024 * 1024 &&
      sourceBytes + size <= 256 * 1024 * 1024, 'source context size limit exceeded');
    sourceBytes += size;
    // Binary wrapper bytes must not round-trip through UTF-8 stdout decoding.
    const bytes = Buffer.from(git('cat-file', 'blob', oid));
    requireThat(bytes.length === size, 'source blob size changed');
    files.push({ path: name, mode, size: bytes.length, sha256: hash(bytes) }); blobs.push(bytes);
  }
  for (const name of ['Dockerfile', 'gradlew', 'gradle.properties', 'settings.gradle.kts', 'build.gradle.kts',
    'gradle/wrapper/gradle-wrapper.jar', 'gradle/wrapper/gradle-wrapper.properties', 'service/build.gradle.kts', 'analytics-kernel/build.gradle.kts']) {
    requireThat(files.some(f => f.path === `scoring-service/${name}`), 'required committed build input missing');
  }
  for (const prefix of ['scoring-service/service/src/main/kotlin/', 'scoring-service/analytics-kernel/src/main/kotlin/',
    'android/app/src/main/java/', 'android/app/src/test/java/']) requireThat(files.some(f => f.path.startsWith(prefix)), 'required committed source root missing');
  const nativeRoot = path.dirname(path.resolve(nativeEvidence)), native = readJSON(nativeEvidence);
  const nativeInputSha256 = nativeMatch(native, files);
  requireThat(native.reports.length <= 32, 'too many native reports');
  const reports = native.reports.map((r, i) => {
    requireThat(sha(r?.sha256), 'native report digest required');
    const bytes = fileBytes(nativeRoot, r.path);
    requireThat(hash(bytes) === r.sha256, 'native report digest mismatch');
    return { path: `native/report-${i}.bin`, sha256: r.sha256, bytes };
  });
  fs.mkdirSync(output); // Must be new; never overwrite an existing release/preparation.
  files.forEach((f, i) => writeNew(output, `context/${f.path}`, blobs[i], f.mode === '100755' ? 0o700 : 0o600));
  const artifacts = [];
  const save = (name, bytes) => { writeNew(output, name, bytes); artifacts.push({ path: name, sha256: hash(bytes) }); };
  save('inputs.json', jsonBytes(files));
  for (const r of reports) save(r.path, r.bytes);
  save('native.json', jsonBytes({ schemaVersion: 1, inputFiles: native.inputFiles, reports: reports.map(({ bytes, ...r }) => r) }));
  const prepared = { schemaVersion: 1, kind: 'scorer-image-prepared', source: { commit, tree,
    contextSha256: hash(jsonBytes(files)), dockerfileSha256: files.find(f => f.path === 'scoring-service/Dockerfile').sha256,
    inputManifestArtifact: 'inputs.json', nativeEvidenceArtifact: 'native.json', nativeInputSha256 },
  build: { platform, buildImage, runtimeImage }, artifacts };
  finish(output, 'prepared.json', prepared);
  return prepared;
}

const manifestTypes = new Set(['application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json']);
const indexTypes = new Set(['application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json']);
function descriptorBytes(stdout, expected) {
  const bytes = Buffer.from(stdout);
  if (`sha256:${hash(bytes)}` === expected) return bytes;
  // Some CLI versions frame --raw output with one LF. Only accept removal when the declared digest proves the bytes.
  if (bytes.at(-1) === 10 && `sha256:${hash(bytes.subarray(0, -1))}` === expected) return bytes.subarray(0, -1);
  requireThat(false, 'registry descriptor bytes differ from digest');
}
function selectManifest(top, platform) {
  requireThat(top?.schemaVersion === 2, 'unsupported registry descriptor');
  if (manifestTypes.has(top.mediaType)) return null;
  requireThat(indexTypes.has(top.mediaType) && Array.isArray(top.manifests), 'unsupported registry media type');
  const [os, architecture] = platform.split('/');
  const matches = top.manifests.filter(m => m?.platform?.os === os && m.platform.architecture === architecture &&
    !m.platform.variant && manifestTypes.has(m.mediaType));
  requireThat(matches.length === 1 && digest(matches[0].digest), 'missing/ambiguous platform manifest');
  return matches[0].digest;
}
export function verifyImage(image, expected) {
  requireThat(image?.id === expected.configId && image.revision === expected.revision &&
    `${image.os}/${image.architecture}` === expected.platform, 'immutable image config/revision/platform differs');
  requireThat(Array.isArray(image.repoDigests) && image.repoDigests.includes(expected.reference), 'immutable image RepoDigest differs');
}
export const IMAGE_FORMAT = '{"id":{{json .Id}},"revision":{{json (index .Config.Labels "org.opencontainers.image.revision")}},"os":{{json .Os}},"architecture":{{json .Architecture}},"repoDigests":{{json .RepoDigests}}}';

export function validateRelease(value, directory) {
  requireThat(value?.schemaVersion === 1 && value.kind === 'scorer-image-release', 'image release schema required');
  buildOptions(value.build);
  requireThat(typeof value.build.builderVersion === 'string' && value.build.builderVersion.length > 0 &&
    value.build.builderVersion.length <= 512 && !/[\r\n\x00]/.test(value.build.builderVersion), 'builder version required');
  const read = artifactReader(directory, value.artifacts);
  sourceEvidence(value.source, read);
  const im = value.image, ref = imageReference(im?.reference);
  requireThat(im.registryDigest === ref.digest && digest(im.platformManifestDigest) && digest(im.configId) &&
    im.revision === value.source.commit && im.platform === value.build.platform, 'release image/source association differs');
  const topBytes = read(im.registryArtifact);
  requireThat(`sha256:${hash(topBytes)}` === ref.digest, 'registry artifact digest differs');
  const selected = selectManifest(parse(topBytes, 'registry descriptor'), im.platform) ?? ref.digest;
  requireThat(selected === im.platformManifestDigest, 'selected platform digest differs');
  const child = read(im.manifestArtifact);
  requireThat(`sha256:${hash(child)}` === selected, 'platform manifest bytes differ');
  const manifest = parse(child, 'platform manifest');
  requireThat(manifest.schemaVersion === 2 && manifestTypes.has(manifest.mediaType) && manifest.config?.digest === im.configId, 'manifest/config association differs');
  const metadata = parse(read(value.build.metadataArtifact), 'build metadata');
  requireThat(metadata['containerimage.digest'] === im.registryDigest && metadata['containerimage.config.digest'] === im.configId, 'build metadata association differs');
  verifyImage(parse(read(im.inspectionArtifact), 'image inspection'), im);
  return value;
}
export function readRelease(filename) {
  return validateRelease(readJSON(filename), path.dirname(path.resolve(filename)));
}
export function packetRelease(e, directory) {
  const name = e.server?.imageProvenanceArtifact;
  relative(name);
  const entries = e.artifacts?.filter(a => a.path === name);
  requireThat(entries?.length === 1 && sha(entries[0].sha256), 'image release has no unique verified artifact');
  const content = fileBytes(directory, name, 1024 * 1024);
  requireThat(hash(content) === entries[0].sha256, 'image release artifact digest mismatch');
  const release = validateRelease(parse(content, 'image release'), path.dirname(path.join(directory, name)));
  requireThat(release.source.commit === e.server.commit && release.image.registryDigest === e.server.imageDigest &&
    release.image.configId === e.server.dockerImageId, 'server image provenance differs from packet');
  return release;
}

export function publish({ preparedFile, output, repository }, run = runCommand) {
  requireThat(repositoryOK(repository), 'explicit image repository required');
  const directory = path.dirname(path.resolve(preparedFile)), plan = readJSON(preparedFile);
  requireThat(plan.schemaVersion === 1 && plan.kind === 'scorer-image-prepared', 'prepared source required');
  buildOptions(plan.build);
  const read = artifactReader(directory, plan.artifacts), files = sourceEvidence(plan.source, read);
  const context = path.join(directory, 'context'), actual = [];
  requireThat(fs.lstatSync(context).isDirectory(), 'prepared context must be a directory, not a symlink');
  const scan = (folder, prefix = '') => {
    for (const d of fs.readdirSync(folder, { withFileTypes: true })) {
      requireThat(!d.isSymbolicLink(), 'prepared context symlink not permitted');
      const name = prefix + d.name;
      if (d.isDirectory()) scan(path.join(folder, d.name), name + '/'); else actual.push(name);
    }
  };
  scan(context);
  requireThat(JSON.stringify(actual.sort()) === JSON.stringify(files.map(f => f.path).sort()), 'prepared context inventory changed');
  requireThat(files.reduce((sum, f) => sum + f.size, 0) <= 256 * 1024 * 1024, 'prepared context exceeds 256 MiB');
  const captured = files.map(f => {
    const content = fileBytes(context, f.path);
    requireThat(hash(content) === f.sha256 && content.length === f.size, 'prepared context bytes changed');
    return content;
  });
  fs.mkdirSync(output);
  // Build a private byte snapshot, not the mutable prepared directory inspected above.
  const buildContext = path.join(path.resolve(output), 'build-context');
  files.forEach((f, i) => writeNew(buildContext, f.path, captured[i], f.mode === '100755' ? 0o500 : 0o400));
  const artifacts = [];
  const save = (name, bytes) => { writeNew(output, name, bytes); artifacts.push({ path: name, sha256: hash(bytes) }); };
  for (const a of plan.artifacts) save(a.path, read(a.path));
  const builderVersion = run('docker', ['buildx', 'version']).toString().trim();
  requireThat(builderVersion.length > 0 && builderVersion.length <= 512 && !/[\r\n\x00]/.test(builderVersion), 'unsupported builder version output');
  const metadataPath = path.join(path.resolve(output), 'builder-metadata.json');
  const tag = `${repository}:git-${plan.source.commit}-${plan.source.contextSha256.slice(0, 16)}-${crypto.randomUUID()}`;
  run('docker', ['buildx', 'build', '--platform', plan.build.platform, '--build-arg', `VCS_REF=${plan.source.commit}`,
    '--build-arg', `BUILD_IMAGE=${plan.build.buildImage}`, '--build-arg', `RUNTIME_IMAGE=${plan.build.runtimeImage}`,
    '--file', path.join(buildContext, 'scoring-service/Dockerfile'), '--tag', tag, '--metadata-file', metadataPath, '--push', buildContext], { timeout: 3600_000 });
  const metadata = readJSON(metadataPath);
  const registryDigest = metadata['containerimage.digest'], configId = metadata['containerimage.config.digest'];
  requireThat(digest(registryDigest) && digest(configId), 'builder did not resolve immutable digests');
  // Retain only the required non-secret metadata fields, not arbitrary builder provenance/environment.
  save('build-result.json', jsonBytes({ 'containerimage.digest': registryDigest, 'containerimage.config.digest': configId }));
  const reference = `${repository}@${registryDigest}`;
  const top = descriptorBytes(run('docker', ['buildx', 'imagetools', 'inspect', '--raw', reference]), registryDigest);
  save('registry.json', top);
  const platformManifestDigest = selectManifest(parse(top, 'registry descriptor'), plan.build.platform) ?? registryDigest;
  const child = platformManifestDigest === registryDigest ? top : descriptorBytes(run('docker',
    ['buildx', 'imagetools', 'inspect', '--raw', `${repository}@${platformManifestDigest}`]), platformManifestDigest);
  save('manifest.json', child);
  requireThat(parse(child, 'platform manifest').config?.digest === configId, 'pushed config differs from built image');
  run('docker', ['pull', '--platform', plan.build.platform, reference], { timeout: 600_000 });
  const image = { reference, registryDigest, platformManifestDigest, configId, revision: plan.source.commit, platform: plan.build.platform,
    registryArtifact: 'registry.json', manifestArtifact: 'manifest.json', inspectionArtifact: 'image.json' };
  const inspection = parse(run('docker', ['image', 'inspect', '--format', IMAGE_FORMAT, reference]), 'image inspection');
  verifyImage(inspection, image); save('image.json', jsonBytes(inspection));
  const value = { schemaVersion: 1, kind: 'scorer-image-release', source: plan.source,
    build: { ...plan.build, builderVersion, metadataArtifact: 'build-result.json' }, image, artifacts };
  validateRelease(value, output); finish(output, 'release.json', value);
  return value;
}

const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
export function deployPinned({ manifest, host, key, knownHosts }, run = runCommand) {
  const release = readRelease(manifest); // Must precede any external call.
  requireThat(typeof host === 'string' && host.length <= 253 && !/[^\x21-\x7e]/.test(host) &&
    /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(host), 'explicit deployment host required');
  for (const filename of [key, knownHosts]) requireThat(typeof filename === 'string' && path.isAbsolute(filename) &&
    !/[\r\n\x00]/.test(filename) && fs.statSync(filename).isFile(), 'explicit SSH identity/known-hosts file required');
  const options = ['-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
    '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'GlobalKnownHostsFile=/dev/null',
    '-o', `UserKnownHostsFile="${knownHosts.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`, '-i', key];
  const ssh = (command, extra = {}) => run('ssh', [...options, `deploy@${host}`, command], extra);
  const base = '/opt/frwhoop/supabase-docker/docker';
  const pin = `${base}/scoring-pin-${hash(jsonBytes(release))}.yml`;
  const compose = `docker compose --project-directory ${base} -f ${base}/docker-compose.yml -f ${base}/docker-compose.caddy.yml -f ${base}/docker-compose.envoy.yml -f ${base}/docker-compose.scoring.yml`;
  // Existing configured deployment only. Do not recreate DB/rest dependencies or modify secrets.
  for (const service of ['db', 'rest']) {
    const ids = ssh(`${compose} ps -q --status running ${service}`).toString().trim().split('\n');
    requireThat(ids.length === 1 && sha(ids[0]), 'required dependency is not running');
  }
  ssh(`docker pull --platform ${quote(release.image.platform)} ${quote(release.image.reference)}`, { timeout: 600_000 });
  verifyImage(parse(ssh(`docker image inspect --format ${quote(IMAGE_FORMAT)} ${quote(release.image.reference)}`), 'pulled image'), release.image);
  const override = `services:\n  scoring:\n    image: ${JSON.stringify(release.image.reference)}\n    platform: ${JSON.stringify(release.image.platform)}\n`;
  // Fixed destination, strict no-overwrite. A retry may reuse only identical retained bytes.
  const retain = (filename, bytes) => ssh(`umask 077; if test -e ${quote(filename)}; then cmp -s - ${quote(filename)}; else (set -C; cat > ${quote(filename)}); fi`, { input: bytes });
  retain(pin, override); retain(`${pin}.release.json`, jsonBytes(release));
  const pinned = `${compose} -f ${pin}`;
  ssh(`${pinned} up -d --no-build --no-deps --pull never scoring`, { timeout: 120_000 });
  const ids = ssh(`${pinned} ps -q scoring`).toString().trim().split('\n');
  requireThat(ids.length === 1 && sha(ids[0]), 'expected exactly one scorer container');
  const format = '{"id":{{json .Id}},"running":{{json .State.Running}},"imageId":{{json .Image}},"imageReference":{{json .Config.Image}}}';
  const instance = parse(ssh(`docker inspect --type container --format ${quote(format)} ${quote(ids[0])}`), 'selected scorer');
  requireThat(instance?.id === ids[0] && instance.running === true && instance.imageId === release.image.configId &&
    instance.imageReference === release.image.reference, 'selected scorer differs from pinned image');
  return { status: 'PINNED_DEPLOYMENT_SELECTED', containerId: ids[0], imageReference: release.image.reference,
    productionReadiness: 'NOT_READY: independently review container/target and run separate acceptance' };
}

function argumentsFor(argv, names) {
  const result = {};
  requireThat(argv.length % 2 === 0, 'expected named arguments');
  for (let i = 0; i < argv.length; i += 2) {
    requireThat(names.includes(argv[i]) && !(argv[i] in result) && argv[i + 1]?.length > 0, 'unknown/duplicate/missing argument');
    result[argv[i]] = argv[i + 1];
  }
  requireThat(names.every(name => name in result), 'required argument missing');
  return result;
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const [mode, ...args] = process.argv.slice(2);
    if (mode === 'validate') {
      const a = argumentsFor(args, ['--manifest']); readRelease(a['--manifest']);
      console.log('IMAGE_PROVENANCE_VALIDATED; NOT_READY: consistency is not authenticated build/deployment evidence');
    } else if (mode === 'prepare') {
      const a = argumentsFor(args, ['--repo', '--commit', '--output', '--platform', '--build-image', '--runtime-image', '--native-evidence']);
      prepare({ repo: a['--repo'], commit: a['--commit'], output: a['--output'], platform: a['--platform'], buildImage: a['--build-image'],
        runtimeImage: a['--runtime-image'], nativeEvidence: a['--native-evidence'] });
      console.log('SOURCE_PREPARED; NOT_READY: no image built or published');
    } else if (mode === 'publish') {
      const a = argumentsFor(args, ['--prepared', '--output', '--repository']);
      publish({ preparedFile: a['--prepared'], output: a['--output'], repository: a['--repository'] });
      console.log('IMAGE_RELEASE_RECORDED; NOT_READY: independent provenance/deployment review required');
    } else if (mode === 'deploy-pinned') {
      const a = argumentsFor(args, ['--manifest', '--host', '--key', '--known-hosts']);
      console.log(JSON.stringify(deployPinned({ manifest: a['--manifest'], host: a['--host'], key: a['--key'], knownHosts: a['--known-hosts'] })));
    } else requireThat(false, 'choose prepare, validate, publish or deploy-pinned explicitly');
  } catch (error) { reportError(error); }
}
