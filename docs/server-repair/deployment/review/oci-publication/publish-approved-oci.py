#!/usr/bin/env python3
"""Validate exact405 OCI archives offline by default. Remote execution requires separate approval.
No builds, docker load/save, mutable destination tags, ambient registry credentials or model starts.
"""
import argparse, base64, datetime, hashlib, json, os, pathlib, re, stat, subprocess, sys, tarfile, tempfile, uuid, shutil

SOURCE = '405ee1b6a6238e7f4c77e2e2f8274d01f524e5f2'
AGGREGATE_SHA = '9a6f857574fa1019f69013ec912cabc54ab0d59b4baaf755e5df8ced493b1b0c'
SKOPEO = 'quay.io/skopeo/stable@sha256:3f276c7780973ede33a7ae4a5f5ac002cb2fd53d6d892f38ab313def3570188d'
SKOPEO_PLATFORM = 'linux/arm64'
REPOSITORIES = {'selectedV1':'ghcr.io/kkakodka-bot/frwhoop_v2/baseline', 'shadowV2':'ghcr.io/kkakodka-bot/frwhoop_v2/physiology', 'intake':'ghcr.io/kkakodka-bot/frwhoop_v2/intake'}
SHA = re.compile(r'^sha256:[0-9a-f]{64}$')
class Rejected(ValueError): pass

def require(ok, reason):
    if not ok: raise Rejected(reason)
