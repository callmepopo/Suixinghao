import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('sync-relay-ledger.py')

class PrivateLedgerSyncTests(unittest.TestCase):
    def test_legacy_null_history_and_repeat_preserve_manual_sections(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            material = root / 'testers.md'
            original = '# 私有材料\n\n人工接收人记录：保留\n'
            material.write_text(original); material.chmod(0o600)
            ledger = root / 'ledger.json'
            ledger.write_text(json.dumps({'schema_version': 1, 'generated_at': '2026-10-13T00:00:00Z',
                'counts': {'issued': 1, 'active': 1}, 'grants': [{
                    'id': '0123456789abcdef', 'name': '<script>|测试\n昵称', 'environment': 'production',
                    'method': 'legacy_manual', 'status': 'active', 'created_at': '0001-01-01T00:00:00Z',
                    'history': None}]}))
            command = ['python3', str(SCRIPT), '--ledger', str(ledger), '--material', str(material)]
            for _ in range(2):
                subprocess.run(command, capture_output=True, check=True)
            result = material.read_text()
            self.assertTrue(result.startswith(original))
            self.assertEqual(result.count('<!-- relay-ledger:start -->'), 1)
            self.assertNotIn('<script>', result)
            self.assertIn('历史时间未留存', result)
            self.assertEqual(material.stat().st_mode & 0o777, 0o600)

    def test_plaintext_export_is_rejected_without_touching_material(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); material = root / 'testers.md'; ledger = root / 'ledger.json'
            material.write_text('Original private notes\n'); material.chmod(0o600)
            ledger.write_text(json.dumps({'schema_version': 1, 'grants': [], 'credential': 'sxr_' + 'a' * 64}))
            result = subprocess.run(['python3', str(SCRIPT), '--ledger', str(ledger), '--material', str(material)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(material.read_text(), 'Original private notes\n')
            self.assertNotIn(('sxr_' + 'a' * 64).encode(), result.stdout + result.stderr)

if __name__ == '__main__':
    unittest.main()
