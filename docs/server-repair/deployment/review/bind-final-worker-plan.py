#!/usr/bin/env python3
"""Offline only: require actual final source/artifacts before calling the reviewed binder."""
import hashlib,json,os,pathlib,re,stat,subprocess,sys
try:
 path=pathlib.Path(sys.argv[1]);info=path.lstat();assert stat.S_ISREG(info.st_mode) and not info.st_mode&0o077 and info.st_uid==os.getuid()
 value=json.loads(path.read_text());source=value.get('finalSource')
 if not isinstance(source,str) or not re.fullmatch(r'[a-f0-9]{40}',source):raise ValueError('FINAL_SOURCE_AND_ARTIFACT_BINDINGS_REQUIRED')
 required=['artifactRoot','releaseManifest','selectedV1Image','shadowV2Image','intakeImage']
 if not all(isinstance(value.get(k),str) and value[k] for k in required):raise ValueError('FINAL_SOURCE_AND_ARTIFACT_BINDINGS_REQUIRED')
 root=pathlib.Path(value['repoRoot']);assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()==source
 assert not subprocess.check_output(['git','status','--porcelain','--untracked-files=all'],cwd=root,text=True).strip()
 for entry in value['sourceContracts']:
  data=subprocess.check_output(['git','show',source+':'+entry['path']],cwd=root)
  assert len(data)==entry['sizeBytes'] and hashlib.sha256(data).hexdigest()==entry['sha256']
 pins=value['targetIdentity']
 args=['node',str(root/'Tools/release/release-artifact-manifest.mjs'),'bind-deployment','--repo-root',str(root),'--artifact-root',value['artifactRoot'],'--manifest',value['releaseManifest'],'--selected-v1-image',value['selectedV1Image'],'--shadow-v2-image',value['shadowV2Image'],'--intake-image',value['intakeImage'],'--intake-instance-id',value['intakeInstanceId'],'--intake-project-ref',value['intakeProjectRef'],'--scope','initial-selected-v1','--admission-config',value['admissionConfig'],'--target-ip',pins['ip'],'--target-ssh-port',str(pins['sshPort']),'--target-ssh-host-key-line',pins['sshHostPublicKeyLine'],'--target-ssh-host-key-fingerprint',pins['sshHostPublicKeyFingerprint'],'--deploy-public-key-fingerprint',pins['deployPublicKeyFingerprint'],'--output',value['output']]
 result=subprocess.run(args,capture_output=True,text=True,timeout=600)
 assert result.returncode==0
 output=json.loads(result.stdout);assert output['status']=='WORKER_DEPLOYMENT_BOUND' and output['admissionSha256']==value['admissionSha256']
 print(json.dumps(output))
except ValueError as error:
 if str(error)=='FINAL_SOURCE_AND_ARTIFACT_BINDINGS_REQUIRED':print('NOT_READY: final source/artifact bindings pending',file=sys.stderr)
 else:print('NOT_READY: offline worker plan validation failed',file=sys.stderr)
 raise SystemExit(3)
except Exception:
 print('NOT_READY: offline worker plan validation failed',file=sys.stderr);raise SystemExit(3)
