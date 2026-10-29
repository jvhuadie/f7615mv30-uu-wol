$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath("$PSScriptRoot/../profiles/g7615")
Add-Type -Path "$root/LanTransfer.cs"
. "$root/../../tools/Network.ps1"
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Manage.ps1",[ref]$t,[ref]$e)
if($e.Count){throw $e[0]}
foreach($n in @('HashBytes','Try-LanUpload','Upload')){
 $fn=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Get-Bytes($url){
 $req=[Net.HttpWebRequest]::Create($url);$req.Proxy=$null;$req.Timeout=10000
 $res=$req.GetResponse();$stream=$res.GetResponseStream();$mem=New-Object IO.MemoryStream
 try{$stream.CopyTo($mem);return ,$mem.ToArray()}finally{$stream.Dispose();$res.Dispose();$mem.Dispose()}
}
$payload=New-Object byte[] (5*1024*1024);$rng=New-Object Random(426);$rng.NextBytes($payload)
$server=New-Object G7615LanTransfer('127.0.0.1','127.0.0.1','program',$payload)
$port=$server.Port
try{
 $timer=[Diagnostics.Stopwatch]::StartNew();$received=Get-Bytes $server.Url
 if((HashBytes $received) -cne (HashBytes $payload)){throw 'HTTP payload corruption'}
 if($server.BytesSent -ne $payload.Length){throw 'Incorrect progress counter'}
 Write-Output ('LOOPBACK_5_MIB_SECONDS='+[Math]::Round($timer.Elapsed.TotalSeconds,3))
 foreach($url in @("http://127.0.0.1:$port/wrong-token/program",($server.Url+'/../other'))){
  $denied=$false;try{$null=Get-Bytes $url}catch{$err=$_.Exception;while($err -and !($err -is [Net.WebException])){$err=$err.InnerException};if($err -and $err.Response -and [int]$err.Response.StatusCode -eq 404){$denied=$true}else{throw}}
  if(!$denied){throw 'Non-whitelisted URL accepted'}
 }
}finally{$server.Dispose()}
$client=New-Object Net.Sockets.TcpClient
try{$failed=$false;try{$client.Connect('127.0.0.1',$port)}catch{$failed=$true};if(!$failed){throw 'Listener survived disposal'}}finally{$client.Dispose()}
$server=New-Object G7615LanTransfer('127.0.0.1','127.0.0.2','program',$payload)
try{$denied=$false;try{$null=Get-Bytes $server.Url}catch{$denied=$true};if(!$denied){throw 'Foreign peer accepted'}}finally{$server.Dispose()}
$RouterAddress='127.0.0.1';$base='/proc/2750/root/opt/uu-wol-g7615'
function Remote($command,$timeout=30000,[switch]$AllowFailure,[scriptblock]$Progress){
 $script:commands.Add($command)
 if($command -eq '[ -x /bin/curl ] && echo CURL || echo NONE'){return [pscustomobject]@{Text='CURL';Code=0}}
 if($command -match "/bin/curl -q .*'(http://[^']+)'$"){
  $url=$Matches[1]
  if($script:mode -eq 'timeout'){throw 'transport timeout'}
  if($script:mode -eq 'failed'){return [pscustomobject]@{Code=7;Text='connect failed'}}
  $script:downloaded=Get-Bytes $url
  & $Progress
  return [pscustomobject]@{Code=0;Text=''}
 }
 if($script:mode -eq 'hash-fails' -and $command.Contains('sha256sum -c -')){throw 'checksum mismatch; not promoted'}
 return [pscustomobject]@{Code=0;Text=''}
}
foreach($mode in @('success','failed','timeout')){
 $script:mode=$mode;$script:lanUnavailable=$false;$script:commands=New-Object 'Collections.Generic.List[string]'
 $thrown=$false;$fast=$false
 try{$fast=Try-LanUpload 'uuplugin' $payload "$base/uuplugin.part" 6>$null}catch{$thrown=$true}
 $reset=($commands -join "`n").Contains(": > '$base/uuplugin.part'")
 if($mode -eq 'success'){
  if(!$fast -or $thrown -or $reset -or (HashBytes $downloaded) -ne (HashBytes $payload)){throw 'Fast transfer failed'}
 }elseif($mode -eq 'failed'){
  if($fast -or $thrown -or !$reset -or !$script:lanUnavailable){throw 'Explicit failure did not reset and fall back'}
 }elseif(!$thrown -or $reset){throw 'Ambiguous timeout retried or reset remote file'}
}
$script:mode='hash-fails';$script:lanUnavailable=$false;$script:commands.Clear()
$thrown=$false;try{Upload 'uuplugin' $payload 6>$null}catch{$thrown=$true}
if(!$thrown){throw 'Checksum failure ignored'}
if(($commands -join "`n") -match "printf '"){throw 'Fast path used slow octal upload'}
'LAN_BINARY_HASH_PEER_TOKEN_DISPOSAL_PROGRESS_FALLBACK_AND_CHECKSUM_GUARDS_OK'

# Exercise the actual Telnet callback on its calling thread.
Add-Type -Path "$root/../../tools/TelnetSession.cs"
Add-Type @'
using System;using System.Net;using System.Net.Sockets;using System.Text;using System.Threading;
public sealed class TransferAckFixture:IDisposable {
 TcpListener listener;Thread thread;public int Port;
 public TransferAckFixture(){listener=new TcpListener(IPAddress.Loopback,0);listener.Start();Port=((IPEndPoint)listener.LocalEndpoint).Port;thread=new Thread(Run);thread.IsBackground=true;thread.Start();}
 void Run(){using(var c=listener.AcceptTcpClient()){var s=c.GetStream();while(s.ReadByte()!=10){} Thread.Sleep(1200);byte[] b=Encoding.ASCII.GetBytes("DONE:0\r\r\n");s.Write(b,0,b.Length);Thread.Sleep(200);}}
 public void Dispose(){listener.Stop();thread.Join(2000);}
}
'@
$fixture=New-Object TransferAckFixture;$telnet=$null;$script:ticks=0
try{
 $telnet=New-Object ZteUuInstaller.TelnetSession('127.0.0.1',$fixture.Port,3000)
 $telnet.SendLine('test')
 $ack=$telnet.ReadUntilWithProgress('DONE:0\r*\n',4000,[Action]{$script:ticks++})
 if($ack -notmatch 'DONE:0' -or $script:ticks -lt 2){throw 'Actual Telnet progress callback not invoked'}
 'REAL_TELNET_PROGRESS_CALLBACK_OK'
}finally{if($telnet){$telnet.Dispose()};$fixture.Dispose()}
