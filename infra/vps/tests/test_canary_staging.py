"""Execute the actual staging payloads with Docker doubles; no candidate may start."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

VPS=Path(__file__).resolve().parents[1]
SCRIPT=(VPS/'scripts/deploy-scoring-service.sh').read_text()
SPEC=importlib.util.spec_from_file_location('admission',VPS/'scripts/scoring-admission.py')
A=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(A)
SOURCE='a'*40;IDENTIFIER='b'*64;ENGINE='sha256:'+'c'*64
PAIR={'mode':'canary','ownerId':'11111111-1111-4111-8111-111111111112',
      'deviceId':'11111111-1111-4111-8111-111111111113'}

DOCKER=r'''#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path(os.environ['FIXTURE']);args=sys.argv[1:];scenario=os.environ['SCENARIO']
with (p/'calls').open('a') as stream: stream.write(json.dumps(args)+'\n')
state=json.loads((p/'state').read_text())
role=os.environ['ROLE']; name='intake-consumer' if role=='intake' else 'scoring-baseline-v1'
if args[0]=='compose':
 assert 'create' in args and '--no-deps' in args and 'run' not in args and 'start' not in args
 if role=='intake':
  data=json.loads(pathlib.Path(args[args.index('-f')+1]).read_text());service=data['services'][name]
  assert service['restart']=='no';state['environment']=service['environment'];state['restart']='no'
 else:
  files=[args[i+1] for i,value in enumerate(args) if value=='-f']
  assert len(files)==2 and files[0]=='docker-compose.yml'
  override=json.loads(pathlib.Path(files[1]).read_text())
  assert override=={'services':{'scoring-baseline-v1':{'restart':'no'}}}
  assert pathlib.Path(files[1]).stat().st_mode & 0o777==0o600
  state['restart']='no'
 state['exists']=True;state['running']=scenario=='running';(p/'state').write_text(json.dumps(state))
elif args[0]=='inspect':
 if not state['exists']:
  if scenario=='existing':print('d'*64);sys.exit(0)
  sys.exit(1)
 field=args[args.index('-f')+1]
 if field=='{{.Id}}':print('b'*64)
 elif field=='{{.State.Running}}':print(str(state['running']).lower())
 elif field=='{{.Image}}':print('sha256:'+'c'*64)
 elif field=='{{.HostConfig.RestartPolicy.Name}}':print(state['restart'])
 elif field=='{{.HostConfig.Memory}}':print(2147483648)
 elif field=='{{.HostConfig.NanoCpus}}':print(1000000000)
 elif 'com.docker.compose.project' in field:print('foreign' if scenario=='foreign' else 'fixture-project')
 elif field=='{{json .Config.Env}}':
  env=dict(state['environment'])
  if scenario=='wrong-scope':env[('INTAKE_' if role=='intake' else 'SCORING_')+'CANARY_DEVICE_ID']='11111111-1111-4111-8111-111111111114'
  print(json.dumps([k+'='+v for k,v in env.items()]))
 else:raise AssertionError(field)
elif args[0]=='pull':pass
elif args[0]=='update':
 assert args==['update','--restart','no','b'*64]
 state['restart']='no';(p/'state').write_text(json.dumps(state))
else:raise AssertionError('unapproved mutation '+str(args))
'''


class CanaryStagingTest(unittest.TestCase):
    def execute(self,role,scenario='normal'):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);build=root/'build';scripts=build/'infra/vps/scripts';scripts.mkdir(parents=True)
            shutil.copy(VPS/'scripts/scoring-admission.py',scripts)
            (scripts/'verify-worker-image.py').write_text("print('"+ENGINE+"')\n")
            # This image-verification boundary is covered with real archives in test_worker_image.
            env={'INTAKE_ADMISSION_MODE':'canary','INTAKE_CANARY_OWNER_ID':PAIR['ownerId'],
                 'INTAKE_CANARY_DEVICE_ID':PAIR['deviceId'],'INTAKE_WORKER_SOURCE_REVISION':SOURCE,
                 'INTAKE_WORKER_INSTANCE_ID':'11111111-1111-4111-8111-111111111111',
                 'INTAKE_EXPECTED_SUPABASE_PROJECT':'sgoyxzcagqyxexmsidtk','RAW_STORE':'b2'}
            reference='fixture.invalid/intake@sha256:'+'d'*64
            compiled={'services':{'intake-consumer':{'image':reference,'restart':'no','environment':env}}}
            plan={'scope':'initial-selected-v1','admission':PAIR,'admissionSha256':A.fingerprint(PAIR),
                  'baselineEnvironment':A.environment(PAIR),'images':{'intake':{'reference':reference}},
                  'intake':{'contractVersion':2,'compiledCompose':compiled,'compiledComposeSha256':A.fingerprint(compiled)}}
            plan['deploymentFingerprintSha256']=A.fingerprint(plan)
            A.write_private(build/'deployment.json',plan);A.write_private(build/'worker-admission.json',PAIR)
            (root/'state').write_text(json.dumps({'exists':False,'running':False,'restart':'unless-stopped',
                                                 'environment':A.environment(PAIR)}))
            bin=root/'bin';bin.mkdir();(bin/'docker').write_text(DOCKER);(bin/'docker').chmod(0o755)
            (bin/'timeout').write_text('#!/bin/sh\nshift\nexec "$@"\n');(bin/'timeout').chmod(0o755)
            process_env=dict(os.environ,PATH=str(bin)+os.pathsep+os.environ['PATH'],FIXTURE=str(root),ROLE=role,SCENARIO=scenario)
            if role=='intake':
                body=SCRIPT.split("<<'INTAKE'\n",1)[1].split('\nINTAKE\n',1)[0]
                args=[str(build),SOURCE,reference,ENGINE,plan['deploymentFingerprintSha256'],A.fingerprint(PAIR)]
            else:
                start=SCRIPT.index('# The initial canary is staged only.')
                body='set -euo pipefail\n'+SCRIPT[start:].split('\naccepted=true',1)[0]
                process_env.update(DEPLOYMENT_SCOPE='initial-selected-v1',compose_project='fixture-project',
                    SCORING_SERVICE='scoring-baseline-v1',BUILD=str(build),ADMISSION_SHA256=A.fingerprint(PAIR),
                    SCORING_EXPECTED_IMAGE_ID=ENGINE)
                args=[]
            result=subprocess.run(['bash','-s','--',*args],input=body,text=True,capture_output=True,env=process_env,timeout=15)
            calls=[json.loads(line) for line in (root/'calls').read_text().splitlines()] if (root/'calls').exists() else []
            state=json.loads((root/'state').read_text())
            private=build/'intake-canary-compose.json'
            return result,calls,state,(private.stat().st_mode & 0o777 if private.exists() else None)

    def test_both_production_staging_blocks_create_only_stopped_no_restart_candidates(self):
        for role in ('intake','baseline'):
            with self.subTest(role=role):
                result,calls,state,mode=self.execute(role)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertTrue(state['exists']);self.assertFalse(state['running']);self.assertEqual(state['restart'],'no')
                self.assertTrue(any(c[0]=='compose' and 'create' in c for c in calls))
                self.assertFalse(any(c[0] in ('start','run','stop','rm','rename','update') or 'unless-stopped' in c for c in calls))
                for value in PAIR.values():
                    if value!='canary':self.assertNotIn(value,result.stdout+result.stderr)
                if role=='intake':self.assertEqual(mode,0o600)

    def test_staging_rejects_wrong_live_scope_and_unexpected_running_candidates(self):
        for role in ('intake','baseline'):
            for scenario in ('wrong-scope','running'):
                with self.subTest(role=role,scenario=scenario):
                    result,calls,_,_=self.execute(role,scenario)
                    self.assertNotEqual(result.returncode,0)
                    self.assertFalse(any(c[0] in ('start','run','stop','rm','rename') for c in calls))
                    for value in (PAIR['ownerId'],PAIR['deviceId']):self.assertNotIn(value,result.stdout+result.stderr)

    def test_existing_intake_is_preserved_without_pull_or_creation(self):
        result,calls,_,_=self.execute('intake','existing')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len(calls),1);self.assertEqual(calls[0][0],'inspect')

    def test_foreign_baseline_race_is_not_given_restart_policy(self):
        result,calls,_,_=self.execute('baseline','foreign')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[0]=='update' for c in calls))
