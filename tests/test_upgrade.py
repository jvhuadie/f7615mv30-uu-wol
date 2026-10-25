"""Run the real upgrade algorithm in an isolated device-filesystem fixture.

Platform checks and process start/stop are simulated; no ARM program is run.
The released v0.2 script fingerprints and private-file preservation are real.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--busybox', required=True)
args, remaining = parser.parse_known_args()
BB = Path(args.busybox).resolve().as_posix()
REPO = Path(__file__).resolve().parents[1]
INSTALLER = (REPO / 'install.sh').read_text(encoding='utf-8')
LEGACY = REPO / 'tests/fixtures/v0.2'


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='uu-upgrade-test-')
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'plugin/uu-wol-f7615'
        self.root.joinpath('files').mkdir(parents=True)
        self.base.joinpath('wlan').mkdir()
        self.base.joinpath('tmp').mkdir()
        self.base.joinpath('bin').mkdir()
        self.hook = self.base / 'wlan/wifi_debug.sh'
        for name in ['control.sh', 'hook.sh']:
            (self.root / name).write_bytes((LEGACY / name).read_bytes())
        self.hook.write_bytes((LEGACY / 'hook.sh').read_bytes())
        (self.root / '.uu-f7615-managed-v2').touch()
        for name in ['.sn', '.uuplugin_uuid', 'uu.conf', 'uuplugin', 'xuplugin-guardian']:
            (self.root / 'files' / name).write_bytes(('private fixture: ' + name).encode())
        (self.root / 'hook-before-type').write_text('absent\n')
        (self.base / 'bin/cspd').write_bytes(b'platform check is simulated')
        self.before = {p.name: p.read_bytes() for p in (self.root / 'files').iterdir()}
        b = self.base.as_posix()
        (self.base / 'mounts').write_text(
            f'ubi1_0 {b}/plugin ubifs rw,sync 0 0\n'
            f'/dev/mtdblock4 {b}/wlan jffs2 rw,relatime 0 0\n'
        )

    def tearDown(self):
        self.temp.cleanup()

    def run_installer(self, enabled=True, running=True, fail_start=False):
        if enabled:
            (self.root / 'enabled').touch()
        else:
            (self.root / 'enabled').unlink(missing_ok=True)
        b = self.base.as_posix()
        text = INSTALLER
        for old, new in [
            ('/usr/plugin', b + '/plugin'), ('/tmp', b + '/tmp'),
            ('/wlan', b + '/wlan'), ('/bin/cspd', b + '/bin/cspd'),
            ('/proc/mounts', b + '/mounts'),
        ]:
            text = text.replace(old, new)
        wrappers = f"BB='{BB}'\n"
        for app in ['cat', 'grep', 'mkdir', 'rmdir', 'cp', 'mv', 'rm', 'chmod', 'cmp', 'sed', 'readlink']:
            wrappers += f'{app}() {{ "$BB" {app} "$@"; }}\n'
        wrappers += 'id() { echo 0; }\nuname() { echo aarch64; }\nwhich() { echo simulated-tool; }\nsync() { :; }\n'
        wrappers += (
            'sha256sum() {\n'
            'line=$(cat)\n'
            f"case \"$line\" in *'{b}/bin/cspd') echo 'simulated platform: OK' ;;\n"
            '*) printf "%s\\n" "$line" | "$BB" sha256sum "$@" ;; esac\n}\n'
        )
        wrappers += 'sh() {\n'
        wrappers += f'echo "$2" >> "{b}/actions"\n'
        wrappers += 'case "$2" in\n'
        wrappers += f'is-running) return {0 if running else 1} ;;\n'
        if fail_start:
            wrappers += f'start) if [ ! -f "{b}/start-failed-once" ]; then : > "{b}/start-failed-once"; return 1; fi; return 0 ;;\n'
        else:
            wrappers += 'start) return 0 ;;\n'
        wrappers += 'stop|status) return 0 ;;\n*) return 9 ;; esac\n}\n'
        path = self.base / 'test-install.sh'
        path.write_text(wrappers + text, encoding='utf-8', newline='\n')
        return subprocess.run([BB, 'ash', str(path)], capture_output=True, text=True, timeout=15)

    def assert_private_files_unchanged(self):
        self.assertEqual(self.before, {p.name: p.read_bytes() for p in (self.root / 'files').iterdir()})

    def test_upgrade_keeps_binding_binaries_and_original_hook_recovery(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('UPGRADE_COMPLETE v0.3', result.stdout)
        self.assert_private_files_unchanged()
        self.assertTrue((self.root / 'enabled').exists())
        self.assertEqual((self.root / 'version').read_text().strip(), '0.3')
        self.assertEqual(self.hook.read_bytes(), (self.root / 'hook.sh').read_bytes())
        self.assertEqual((self.root / 'backup-before-v0.3/control.sh').read_bytes(), (LEGACY / 'control.sh').read_bytes())
        self.assertEqual((self.root / 'hook-before-type').read_text(), 'absent\n')
        self.assertTrue((self.root / 'log-writer.sh').is_file())
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ALREADY_INSTALLED v0.3', result.stdout)
        self.assert_private_files_unchanged()

    def test_disabled_and_stopped_installation_stays_disabled_and_stopped(self):
        result = self.run_installer(enabled=False, running=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'enabled').exists())
        self.assertNotIn('start', (self.base / 'actions').read_text().splitlines())
        self.assert_private_files_unchanged()

    def test_failed_new_start_restores_v02_scripts(self):
        result = self.run_installer(fail_start=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('UPGRADE_FAILED', result.stderr)
        for name in ['control.sh', 'hook.sh']:
            self.assertEqual((self.root / name).read_bytes(), (LEGACY / name).read_bytes())
        self.assertEqual(self.hook.read_bytes(), (LEGACY / 'hook.sh').read_bytes())
        self.assertFalse((self.root / 'log-writer.sh').exists())
        self.assert_private_files_unchanged()
        self.assertFalse(self.base.joinpath('plugin/uu-wol-f7615.installing').exists())

    def test_modified_previous_scripts_are_rejected_before_process_stop(self):
        with (self.root / 'control.sh').open('ab') as file:
            file.write(b'\n# user customization\n')
        original = (self.root / 'control.sh').read_bytes()
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'control.sh').read_bytes(), original)
        self.assertEqual(self.hook.read_bytes(), (LEGACY / 'hook.sh').read_bytes())
        self.assertFalse((self.base / 'actions').exists())
        self.assert_private_files_unchanged()

    def test_stop_matches_guardian_executable_even_if_its_working_directory_is_root(self):
        b = self.base.as_posix()
        for pid in ['111', '222', '333']:
            (self.base / 'proc' / pid).mkdir(parents=True)
        script = (REPO / 'src/control.sh').read_text(encoding='utf-8')
        script = script.replace('/usr/plugin', b + '/plugin').replace('/tmp', b + '/tmp').replace('/proc', b + '/proc')
        wrapper = f'BB="{BB}"\nid() {{ echo 0; }}\nsleep() {{ :; }}\n'
        wrapper += 'cat() { "$BB" cat "$@"; }\ngrep() { "$BB" grep "$@"; }\n'
        wrapper += 'readlink() {\ncase "$1" in\n'
        for pid, name in [('111', 'uuplugin'), ('222', 'xuplugin-guardian')]:
            wrapper += f'"{b}/proc/{pid}/exe") [ ! -f "{b}/gone-{pid}" ] || return 1; echo "{self.root.as_posix()}/files/{name}" ;;\n'
        wrapper += f'"{b}/proc/333/exe") echo "/another/tool/uuplugin" ;;\n'
        wrapper += '*/cwd) echo "/" ;;\n*) return 1 ;; esac\n}\n'
        wrapper += f'kill() {{ echo "$*" >> "{b}/signals"; [ "$1" != -TERM ] || : > "{b}/gone-$2"; return 0; }}\n'
        path = self.base / 'test-stop.sh'
        path.write_text(wrapper + script, encoding='utf-8', newline='\n')
        result = subprocess.run([BB, 'ash', str(path), 'stop'], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        signals = (self.base / 'signals').read_text().splitlines()
        self.assertIn('-TERM 111', signals)
        self.assertIn('-TERM 222', signals)
        self.assertFalse(any('333' in line for line in signals))


if __name__ == '__main__':
    assert hashlib.sha256((LEGACY / 'control.sh').read_bytes()).hexdigest() == '4041c66104c7ffc9c7aeddb37a5465a9523488698bcb97a420adbf6e0bc39327'
    unittest.main(argv=['test_upgrade.py', *remaining])
