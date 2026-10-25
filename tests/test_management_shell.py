"""Exercise restore/lock shell commands in fixtures; never touches a real modem."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--busybox', required=True)
args, remaining = parser.parse_known_args()
BB = Path(args.busybox).resolve().as_posix()
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='uu-command-export-') as directory:
    path = Path(directory) / 'export.ps1'
    path.write_text(". '" + (ROOT / 'tools/Manage.ps1').as_posix() + "'\n"
                    "@{restore=(Get-UuRestoreCommand);lock=(Protect-UuManagementCommand 'echo BODY; exit 7');guard=(Get-UuManagementGuard)} | ConvertTo-Json -Compress\n", encoding='utf-8-sig')
    exported = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(path)], capture_output=True, check=True)
    COMMANDS = json.loads(exported.stdout)


class RestoreShellTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='uu-management-')
        self.base = Path(self.temp.name)
        self.root = self.base / 'plugin'
        self.root.mkdir()
        self.hook = self.base / 'active-hook'
        self.hook.write_bytes(b'original probe\n')
        (self.root / 'hook.before').write_bytes(self.hook.read_bytes())
        (self.root / 'hook-before-type').write_text('probe\n')
        (self.root / 'hook.sh').write_bytes(b'new uu callback\n')
        (self.root / 'uninstalled').touch()
        self.actions = self.base / 'actions'
        self.running = self.base / 'running'
        self.root.joinpath('files').mkdir()
        self.private = {'.sn': b'fixture-sn', '.uuplugin_uuid': b'fixture-uuid', 'uu.conf': b'fixture-conf'}
        for name, data in self.private.items(): (self.root / 'files' / name).write_bytes(data)
        prefix = 'BB=' + shlex.quote(BB) + '\n'
        script = prefix + 'case "$1" in\n'
        script += 'is-running) [ -f ' + shlex.quote(self.running.as_posix()) + ' ]; exit $? ;;\n'
        script += 'start) echo start >> ' + shlex.quote(self.actions.as_posix()) + '; "$BB" touch ' + shlex.quote(self.running.as_posix()) + '; '
        script += 'if [ -f ' + shlex.quote((self.base / 'fail-start').as_posix()) + ' ]; then exit 1; fi ;;\n'
        script += 'stop) echo stop >> ' + shlex.quote(self.actions.as_posix()) + '; "$BB" rm -f ' + shlex.quote(self.running.as_posix()) + ' ;;\nesac\n'
        (self.root / 'control.sh').write_text(script, newline='\n')

    def tearDown(self):
        for name, data in self.private.items(): self.assertEqual((self.root / 'files' / name).read_bytes(), data)
        self.temp.cleanup()

    def run_command(self, command):
        command = command.replace('ROOT=/usr/plugin/uu-wol-f7615', 'ROOT=' + shlex.quote(self.root.as_posix()))
        command = command.replace('HOOK=/wlan/wifi_debug.sh', 'HOOK=' + shlex.quote(self.hook.as_posix()))
        command = command.replace('/tmp/uu-f7615-manage.lock', (self.base / 'manage.lock').as_posix())
        wrapper = 'BB=' + shlex.quote(BB) + '\n'
        for app in ['cat', 'cp', 'cmp', 'rm', 'sync', 'mkdir', 'rmdir']:
            wrapper += app + '() { "$BB" ' + app + ' "$@"; }\n'
        wrapper += 'sh() { "$BB" ash "$@"; }\n'
        path = self.base / 'test.sh'
        path.write_text(wrapper + command, newline='\n')
        return subprocess.run([BB, 'ash', str(path)], capture_output=True, timeout=15)

    def test_restore_saved_probe_and_binding(self):
        result = self.run_command(COMMANDS['restore'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.hook.read_bytes(), (self.root / 'hook.sh').read_bytes())
        self.assertTrue((self.root / 'enabled').exists())
        self.assertFalse((self.root / 'uninstalled').exists())
        self.assertTrue(self.running.exists())

    def test_restore_when_original_hook_was_absent(self):
        self.hook.unlink()
        (self.root / 'hook-before-type').write_text('absent\n')
        result = self.run_command(COMMANDS['restore'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.hook.exists())

    def test_unknown_hook_is_preserved_without_start(self):
        self.hook.write_bytes(b'another application\n')
        result = self.run_command(COMMANDS['restore'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.hook.read_bytes(), b'another application\n')
        self.assertFalse(self.actions.exists())
        self.assertTrue((self.root / 'uninstalled').exists())

    def test_failed_start_stops_partial_process_and_rolls_back(self):
        (self.base / 'fail-start').touch()
        result = self.run_command(COMMANDS['restore'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'RESTORE_ROLLED_BACK', result.stdout)
        self.assertEqual(self.hook.read_bytes(), b'original probe\n')
        self.assertTrue((self.root / 'uninstalled').exists())
        self.assertFalse((self.root / 'enabled').exists())
        self.assertFalse(self.running.exists())
        self.assertEqual(self.actions.read_text().splitlines(), ['start', 'stop'])

    def test_absent_hook_failed_start_removes_only_restored_hook(self):
        self.hook.unlink()
        (self.root / 'hook-before-type').write_text('absent\n')
        (self.base / 'fail-start').touch()
        result = self.run_command(COMMANDS['restore'])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.hook.exists())
        self.assertTrue((self.root / 'uninstalled').exists())

    def test_lock_cleanup_preserves_command_exit_status(self):
        result = self.run_command(COMMANDS['lock'])
        self.assertEqual(result.returncode, 7)
        self.assertIn(b'BODY', result.stdout)
        self.assertFalse((self.base / 'manage.lock').exists())

    def test_existing_lock_refuses_operation_and_is_not_removed(self):
        (self.base / 'manage.lock').mkdir()
        result = self.run_command(COMMANDS['lock'])
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'BODY', result.stdout)
        self.assertTrue((self.base / 'manage.lock').is_dir())

    def test_guard_fingerprints_match_current_unmodified_scripts(self):
        for name in ['control.sh', 'hook.sh']:
            digest = hashlib.sha256((ROOT / 'src' / name).read_text().encode()).hexdigest()
            self.assertIn(digest, COMMANDS['guard'])

    def test_missing_managed_marker_stops_before_hash_checks(self):
        called = self.base / 'sha-called'
        command = COMMANDS['guard'].replace('| sha256sum -c -', '| ( cat >/dev/null; echo CALLED >> ' + shlex.quote(called.as_posix()) + '; exit 0 )')
        result = self.run_command(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(called.exists())


class ReadOnlyGuardTests(unittest.TestCase):
    def test_read_only_rejects_management_before_network_connection(self):
        for gui in [False, True]:
            with self.subTest(gui=gui), socket.socket() as listener, tempfile.TemporaryDirectory() as directory:
                listener.bind(('127.0.0.1', 0)); listener.listen(1); listener.settimeout(0.1)
                script = "$ErrorActionPreference='Stop'\n$p=New-Object Security.SecureString\n$p.AppendChar([char]120)\n"
                if gui:
                    script += ". '" + (ROOT / 'tools/GuiWorker.ps1').as_posix() + "'\n"
                    script += "$w=Start-UuGuiWorker -ToolRoot '" + ROOT.as_posix() + "' -Address 127.0.0.1 -Port " + str(listener.getsockname()[1]) + " -Username root -Password $p -ReadOnly $true -Action Stop\n"
                    script += "while(!$w.Async.IsCompleted){Start-Sleep -Milliseconds 20}\n$r=Complete-UuGuiWorker $w\n$r.Messages\nif(!$r.Success){exit 1}\n"
                else:
                    script += "& '" + (ROOT / 'Auto.ps1').as_posix() + "' -RouterAddress 127.0.0.1 -Port " + str(listener.getsockname()[1]) + " -Username root -Password $p -CheckOnly -Action Stop -NonInteractive\nexit $LASTEXITCODE\n"
                path = Path(directory) / 'guard.ps1'; path.write_text(script, encoding='utf-8-sig')
                result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(path)], capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('只读模式'.encode(), result.stdout)
                with self.assertRaises(socket.timeout): listener.accept()


if __name__ == '__main__':
    unittest.main(argv=['test_management_shell.py', *remaining])
