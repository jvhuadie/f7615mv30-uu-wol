"""Exercise real shell branches in an isolated filesystem (no ONT connection)."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BB = os.environ.get('PROBE_BUSYBOX') or shutil.which('busybox')


@unittest.skipUnless(BB, 'PROBE_BUSYBOX required')
class G7615ShellTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='g7615-shell-')
        self.disk = Path(self.temp.name)
        self.prefix = self.disk.as_posix()
        if os.name == 'nt':
            self.prefix = self.prefix[2:]  # BusyBox current-drive absolute path.
        self.base = self.disk / 'opt/uu-wol-g7615'
        self.base.mkdir(parents=True)
        (self.disk / 'etc/init.d').mkdir(parents=True)
        (self.disk / 'etc/rc.d').mkdir()
        (self.disk / 'proc').mkdir()
        (self.disk / 'tmp').mkdir()
        (self.disk / 'etc/rc.common').write_text('exit 0\n')
        for name in ['control.sh', 'service.sh', 'run.sh']:
            text = (ROOT / 'profiles/g7615' / name).read_text()
            for path in ['/opt/uu-wol-g7615', '/etc/', '/proc/', '/var/', '/tmp/uu']:
                text = text.replace(path, self.prefix + path)
            text = text.replace('/bin/sh', 'sh').replace('sleep 3', ':').replace('sleep 5', ':')
            (self.base / name).write_text(text, newline='\n')
        for name in ['uuplugin', 'xuplugin-guardian', 'uu.conf', 'managed-v1']:
            (self.base / name).write_text('fixture\n')
        sums = ''.join(hashlib.sha256((self.base / name).read_bytes()).hexdigest() + '  ' + name + '\n'
                       for name in ['control.sh', 'service.sh', 'run.sh', 'uuplugin', 'xuplugin-guardian'])
        (self.base / 'payload.sha256').write_text(sums)

    def tearDown(self):
        self.temp.cleanup()

    def run_control(self, action):
        return subprocess.run([BB, 'sh', '-c', (self.base / 'control.sh').read_text(), 'fixture', action],
                              capture_output=True, timeout=10)

    def register(self):
        r = self.run_control('register')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_all_shell_syntax_and_inline_preflight(self):
        for path in (ROOT / 'profiles/g7615').glob('*.sh'):
            r = subprocess.run([BB, 'sh', '-n', str(path)], capture_output=True)
            self.assertEqual(r.returncode, 0, (path, r.stderr))
        import re
        source = (ROOT / 'profiles/g7615/preflight.sh').read_text()
        flat = '; '.join(line for line in source.splitlines() if line.strip() and not line.lstrip().startswith('#'))
        flat = re.sub(r'\b(do|then|else); ', r'\1 ', flat)
        self.assertLess(len(flat), 3500)
        r = subprocess.run([BB, 'sh', '-n', '-c', flat], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_register_and_status_never_claim_cloud(self):
        self.register()
        r = self.run_control('status')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b'state=STOPPED', r.stdout)
        self.assertIn(b'AUTOSTART=DISABLED', r.stdout)
        self.assertIn(b'CLOUD=UNVERIFIED', r.stdout)

    def test_framework_mount_excludes_nested_apps_readonly_and_foreign_overlay(self):
        import re
        source = (ROOT / 'profiles/g7615/preflight.sh').read_text()
        rule = re.search(r"awk '(.+)' \"\$p/mountinfo\"", source).group(1)
        sample = ('103 59 0:44 / / rw,relatime - overlay /opt/cu/framework/ufw/rootfs '
                  'rw,lowerdir=/opt/cu/framework/ufw/rootfs,upperdir=/opt/cu/apps/apps,workdir=/opt/cu/apps/work\n')
        for text, accepted in [
            (sample, True),
            (sample.replace('0:44 / /', '0:44 /opt/apps/fpcdn/rootfs /'), False),
            (sample.replace('/ / rw,', '/ / ro,'), False),
            (sample.replace('upperdir=/opt/cu/apps/apps', 'upperdir=/foreign'), False),
        ]:
            r = subprocess.run([BB, 'awk', rule], input=text.encode(), capture_output=True)
            self.assertEqual(r.returncode == 0, accepted, (text, r.stderr))

    def test_refuse_modified_payload(self):
        self.register()
        (self.base / 'uuplugin').write_text('changed')
        r = self.run_control('start')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b'PAYLOAD_CHANGED', r.stderr)

    def test_refuse_foreign_service_and_boot_link(self):
        service = self.disk / 'etc/init.d/uu-wol-g7615'
        service.write_text('foreign')
        r = self.run_control('register')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(service.read_text(), 'foreign')
        service.unlink()
        (self.disk / 'etc/rc.d/S99uu-wol-g7615').write_text('foreign')
        r = self.run_control('register')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b'BOOT_LINK_CHANGED', r.stderr)

    def test_start_failure_not_success(self):
        self.register()
        r = self.run_control('start')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b'START_FAILED_CHECK_LOGREAD', r.stderr)

    def test_keep_binding_and_purge_only_owned_directory(self):
        self.register()
        (self.base / '.sn').write_text('binding')
        sibling = self.disk / 'opt/factory-app'
        sibling.write_text('preserve')
        r = self.run_control('uninstall')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / '.sn').read_text(), 'binding')
        self.assertTrue((self.base / 'uninstalled').exists())
        r = self.run_control('purge')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.base.exists())
        self.assertEqual(sibling.read_text(), 'preserve')

    def test_missing_marker_refuses_delete(self):
        self.register()
        (self.base / 'managed-v1').unlink()
        r = self.run_control('purge')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.base.exists())


if __name__ == '__main__':
    unittest.main()
