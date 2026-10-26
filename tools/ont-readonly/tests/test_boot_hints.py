import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
BB=os.environ.get('PROBE_BUSYBOX') or shutil.which('busybox')
ROWS={x['id']:x['command'] for x in json.loads((ROOT/'commands.json').read_text(encoding='utf-8'))}

@unittest.skipUnless(BB, 'Set PROBE_BUSYBOX to a BusyBox executable for shell checks')
class HintsTests(unittest.TestCase):
 def run_fixture(self, key, contents, paths):
  with tempfile.TemporaryDirectory(prefix='ont-hints-') as td:
   p=Path(td)/'fixture';p.write_bytes(contents)
   cmd=ROWS[key]
   for path in paths:cmd=cmd.replace(path,p.as_posix())
   r=subprocess.run([str(BB),'sh','-c',cmd],capture_output=True,timeout=10)
   self.assertEqual(r.returncode,0,r.stderr)
   return r.stdout.decode('utf-8',errors='replace')
 def test_framework_whitelist_excludes_unrelated_secrets(self):
  out=self.run_fixture('plugin-autoload-properties',b'password=PRIVATE\nacs.url=PRIVATE\nfelix.auto.deploy.dir=/usr/plugin/bdl\nfelix.auto.deploy.action=install,start\norg.osgi.framework.storage=/usr/plugin/bundlecache\n', ['/usr/java/conf/config_chongqinggd.properties','/usr/java/conf/config.properties'])
  self.assertNotIn('PRIVATE',out)
  self.assertIn('felix.auto.deploy.dir=/usr/plugin/bdl',out)
  self.assertIn('org.osgi.framework.storage=',out)
 def test_script_paths_match_and_filter_before_limit(self):
  data=b'/usr/plugin/not-a-script.data\0'*250+b'/usr/plugin/example/callback.sh\0'
  out=self.run_fixture('native-script-paths',data,['/bin/cspd','/bin/osgid','/bin/pc'])
  self.assertIn('/usr/plugin/example/callback.sh',out)
  self.assertNotIn('not-a-script',out)
 def test_all_commands_parse_as_shell(self):
  for key,cmd in ROWS.items():
   r=subprocess.run([str(BB),'sh','-n','-c',cmd],capture_output=True,timeout=5)
   self.assertEqual(r.returncode,0,(key,r.stderr))
 def test_lxc_fields_exclude_environment_and_hook_commands(self):
  data=b'lxc.rootfs.path = dir:/opt/cu/apps/test\nlxc.start.auto = 1\nlxc.environment = password=PRIVATE\nlxc.hook.pre-start = /root/PRIVATE.sh\n'
  out=self.run_fixture('cu-lxc-fields',data,['/etc/lxc/default.conf'])
  self.assertIn('lxc.rootfs.path',out);self.assertIn('lxc.start.auto',out);self.assertNotIn('PRIVATE',out)

if __name__=='__main__':unittest.main()
