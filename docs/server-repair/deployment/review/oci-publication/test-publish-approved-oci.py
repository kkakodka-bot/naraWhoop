#!/usr/bin/env python3
import base64, hashlib, importlib.util, io, json, pathlib, subprocess, tarfile, tempfile, unittest
from unittest import mock
HERE=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('publisher',HERE/'publish-approved-oci.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
ROOT=HERE.parent.parent
class PublicationTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name).resolve()
 def tearDown(self):self.tmp.cleanup()
 def fixture(self,arch='amd64',duplicate=False,corrupt_blob=False,index_media=False):
  config=json.dumps({'architecture':arch,'os':'linux','config':{'Labels':{'org.opencontainers.image.revision':p.SOURCE}}}).encode();layer=b'original compressed layer bytes for transport test'
  def desc(b,media):return {'mediaType':media,'digest':'sha256:'+p.sha_bytes(b),'size':len(b)}
  cd=desc(config,'application/vnd.oci.image.config.v1+json');ld=desc(layer,'application/vnd.oci.image.layer.v1.tar+gzip')
  manifest=json.dumps({'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':cd,'layers':[ld]}).encode();md=desc(manifest,'application/vnd.oci.image.index.v1+json' if index_media else 'application/vnd.oci.image.manifest.v1+json');md['platform']={'architecture':arch,'os':'linux'}
  index=json.dumps({'schemaVersion':2,'manifests':[md]}).encode();path=self.root/'image.tar'
  payloads={'index.json':index,'oci-layout':b'{"imageLayoutVersion":"1.0.0"}', 'blobs/sha256/'+cd['digest'][7:]:config,'blobs/sha256/'+ld['digest'][7:]:b'X'+layer[1:] if corrupt_blob else layer,'blobs/sha256/'+md['digest'][7:]:manifest}
  with tarfile.open(path,'w') as t:
   for name,b in payloads.items():
    m=tarfile.TarInfo(name);m.size=len(b);t.addfile(m,io.BytesIO(b))
   if duplicate:
    m=tarfile.TarInfo('index.json');m.size=len(index);t.addfile(m,io.BytesIO(index))
  a={'file':{'sizeBytes':path.stat().st_size,'sha256':p.sha_file(path)},'image':{'sourceRevision':p.SOURCE,'platform':'linux/amd64','indexJsonSha256':p.sha_bytes(index),'manifestDigest':md['digest'],'configDigest':cd['digest'],'labels':{'org.opencontainers.image.revision':p.SOURCE}}}
  return path,a
 def test_exact_image_descriptor_and_all_blob_bytes_validate(self):
  path,a=self.fixture();r=p.validate_archive(path,a);self.assertEqual(r['manifestDigest'],a['image']['manifestDigest']);self.assertEqual(len(r['layers']),1)
 def test_changed_archive_cannot_pass_approved_file_hash(self):
  path,a=self.fixture();path.write_bytes(path.read_bytes()+b'x')
  with self.assertRaisesRegex(p.Rejected,'archive_size'):p.validate_archive(path,a)
 def test_inner_blob_tampering_rejected_even_when_outer_hash_is_updated(self):
  path,a=self.fixture(corrupt_blob=True)
  with self.assertRaisesRegex(p.Rejected,'descriptor_bytes'):p.validate_archive(path,a)
 def test_wrong_platform_rejected(self):
  path,a=self.fixture(arch='arm64')
  with self.assertRaisesRegex(p.Rejected,'wrong_selected_platform'):p.validate_archive(path,a)
 def test_index_cannot_substitute_for_selected_image(self):
  path,a=self.fixture(index_media=True)
  with self.assertRaisesRegex(p.Rejected,'selected_manifest_is_not_image'):p.validate_archive(path,a)
 def test_duplicate_tar_name_cannot_shadow_verified_blob(self):
  path,a=self.fixture(duplicate=True)
  with self.assertRaisesRegex(p.Rejected,'duplicate_tar'):p.validate_archive(path,a)
 def test_wrong_config_digest_rejected(self):
  path,a=self.fixture();a['image']['configDigest']='sha256:'+'0'*64
  with self.assertRaisesRegex(p.Rejected,'config_digest'):p.validate_archive(path,a)
 def auth(self):
  f=self.root/'auth.json';f.write_text(json.dumps({'auths':{'ghcr.io':{'auth':base64.b64encode(b'fixture-user:fixture-token').decode()}}}));f.chmod(0o600);return f
 def test_auth_is_explicit_private_and_no_helper_or_unrelated_registry(self):
  f=self.auth();self.assertEqual(p.validate_auth(f),f);f.chmod(0o644)
  with self.assertRaisesRegex(p.Rejected,'owner_only'):p.validate_auth(f)
  f.chmod(0o600);f.write_text('{"auths":{},"credsStore":"ambient"}')
  with self.assertRaisesRegex(p.Rejected,'only_contain_ghcr'):p.validate_auth(f)
 def test_symlink_auth_is_rejected(self):
  f=self.auth();q=self.root/'linked.json';q.symlink_to(f)
  with self.assertRaisesRegex(p.Rejected,'canonical_absolute'):p.validate_auth(q)
 def test_default_runs_actual_405_validation_without_any_process_or_network(self):
  with mock.patch.object(p.subprocess,'run',side_effect=AssertionError('dryrun launched process')):
   self.assertEqual(p.main(['--plan',str(HERE/'publication-plan.json'),'--release-root',str(ROOT),'--evidence-dir',str(self.root/'dry')]),0)
  result=json.loads((self.root/'dry/receipt.json').read_text());self.assertFalse(result['networkAccess']);self.assertFalse(result['registryMutation']);self.assertEqual(set(result['archives']),set(p.REPOSITORIES))
 def test_execution_requires_exact_plan_confirmation_before_process(self):
  with mock.patch.object(p.subprocess,'run',side_effect=AssertionError('unapproved process')):
   with self.assertRaisesRegex(p.Rejected,'exact_plan_confirmation'):
    p.main(['--plan',str(HERE/'publication-plan.json'),'--release-root',str(ROOT),'--evidence-dir',str(self.root/'execute'),'--execute'])
 def test_repository_mutation_is_rejected_before_any_archive_process(self):
  d=json.loads((HERE/'publication-plan.json').read_text());d['repositories']['intake']='example.invalid/wrong';f=self.root/'wrong-plan.json';f.write_text(json.dumps(d))
  with self.assertRaisesRegex(p.Rejected,'destination_repository'):p.validate_plan(f,ROOT)
 def test_control_commands_are_bounded_when_daemon_hangs(self):
  def hanging(cmd,**kw):
   self.assertEqual(kw['timeout'],30);raise subprocess.TimeoutExpired(cmd,30)
  with mock.patch.object(p.subprocess,'run',side_effect=hanging):
   with self.assertRaises(subprocess.TimeoutExpired):p.run(['docker','inspect','fixture'])
 def test_started_command_timeout_removes_only_exact_created_container(self):
  cid='a'*64;calls=[]
  def fake(cmd,**kw):
   calls.append((cmd,kw))
   if 'create' in cmd:
    self.assertEqual(kw['timeout'],30);return subprocess.CompletedProcess(cmd,0,cid+'\n','')
   if 'start' in cmd:
    self.assertEqual(kw['timeout'],900);raise subprocess.TimeoutExpired(cmd,900)
   if 'rm' in cmd:
    self.assertEqual(kw['timeout'],30);self.assertEqual(cmd[-3:],['rm','--force',cid]);return subprocess.CompletedProcess(cmd,0)
   raise AssertionError(cmd)
  args=type('Args',(),{'local_registry_container':None})()
  with mock.patch.object(p.subprocess,'run',side_effect=fake):
   with self.assertRaises(subprocess.TimeoutExpired):p.skopeo_run(['docker'],args,[],self.root,'timeout',['--version'])
  self.assertEqual(len(calls),3)
if __name__=='__main__':unittest.main(verbosity=2)
