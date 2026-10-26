"""Full-backup integration tests against a synthetic localhost Telnet endpoint."""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tarfile
import tempfile
import threading
import time
import unittest

BUSYBOX = os.environ.get('PROBE_BUSYBOX')

ROOT = Path(__file__).resolve().parents[1]
SECRET = 'BackupFixtureSecret42'


class Endpoint:
    def __init__(self, scenario='ok', size=4096):
        self.scenario = scenario
        self.data = (bytes(range(256)) * ((size + 255) // 256))[:size]
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w') as archive:
            payload = b'private configuration fixture\n'
            info = tarfile.TarInfo('etc/device.conf')
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
        self.tar = stream.getvalue()
        self.commands = []
        self.error = None
        self.sock = socket.socket()
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(1)
        self.sock.settimeout(12)
        self.port = self.sock.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        source = None
        try:
            conn, _ = self.sock.accept()
            with conn:
                conn.settimeout(15)
                source = conn.makefile('rb')
                conn.sendall(b'Login: ')
                assert source.readline().strip() == b'root'
                conn.sendall(b'Password: ')
                assert source.readline().strip().decode() == SECRET
                if self.scenario == 'login-failed':
                    conn.sendall(b'Access denied\r\nLogin: ')
                    return
                conn.sendall(b'\r\n/ # ')
                while True:
                    raw = source.readline()
                    if not raw:
                        break
                    command = raw.decode().strip()
                    self.commands.append(command)
                    match = re.match(r'echo (__BACKUP_START_([a-f0-9]+)__); \( (.*?) \); rc=', command)
                    if match:
                        key = match[3]
                        code = 0
                        values = {
                            'id -u': '1000' if self.scenario == 'not-root' else '0',
                            'uname -n': 'G7615V2', 'uname -m': 'aarch64',
                            'cat /proc/mounts': '/dev/root / squashfs ro 0 0\nproc /proc proc rw 0 0\ntmpfs /tmp tmpfs rw 0 0\n' + ('tmpfs /unsafe;path tmpfs rw 0 0\n' if self.scenario == 'unsafe-mount' else ''),
                            'busybox --list': 'cat\nhexdump\ntar\nsha256sum',
                            'tar --help 2>&1 || true': 'tar -C DIR --exclude PATTERN',
                            'if [ -r /proc/mtd ]; then cat /proc/mtd; fi':
                                '' if self.scenario in ('no-flash', 'emmc') else 'dev: size erasesize name\nmtd0: %08x 00020000 "whole flash"\nmtd1: 00000800 00020000 "kernel"' % len(self.data),
                            'for d in /sys/block/mmcblk*; do [ -f "$d/size" ] || continue; echo "${d##*/} $(cat "$d/size")"; done':
                                'mmcblk0 8\nmmcblk0boot0 8' if self.scenario == 'emmc' else '',
                        }
                        if key.startswith('sha256sum /dev/'):
                            value = ('0' * 64 if self.scenario == 'changed' else hashlib.sha256(self.data).hexdigest()) + '  ' + key.split(' ', 1)[1]
                        else:
                            assert key in values, key
                            value = values[key]
                        message = match[1] + '\r\n' + value.replace('\n', '\r\n') + '\r\n__BACKUP_END_' + match[2] + '__:' + str(code) + '\r\n/ # '
                        conn.sendall(message.encode())
                        continue
                    match = re.match(r'echo __DATA_START_([a-f0-9]+)__;', command)
                    assert match, command
                    token = match[1]
                    if self.scenario in ('actual-shell', 'actual-tar'):
                        with tempfile.TemporaryDirectory(prefix='ont-stream-fixture-') as folder:
                            image = Path(folder) / 'flash.dat'
                            image.write_bytes(self.data)
                            bb = Path(BUSYBOX).as_posix()
                            shell_command = command.replace('cat /dev/mtdblock0', "'" + bb + "' cat '" + image.as_posix() + "'").replace('busybox hexdump', "'" + bb + "' hexdump")
                            if self.scenario == 'actual-tar':
                                fixture = Path(folder) / 'root'
                                (fixture / 'etc').mkdir(parents=True)
                                (fixture / 'proc').mkdir()
                                (fixture / 'etc/device.conf').write_bytes(b'private fixture')
                                (fixture / 'proc/virtual').write_bytes(b'excluded')
                                shell_command = shell_command.replace('tar -c -f - -C / ', "'" + bb + "' tar -c -f - -C '" + fixture.as_posix() + "' ")
                            output = subprocess.run([BUSYBOX, 'sh', '-c', shell_command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
                            assert output.returncode == 0, output.stdout[:200]
                            conn.sendall(output.stdout)
                            continue
                    conn.sendall(('__DATA_START_' + token + '__\r\n').encode())
                    data = self.tar if 'tar -c -f - -C /' in command else self.data
                    if self.scenario == 'size-mismatch':
                        data = data[:-32]
                    if self.scenario == 'overrun':
                        data += b'\0' * 32
                    if self.scenario == 'corrupt':
                        conn.sendall(b'not-hex\r\n')
                        return
                    for offset in range(0, len(data), 4096):
                        chunk = data[offset:offset + 4096]
                        encoded = b'\r\n'.join(chunk[n:n + 32].hex().encode() for n in range(0, len(chunk), 32)) + b'\r\n'
                        conn.sendall(encoded)
                        if self.scenario == 'disconnect':
                            return
                        if self.scenario == 'cancel':
                            time.sleep(0.025)
                    src_rc = 1 if self.scenario == 'source-error' else 0
                    source_status = '' if self.scenario == 'no-source-status' else '\r\n__SOURCE_RC_' + token + ':' + str(src_rc)
                    conn.sendall((source_status + '\r\n__READ_RC_' + token + ':0\r\n__DATA_END_' + token + '__\r\n/ # ').encode())
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            if self.scenario not in ('cancel', 'corrupt', 'overrun'):
                self.error = RuntimeError('Unexpected closed connection')
        except Exception as error:
            self.error = error
        finally:
            if source is not None:
                source.close()
            self.sock.close()


class BackupTests(unittest.TestCase):
    def perform(self, scenario='ok', mode='Firmware', size=4096):
        with tempfile.TemporaryDirectory(prefix='ont-private-backup-中文 ') as folder:
            directory = Path(folder)
            endpoint = Endpoint(scenario, size)
            runner = directory / 'run.ps1'
            result_file = directory / 'result.json'
            cancel = '$cts.CancelAfter(2000);' if scenario == 'cancel' else ''
            runner.write_text("$ErrorActionPreference='Stop'; $p=New-Object Security.SecureString; foreach($c in $env:BACKUP_TEST_SECRET.ToCharArray()){$p.AppendChar($c)}; $cts=New-Object Threading.CancellationTokenSource; " + cancel +
                "try {$r=& '" + (ROOT / 'Backup.ps1').as_posix() + "' -RouterAddress 127.0.0.1 -Port " + str(endpoint.port) + " -Password $p -OutputDirectory '" + directory.as_posix() + "' -Mode " + mode + " -CancellationToken $cts.Token; [IO.File]::WriteAllText('" + result_file.as_posix() + "',($r|ConvertTo-Json -Depth 6),[Text.Encoding]::UTF8)} finally {$p.Dispose();$cts.Dispose()}", encoding='utf-8-sig')
            process = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(runner)], capture_output=True, timeout=35, env=dict(os.environ, BACKUP_TEST_SECRET=SECRET))
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            endpoint.thread.join(4)
            self.assertFalse(endpoint.thread.is_alive())
            self.assertIsNone(endpoint.error)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            self.assertNotIn(SECRET.encode(), process.stdout + process.stderr)
            result = json.loads(result_file.read_text(encoding='utf-8-sig'))
            output = Path(result['Directory'])
            manifest = json.loads((output / 'backup-manifest.json').read_text(encoding='utf-8'))
            self.assertTrue(manifest['privateBackup'])
            self.assertNotIn(SECRET, json.dumps(manifest))
            files = {p.name: p.read_bytes() for p in output.iterdir() if p.is_file()}
            return result, manifest, files, endpoint

    def test_whole_flash_selected_once_and_hash_verified(self):
        result, manifest, files, endpoint = self.perform()
        self.assertEqual(result['State'], 'COMPLETE')
        self.assertEqual(files['mtdblock0.img'], endpoint.data)
        self.assertNotIn('mtdblock1.img', files)
        self.assertEqual(manifest['items'][0]['remoteSha256'], hashlib.sha256(endpoint.data).hexdigest())

    @unittest.skipUnless(BUSYBOX, 'Set PROBE_BUSYBOX for an actual shell/hex pipeline round trip')
    def test_actual_shell_pipeline_and_non_aligned_final_hex_line(self):
        result, _, files, endpoint = self.perform('actual-shell', size=4101)
        self.assertEqual(result['State'], 'COMPLETE')
        self.assertEqual(files['mtdblock0.img'], endpoint.data)

    @unittest.skipUnless(BUSYBOX, 'Set PROBE_BUSYBOX for actual tar and hex streaming')
    def test_actual_tar_pipeline_excludes_virtual_directory(self):
        result, _, files, _ = self.perform('actual-tar', mode='Filesystem')
        self.assertEqual(result['State'], 'COMPLETE')
        with tarfile.open(fileobj=io.BytesIO(files['filesystem.tar'])) as archive:
            self.assertIn('./etc/device.conf', archive.getnames())
            self.assertNotIn('./proc/virtual', archive.getnames())

    def test_size_mismatch_retains_partial(self):
        result, _, files, _ = self.perform('size-mismatch')
        self.assertEqual(result['State'], 'PARTIAL')
        self.assertIn('mtdblock0.img.partial', files)

    def test_read_overrun_stops_at_declared_device_size(self):
        result, _, files, _ = self.perform('overrun')
        self.assertEqual(result['State'], 'PARTIAL')
        self.assertLessEqual(len(files['mtdblock0.img.partial']),4096)

    def test_end_marker_without_source_status_is_not_complete(self):
        result, _, files, _ = self.perform('no-source-status')
        self.assertEqual(result['State'], 'PARTIAL')
        self.assertNotIn('mtdblock0.img',files)

    def test_mount_path_cannot_inject_shell_arguments(self):
        result, manifest, _, endpoint = self.perform('unsafe-mount', mode='Filesystem')
        self.assertEqual(result['State'], 'FAILED')
        self.assertEqual(manifest['failure'], 'MOUNT_PATH_UNSUPPORTED')
        self.assertFalse(any('__DATA_START_' in c for c in endpoint.commands))

    def test_filesystem_tar_and_exclusions(self):
        result, manifest, files, endpoint = self.perform(mode='Filesystem')
        self.assertEqual(result['State'], 'COMPLETE')
        self.assertEqual(files['filesystem.tar'], endpoint.tar)
        self.assertIn('--exclude=\'./proc\'', '\n'.join(endpoint.commands))
        with tarfile.open(fileobj=io.BytesIO(files['filesystem.tar'])) as archive:
            self.assertEqual(archive.getnames(), ['etc/device.conf'])

    def test_combined_mode_exports_both(self):
        result, manifest, files, _ = self.perform(mode='All')
        self.assertEqual(result['State'], 'COMPLETE')
        self.assertIn('filesystem.tar', files)
        self.assertIn('mtdblock0.img', files)
        self.assertEqual(len(manifest['items']), 2)

    def test_large_stream_exceeds_receive_buffer_without_buffering_whole_file(self):
        result, _, files, endpoint = self.perform(size=5 * 1024 * 1024)
        self.assertEqual(result['State'], 'COMPLETE')
        self.assertEqual(files['mtdblock0.img'], endpoint.data)

    def test_changed_source_retains_partial(self):
        result, manifest, files, _ = self.perform('changed')
        self.assertEqual(result['State'], 'PARTIAL')
        self.assertIn('mtdblock0.img.partial', files)
        self.assertNotIn('mtdblock0.img', files)
        self.assertEqual(manifest['items'][0]['state'], 'PARTIAL')

    def test_disconnect_retains_received_data_and_manifest(self):
        result, manifest, files, _ = self.perform('disconnect', size=16384)
        self.assertEqual(result['State'], 'PARTIAL')
        self.assertEqual(len(files['mtdblock0.img.partial']), 4096)
        self.assertEqual(manifest['items'][0]['bytes'], 4096)

    def test_remote_source_error_does_not_mark_complete(self):
        result, _, files, _ = self.perform('source-error', mode='Filesystem')
        self.assertEqual(result['State'], 'PARTIAL')
        self.assertIn('filesystem.tar.partial', files)

    def test_cancellation_retains_partial_and_stops_connection(self):
        result, _, files, _ = self.perform('cancel', size=1024 * 1024)
        self.assertEqual(result['State'], 'CANCELLED')
        self.assertIn('mtdblock0.img.partial', files)

    def test_invalid_stream_is_rejected(self):
        result, _, files, _ = self.perform('corrupt')
        self.assertEqual(result['State'], 'PARTIAL')
        self.assertNotIn('mtdblock0.img', files)

    def test_emmc_fallback_includes_boot_device(self):
        result, _, files, _ = self.perform('emmc')
        self.assertEqual(result['State'], 'COMPLETE')
        self.assertIn('mmcblk0.img', files)
        self.assertIn('mmcblk0boot0.img', files)

    def test_unsupported_flash_explicitly_fails(self):
        result, manifest, _, _ = self.perform('no-flash')
        self.assertEqual(result['State'], 'FAILED')
        self.assertEqual(manifest['failure'], 'NO_SUPPORTED_FLASH_DEVICE')

    def test_root_is_required_before_export(self):
        result, manifest, _, endpoint = self.perform('not-root')
        self.assertEqual(result['State'], 'FAILED')
        self.assertEqual(manifest['failure'], 'ROOT_REQUIRED')
        self.assertFalse(any('__DATA_START_' in c for c in endpoint.commands))

    def test_login_failure_does_not_run_commands(self):
        result, manifest, _, endpoint = self.perform('login-failed')
        self.assertEqual(result['State'], 'FAILED')
        self.assertEqual(manifest['failure'], 'LOGIN_FAILED')
        self.assertEqual(endpoint.commands, [])


if __name__ == '__main__':
    unittest.main()
