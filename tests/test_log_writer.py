"""Exercise the actual shell pipe consumer with synthetic byte streams."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--busybox', required=True)
args, remaining = parser.parse_known_args()
BUSYBOX = str(Path(args.busybox).resolve())
SCRIPT = Path(__file__).resolve().parents[1] / 'src/log-writer.sh'
LIMIT = 256 * 1024


class LogWriterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='uu-log-test-')
        self.directory = Path(self.temp.name).resolve()
        self.log = self.directory / 'service.log'
        self.previous = self.directory / 'service.log.previous'
        self.pid = self.directory / 'writer.pid'
        self.process = None

    def tearDown(self):
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.communicate(timeout=5)
        # TemporaryDirectory only removes the unique test-owned directory.
        self.temp.cleanup()

    def launch(self, log=None):
        self.process = subprocess.Popen(
            [BUSYBOX, 'ash', str(SCRIPT), str(log or self.log), str(self.pid)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return self.process

    def test_large_binary_stream_is_bounded_and_retains_latest_output(self):
        data = bytes(range(256)) * 16384 + b'FINAL_OUTPUT_MARKER'
        maximum = [0, 0]
        done = threading.Event()

        def observe():
            while not done.is_set():
                for index, path in enumerate([self.log, self.previous]):
                    try:
                        maximum[index] = max(maximum[index], path.stat().st_size)
                    except FileNotFoundError:
                        pass
                done.wait(0.001)

        observer = threading.Thread(target=observe)
        observer.start()
        try:
            process = self.launch()
            _, error = process.communicate(data, timeout=20)
            self.assertEqual(process.returncode, 0, error.decode(errors='replace'))
        finally:
            done.set()
            observer.join()
        for size in maximum:
            self.assertLessEqual(size, LIMIT)
        for path in [self.log, self.previous]:
            self.assertLessEqual(path.stat().st_size, LIMIT)
        self.assertTrue(self.previous.read_bytes().endswith(b'FINAL_OUTPUT_MARKER'))
        self.assertFalse(self.pid.exists())

    def test_idle_and_short_writes_remain_live_until_eof(self):
        process = self.launch()
        deadline = time.monotonic() + 5
        while not self.log.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(self.log.exists())
        self.assertIsNone(process.poll())
        for line in [b'first\n', b'second\n', b'third\n']:
            process.stdin.write(line)
            process.stdin.flush()
            time.sleep(0.02)
        process.stdin.close()
        process.stdin = None
        _, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, error.decode(errors='replace'))
        retained = self.previous.read_bytes() + self.log.read_bytes()
        self.assertEqual(retained, b'first\nsecond\nthird\n')

    def test_existing_large_legacy_logs_are_bounded_after_migration(self):
        self.log.write_bytes(b'legacy' * 200000)
        self.previous.write_bytes(b'old' * 300000)
        process = self.launch()
        _, error = process.communicate(b'new message\n', timeout=10)
        self.assertEqual(process.returncode, 0, error.decode(errors='replace'))
        self.assertLessEqual(self.log.stat().st_size, LIMIT)
        self.assertLessEqual(self.previous.stat().st_size, LIMIT)
        self.assertEqual(self.previous.read_bytes(), b'new message\n')

    def test_bounded_previous_log_survives_empty_restart(self):
        self.previous.write_bytes(b'previous session\n')
        process = self.launch()
        process.communicate(b'', timeout=5)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(self.previous.read_bytes(), b'previous session\n')

    def test_write_failure_keeps_draining_instead_of_breaking_producer_pipe(self):
        process = self.launch(self.directory / 'missing-parent' / 'service.log')
        # If the consumer exited immediately on the open error, this write would
        # break the producer's pipe. The consumer must drain until producer EOF.
        process.stdin.write(b'x' * (2 * 1024 * 1024))
        process.stdin.close()
        process.stdin = None
        process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(self.pid.exists())


if __name__ == '__main__':
    unittest.main(argv=['test_log_writer.py', *remaining])
