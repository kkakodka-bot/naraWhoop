import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

spec = importlib.util.spec_from_file_location('subject', Path(__file__).with_name('apply-scoring-tls-update.py'))
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)

class TLSUpdateTests(unittest.TestCase):
    def fixture(self):
        before = 'jdbc:postgresql://postgres:synthetic%24password@db.' + s.PROJECT + '.supabase.co:5432/postgres?sslmode=require&ApplicationName=scoring'
        after = before.replace('sslmode=require', 'sslmode=verify-full') + '&' + urlencode({'sslrootcert': s.CA})
        original = b'# unchanged header\nOTHER=literal\n' + ('export SCORING_DATABASE_URL="' + before + '"\n').encode() + b'UNRELATED="$(must-not-run)"\n'
        update = {'schemaVersion':1,'targetPath':s.TARGET,'key':s.KEY,'projectRef':s.PROJECT,
                  'requiredSSLRootCert':s.CA,'requiredSSLRootCertSha256':s.CA_SHA,
                  'expectedOriginalFileSha256':s.digest(original),'expectedOriginalValueSha256':s.digest(before.encode()),
                  'replacementValue':after,'replacementValueSha256':s.digest(after.encode())}
        return update, original

    def test_changes_only_one_key_and_preserves_literal_other_bytes(self):
        u, b = self.fixture(); out=s.render(u,b)
        self.assertEqual(out.splitlines()[0:2],b.splitlines()[0:2])
        self.assertEqual(out.splitlines()[3:],b.splitlines()[3:])
        self.assertIn(b'sslmode=verify-full',out)

    def test_old_file_drift_rejected(self):
        u,b=self.fixture()
        with self.assertRaises(ValueError):s.render(u,b+b'OTHER2=new\n')

    def test_duplicate_or_missing_key_rejected(self):
        u,b=self.fixture()
        for changed in [b+b'SCORING_DATABASE_URL=duplicate\n',b.replace(b'SCORING_DATABASE_URL',b'WRONG_KEY')]:
            u['expectedOriginalFileSha256']=s.digest(changed)
            with self.assertRaises(ValueError):s.render(u,changed)

    def test_credentials_project_or_other_query_change_rejected(self):
        for change in [('synthetic','changed'),('db.'+s.PROJECT,'db.other'),('ApplicationName=scoring','ApplicationName=changed')]:
            u,b=self.fixture();u['replacementValue']=u['replacementValue'].replace(*change);u['replacementValueSha256']=s.digest(u['replacementValue'].encode())
            with self.assertRaises(ValueError):s.render(u,b)

    def test_trust_downgrade_or_wrong_path_rejected(self):
        for change in [('verify-full','require'),('supabase-prod-ca-2021.crt','other.crt')]:
            u,b=self.fixture();u['replacementValue']=u['replacementValue'].replace(*change);u['replacementValueSha256']=s.digest(u['replacementValue'].encode())
            with self.assertRaises(ValueError):s.render(u,b)

    def test_original_value_hash_required(self):
        u,b=self.fixture();u['expectedOriginalValueSha256']='0'*64
        with self.assertRaises(ValueError):s.render(u,b)

    def test_atomic_replace_preserves_original_backup_and_mode(self):
        u,b=self.fixture();out=s.render(u,b)
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'secrets.env';p.write_bytes(b);p.chmod(0o600)
            backup=s.replace_checked(p,b,out)
            self.assertEqual(backup.read_bytes(),b);self.assertEqual(p.read_bytes(),out)
            self.assertEqual(p.stat().st_mode&0o777,0o600)

    def test_racing_change_and_existing_backup_fail_closed(self):
        u,b=self.fixture();out=s.render(u,b)
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'secrets.env';p.write_bytes(b+b'changed\n');p.chmod(0o600)
            with self.assertRaises(ValueError):s.replace_checked(p,b,out)
            self.assertEqual(p.read_bytes(),b+b'changed\n')
            p.write_bytes(b);backup=p.with_name(p.name+'.tls-backup.'+s.digest(b)[:16]);backup.write_bytes(b'preserve')
            with self.assertRaises(FileExistsError):s.replace_checked(p,b,out)
            self.assertEqual(p.read_bytes(),b);self.assertEqual(backup.read_bytes(),b'preserve')

    def test_backup_directory_barrier_failure_leaves_original_target(self):
        u,b=self.fixture();out=s.render(u,b)
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'secrets.env';p.write_bytes(b);p.chmod(0o600)
            with patch.object(s,'sync_directory',side_effect=OSError('injected barrier failure')):
                with self.assertRaises(OSError):s.replace_checked(p,b,out)
            self.assertEqual(p.read_bytes(),b)
            self.assertEqual(p.with_name(p.name+'.tls-backup.'+s.digest(b)[:16]).read_bytes(),b)

if __name__ == '__main__':unittest.main()
