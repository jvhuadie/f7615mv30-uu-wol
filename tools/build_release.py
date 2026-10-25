"""Build allowlisted release assets using only Python's standard library."""
import argparse
import hashlib
import subprocess
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = 'v0.6.1'
FILES = [
    '.gitattributes', '.gitignore', 'README.md', 'INSTALL.txt', 'CHANGELOG.md',
    'install.sh', 'Serve.ps1', 'Start.cmd', 'Auto.ps1', 'Check.cmd', 'Manual.cmd',
    'Gui.ps1', 'Console.cmd', 'Check-console.cmd', 'tools/GuiWorker.ps1', 'tools/Manage.ps1',
    'tools/GuiLauncher.cs', 'tools/build_gui.ps1', 'UuWol.exe',
    'src/full-uninstall.sh', 'src/control.sh', 'src/hook.sh', 'src/install-template.sh', 'src/log-writer.sh', 'src/upgrade.sh',
    'tools/build.py', 'tools/build_release.py', 'tools/TelnetSession.cs', 'tools/Network.ps1', 'tools/Prompts.ps1',
    'docs/VALIDATION.md', 'docs/RESEARCH.md',
    'tests/test_log_writer.py', 'tests/test_upgrade.py',
    'tests/test_auto_install.py',
    'tests/test_single_exe.py',
    'tests/test_management_shell.py', 'tests/test_full_uninstall.py', 'tests/test_uninstall_dialog.ps1',
    'tests/test_network.ps1', 'tests/test_prompts.ps1', 'defaults.json',
    'tests/fixtures/v0.2/control.sh', 'tests/fixtures/v0.2/hook.sh',
]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=ROOT / 'dist' / VERSION)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
stem = f'f7615mv30-uu-wol-{VERSION}'
archive = output / (stem + '.zip')
launcher = output / (stem + '.exe')
if launcher.exists():
    launcher.unlink()
subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', str(ROOT / 'tools/build_gui.ps1'), '-OutputPath', str(launcher)], check=True)

def release_bytes(name):
    if name == 'UuWol.exe':
        return launcher.read_bytes()
    text = (ROOT / name).read_text(encoding='utf-8-sig')
    if name.endswith(('.cmd', '.ps1')):
        text = text.replace('\n', '\r\n')
    return text.encode('utf-8-sig' if name.endswith(('.ps1', '.cs')) else 'utf-8')

with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name in FILES:
        source = launcher if name == 'UuWol.exe' else ROOT / name
        if source.is_symlink() or not source.is_file():
            raise SystemExit(f'Missing file or unexpected symlink: {name}')
        entry = zipfile.ZipInfo(stem + '/' + name, date_time=(2026, 10, 24, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.create_system = 3
        entry.external_attr = (0o100755 if name.endswith('.sh') else 0o100644) << 16
        z.writestr(entry, release_bytes(name))

guide = output / f'INSTALL-{VERSION}.txt'
guide.write_bytes(release_bytes('INSTALL.txt'))
sums = output / 'SHA256SUMS.txt'
with sums.open('w', encoding='utf-8', newline='\n') as out:
    for file in [launcher, archive, guide]:
        out.write(f'{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}\n')

with zipfile.ZipFile(archive) as z:
    if z.testzip() is not None:
        raise SystemExit('ZIP integrity check failed')
    expected = {stem + '/' + name for name in FILES}
    if set(z.namelist()) != expected:
        raise SystemExit('ZIP member allowlist mismatch')
    for name in FILES:
        if z.read(stem + '/' + name) != release_bytes(name):
            raise SystemExit(f'Packaged file mismatch: {name}')

for file in [launcher, archive, guide, sums]:
    print(file)
