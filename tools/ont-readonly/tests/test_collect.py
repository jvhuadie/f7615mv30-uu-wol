"""Synthetic endpoint tests: never connects to an actual modem."""
import hashlib,json,os,re,socket,subprocess,tempfile,threading,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
COMMANDS=json.loads((ROOT/'commands.json').read_text(encoding='utf-8'))
SECRET='SyntheticProbePassword42'
class Endpoint:
 def __init__(self,mode='ok'):
  self.mode=mode;self.commands=[];self.error=None
  self.s=socket.socket();self.s.bind(('127.0.0.1',0));self.s.listen(1);self.s.settimeout(10);self.port=self.s.getsockname()[1]
  self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
 def run(self):
  try:
   c,_=self.s.accept()
   with c:
    c.settimeout(10);f=c.makefile('rb')
    def line():return f.readline().decode().rstrip('\r\n')
    c.sendall(b'G7615V2\r\nLogin: ');assert line()=='root';c.sendall(b'Password: ');assert line()==SECRET
    if self.mode=='login-failed':c.sendall(b'Access denied\r\nLogin: ');return
    c.sendall(b'\r\n/ # ')
    pending_rc=0
    while True:
     text=line()
     if not text:break
     m=re.fullmatch(r'echo (__PROBE_START_[a-f0-9]+__); \( (.*) \)',text)
     if m:
      cmd=m.group(2);assert cmd in [x['command'] for x in COMMANDS],cmd
      self.commands.append(cmd)
      if self.mode=='partial' and len(self.commands)==3:return
      pending_rc=127 if self.mode=='missing' else 0
      body='Name: fixture\nSerial: SENSITIVE-SERIAL\nssid=PRIVATE-WIFI\npassword=bad\n'+SECRET+'\ninet 192.168.1.12 ether aa:bb:cc:dd:ee:ff\ninet6 fe80::abcd:1234\ndate 12:46:12\n::sysinit:/etc/init.d/rcS\nptyp0::sysinit:/bin/shellproxy\nbridge 8000.aabbccddeeff\nboot=/etc/rcS.d\n'
      body+='PASS="OtherPassword42"\nUSER="PrivateUser42"\nurl=https://HiddenLogin:HiddenPassword@example.invalid/path\nFIRMWARE_VERSION_EVIDENCE=V1.2.3.4\n'
      if pending_rc==0:
       if cmd==COMMANDS[0]['command']:
        hostname='OpenWrt' if self.mode=='unknown' else 'G7615V2' if self.mode=='real-line-endings' else 'F7005MV3'
        version='Sun Feb 4 20:00:49 CST 2024' if self.mode=='real-line-endings' else '1.2.3.4'
        body='HOSTNAME='+hostname+'\nARCH=aarch64\nSOFTWARE_VERSION='+version+'\n'+body
       if self.mode=='conflict' and cmd==next(x['command'] for x in COMMANDS if x['id']=='model'):
        body='FILE /proc/device-tree/model\nZTE G7615V2\n'+body
       if cmd==next(x['command'] for x in COMMANDS if x['id']=='hooks'):
        body+='a'*64+'  /bin/cspd\n'
       if self.mode=='real-line-endings' and cmd==next(x['command'] for x in COMMANDS if x['id']=='model'):
        body='FILE /proc/device-tree/model\nZTE 133\n'+body
       if self.mode=='oversized' and cmd==COMMANDS[0]['command']:body+='\n'+'A'*196900
       if self.mode=='limited' and cmd==next(x['command'] for x in COMMANDS if x['id']=='namespace-startup-metadata'):body+='ENTRY_LIMIT_REACHED\n'
      if self.mode=='real-line-endings':body=body.replace('\n','\r\n')
      c.sendall((text+'\r\n'+m.group(1)+'\r\n'+body.replace('\n','\r\n')+'/ # ').encode())
     else:
      m=re.fullmatch(r'echo (__PROBE_END_[a-f0-9]+__):\$\?',text);assert m,text
      c.sendall((text+'\r\n'+m.group(1)+':'+str(pending_rc)+'\r\n/ # ').encode())
  except Exception as e:self.error=e
  finally:self.s.close()
