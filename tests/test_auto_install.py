"""Exercise Windows automation against a local, synthetic Telnet endpoint."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--powershell', default=shutil.which('powershell.exe'))
args, remaining = parser.parse_known_args()
if not args.powershell:
    raise SystemExit('Windows PowerShell is required for this integration test.')
REPO = Path(__file__).resolve().parents[1]
TEST_PASSWORD = "synthetic-only:$'\";&!"
PAYLOAD = (REPO / 'install.sh').read_text(encoding='utf-8-sig').replace('\r\n', '\n')
if not PAYLOAD.endswith('\n'):
    PAYLOAD += '\n'


class FakeTelnet:
    def __init__(self, mode):
        self.mode = mode
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(15)
        self.port = self.listener.getsockname()[1]
        self.error = None
        self.uploaded = None
        self.executed = False
        self.status_checked = False
        self.cleaned = False
        self.login_attempts = 0
        self.commands = []
        self.negotiations = []
        self.managed_actions = []
        self.removed = False
        self.uninstalled = mode in ('uninstalled', 'restore-failed', 'restore-hook-changed')
        self.running = not self.uninstalled and mode != 'stopped'
        self.enabled = not self.uninstalled
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def run(self):
        try:
            conn, _ = self.listener.accept()
            with conn:
                conn.settimeout(15)
                self.conn = conn
                self.raw = bytearray()
                self.nvt = 0
                self.option_command = None
                # Fragment IAC negotiation to exercise state across TCP reads.
                for chunk in [b'\xff', b'\xfb', b'\x01', b'\xff\xfd', b'\x18', b'\xff\xfa\x18\x00test\xff\xf0']:
                    conn.sendall(chunk)
                    time.sleep(0.001)
                conn.sendall(b'F7615MV30\r\nLo')
                conn.sendall(b'gin: ')
                assert self.line() == 'root'
                conn.sendall(b'Pass')
                conn.sendall(b'word: ')
                assert self.line() == TEST_PASSWORD
                self.login_attempts += 1
                if self.mode == 'bad-login':
                    conn.sendall(b'\r\nAccess denied\r\nLogin: ')
                    return
                conn.sendall(b'\r\nBusyBox ash\r\n/ # ')
                rc = 0
                upload = None
                lines = []
                verified = False
                while True:
                    command = self.line()
                    if command is None:
                        break
                    # Echo input as a terminal would; it must not fool markers.
                    conn.sendall((command + '\r\n').encode('utf-8'))
                    if upload is not None:
                        if command == upload:
                            self.uploaded = ('\n'.join(lines) + '\n').encode('utf-8')
                            upload = None
                            rc = 0
                        else:
                            lines.append(command)
                        continue
                    self.commands.append(command)
                    match = re.fullmatch(r"umask 077; cat > '(/tmp/uu-f7615-(?:auto|full)-[0-9a-f]+\.sh)' <<'(UU_UPLOAD_[0-9a-f]+)'", command)
                    if match:
                        upload = match.group(2)
                        lines = []
                    elif command == 'id -u':
                        conn.sendall(b'1000\r\n/ # ' if self.mode == 'non-root' else b'0\r\n/ # ')
                        rc = 0
                    elif command.startswith('echo __UU_'):
                        marker = re.fullmatch(r'echo (__UU_[A-Z_]+[a-z0-9_]*):\$\?', command)
                        assert marker, command
                        # The prompt deliberately shares the marker's line.
                        conn.sendall(('/ # ' + marker.group(1) + ':' + str(rc) + '\r\n/ # ').encode())
                    elif '/bin/cspd' in command and '| sha256sum -c -' in command:
                        rc = 1 if self.mode == 'bad-firmware' else 0
                        conn.sendall(b'firmware checked\r\n/ # ')
                    elif command.startswith('( set -e; ROOT=') and '789a19a789781e66' in command:
                        rc = 1 if self.mode == 'bad-scripts' else 0
                        conn.sendall(b'management scripts checked\r\n/ # ')
                    elif command.startswith('ROOT=/usr/plugin/uu-wol-f7615;') and 'UU_INSTALL=' in command:
                        rc = 0
                        state = 'MISSING' if (self.mode == 'missing-installation' or self.removed) else 'UNINSTALLED' if self.uninstalled else 'INSTALLED'
                        running = 'UNKNOWN' if self.mode == 'output-missing' else 'YES' if self.running else 'NO'
                        enabled = 'ENABLED' if self.enabled else 'DISABLED'
                        conn.sendall((f'UU_INSTALL={state}\r\nUU_RUNNING={running}\r\nUU_AUTOSTART={enabled}\r\nUU_VERSION=0.3\r\n/ # ').encode())
                    elif 'if ! mkdir /tmp/uu-f7615-manage.lock' in command:
                        rc = 0
                        if self.mode == 'management-busy':
                            rc = 1
                            conn.sendall(b'MANAGEMENT_BUSY\r\n/ # ')
                            continue
                        if '--confirmed-full' in command:
                            assert verified
                            verb = 'full'
                            self.cleaned = True
                        elif 'RESTORED_WITH_BINDING' in command:
                            verb = 'restore'
                        else:
                            match = re.search(r'sh /usr/plugin/uu-wol-f7615/control.sh (enable|disable|start|stop|uninstall)\b', command)
                            assert match, command
                            verb = match.group(1)
                        self.managed_actions.append(verb)
                        if self.mode in ('management-failed', 'restore-failed', 'restore-hook-changed'):
                            rc = 1
                            message = 'RESTORE_ROLLED_BACK' if self.mode == 'restore-failed' else 'HOOK_CHANGED' if self.mode == 'restore-hook-changed' else 'MANAGEMENT_FAILED'
                            conn.sendall((message + '\r\n/ # ').encode())
                            continue
                        if self.mode != 'no-state-change':
                            if verb == 'full': self.removed, self.running, self.enabled = True, False, False
                            elif verb == 'enable': self.enabled = True
                            elif verb == 'disable': self.enabled = False
                            elif verb == 'start': self.running = True
                            elif verb == 'stop': self.running = False
                            elif verb == 'uninstall': self.uninstalled, self.running, self.enabled = True, False, False
                            elif verb == 'restore': self.uninstalled, self.running, self.enabled = False, True, True
                        conn.sendall(b'FULL_UNINSTALL_COMPLETE\r\n/ # ' if verb == 'full' else b'MANAGEMENT_COMPLETE\r\n/ # ')
                    elif '| sha256sum -c -' in command:
                        match = re.search(r"echo '([0-9a-f]{64})  /tmp/", command)
                        assert match and self.uploaded is not None
                        verified = hashlib.sha256(self.uploaded).hexdigest() == match.group(1)
                        if self.mode == 'bad-checksum':
                            verified = False
                        rc = 0 if verified else 1
                        conn.sendall(b'checksum OK\r\n/ # ' if verified else b'checksum FAILED\r\n/ # ')
                    elif command.startswith("( sh '/tmp/uu-f7615-auto-"):
                        assert verified, 'Installer executed before successful checksum'
                        assert command.endswith(' )'), 'Exit must not close the login shell'
                        self.executed = True
                        self.cleaned = True
                        rc = 7 if self.mode == 'install-failed' else 0
                        conn.sendall(b'ERROR: simulated installation failure\r\n/ # ' if rc else b'ALREADY_INSTALLED v0.3\r\n/ # ')
                    elif command.startswith("rm -f '/tmp/uu-f7615-"):
                        self.cleaned = True
                        rc = 0
                    elif command == 'sh /usr/plugin/uu-wol-f7615/control.sh status':
                        self.status_checked = True
                        rc = 0
                        conn.sendall(
                            b'VERSION=0.3\r\nAUTOSTART_ENABLED\r\n' +
                            (b'Log writer PID: NOT_RUNNING\r\n' if self.mode.startswith('output-') else b'Log writer PID: 3885\r\n') +
                            b'tcp 0 0 192.168.1.1:1234 192.0.2.1:16000 ESTABLISHED 3884/uuplugin\r\n/ # '
                        )
                    elif command.startswith('seen=0; other=0;'):
                        rc = 0
                        state = {'output-null': 'DEV_NULL', 'output-missing': 'NOT_FOUND'}.get(self.mode, 'UNCONFIRMED')
                        if self.mode == 'output-error':
                            rc = 1
                            state = 'DEV_NULL'  # Failure must never be reported as confirmed.
                        conn.sendall(('UU_OUTPUT=' + state + '\r\n/ # ').encode())
                    else:
                        raise AssertionError('Unexpected command: ' + command[:100])
        except Exception as error:
            self.error = error
        finally:
            self.listener.close()

    def line(self):
        while True:
            if not self.raw:
                try:
                    chunk = self.conn.recv(4096)
                except ConnectionResetError:
                    return None
                if not chunk:
                    return None
                # Keep socket buffering local, including multiple command lines.
                self.raw.extend(chunk)
            while self.raw:
                b = self.raw.pop(0)
                if self.nvt == 0:
                    if b == 255:
                        self.nvt = 1
                    elif b == 10:
                        result = bytes(getattr(self, 'line_buffer', b'')).decode('utf-8').rstrip('\r')
                        self.line_buffer = bytearray()
                        return result
                    elif b != 0:
                        if not hasattr(self, 'line_buffer'):
                            self.line_buffer = bytearray()
                        self.line_buffer.append(b)
                elif self.nvt == 1:
                    self.option_command = b
                    self.nvt = 2
                else:
                    self.negotiations.append((self.option_command, b))
                    self.nvt = 0

    def finish(self):
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            self.listener.close()
            raise AssertionError('Fake server did not close')
        if self.error:
            raise self.error


class AutoInstallTests(unittest.TestCase):
    def perform(self, mode='normal', check_only=False, gui_worker=False, action=''):
        server = FakeTelnet(mode)
        server.start()
        with tempfile.TemporaryDirectory(prefix='uu-auto-test-') as directory:
            runner = Path(directory) / 'runner.ps1'
            auto_path = (REPO / 'Auto.ps1').as_posix().replace("'", "''")
            script = (
                "$ErrorActionPreference='Stop'\n"
                "$global:LASTEXITCODE=0\n"
                "$p=New-Object Security.SecureString\n"
                "foreach($c in $env:UU_TEST_PASSWORD.ToCharArray()) { $p.AppendChar($c) }\n"
                "$p.MakeReadOnly()\n"
                f"& '{auto_path}' -RouterAddress 127.0.0.1 -Port {server.port} "
                "-Username root -Password $p -NonInteractive "
                + ('-CheckOnly' if check_only else '') + (f" -Action '{action}'" if action else '') + "\n"
                "exit $LASTEXITCODE\n"
            )
            if gui_worker:
                worker_path = (REPO / 'tools/GuiWorker.ps1').as_posix().replace("'", "''")
                repo_path = REPO.as_posix().replace("'", "''")
                script = (
                    "$ErrorActionPreference='Stop'\n"
                    f". '{worker_path}'\n"
                    "$p=New-Object Security.SecureString\n"
                    "foreach($c in $env:UU_TEST_PASSWORD.ToCharArray()) { $p.AppendChar($c) }\n"
                    "$p.MakeReadOnly()\n"
                    f"$w=Start-UuGuiWorker -ToolRoot '{repo_path}' -Address 127.0.0.1 -Port {server.port} "
                    f"-Username root -Password $p -ReadOnly ${str(check_only).lower()} -Action '{action}'\n"
                    "while(!$w.Async.IsCompleted) { Receive-UuGuiMessages $w; Start-Sleep -Milliseconds 20 }\n"
                    "$r=Complete-UuGuiWorker $w\n"
                    "$r.Messages\n"
                    "if(!$r.Success){exit 1}\n"
                )
            runner.write_text(script, encoding='utf-8-sig')
            result = subprocess.run(
                [args.powershell, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(runner)],
                env=dict(os.environ, UU_TEST_PASSWORD=TEST_PASSWORD),
                capture_output=True, timeout=40,
            )
        self.assertNotIn(TEST_PASSWORD.encode(), result.stdout + result.stderr)
        try:
            server.finish()
        except Exception as error:
            output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
            raise AssertionError(str(error) + '\n' + output) from error
        self.assertIn((253, 1), server.negotiations)  # Accept server-side ECHO.
        self.assertIn((252, 24), server.negotiations)  # Decline terminal type.
        return server, result

    def test_full_upload_checksum_install_and_status(self):
        server, result = self.perform()
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode('utf-8', errors='replace'))
        self.assertEqual(server.uploaded, PAYLOAD.encode('utf-8'))
        self.assertTrue(server.executed)
        self.assertTrue(server.status_checked)
        self.assertTrue(server.cleaned)
        self.assertIn('操作完成'.encode('utf-8'), result.stdout)

    def test_wrong_password_never_uploads_or_executes(self):
        server, result = self.perform('bad-login')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(server.login_attempts, 1)
        self.assertIsNone(server.uploaded)
        self.assertFalse(server.executed)

    def test_non_root_never_uploads_or_executes(self):
        server, result = self.perform('non-root')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(server.uploaded)
        self.assertFalse(server.executed)

    def test_failed_checksum_never_executes_and_cleans_upload(self):
        server, result = self.perform('bad-checksum')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(server.executed)
        self.assertTrue(server.cleaned)

    def test_install_error_is_not_reported_as_success(self):
        server, result = self.perform('install-failed')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(server.executed)
        self.assertFalse(server.status_checked)

    def test_check_mode_never_uploads_or_executes(self):
        server, result = self.perform(check_only=True)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode('utf-8', errors='replace'))
        self.assertIsNone(server.uploaded)
        self.assertFalse(server.executed)
        self.assertTrue(server.status_checked)

    def test_absent_logger_with_dev_null_output_is_informational(self):
        server, result = self.perform('output-null', check_only=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('当前不写入管道日志'.encode(), result.stdout)
        self.assertNotIn('未检测到，请检查'.encode(), result.stdout)
        self.assertFalse(server.executed)
        self.assertIsNone(server.uploaded)

    def test_unconfirmed_output_retains_diagnostic_notice(self):
        for mode in ['output-unknown', 'output-error']:
            with self.subTest(mode=mode):
                server, result = self.perform(mode, check_only=True)
                self.assertEqual(result.returncode, 0)
                self.assertIn('输出去向未确认'.encode(), result.stdout)
                self.assertNotIn('当前不写入管道日志'.encode(), result.stdout)
                self.assertFalse(server.executed)

    def test_missing_uu_process_is_not_reported_as_idle_logging(self):
        server, result = self.perform('output-missing', check_only=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('未找到本项目的 UU 主进程'.encode(), result.stdout)
        self.assertFalse(server.executed)


class GuiWorkerTests(AutoInstallTests):
    def perform(self, mode='normal', check_only=False, gui_worker=True, action=''):
        return super().perform(mode, check_only, gui_worker=True, action=action)


class ManagementTests(AutoInstallTests):
    def test_full_uninstall_upload_verified_and_missing_afterward(self):
        for mode in ('ok', 'uninstalled'):
            with self.subTest(mode=mode):
                server, result = self.perform(mode, action='UninstallFull')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(server.managed_actions, ['full'])
                self.assertTrue(server.cleaned)
                self.assertEqual(server.uploaded, (REPO / 'src/full-uninstall.sh').read_bytes())
                self.assertTrue(server.removed)

    def test_full_checksum_failure_never_removes(self):
        server, result = self.perform('bad-checksum', action='UninstallFull')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(server.managed_actions, [])
        self.assertTrue(server.cleaned)

    def test_full_busy_failure_or_unexpected_state_is_not_success(self):
        for mode in ('management-busy', 'management-failed', 'no-state-change'):
            with self.subTest(mode=mode):
                server, result = self.perform(mode, action='UninstallFull')
                self.assertNotEqual(result.returncode, 0)
                if mode == 'management-busy': self.assertEqual(server.managed_actions, [])

    def test_enable_and_disable_only_change_autostart(self):
        for action, enabled, verb in [('EnableAutostart', True, 'enable'), ('DisableAutostart', False, 'disable')]:
            with self.subTest(action=action):
                server, result = self.perform(action=action)
                self.assertEqual(result.returncode, 0, result.stdout.decode('utf-8', errors='replace'))
                self.assertEqual(server.enabled, enabled)
                self.assertTrue(server.running)
                self.assertEqual(server.managed_actions, [verb])
                self.assertIsNone(server.uploaded)
                self.assertFalse(server.executed)

    def test_start_and_stop_leave_autostart_unchanged(self):
        for action, running, mode in [('Start', True, 'stopped'), ('Stop', False, 'normal')]:
            with self.subTest(action=action):
                server, result = self.perform(mode, action=action)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(server.running, running)
                self.assertTrue(server.enabled)
                self.assertFalse(server.uninstalled)

    def test_uninstall_then_retained_state_is_displayed(self):
        server, result = self.perform(action='Uninstall')
        self.assertEqual(result.returncode, 0)
        self.assertTrue(server.uninstalled)
        self.assertFalse(server.running)
        self.assertFalse(server.enabled)
        self.assertIn('已卸载，保留文件'.encode(), result.stdout)
        self.assertNotIn('尚未检测到'.encode(), result.stdout)

    def test_restore_uninstalled_preserves_binding_without_installer(self):
        server, result = self.perform('uninstalled', action='Restore')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(server.managed_actions, ['restore'])
        self.assertTrue(server.running and server.enabled)
        self.assertFalse(server.uninstalled)
        self.assertIsNone(server.uploaded)
        self.assertNotIn('rm -f /usr/plugin/uu-wol-f7615/files', '\n'.join(server.commands))

    def test_firmware_or_script_mismatch_never_mutates(self):
        for mode in ['bad-firmware', 'bad-scripts']:
            with self.subTest(mode=mode):
                server, result = self.perform(mode, action='Uninstall')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(server.managed_actions, [])
                self.assertTrue(server.running and server.enabled)

    def test_failure_busy_and_unexpected_post_state_are_not_success(self):
        for mode in ['management-failed', 'management-busy', 'no-state-change']:
            with self.subTest(mode=mode):
                server, result = self.perform(mode, action='DisableAutostart')
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(server.enabled)

    def test_restore_failure_or_unknown_hook_is_reported(self):
        for mode in ['restore-failed', 'restore-hook-changed']:
            with self.subTest(mode=mode):
                server, result = self.perform(mode, action='Restore')
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(server.uninstalled)
                self.assertFalse(server.running)

    def test_idempotent_uninstall_and_restore_do_not_repeat_mutation(self):
        for mode, action in [('uninstalled', 'Uninstall'), ('normal', 'Restore')]:
            with self.subTest(action=action):
                server, result = self.perform(mode, action=action)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(server.managed_actions, [])

    def test_status_of_missing_installation_is_read_only(self):
        server, result = self.perform('missing-installation', check_only=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('服务：未安装'.encode(), result.stdout)
        self.assertEqual(server.managed_actions, [])
        self.assertIsNone(server.uploaded)


class GuiManagementTests(ManagementTests):
    def perform(self, mode='normal', check_only=False, gui_worker=True, action=''):
        return super().perform(mode, check_only, gui_worker=True, action=action)


if __name__ == '__main__':
    unittest.main(argv=['test_auto_install.py', *remaining])
