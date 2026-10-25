"""Check the standalone EXE from an otherwise empty folder; no router connection."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--exe', type=Path, required=True)
args, remaining = parser.parse_known_args()
EXE = args.exe.resolve()


class SingleExeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='uu-single-窗口 ')
        self.directory = Path(self.temp.name)
        self.exe = self.directory / '远程开机工具.exe'
        shutil.copyfile(EXE, self.exe)
        self.before = set(Path(tempfile.gettempdir()).glob('UuWol-runtime-*'))

    def tearDown(self):
        self.assertEqual(set(Path(tempfile.gettempdir()).glob('UuWol-runtime-*')) - self.before, set())
        self.temp.cleanup()

    def run_exe(self, *arguments):
        return subprocess.run([str(self.exe), *arguments], cwd=self.directory, timeout=30).returncode

    def test_embedded_resources_and_syntax_without_sibling_files(self):
        self.assertEqual(self.run_exe('--self-test'), 0)
        self.assertEqual({p.name for p in self.directory.iterdir()}, {self.exe.name})

    def test_real_gui_render_ignores_adjacent_scripts(self):
        marker = self.directory / 'unexpected-script-execution'
        (self.directory / 'Gui.ps1').write_text(
            "[IO.File]::WriteAllText('" + marker.as_posix() + "','bad')\n", encoding='utf-8-sig')
        (self.directory / 'defaults.json').write_text('{"Password":"not-the-embedded-default"}')
        preview = self.directory / '窗口预览.png'
        self.assertEqual(self.run_exe('--preview', str(preview)), 0)
        self.assertTrue(preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
        self.assertFalse(marker.exists())

    def test_read_only_window_render(self):
        preview = self.directory / '只读窗口.png'
        self.assertEqual(self.run_exe('--check', '--preview', str(preview)), 0)
        self.assertTrue(preview.is_file())

    def test_corrupt_resource_fails_without_leaving_extracted_files(self):
        data = bytearray(self.exe.read_bytes())
        start = data.find(b'\x1f\x8b\x08')
        self.assertGreater(start, 0)
        data[start + 10] ^= 0xFF
        self.exe.write_bytes(data)
        self.assertEqual(self.run_exe('--self-test'), 1)

    def test_parallel_instances_have_independent_temporary_roots(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.run_exe('--self-test'), range(2)))
        self.assertEqual(results, [0, 0])


if __name__ == '__main__':
    unittest.main(argv=['test_single_exe.py', *remaining])