class CollectorTests(unittest.TestCase):
 def perform(self,mode,declared=''):
  with tempfile.TemporaryDirectory(prefix='g7615-probe-中文 ') as td:
   base=Path(td);server=Endpoint(mode)
   runner=base/'run.ps1';out=base/'result.json'
   runner.write_text("$ErrorActionPreference='Stop'\n$p=New-Object Security.SecureString; foreach($c in $env:PROBE_TEST_SECRET.ToCharArray()){$p.AppendChar($c)}\ntry { $r=& '"+(ROOT/'Collect.ps1').as_posix()+"' -RouterAddress 127.0.0.1 -Port "+str(server.port)+" -Username root -Password $p -OutputDirectory '"+base.as_posix()+"'; [IO.File]::WriteAllText('"+out.as_posix()+"',($r|ConvertTo-Json),[Text.Encoding]::UTF8) } finally { $p.Dispose() }",encoding='utf-8-sig')
   if declared:
    runner.write_text(runner.read_text(encoding='utf-8-sig').replace(' -OutputDirectory '," -DeclaredModel '"+declared+"' -DeclaredHardware 'V2.0' -OutputDirectory "),encoding='utf-8-sig')
   result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(runner)],capture_output=True,env=dict(os.environ,PROBE_TEST_SECRET=SECRET),timeout=45)
   server.thread.join(3);self.assertIsNone(server.error);self.assertFalse(server.thread.is_alive(),(result.stdout+result.stderr).decode("utf-8",errors="replace"));self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   self.assertNotIn(SECRET.encode(),result.stdout+result.stderr)
   obj=json.loads(out.read_text(encoding='utf-8-sig'))
   import zipfile
   with zipfile.ZipFile(obj['Zip']) as z:
    self.assertEqual(set(z.namelist()),{'report.txt','report.json'})
    for name in z.namelist():
     data=z.read(name)
     for secret in [SECRET,'SENSITIVE-SERIAL','PRIVATE-WIFI','192.168.1.12','aa:bb:cc:dd:ee:ff','fe80::abcd:1234','8000.aabbccddeeff','OtherPassword42','PrivateUser42','HiddenLogin','HiddenPassword']:
      self.assertNotIn(secret.encode(),data)
    report=json.loads(z.read('report.json').decode('utf-8-sig'))
    text=z.read('report.txt').decode('utf-8-sig')
    self.assertIn('设备型号：',text.split('=====')[0])
    self.assertIn('识别状态：',text.split('=====')[0])
   return obj,report,server.commands
 def test_complete_redacted_report_and_exact_readonly_commands(self):
  obj,report,commands=self.perform('ok');self.assertEqual(obj['State'],'COMPLETE');self.assertEqual(len(report['sections']),len(COMMANDS));self.assertEqual(commands,[x['command'] for x in COMMANDS]);self.assertIn('/etc/rcS.d',report['sections'][0]['output']);self.assertIn('12:46:12',report['sections'][0]['output']);self.assertIn('::sysinit:/etc/init.d/rcS',report['sections'][0]['output']);self.assertIn('ptyp0::sysinit:',report['sections'][0]['output'])
 def test_missing_command_still_exports_warning_results(self):
  obj,report,_=self.perform('missing');self.assertEqual(obj['State'],'COMPLETE');self.assertTrue(all(s['exitCode']==127 for s in report['sections']))
  self.assertEqual(report['identity']['status'],'UNKNOWN');self.assertIn('型号未知',obj['Zip'])
  self.assertEqual(report['coverage']['warningSections'],len(COMMANDS))
 def test_repeated_carriage_returns_and_board_build_time(self):
  _,report,_=self.perform('real-line-endings');i=report['identity']
  self.assertEqual(i['model'],'G7615V2');self.assertEqual(i['boardModel'],'ZTE 133')
  self.assertEqual(i['systemBuildTime'],'Sun Feb 4 20:00:49 CST 2024');self.assertEqual(i['softwareVersion'],'')
 def test_section_output_limit_is_visible_in_coverage(self):
  _,report,_=self.perform('oversized')
  self.assertEqual(report['coverage']['truncatedSections'],1)
  self.assertIn('OUTPUT_LIMIT_REACHED',report['sections'][0]['warnings'])
 def test_entry_limit_is_not_reported_as_absence(self):
  _,report,_=self.perform('limited')
  section=next(x for x in report['sections'] if x['id']=='namespace-startup-metadata')
  self.assertIn('ENTRY_LIMIT_REACHED',section['warnings'])
 def test_identity_summary_filename_and_dotted_version(self):
  obj,report,_=self.perform('ok');i=report['identity']
  self.assertEqual(i['model'],'F7005MV3');self.assertEqual(i['status'],'CANDIDATE')
  self.assertEqual(i['softwareVersion'],'1.2.3.4');self.assertEqual(i['architecture'],'aarch64')
  self.assertEqual(i['firmwareFingerprint'],'a'*64);self.assertIn('uname -n',i['candidates'][0]['source'])
  self.assertIn('ZTE-F7005MV3-aarch64-readonly-',obj['Zip'])
  self.assertIn('FIRMWARE_VERSION_EVIDENCE=V1.2.3.4',report['sections'][0]['output'])
 def test_conflicting_sources_are_not_silently_selected(self):
  obj,report,_=self.perform('conflict');i=report['identity']
  self.assertEqual(i['status'],'CONFLICT');self.assertEqual(i['model'],'');self.assertEqual(len(i['candidates']),2);self.assertIn('型号冲突',obj['Zip'])
 def test_manual_model_is_separate_and_conflict_visible(self):
  obj,report,_=self.perform('ok','G7615V2');i=report['identity']
  self.assertEqual(i['status'],'CONFLICT');self.assertEqual(i['model'],'F7005MV3');self.assertEqual(i['declaredModel'],'G7615V2');self.assertEqual(i['declaredHardwareVersion'],'V2.0')
 def test_generic_hostname_uses_explicit_manual_filename(self):
  obj,report,_=self.perform('unknown','G7615V2');i=report['identity']
  self.assertEqual(i['status'],'UNKNOWN');self.assertEqual(i['model'],'');self.assertIn('用户填写-G7615V2',obj['Zip'])
 def test_login_failure_no_commands_or_retry(self):
  obj,report,commands=self.perform('login-failed');self.assertEqual(obj['State'],'FAILED');self.assertEqual(commands,[]);self.assertEqual(report['sections'],[])
 def test_disconnect_keeps_redacted_partial_report(self):
  obj,report,commands=self.perform('partial');self.assertEqual(obj['State'],'PARTIAL');self.assertEqual(len(report['sections']),2);self.assertEqual(len(commands),3)
  self.assertEqual(report['coverage']['interruptedGroup'],COMMANDS[2]['id']);self.assertEqual(len(report['coverage']['notCompleted']),len(COMMANDS)-2)
 def test_command_allowlist_has_no_mutations_or_sensitive_config_reads(self):
  for row in COMMANDS:
   self.assertLess(len(row['command']),1800)
   self.assertNotRegex(row['command'],r'\b(rm|mv|cp|mkdir|chmod|chown|kill|reboot|wget|curl|mount|umount|touch|dd)\b(?=\s+[-/])')
   self.assertNotRegex(row['command'],r'(?:^|[^2])>|/etc/(?:passwd|shadow)|/proc/[^ ]*/cmdline|uu\.conf|/userconfig/')
if __name__=='__main__':unittest.main()
