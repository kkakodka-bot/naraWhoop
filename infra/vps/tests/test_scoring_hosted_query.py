import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'scripts/scoring-hosted-query.py'
spec = importlib.util.spec_from_file_location('scoring_hosted_query', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HostedQueryBindingTest(unittest.TestCase):
    def test_pooler_and_rest_bind_to_same_project_without_credential_output(self):
        env = module.connection_environment('postgresql://postgres.test:synthetic%2Bvalue@aws-0.pooler.supabase.com/postgres?sslmode=require',
                                            'https://test.supabase.co/rest/v1')
        self.assertEqual(env['PGPASSWORD'], 'synthetic+value')
        self.assertIn('default_transaction_read_only=on', env['PGOPTIONS'])
        self.assertEqual(env['PGSSLMODE'], 'require')

    def test_direct_database_and_rest_bind(self):
        env = module.connection_environment('postgresql://postgres:fixture@db.test.supabase.co/postgres',
                                            'https://test.supabase.co/rest/v1')
        self.assertEqual(env['PGSSLMODE'], 'verify-full')

    def test_wrong_project_local_target_and_unencrypted_connection_are_rejected(self):
        for database in ['postgresql://postgres.other:fixture@aws-0.pooler.supabase.com/postgres',
                         'postgresql://postgres:fixture@127.0.0.1/postgres',
                         'postgresql://postgres:fixture@db.other.supabase.co/postgres',
                         'postgresql://postgres.test:fixture@aws-0.pooler.supabase.com/postgres?sslmode=disable']:
            with self.assertRaises(ValueError):
                module.connection_environment(database, 'https://test.supabase.co/rest/v1')

    def test_untrusted_endpoint_credentials_and_paths_are_rejected(self):
        for endpoint in ['https://test.supabase.co.invalid/rest/v1', 'https://user@test.supabase.co/rest/v1',
                         'http://test.supabase.co/rest/v1', 'https://test.supabase.co/functions/v1']:
            with self.assertRaises(ValueError):
                module.connection_environment('postgresql://postgres.test:fixture@aws-0.pooler.supabase.com/postgres', endpoint)
