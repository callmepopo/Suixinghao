#!/usr/bin/env python3
"""Check independent component releases, rebuilds and historical compatibility."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'ios/scripts/version.py'

class ComponentVersionTests(unittest.TestCase):
    def test_component_and_build_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / 'ios/scripts/version.py'
            tool.parent.mkdir(parents=True)
            (root / 'server').mkdir()
            shutil.copyfile(SOURCE, tool)
            def config(version, build):
                return f'SXH_RELEASE_VERSION = {version}\nCURRENT_PROJECT_VERSION = {build}\nMARKETING_VERSION = 0.1.0\n'
            (root / 'Version.xcconfig').write_text(config('0.1.1', 24))
            (root / 'server/Version.xcconfig').write_text(config('0.1.1', 1))
            def run(*args):
                return json.loads(subprocess.check_output(['python3', str(tool), *args]))
            server = (root / 'server/Version.xcconfig').read_bytes()
            self.assertEqual(run('--build-only')['version'], '0.1.1')
            self.assertEqual(run()['build'], 25)
            self.assertEqual((root / 'server/Version.xcconfig').read_bytes(), server)
            app = (root / 'Version.xcconfig').read_bytes()
            self.assertEqual(run('--module', 'server', '--next')['version'], '0.1.2')
            self.assertEqual((root / 'Version.xcconfig').read_bytes(), app)
            for version in ['202610099', '2026100912']:
                (root / 'Version.xcconfig').write_text(config(version, 20))
                self.assertEqual(run()['version'], version)
                failed = subprocess.run(['python3', str(tool), '--next'], capture_output=True)
                self.assertNotEqual(failed.returncode, 0)
                self.assertEqual(run()['version'], version)

if __name__ == '__main__':
    unittest.main()