def sha_bytes(b): return hashlib.sha256(b).hexdigest()
def sha_file(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def json_bytes(x): return (json.dumps(x,indent=2,sort_keys=True)+'\n').encode()
def regular(p, private=False):
    p=pathlib.Path(p)
    require(p.is_absolute() and p.resolve()==p and not p.is_symlink(),'canonical_absolute_file_required')
    s=p.stat();require(stat.S_ISREG(s.st_mode),'regular_file_required')
    if private: require(s.st_uid==os.getuid() and s.st_mode&0o077==0,'private_owner_only_file_required')
    return p

def descriptor(t, members, d, maximum=None):
    require(isinstance(d,dict) and SHA.fullmatch(d.get('digest','')) is not None,'invalid_descriptor_digest')
    n='blobs/sha256/'+d['digest'][7:];m=members.get(n)
    require(m is not None and m.isfile() and m.size==d.get('size'),'descriptor_size_or_member_mismatch')
    require(maximum is None or m.size<=maximum,'oversized_json_descriptor')
    h=hashlib.sha256(); data=[] if maximum else None
    with t.extractfile(m) as f:
        for b in iter(lambda:f.read(1024*1024),b''):
            h.update(b)
            if data is not None:data.append(b)
    require('sha256:'+h.hexdigest()==d['digest'],'descriptor_bytes_mismatch')
    return b''.join(data) if data is not None else None

def validate_archive(path, artifact):
    path=regular(path);require(path.stat().st_size==artifact['file']['sizeBytes'],'archive_size_mismatch')
    require(sha_file(path)==artifact['file']['sha256'],'archive_sha_mismatch')
    expected=artifact['image'];require(expected['sourceRevision']==SOURCE and expected['platform']=='linux/amd64','wrong_artifact_identity')
    with tarfile.open(path,'r:') as t:
        all_members=t.getmembers();members={m.name:m for m in all_members}
        require(len(members)==len(all_members),'duplicate_tar_members')
        for m in all_members:
            require(m.isdir() or m.isfile(),'non_regular_archive_member')
            require(not m.name.startswith('/') and '..' not in pathlib.PurePosixPath(m.name).parts,'unsafe_archive_path')
        require(members['index.json'].size<=1024*1024,'oversized_index')
        idx_bytes=t.extractfile(members['index.json']).read()
        require(sha_bytes(idx_bytes)==expected['indexJsonSha256'],'index_sha_mismatch')
        idx=json.loads(idx_bytes); ds=idx.get('manifests',[])
        require(len(ds)==1,'ambiguous_archive_index')
        d=ds[0];require(d.get('mediaType')=='application/vnd.oci.image.manifest.v1+json','selected_manifest_is_not_image')
        require(d.get('platform',{}).get('os')=='linux' and d.get('platform',{}).get('architecture')=='amd64','wrong_selected_platform')
        require(d.get('digest')==expected['manifestDigest'],'selected_manifest_digest_mismatch')
        raw=descriptor(t,members,d,1024*1024);manifest=json.loads(raw)
        require(manifest.get('schemaVersion')==2 and manifest.get('mediaType')=='application/vnd.oci.image.manifest.v1+json','wrong_manifest_type')
        config_d=manifest['config'];require(config_d.get('digest')==expected['configDigest'],'config_digest_mismatch')
        config=json.loads(descriptor(t,members,config_d,2*1024*1024))
        require(config.get('os')=='linux' and config.get('architecture')=='amd64','wrong_config_platform')
        labels=config.get('config',{}).get('Labels',{})
        require(labels.get('org.opencontainers.image.revision')==SOURCE,'wrong_config_source')
        require(labels==expected['labels'],'config_labels_mismatch')
        layers=manifest.get('layers',[]);require(0<len(layers)<=64,'invalid_layer_count')
        for layer in layers:descriptor(t,members,layer)
    return {'manifestDigest':d['digest'],'manifestBytes':len(raw),'config':config_d,'layers':layers,'platform':'linux/amd64','archiveSha256':artifact['file']['sha256'],'archiveBytes':artifact['file']['sizeBytes']}

def validate_auth(path):
    p=regular(path,True);require(p.stat().st_size<=65536,'auth_file_too_large')
    a=json.loads(p.read_text());require(set(a)=={'auths'} and set(a['auths'])=={'ghcr.io'},'auth_file_must_only_contain_ghcr_auth')
    value=a['auths']['ghcr.io'];require(set(value)=={'auth'} and isinstance(value['auth'],str),'inline_basic_auth_required_no_helpers')
    try: decoded=base64.b64decode(value['auth'],validate=True)
    except Exception:raise Rejected('invalid_auth_encoding')
    require(b':' in decoded and all(decoded.split(b':',1)),'empty_auth_credentials')
    return p

def run(cmd, **kwargs):
    kwargs.setdefault('timeout',30)
    return subprocess.run(cmd,check=True,**kwargs)

def validate_plan(path, release_root):
    path=regular(path);plan=json.loads(path.read_text());root=pathlib.Path(release_root).resolve()
    require(plan.get('sourceSha')==SOURCE and plan.get('aggregateSha256')==AGGREGATE_SHA,'plan_source_or_aggregate_mismatch')
    require(plan.get('publisherSha256')==sha_file(pathlib.Path(__file__).resolve()),'publisher_script_changed')
    require(plan.get('skopeoImage')==SKOPEO and plan.get('skopeoPlatform')==SKOPEO_PLATFORM,'unpinned_publisher_tool')
    require(plan.get('repositories')==REPOSITORIES,'destination_repository_mismatch')
    aggregate=regular(root/'release/release-artifact-manifest.json')
    require(sha_file(aggregate)==AGGREGATE_SHA,'aggregate_file_changed')
    m=json.loads(aggregate.read_text());require(m['source']['commit']==SOURCE,'aggregate_source_mismatch')
    approved={};paths={}
    for role in REPOSITORIES:
        a=m['artifacts'][role];p=(root/a['file']['path']).resolve()
        require(p.is_relative_to(root),'archive_outside_release_root')
        paths[role]=p;approved[role]=validate_archive(p,a)
    return plan,paths,approved

def docker_base(args, cfg):
    require(re.fullmatch(r'unix:///[^\n\r]+',args.docker_host or '') is not None,'local_unix_docker_host_required')
    return ['docker','--config',str(cfg),'--host',args.docker_host]

def skopeo_run(docker, args, mounts, out, name, operation):
    # A separate exact-ID container per bounded command; no Docker socket or ambient credentials mounted.
    cmd=docker+['create','--pull=never','--platform',SKOPEO_PLATFORM,'--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=128','--memory=1g','--cpus=1','--tmpfs','/tmp:rw,nosuid,nodev,size=1073741824','--tmpfs','/var/tmp:rw,nosuid,nodev,size=1073741824','--env','TMPDIR=/tmp']
    if args.local_registry_container:cmd+=['--network','container:'+args.local_registry_container]
    for host,container,ro in mounts:cmd+=['--mount',f'type=bind,source={host},target={container}'+(',readonly' if ro else '')]
    cmd+=[SKOPEO,'--override-os','linux','--override-arch','amd64']+operation
    created=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
    (out/(name+'-create.stderr')).write_text(created.stderr)
    created.check_returncode()
    cid=created.stdout.strip();require(re.fullmatch('[0-9a-f]{64}',cid) is not None,'invalid_created_container_id')
    try:
        with (out/(name+'.stdout')).open('wb') as stdout,(out/(name+'.stderr')).open('wb') as stderr:
            run(docker+['start','--attach',cid],stdout=stdout,stderr=stderr,timeout=900)
        state=json.loads(run(docker+['inspect',cid],capture_output=True,text=True).stdout)[0]['State']
        require(not state['Running'] and state['ExitCode']==0,'publisher_container_failed')
    finally:
        subprocess.run(docker+['rm','--force',cid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
    return (out/(name+'.stdout')).read_bytes()

def execute_staged(args, paths, approved, out, stage, auth):
    cfg=out/'anonymous-docker-config';cfg.mkdir(mode=0o700);(cfg/'config.json').write_text('{"auths":{}}\n')
    docker=docker_base(args,cfg)
    tool=json.loads(run(docker+['image','inspect',SKOPEO],capture_output=True,text=True).stdout)[0]
    require(SKOPEO in tool.get('RepoDigests',[]) and tool.get('Architecture')=='arm64' and tool.get('Os')=='linux','pinned_tool_not_preloaded')
    local=bool(args.local_registry_container)
    if local:
        require(re.fullmatch('[0-9a-f]{64}',args.local_registry_container) is not None,'exact_local_registry_container_id_required')
        reg=json.loads(run(docker+['inspect',args.local_registry_container],capture_output=True,text=True).stdout)[0]
        require(reg['Config'].get('Labels',{}).get('io.frwhoop.publication-local-test')==SOURCE and reg['State']['Running'],'not_disposable_local_registry')
        require(not args.auth_file,'local_test_must_not_receive_credentials')
    observations={}
    for role,source in paths.items():
        expected=approved[role];dest_repo=('127.0.0.1:5000/frwhoop-test/'+role.lower()) if local else REPOSITORIES[role]
        dest='docker://'+dest_repo+'@'+expected['manifestDigest']
        target=stage/role;target.mkdir();staged_source=stage/(role+'.oci.tar')
        shutil.copyfile(source,staged_source);require(sha_file(staged_source)==expected['archiveSha256'],'staged_archive_changed')
        mounts=[(staged_source,'/input/image.oci.tar',True),(target,'/output',False)]
        auth_args=['--authfile','/auth/auth.json'] if auth else ['--no-creds']
        if auth:mounts.append((auth,'/auth/auth.json',True))
        tls='false' if local else 'true'
        copy=['copy','--preserve-digests','--multi-arch=system','--retry-times=2','--image-parallel-copies=2','--dest-tls-verify='+tls,'--digestfile','/output/pushed.digest']
        copy+=['--dest-authfile','/auth/auth.json'] if auth else ['--dest-no-creds']
        copy+=['oci-archive:/input/image.oci.tar',dest]
        skopeo_run(docker,args,mounts,target,'push',copy)
        require((target/'pushed.digest').read_text().strip()==expected['manifestDigest'],'published_digest_mismatch')
        raw=skopeo_run(docker,args,mounts,target,'remote-manifest',['inspect','--raw','--tls-verify='+tls]+auth_args+[dest])
        require('sha256:'+sha_bytes(raw)==expected['manifestDigest'],'remote_manifest_changed')
        require(json.loads(raw).get('mediaType')=='application/vnd.oci.image.manifest.v1+json','remote_index_published_instead_of_image')
        back=['copy','--preserve-digests','--multi-arch=system','--retry-times=2','--image-parallel-copies=2','--src-tls-verify='+tls]
        back+=['--src-authfile','/auth/auth.json'] if auth else ['--src-no-creds']
        back+=[dest,'dir:/output/readback'];skopeo_run(docker,args,mounts,target,'readback',back)
        require('sha256:'+sha_file(target/'readback/manifest.json')==expected['manifestDigest'],'readback_manifest_changed')
        blobs=[]
        for d in [expected['config']]+expected['layers']:
            p=target/'readback'/d['digest'][7:]
            require(p.stat().st_size==d['size'] and 'sha256:'+sha_file(p)==d['digest'],'readback_blob_changed')
            blobs.append({'digest':d['digest'],'bytes':d['size'],'byteIdentity':'PASS'})
        require(sha_file(source)==expected['archiveSha256'],'source_archive_changed_during_copy')
        shutil.copytree(target,out/role)
        observations[role]={'destination':dest,'selectedManifestPreserved':True,'configAndLayers':blobs,'configAndLayerCount':len(blobs),'sourceArchiveUnchanged':True}
    return observations

def execute(args, paths, approved, out):
    auth=None if args.local_registry_container else validate_auth(args.auth_file)
    base=pathlib.Path(args.docker_staging_dir or '')
    require(base.is_absolute() and base.resolve()==base and not base.is_symlink() and base.is_dir(),'private_shared_staging_directory_required')
    s=base.stat();require(s.st_uid==os.getuid() and s.st_mode&0o077==0,'staging_owner_only_required')
    # Colima need not mount the release volume. Copies retain original bytes and never rebuild images.
    # The temporary auth copy is owner-only, never exported, and removed with the stage on all exits.
    with tempfile.TemporaryDirectory(prefix='publication-',dir=base) as tmp:
        stage=pathlib.Path(tmp);staged_auth=None
        if auth:
            staged_auth=stage/'auth.json';staged_auth.write_bytes(auth.read_bytes());staged_auth.chmod(0o600)
        try:
            return execute_staged(args,paths,approved,out,stage,staged_auth)
        finally:
            for role in REPOSITORIES:
                if (stage/role).exists() and not (out/role).exists():
                    shutil.copytree(stage/role,out/role)

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--plan',required=True);p.add_argument('--release-root',required=True);p.add_argument('--evidence-dir',required=True)
    p.add_argument('--execute',action='store_true');p.add_argument('--approved-plan-sha256');p.add_argument('--auth-file');p.add_argument('--docker-host');p.add_argument('--local-registry-container');p.add_argument('--docker-staging-dir')
    args=p.parse_args(argv);plan,paths,approved=validate_plan(pathlib.Path(args.plan),args.release_root)
    if args.execute:
        require(args.approved_plan_sha256==sha_file(pathlib.Path(args.plan)),'explicit_exact_plan_confirmation_required')
        require(args.local_registry_container or args.auth_file,'private_auth_file_required_for_remote_execution')
    else:
        require(not args.auth_file and not args.local_registry_container,'dry_run_reads_no_credentials_or_registry')
    out=pathlib.Path(args.evidence_dir);require(out.is_absolute() and not out.exists(),'new_absolute_evidence_directory_required');out.mkdir(parents=True,mode=0o700)
    result={'schemaVersion':1,'sourceSha':SOURCE,'planSha256':sha_file(pathlib.Path(args.plan)),'aggregateSha256':AGGREGATE_SHA,'skopeoImage':SKOPEO,'selectedSourcePlatform':'linux/amd64','archives':approved,'mode':'DRY_RUN_OFFLINE','networkAccess':False,'registryMutation':False,'approval':'EXTERNAL_EXPLICIT_AUTHORIZATION_REQUIRED_BEFORE_REMOTE_EXECUTION','recordedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    if args.execute:
        result['mode']='DISPOSABLE_LOCAL_REGISTRY_TEST' if args.local_registry_container else 'EXPLICIT_OPERATOR_EXECUTION'
        result['networkAccess']=True;result['registryMutation']=True
        result['observations']=execute(args,paths,approved,out)
    (out/'receipt.json').write_bytes(json_bytes(result));print(json.dumps({'mode':result['mode'],'receipt':str(out/'receipt.json'),'sha256':sha_file(out/'receipt.json')}))
    return 0
if __name__=='__main__':
    try:sys.exit(main())
    except (Rejected,KeyError,ValueError,OSError,subprocess.SubprocessError) as e:
        # Never print auth-file data or subprocess arguments/credentials.
        print('Publication stopped: '+(str(e) if isinstance(e,Rejected) else type(e).__name__),file=sys.stderr);sys.exit(2)
