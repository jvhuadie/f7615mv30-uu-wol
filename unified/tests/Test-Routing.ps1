$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$root/tools/Profiles.ps1"
$f='58a5a48a3bfb5bd38209ffa58e3fb5b635623d4a2125799cd8e7e897e3a6a58f'
$g='453c47535b274071a5ae83d533d825e5072c8b562857e51eeefa8826953180ed'
$b='7c4cc96aaaafc766d1d0b558672487b3532eae3b2df11111a51160a071455f21'
function Expect-Rejection([scriptblock]$Block){$rejected=$false;try{& $Block | Out-Null}catch{$rejected=$true};if(!$rejected){throw 'Unsafe input accepted'}}
if((Resolve-OntProfile F7615MV30 aarch64 $f '') -ne 'f7615'){throw 'F7615 route'}
if((Resolve-OntProfile F7005MV3 aarch64 $g $b) -ne 'f7005'){throw 'F7005 route'}
Expect-Rejection {Resolve-OntProfile F7615MV30 aarch64 $g $b}
Expect-Rejection {Resolve-OntProfile F7005MV3 aarch64 $f $b}
Expect-Rejection {Resolve-OntProfile F7005MV3 aarch64 $g ('0'*64)}
Expect-Rejection {Resolve-OntProfile F7005MV3 armv7l $g $b}
Expect-Rejection {Resolve-OntProfile G7615V2 aarch64 $f $b}
Expect-Rejection {Resolve-OntProfile F7615MV30-test aarch64 $f $b}
Expect-Rejection {Get-OntRoute f7615 Install $true ''}
Expect-Rejection {Get-OntRoute f7615 Install $false 'binding.tgz'}
Expect-Rejection {Get-OntRoute f7615 EnableService $false ''}
Expect-Rejection {Get-OntRoute f7005 Restore $false ''}
if((@(Get-OntRoute f7615 Start $false '') -join ',') -ne 'Start,EnableAutostart'){throw 'start route'}
if((@(Get-OntRoute f7615 Stop $false '') -join ',') -ne 'DisableAutostart,Stop'){throw 'stop route'}
if(@(Get-OntRoute f7005 Detect $false '').Count -ne 0){throw 'detect must not dispatch'}
if((@(Get-OntRoute f7615 ServiceStart $false '') -join ',') -ne 'Start'){throw 'GUI start must preserve F7615 autostart'}
if((@(Get-OntRoute f7615 ServiceStop $false '') -join ',') -ne 'Stop'){throw 'GUI stop must preserve F7615 autostart'}
if((@(Get-OntRoute f7615 DisableAutostart $false '') -join ',') -ne 'DisableAutostart'){throw 'F7615 independent autostart'}
if((@(Get-OntRoute f7005 DisableAutostart $false '') -join ',') -ne 'Stop'){throw 'F7005 coupled autostart'}
Expect-Rejection {Get-OntRoute g7615 Install $true ''}
Expect-Rejection {Get-OntRoute g7615 Install $false 'binding.tgz'}
Expect-Rejection {Get-OntRoute g7615 EnableService $false ''}
if((@(Get-OntRoute g7615 ServiceStop $false '') -join ',') -ne 'Stop'){throw 'G7615 independent stop'}
if((@(Get-OntRoute g7615 DisableAutostart $false '') -join ',') -ne 'DisableAutostart'){throw 'G7615 independent autostart'}
Write-Output 'PROFILE_AND_NEGATIVE_ROUTING_TESTS_OK'

