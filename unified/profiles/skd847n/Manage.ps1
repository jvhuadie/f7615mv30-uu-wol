param([ValidateSet('Install','Status','Start','Stop','Restore','Uninstall','UninstallFull')][string]$Action='Status',
 [string]$RouterAddress='192.168.1.1',[string]$Username='root',[Security.SecureString]$Password,[string]$BindingArchive='')
$ErrorActionPreference='Stop';$root=$PSScriptRoot;$session=$null;$ownsPassword=$false;$script:lanUnavailable=$false
. "$root/../../tools/Network.ps1"
if(!(Test-UuLanIPv4 $RouterAddress) -or $Username -notmatch '^[A-Za-z0-9_.-]{1,32}$'){throw '地址或用户名格式错误'}
if(!$Password){$Password=Read-Host '创维 Telnet 密码（常见为 Pon521）' -AsSecureString;$ownsPassword=$true}
if(!('ZteUuInstaller.TelnetSession' -as [type])){Add-Type -Path "$root/../../tools/TelnetSession.cs"}
$base='/usr/data/uu-wol-skd847n'
function Remote([string]$command,[int]$timeout=30000,[switch]$AllowFailure,[scriptblock]$Progress){
 $id=[Guid]::NewGuid().ToString('N');$start='START_'+$id;$end='END_'+$id
 $session.SendLine("echo '$start'; ( $command ); rc=`$?; echo; echo '${end}:'`$rc")
 # Consume the complete line: ReadUntil returns only through the regex match.
 $pattern='(?m)^'+$end+':([0-9]+)\r*\n'
 $raw=if($Progress -and $session.PSObject.Methods['ReadUntilWithProgress']){$session.ReadUntilWithProgress($pattern,$timeout,[Action]$Progress)}else{$session.ReadUntil($pattern,$timeout)}
 $raw=$raw -replace '\r+\n',"`n"
 $begin=[regex]::Match($raw,'(?m)^'+$start+'\n');$finish=[regex]::Match($raw,'(?m)^'+$end+':([0-9]+)$')
 if(!$begin.Success -or !$finish.Success -or $finish.Index -lt ($begin.Index+$begin.Length)){throw '远端响应不完整，已停止操作。'}
 $body=$raw.Substring($begin.Index+$begin.Length,$finish.Index-$begin.Index-$begin.Length).Trim();$code=[int]$finish.Groups[1].Value
 if($code -ne 0 -and !$AllowFailure){throw ('创维操作失败，代码 '+$code+'：'+$body)}
 return [pscustomobject]@{Text=$body;Code=$code}
}
function HashBytes([byte[]]$bytes){$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function ShellLiteral([string]$s){return "'"+$s.Replace("'","'\''")+"'"}
function Try-LanUpload([string]$name,[byte[]]$bytes,[string]$part){
 if($bytes.Length -lt 512 -or $name.EndsWith('.restore') -or $script:lanUnavailable){return $false}
 $curl=(Remote '[ -x /bin/curl ] && echo CURL || echo NONE').Text
 if($curl -cne 'CURL'){Write-Host '宿主未找到 curl，使用 Telnet 备用传输。';$script:lanUnavailable=$true;return $false}
 $server=$null
 try{
  try{
   if(!('G7615LanTransfer' -as [type])){Add-Type -Path "$root/../g7615/LanTransfer.cs"}
   $socket=New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Dgram,[Net.Sockets.ProtocolType]::Udp)
   try{$socket.Connect($RouterAddress,23);$local=$socket.LocalEndPoint.Address.ToString()}finally{$socket.Dispose()}
   if(!(Test-UuLanIPv4 $local)){throw '未找到可用于局域网传输的地址'}
   $server=New-Object G7615LanTransfer($local,$RouterAddress,$name,$bytes)
  }catch{
   Write-Host ('无法建立临时传输服务，回退 Telnet：'+$_.Exception.Message)
   $script:lanUnavailable=$true;return $false
  }
  $watch=[Diagnostics.Stopwatch]::StartNew()
  Write-Host ('局域网直传 '+$name+'：'+[Math]::Round($bytes.Length/1048576.0,2)+' MiB；连接超时 5 秒，不修改防火墙规则。')
  $progress={
   $sent=$server.BytesSent;$seconds=[Math]::Max(0.1,$watch.Elapsed.TotalSeconds)
   Write-Host ('直传 '+$name+'：已发送 '+[Math]::Round($sent/1048576.0,2)+' / '+[Math]::Round($bytes.Length/1048576.0,2)+' MiB，平均 '+[Math]::Round($sent/1024.0/$seconds,1)+' KiB/s；等待设备下载确认。')
  }
  # Fixed host curl, no curlrc/proxy/redirects; process deadline precedes Telnet deadline.
  $url=$server.Url
  $r=Remote "[ -f '$part' ] && [ ! -L '$part' ] && /bin/curl -q --noproxy '*' --connect-timeout 5 --max-time 120 -fsS -o '$part' '$url'" 135000 -AllowFailure -Progress $progress
  if($r.Code -eq 0){return $true}
  Write-Host ('局域网下载失败（代码 '+$r.Code+'），回退 Telnet；防火墙或光猫到电脑的路由可能阻止连接。')
  # Only after a definite exit: do not retry if the session timed out/disconnected.
  $null=Remote "[ -f '$part' ] && [ ! -L '$part' ] && : > '$part'"
  $script:lanUnavailable=$true
  return $false
 }finally{if($server){$server.Dispose()}}
}
function Upload([string]$name,[byte[]]$bytes){
 if($name -notmatch '^[A-Za-z0-9_.-]+$'){throw '文件名不合法'}
 $target="$base/$name";$part=$target+'.part';$hash=HashBytes $bytes
 $null=Remote "[ ! -e '$part' ] && [ ! -L '$part' ] && [ ! -e '$target' ] && [ ! -L '$target' ] && (umask 077; set -C; : > '$part')"
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $fast=Try-LanUpload $name $bytes $part
 $nextProgress=0
 if(!$fast){
 for($offset=0;$offset -lt $bytes.Length;$offset+=128){
  $take=[Math]::Min(128,$bytes.Length-$offset);$encoded=New-Object Text.StringBuilder
  for($j=0;$j -lt $take;$j++){$null=$encoded.Append('\').Append([Convert]::ToString($bytes[$offset+$j],8).PadLeft(3,'0'))}
  $null=Remote ("printf '"+$encoded.ToString()+"' >> '$part'")
  if($watch.Elapsed.TotalSeconds -ge $nextProgress){$sent=$offset+$take;Write-Host ('Telnet '+$name+'：'+[int](100*$sent/$bytes.Length)+'%，'+[Math]::Round($sent/1024.0,1)+' / '+[Math]::Round($bytes.Length/1024.0,1)+' KiB，平均 '+[Math]::Round($sent/1024.0/[Math]::Max(0.1,$watch.Elapsed.TotalSeconds),1)+' KiB/s');$nextProgress=$watch.Elapsed.TotalSeconds+2}
 }
 }
 $null=Remote "echo '$hash  $part' | sha256sum -c - && [ ! -e '$target' ] && [ ! -L '$target' ] && mv '$part' '$target'"
 Write-Host ('传输完成并通过 SHA256：'+$name+'，耗时 '+[Math]::Round($watch.Elapsed.TotalSeconds,1)+' 秒。')
}
function Find-Data {
 $value=(Remote 'for f in /usr/data/o_ins/felix-cache/bundle*/bundle.info; do [ -f "$f" ] && [ ! -L "$f" ] || continue; [ "$(sed -n 2p "$f")" = file:/usr/data/uu-wol-skd847n/service.jar ] || continue; echo "${f%/bundle.info}/data"; done').Text
 if($value -notmatch '^/usr/data/o_ins/felix-cache/bundle[0-9]+/data$'){throw '项目插件登记不唯一或尚未完成'}
 return $value
}
function Control([string]$operation){
 $hash=HashBytes ([IO.File]::ReadAllBytes("$root/control.sh"))
 $null=Remote "[ ! -L '$base' ] && [ ! -L '$base/control.sh' ] && echo '$hash  $base/control.sh' | sha256sum -c -"
 return (Remote "sh '$base/control.sh' '$operation'" 45000).Text
}
function Read-BindingArchive([string]$path){
 $file=Get-Item -LiteralPath $path
 if($file.Length -gt 196608){throw '绑定备份过大'}
 $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
 if($record.Model -cne 'SK-D847N' -or $record.Format -cne 'SK_BINDING_V1' -or !$record.Files){throw '绑定备份型号或格式不匹配'}
 $files=@{}
 foreach($property in $record.Files.PSObject.Properties){
  if($property.Name -cnotin @('.sn','.uuplugin_uuid','uu.conf') -or $property.Value -isnot [string] -or $property.Value.Length -gt 24000){throw '绑定备份包含未知文件或条目过大'}
  $bytes=[Convert]::FromBase64String($property.Value)
  if($bytes.Length -gt 16384){throw '绑定条目过大'}
  $files[$property.Name]=$bytes
 }
 return $files
}
function Backup-Binding {
 $data=Find-Data;$files=@{}
 foreach($name in @('.sn','.uuplugin_uuid','uu.conf')){
  $exists=Remote "[ -f '$data/$name' ] && [ ! -L '$data/$name' ]" -AllowFailure
  if($exists.Code -ne 0){continue}
  $size=(Remote "wc -c < '$data/$name'").Text
  if($size -notmatch '^\d+$' -or [int]$size -gt 16384){throw '绑定文件大小异常，未卸载'}
  $hash=(Remote "sha256sum '$data/$name'").Text.Split(' ')[0]
  $hex=(Remote "busybox hexdump -v -e '1/1 `"%02x`"' '$data/$name'").Text
  if($hex.Length -ne 2*[int]$size -or ($hex -and $hex -notmatch '^[0-9a-f]+$')){throw '绑定备份不完整，未卸载'}
  $bytes=New-Object byte[] ([int]$size)
  for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=[Convert]::ToByte($hex.Substring(2*$i,2),16)}
  if((HashBytes $bytes) -cne $hash -or (Remote "sha256sum '$data/$name'").Text.Split(' ')[0] -cne $hash){throw '绑定备份校验失败，未卸载'}
  $files[$name]=[Convert]::ToBase64String($bytes)
 }
 $dir=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SK-D847N-UU-WOL'
 $null=New-Item -ItemType Directory -Path $dir -Force
 $file=Join-Path $dir ('binding-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.json')
 @{Model='SK-D847N';Format='SK_BINDING_V1';Files=$files}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $file -Encoding UTF8
 Write-Host ('绑定文件已备份并校验：'+$file)
}
try{
 $session=New-Object ZteUuInstaller.TelnetSession($RouterAddress,23,5000)
 $hello=$session.ReadUntil('(?im)(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
 if($hello -match '(?im)(?:login|username)\s*:\s*$'){
  $session.SendLine($Username);$null=$session.ReadUntil('(?im)password\s*:\s*$',15000);$session.SendSecureLine($Password)
  $hello=$session.ReadUntil('(?im)access denied|login incorrect|(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
  if($hello -match '(?im)access denied|login incorrect|(?:login|username)\s*:\s*$'){throw '登录失败，不尝试其他密码'}
 }
 $guard=(Remote 'id -u; uname -n; uname -m; sha256sum /bin/cspd /etc/default/S01userconfig /bin/osgid').Text
 if($guard -notmatch '(?m)^0$' -or $guard -notmatch '(?m)^skyworth$' -or $guard -notmatch '(?m)^aarch64$' -or $guard -notmatch '4864d4dc6118f9aa5eed96f99538877c16742d10de43f78e66ee4aba7f4e1fa5' -or $guard -notmatch '6a84065579e08f5025cd2d56b93a3d7b511dc79ab93fceec9fd1913a17c3c211' -or $guard -notmatch '92c026a51f3b589800405608296fa1908ccbb366cbd18cae98ddcaadeaefbd3a'){throw '仅支持已核对的 SK-D847N 固件与启动版本'}
 Write-Host '创维 SK-D847N：原厂 OSGi；UU 以 UID 107 和 CAP_NET_RAW 运行，参考设备的重启自启已实测通过，每次新安装仍需验收。'
 $absent=Remote "[ ! -e '$base' ] && [ ! -L '$base' ]" -AllowFailure
 if($Action -eq 'Status' -and $absent.Code -eq 0){
  Write-Host '光猫端版本：未安装';Write-Host '服务：未安装';Write-Host '自启：未安装';Write-Host 'UU 云连接：未连接';return
 }
 if($Action -eq 'Install'){
  $binding=if($BindingArchive){Read-BindingArchive $BindingArchive}else{$null}
  if($absent.Code -ne 0){throw '已有项目安装或残留，未覆盖；请先检查状态，正常安装无需重装'}
  $mount=(Remote 'cat /proc/mounts').Text
  if($mount -notmatch '(?m)^\S+ /usr/data jffs2 (?<opts>\S+) ' -or ($Matches['opts'] -split ',') -notcontains 'rw' -or ($Matches['opts'] -split ',') -contains 'nosuid'){throw '持久分区不符合已验证的 rw/suid JFFS2 环境'}
  $disk=(Remote 'df -k /usr/data').Text
  $free=[regex]::Match($disk,'(?m)^\s*(?:\S+\s+)?\d+\s+\d+\s+(\d+)\s+\d+%\s+/usr/data\s*$')
  if(!$free.Success -or [long]$free.Groups[1].Value -lt 16384){throw '可用持久空间不足 16 MiB 或无法读取'}
  $java=(Remote 'n=0; for p in /proc/[0-9]*; do [ "$(readlink "$p/exe" 2>/dev/null)" = /usr/local/osgi/local/j2re/bin/java ] || continue; grep -q "^Uid:[[:space:]]*107[[:space:]]*107" "$p/status" || exit 1; grep -q "^Gid:[[:space:]]*110[[:space:]]*110" "$p/status" || exit 1; grep -q "^NoNewPrivs:[[:space:]]*0" "$p/status" || exit 1; n=$((n+1)); done; [ "$n" = 1 ] && echo JAVA_OK').Text
  if($java -cne 'JAVA_OK'){throw 'Java 身份或权限环境与已验证版本不同'}
  $null=Remote '[ ! -e /var/run/uuplugin.pid ] && [ ! -L /var/run/uuplugin.pid ] && [ ! -e /tmp/uu ] && [ ! -L /tmp/uu ] || exit 1; for p in /proc/[0-9]*/exe; do e=$(readlink "$p" 2>/dev/null) || continue; case "$e" in */uuplugin|*/xuplugin-guardian) exit 1;; esac; done'
  $m=Get-Content "$root/payload/manifest.json" -Raw|ConvertFrom-Json
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $jar=[IO.File]::ReadAllBytes("$root/payload/service.jar")
  if((HashBytes $jar) -cne $m.'service.jar'){throw '内置服务包校验失败'}
  $payload=@{'service.jar'=$jar;'launch-uu'=[IO.File]::ReadAllBytes("$root/payload/launch-uu");'control.sh'=[IO.File]::ReadAllBytes("$root/control.sh");'managed-v1'=[Text.Encoding]::ASCII.GetBytes("SK_D847N_MANAGED_V1`n")}
  $zip=[IO.Compression.ZipFile]::OpenRead("$root/payload/service.jar")
  try{foreach($name in @('uuplugin','xuplugin-guardian')){
   $entry=$zip.GetEntry("payload/$name");if(!$entry -or $entry.Length -gt 8388608){throw '程序包条目异常'}
   $mem=New-Object IO.MemoryStream;$stream=$entry.Open()
   try{$stream.CopyTo($mem);$payload[$name]=$mem.ToArray()}finally{$mem.Dispose();$stream.Dispose()}
  }}finally{$zip.Dispose()}
  foreach($name in @('uuplugin','xuplugin-guardian','launch-uu')){if((HashBytes $payload[$name]) -cne $m.$name){throw '内置程序校验失败'}}
  $null=Remote "mkdir -m 755 '$base'"
  foreach($name in ($payload.Keys|Sort-Object)){Upload $name $payload[$name]}
  $null=Remote "chown 0:0 '$base' '$base/launch-uu' '$base/uuplugin' '$base/xuplugin-guardian'; chmod 755 '$base'; chmod 555 '$base/uuplugin' '$base/xuplugin-guardian'; chmod 4555 '$base/launch-uu'; chmod 644 '$base/service.jar'; chmod 700 '$base/control.sh'; chmod 600 '$base/managed-v1'; sh -n '$base/control.sh'"
  $null=Remote ("/bin/sidbg 74 osgid install name=local.ont.uuwol.skd847n url=file:$base/service.jar fsize="+$jar.Length)
  $data=$null;$startRequested=$false
  for($i=0;$i -lt 30;$i++){
   Start-Sleep -Milliseconds 500
   try{$data=Find-Data}catch{continue}
   if(!$startRequested){$null=Remote '/bin/sidbg 74 osgid start local.ont.uuwol.skd847n';$startRequested=$true}
   $ready=Remote "[ -f '$data/temp/status.properties' ] && grep -q '^state=STAGED' '$data/temp/status.properties'" -AllowFailure
   if($ready.Code -eq 0){break}
  }
  if(!$data -or $ready.Code -ne 0){throw '插件准备未完成，保留现场；不要重复覆盖安装'}
  $null=Control stop
  if($binding){foreach($name in $binding.Keys){
   $original=$base;$base=$data
   try{Upload ($name+'.restore') $binding[$name]}finally{$base=$original}
   $null=Remote "[ ! -L '$data/$name' ] && chown 107:110 '$data/$name.restore' && chmod 600 '$data/$name.restore' && mv '$data/$name.restore' '$data/$name'"
  };Write-Host '已从电脑备份恢复绑定文件。'}
  $null=Remote "[ ! -e '$data/enabled' ] && [ ! -L '$data/enabled' ] && : > '$data/enabled' && chown 107:110 '$data/enabled' && chmod 644 '$data/enabled'"
  try{$null=Control start}catch{try{$null=Control stop}catch{};throw '项目已暂存，但启动未通过，请检查状态；已尝试停用自启'}
  Write-Host '已安装创维候选版。请在 UU App 验证在线和远程开机；光猫重启需单独验收，工具不自动重启。'
 }else{
  if($Action -eq 'UninstallFull'){Backup-Binding}
  $op=switch($Action){'Status'{'status'} 'Start'{'start'} 'Stop'{'stop'} 'Restore'{'restore'} 'Uninstall'{'uninstall'} 'UninstallFull'{'purge'}}
  $out=Control $op;if($out){Write-Host $out}
  if($Action -eq 'UninstallFull'){Write-Host '光猫端已卸载创维项目程序和登记；电脑绑定备份保留。';return}
 }
 if($Action -ne 'Status'){Write-Host (Control status)}
}finally{if($session){$session.Dispose()};if($ownsPassword){$Password.Dispose()}}
