$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type @'
using System;using System.Collections.Generic;using System.Security;using System.Text.RegularExpressions;
namespace ZteUuInstaller {
 public class TelnetSession:IDisposable {
  public static List<string> Commands=new List<string>();
  public static string Mode="success",Eol="\r\r\n";
  string last="";
  public TelnetSession(string a,int p,int t){}
  public void SendLine(string s){if(s.Contains("\n")||s.Contains("\r"))throw new Exception("Multiline transport");last=s;}
  public void SendSecureLine(SecureString s){}
  public string ReadUntil(string pattern,int timeout){
   if(!last.StartsWith("echo 'START_"))return "/ #";
   var m=Regex.Match(last,@"echo '(START_[a-f0-9]+)'; \( (.*) \); rc=\$\?; echo; echo '(END_[a-f0-9]+):'");
   if(!m.Success)throw new Exception("Bad frame");string c=m.Groups[2].Value;Commands.Add(c);string v="";int rc=0;
   if(c.StartsWith("/bin/sh -c ")){v="/proc/2750/root";if(Mode=="bad-framework"){v="FRAMEWORK_ROOT_NOT_UNIQUE";rc=12;}}
   else if(c.StartsWith("df -k "))v="81304";
   else if(c.Contains("/control.sh 'start'") && Mode=="start-fails"){v="START_FAILED_CHECK_LOGREAD";rc=1;}
   else if(c.Contains("/control.sh 'status'"))v="VERSION=0.1.0-rc1\nstate=RUNNING\nAUTOSTART=ENABLED\nCLOUD=UNVERIFIED";
   else if(c.StartsWith("[ ! -e '/proc/2750/root/opt/uu-wol-g7615'"))rc=Mode=="existing"?1:0;
   else if(c.StartsWith("echo '") || c.StartsWith("[ ! -L ") || c.StartsWith("[ ! -e ") || c.StartsWith("printf '") || c.StartsWith("umask 077; mkdir ") || c.StartsWith("chmod 700 ") || c.StartsWith("/usr/sbin/chroot ")){}
   else throw new Exception("Unexpected command:"+c);
   string transcript=m.Groups[1].Value+Eol+v.Replace("\n",Eol)+Eol+m.Groups[3].Value+":"+rc+Eol;
   var end=Regex.Match(transcript,pattern);if(!end.Success)throw new Exception("Response pattern did not match");
   return transcript.Substring(0,end.Index+end.Length);
  }
  public void Dispose(){}
 }
}
'@
$secret=ConvertTo-SecureString 'fixture' -AsPlainText -Force
function Run-Case([string]$mode,[string]$action,[bool]$fails){
 [ZteUuInstaller.TelnetSession]::Mode=$mode;[ZteUuInstaller.TelnetSession]::Commands.Clear()
 $failed=$false
 try { & "$root/profiles/g7615/Manage.ps1" -Action $action -Password $secret 6>$null | Out-Null } catch { $failed=$true;if(!$fails){throw};if($mode -eq 'bad-framework' -and $_.Exception.Message -notmatch '代码 12：FRAMEWORK_ROOT_NOT_UNIQUE'){throw "Incorrect failure: $_"};if($mode -eq 'start-fails' -and $_.Exception.Message -notmatch 'START_FAILED_CHECK_LOGREAD'){throw "Incorrect failure: $_"} }
 if($failed -ne $fails){throw "Unexpected outcome: $mode $action"}
 return ,([ZteUuInstaller.TelnetSession]::Commands.ToArray())
}
try{
 foreach($eol in @("`n","`r`n","`r`r`n")){
  [ZteUuInstaller.TelnetSession]::Eol=$eol
  $c=Run-Case success Status $false
 }
 $c=Run-Case bad-framework Install $true
 if($c.Count -ne 1){throw 'Wrote after failed preflight'}
 $c=Run-Case existing Install $true
 if(($c -join "`n") -match 'umask 077; mkdir|printf|/control.sh'){throw 'Existing installation overwritten'}
 $c=Run-Case success Status $false
 if(($c -join "`n") -match 'umask 077; mkdir|printf|/control.sh'){throw 'Absent status wrote data'}
 $c=Run-Case start-fails Install $true
 if(($c -join "`n") -match "/control.sh 'enable'"){throw 'Enabled autostart after startup failure'}
 if(($c -join "`n") -notmatch "/control.sh 'start'"){throw 'Missing runtime acceptance'}
 $c=Run-Case success Install $false
 $joined=$c -join "`n"
 if($joined.IndexOf("/control.sh 'start'") -gt $joined.IndexOf("/control.sh 'enable'")){throw 'Enabled before runtime acceptance'}
 foreach($name in @('uuplugin','xuplugin-guardian','control.sh','service.sh','run.sh','uu.conf','payload.sha256','managed-v1')){
  if($joined -notmatch [regex]::Escape("/$name.part' | sha256sum -c -")){throw "Unchecked upload: $name"}
 }
 'G7615_PREFLIGHT_REJECTION_EXISTING_INSTALL_NO_WRITE_CRCRLF_TRANSFER_AND_START_BEFORE_ENABLE_OK'
}finally{$secret.Dispose()}