# A fake Telnet client tests the complete dispatcher without network or device writes.
Add-Type @'
using System;using System.Collections.Generic;using System.Security;using System.Text.RegularExpressions;
namespace ZteUuInstaller {
 public class TelnetSession:IDisposable {
  public static string Model="F7005MV3",Arch="aarch64",Uid="0",Firmware="",Boot="";
  public static List<string> Commands=new List<string>(),Engines=new List<string>();
  string last="";
  public TelnetSession(string a,int p,int t){}
  public void SendLine(string s){last=s;}
  public void SendSecureLine(SecureString s){}
  public string ReadUntil(string pattern,int timeout){
   if(!last.StartsWith("echo 'BEGIN_"))return "/ #";
   var m=Regex.Match(last,@"echo '(BEGIN_[a-f0-9]+)'; \( (.*?) \); rc=\$\?; echo; echo '(END_[a-f0-9]+):'");
   if(!m.Success)throw new Exception("Bad frame");string c=m.Groups[2].Value;Commands.Add(c);string v;
   switch(c){case "id -u":v=Uid;break;case "uname -n":v=Model;break;case "uname -m":v=Arch;break;case "sha256sum /bin/cspd":v=Firmware+"  /bin/cspd";break;case "sha256sum /etc/default/S01userconfig":v=Boot+"  /etc/default/S01userconfig";break;default:throw new Exception("Unexpected write or command");}
   return m.Groups[1].Value+"\r\n"+v+"\r\n"+m.Groups[3].Value+":0\r\n";
  }
  public void Dispose(){}
 }
}
'@
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('OntRouteTest-'+[Guid]::NewGuid().ToString('N'))
$secret=ConvertTo-SecureString 'test-only' -AsPlainText -Force
try{
 foreach($dir in @('tools','profiles/f7615','profiles/f7005','profiles/g7615')){$null=New-Item -ItemType Directory -Path (Join-Path $sandbox $dir) -Force}
 foreach($file in @('Manage.ps1','tools/Profiles.ps1','tools/Network.ps1')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $sandbox $file)}
 foreach($profile in @('f7615','f7005','g7615')){
  $name=if($profile -eq 'f7615'){'Auto.ps1'}else{'Manage.ps1'}
  $stub='param($RouterAddress,$Username,$Password,$Action,$BindingArchive,[switch]$PidOnly,[switch]$NonInteractive) [ZteUuInstaller.TelnetSession]::Engines.Add('''+$profile+':$Action'')'
  $stub=$stub.Replace("'$profile"+':$Action' +"'",'"'+$profile+':$Action"')
  [IO.File]::WriteAllText((Join-Path $sandbox "profiles/$profile/$name"),$stub)
 }
 [ZteUuInstaller.TelnetSession]::Firmware=$g;[ZteUuInstaller.TelnetSession]::Boot=$b
 & "$sandbox/Manage.ps1" -Action Detect -Password $secret | Out-Null
 if([ZteUuInstaller.TelnetSession]::Engines.Count){throw 'Detect dispatched backend'}
 & "$sandbox/Manage.ps1" -Action Install -Password $secret | Out-Null
 if([ZteUuInstaller.TelnetSession]::Engines[0] -ne 'f7005:Install'){throw 'Wrong F7005 backend'}
 [ZteUuInstaller.TelnetSession]::Model='F7615MV30';[ZteUuInstaller.TelnetSession]::Firmware=$f
 & "$sandbox/Manage.ps1" -Action Install -Password $secret | Out-Null
 if([ZteUuInstaller.TelnetSession]::Engines[1] -ne 'f7615:Install'){throw 'Wrong F7615 backend'}
 [ZteUuInstaller.TelnetSession]::Model='G7615V2';[ZteUuInstaller.TelnetSession]::Firmware='0afb71c8d938a82395675bc1fa96cb10ec23f5a9ab9f4f3d66073257d02c7b36'
 & "$sandbox/Manage.ps1" -Action Install -Password $secret | Out-Null
 if([ZteUuInstaller.TelnetSession]::Engines[2] -ne 'g7615:Install'){throw 'Wrong G7615 backend'}
 [ZteUuInstaller.TelnetSession]::Firmware=$f
 $before=[ZteUuInstaller.TelnetSession]::Engines.Count
 [ZteUuInstaller.TelnetSession]::Model='G7615V2'
 Expect-Rejection {& "$sandbox/Manage.ps1" -Action Install -Password $secret}
 [ZteUuInstaller.TelnetSession]::Model='F7005MV3';[ZteUuInstaller.TelnetSession]::Firmware=$f
 Expect-Rejection {& "$sandbox/Manage.ps1" -Action UninstallFull -Password $secret}
 [ZteUuInstaller.TelnetSession]::Uid='1000'
 Expect-Rejection {& "$sandbox/Manage.ps1" -Action Install -Password $secret}
 if([ZteUuInstaller.TelnetSession]::Engines.Count -ne $before){throw 'Rejected probe invoked backend'}
 [ZteUuInstaller.TelnetSession]::Uid='0';[ZteUuInstaller.TelnetSession]::Model='F7615MV30';[ZteUuInstaller.TelnetSession]::Firmware=$f
 [IO.File]::WriteAllText((Join-Path $sandbox 'profiles/f7615/Auto.ps1'),'param($RouterAddress,$Username,$Password,$Action,[switch]$NonInteractive) [ZteUuInstaller.TelnetSession]::Engines.Add("failed:$Action"); exit 1')
 Expect-Rejection {& "$sandbox/Manage.ps1" -Action Start -Password $secret}
 if([ZteUuInstaller.TelnetSession]::Engines.Count -ne ($before+1) -or [ZteUuInstaller.TelnetSession]::Engines[$before] -ne 'failed:Start'){throw 'Continued after backend failure'}
 Write-Output 'DISPATCH_READONLY_AND_NO_MUTATION_ON_REJECTION_OK'
}finally{
 $secret.Dispose()
 $full=[IO.Path]::GetFullPath($sandbox);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
 if([IO.Path]::GetDirectoryName($full) -eq $temp -and [IO.Path]::GetFileName($full).StartsWith('OntRouteTest-')){Remove-Item -LiteralPath $full -Recurse -Force}
}
