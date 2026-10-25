"""Run destructive full removal only inside temporary fixtures, never on a modem."""
import argparse, hashlib, io, shlex, subprocess, tarfile, tempfile, unittest
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('--busybox', required=True)
a,rest=p.parse_known_args(); BB=Path(a.busybox).resolve().as_posix()
REPO=Path(__file__).resolve().parents[1]
SOURCE=(REPO/'src/full-uninstall.sh').read_text(encoding='utf-8')
class FullRemoval(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='uu-full-'); self.base=Path(self.temp.name)
  self.paths={k:self.base/k.lower() for k in ['ROOT','BACKUP','OLD','STAGE','TEST','HOOK','PROC','MOUNTS','WORK']}
  self.root=self.paths['ROOT']; self.root.mkdir(); self.paths['PROC'].mkdir(); self.paths['MOUNTS'].write_text('')
  self.sentinel=self.base/'vendor-config'; self.sentinel.write_bytes(b'keep vendor')
  (self.root/'.uu-f7615-managed-v2').touch(); (self.root/'enabled').touch()
  (self.root/'hook-before-type').write_text('probe\n'); (self.root/'hook.before').write_text('#!/bin/sh\n# UU_F7615_BOOT_PROBE_V1\nexit 0\n')
  (self.root/'hook.sh').write_text('managed hook\n'); self.paths['HOOK'].write_text('managed hook\n')
  (self.root/'files').mkdir(); (self.root/'files/.sn').write_text('private fixture')
  self.actions=self.base/'actions'
  control='BB='+shlex.quote(BB)+'\necho "$1" >> '+shlex.quote(self.actions.as_posix())+'\n'
  control+='[ ! -f '+shlex.quote((self.base/'fail-stop').as_posix())+' ] || exit 1\n'
  control+='"$BB" rm -f '+shlex.quote((self.root/'enabled').as_posix())+'\n'
  control+='"$BB" cp '+shlex.quote((self.root/'hook.before').as_posix())+' '+shlex.quote(self.paths['HOOK'].as_posix())+'\n'
  control+='"$BB" touch '+shlex.quote((self.root/'uninstalled').as_posix())+'\n'
  (self.root/'control.sh').write_text(control,newline='\n')
 def tearDown(self):
  self.assertEqual(self.sentinel.read_bytes(),b'keep vendor'); self.temp.cleanup()
 def run_script(self,mode='--confirmed-full'):
  s=SOURCE
  for k,v in self.paths.items():
   import re
   s=re.sub(r'^'+k+r'=.*$',k+'='+shlex.quote(v.as_posix()),s,flags=re.M)
  # Substitute fixture hashes while retaining real hash checks for fixture scripts.
  for name,old in [('control.sh','789a19a789781e661013362c6ce1dfed6fca7c3717659f6389131485528567af'),('hook.sh','ed636266d90d888f4a2505eeca59484c7b732dc3cf36274d7001e808630fa7a7')]:
   s=s.replace(old,hashlib.sha256((self.root/name).read_bytes()).hexdigest())
  s=s.replace("echo '58a5a48a3bfb5bd38209ffa58e3fb5b635623d4a2125799cd8e7e897e3a6a58f  /bin/cspd' | sha256sum -c - >/dev/null",':')
  s=s.replace('/tmp/uu-f7615-',self.base.as_posix()+'/uu-f7615-')
  wrapper='BB='+shlex.quote(BB)+'\n'
  for app in ['cat','cmp','cp','rm','sync','mkdir','rmdir','find','grep','tar','sha256sum','readlink']:
   wrapper+=app+'() { "$BB" '+app+' "$@"; }\n'
  wrapper+='sh() { "$BB" ash "$@"; }\nid() { echo 0; }\nuname() { echo aarch64; }\n'
  path=self.base/'run.sh'; path.write_text(wrapper+s,newline='\n')
  return subprocess.run([BB,'ash',str(path),mode],capture_output=True,timeout=15)
 def test_full_removes_program_binding_hook_and_known_backup(self):
  self.paths['BACKUP'].mkdir()
  with tarfile.open(self.paths['BACKUP']/'working-backup.tar.gz','w:gz') as t:
   for name in ['.sn','.uuplugin_uuid','uuplugin','uu.conf','xuplugin-guardian','xtables-nft-multi']:
    info=tarfile.TarInfo('./'+name); info.size=1;t.addfile(info,io.BytesIO(b'x'))
  r=self.run_script();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  for k in ['ROOT','HOOK','BACKUP']:self.assertFalse(self.paths[k].exists())
  self.assertIn(b'FULL_UNINSTALL_COMPLETE',r.stdout)
 def test_preflight_keeps_service_binding_and_hook(self):
  r=self.run_script('--preflight');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  self.assertFalse(self.actions.exists());self.assertTrue((self.root/'files/.sn').exists());self.assertTrue(self.paths['HOOK'].exists())
 def test_retained_uninstall_can_be_fully_removed(self):
  (self.root/'uninstalled').touch();(self.root/'enabled').unlink();self.paths['HOOK'].write_bytes((self.root/'hook.before').read_bytes())
  r=self.run_script();self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertFalse(self.root.exists())
 def assert_refused(self):
  r=self.run_script();self.assertNotEqual(r.returncode,0);self.assertTrue(self.root.exists());self.assertFalse(self.actions.exists())
 def test_unknown_backup_refused_before_stop(self):
  self.paths['BACKUP'].mkdir();(self.paths['BACKUP']/'unknown').write_text('keep');self.assert_refused();self.assertTrue((self.paths['BACKUP']/'unknown').exists())
 def test_unknown_hook_refused_before_stop(self):
  self.paths['HOOK'].write_text('vendor hook');self.assert_refused();self.assertEqual(self.paths['HOOK'].read_text(),'vendor hook')
 def test_missing_marker_refused_before_stop(self):
  (self.root/'.uu-f7615-managed-v2').unlink();self.assert_refused()
 def test_installer_stage_refused_before_stop(self):
  self.paths['STAGE'].mkdir();self.assert_refused()
 def test_nested_mount_refused_before_stop(self):
  self.paths['MOUNTS'].write_text('tmpfs '+self.root.as_posix()+'/child tmpfs rw 0 0\n');self.assert_refused()
 def test_stop_failure_preserves_program_and_binding(self):
  (self.base/'fail-stop').touch();r=self.run_script();self.assertNotEqual(r.returncode,0);self.assertTrue((self.root/'files/.sn').exists());self.assertTrue((self.root/'enabled').exists())
 def test_unrecognized_archive_refused_before_stop(self):
  self.paths['BACKUP'].mkdir()
  with tarfile.open(self.paths['BACKUP']/'working-backup.tar.gz','w:gz') as t:
   info=tarfile.TarInfo('vendor/settings');info.size=1;t.addfile(info,io.BytesIO(b'x'))
  self.assert_refused()
 def test_empty_original_hook_has_no_probe_left(self):
  (self.root/'hook-before-type').write_text('absent\n')
  # Fixture controller must restore absence, as the real controller does.
  p=self.root/'control.sh';s=p.read_text();s=s.replace('"$BB" cp '+shlex.quote((self.root/'hook.before').as_posix())+' '+shlex.quote(self.paths['HOOK'].as_posix()),'"$BB" rm -f '+shlex.quote(self.paths['HOOK'].as_posix()));p.write_text(s,newline='\n')
  r=self.run_script();self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertFalse(self.paths['HOOK'].exists())
 def test_argument_required(self):
  r=self.run_script('--wrong');self.assertNotEqual(r.returncode,0);self.assertFalse(self.actions.exists())
if __name__=='__main__':unittest.main(argv=[__file__]+rest)
