param([ValidateSet('Install','Status','Start','Stop','EnableAutostart','DisableAutostart','Restore','Uninstall','UninstallFull')][string]$Action='Status',
 [string]$RouterAddress='192.168.1.1',[string]$Username='root',[Security.SecureString]$Password)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$session=$null;$ownsPassword=$false;$script:lanUnavailable=$false
. "$root/../../tools/Network.ps1"
if(!(Test-UuLanIPv4 $RouterAddress) -or $Username -notmatch '^[A-Za-z0-9_.-]{1,32}$'){throw '地址或用户名格式不正确'}
if(!$Password){$Password=Read-Host 'Telnet 密码' -AsSecureString;$ownsPassword=$true}
if(!('ZteUuInstaller.TelnetSession' -as [type])){Add-Type -Path "$root/../../tools/TelnetSession.cs"}
function Remote([string]$command,[int]$timeout=30000,[switch]$AllowFailure,[scriptblock]$Progress){
 $id=[Guid]::NewGuid().ToString('N');$start='START_'+$id;$end='END_'+$id
 $session.SendLine("echo '$start'; ( $command ); rc=`$?; echo; echo '${end}:'`$rc")
 # Consume the complete line: ReadUntil returns only through the regex match.
 $pattern='(?m)^'+$end+':([0-9]+)\r*\n'
 $raw=if($Progress){$session.ReadUntilWithProgress($pattern,$timeout,[Action]$Progress)}else{$session.ReadUntil($pattern,$timeout)}
 $raw=$raw -replace '\r+\n',"`n"
 $begin=[regex]::Match($raw,'(?m)^'+$start+'\n');$finish=[regex]::Match($raw,'(?m)^'+$end+':([0-9]+)$')
 if(!$begin.Success -or !$finish.Success -or $finish.Index -lt ($begin.Index+$begin.Length)){throw '远端响应不完整，已停止操作。'}
 $body=$raw.Substring($begin.Index+$begin.Length,$finish.Index-$begin.Index-$begin.Length).Trim();$code=[int]$finish.Groups[1].Value
 if($code -ne 0 -and !$AllowFailure){throw ('G7615 操作失败，代码 '+$code+'：'+$body)}
 return [pscustomobject]@{Text=$body;Code=$code}
}
function HashBytes([byte[]]$bytes){$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function ShellLiteral([string]$s){return "'"+$s.Replace("'","'\''")+"'"}
function Find-Framework {
 # Execute our fixed script inline; this stage writes nothing to the device.
 $lines=[IO.File]::ReadAllLines("$root/preflight.sh") | Where-Object {$_.Trim() -and !$_.TrimStart().StartsWith('#')}
 $script=($lines -join '; ') -replace '\b(do|then|else); ', '$1 '
 if($script.Length -gt 3500){throw '预检命令超过传输长度限制'}
 $r=Remote ('/bin/sh -c '+(ShellLiteral $script))
 if($r.Text -notmatch '^/proc/[0-9]+/root$'){throw 'CU 框架识别结果异常，未继续。'}
 return $r.Text
}
function Get-CuFreeKiB {
 # The framework overlay persists here. Host df on /proc/PID/root/opt can
 # select the host root filesystem instead of the container overlay.
 $mounts=(Remote 'cat /proc/mounts').Text
 $mount=[regex]::Matches($mounts,'(?m)^\S+[ \t]+/opt/cu/apps[ \t]+ubifs[ \t]+(?<options>\S+)[ \t]+\d+[ \t]+\d+$')
 if($mount.Count -ne 1 -or ($mount[0].Groups['options'].Value -split ',') -notcontains 'rw'){
  throw '未确认 /opt/cu/apps 为可写 UBIFS 持久分区，未安装。'
 }
 $disk=Remote 'df -k /opt/cu/apps' -AllowFailure
 $rows=[regex]::Matches($disk.Text,'(?m)^[ \t]*(?:\S+[ \t]+)?(?<total>\d+)[ \t]+(?<used>\d+)[ \t]+(?<free>\d+)[ \t]+\d+%[ \t]+/opt/cu/apps[ \t]*$')
 if($disk.Code -ne 0 -or $rows.Count -ne 1){
  Write-Host ('空间检查原始结果：'+$disk.Text)
  throw '无法读取 /opt/cu/apps 的可用空间（不是已确认空间不足），未安装。'
 }
 $free=0L;$total=0L
 if(![long]::TryParse($rows[0].Groups['free'].Value,[ref]$free) -or ![long]::TryParse($rows[0].Groups['total'].Value,[ref]$total) -or $total -le 0 -or $free -gt $total){throw '持久分区容量数据异常，未安装。'}
 Write-Host ('CU 持久分区 /opt/cu/apps：可用 '+$free+' KiB（'+[Math]::Round($free/1024.0,1)+' MiB），最低需要 16 MiB。')
 if($free -lt 16384){throw ('CU 持久分区空间不足：可用 '+$free+' KiB，至少需要 16384 KiB，未安装。')}
 return $free
}
function Try-LanUpload([string]$name,[byte[]]$bytes,[string]$part){
 if($bytes.Length -lt 65536 -or $script:lanUnavailable){return $false}
 $curl=(Remote '[ -x /bin/curl ] && echo CURL || echo NONE').Text
 if($curl -cne 'CURL'){Write-Host '宿主未找到 curl，使用 Telnet 备用传输。';$script:lanUnavailable=$true;return $false}
 $server=$null
 try{
  try{
   if(!('G7615LanTransfer' -as [type])){Add-Type -Path "$root/LanTransfer.cs"}
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
 for($offset=0;$offset -lt $bytes.Length;$offset+=768){
  $take=[Math]::Min(768,$bytes.Length-$offset);$encoded=New-Object Text.StringBuilder
  for($j=0;$j -lt $take;$j++){$null=$encoded.Append('\').Append([Convert]::ToString($bytes[$offset+$j],8).PadLeft(3,'0'))}
  $null=Remote ("printf '"+$encoded.ToString()+"' >> '$part'")
  if($watch.Elapsed.TotalSeconds -ge $nextProgress){$sent=$offset+$take;Write-Host ('Telnet '+$name+'：'+[int](100*$sent/$bytes.Length)+'%，'+[Math]::Round($sent/1024.0,1)+' / '+[Math]::Round($bytes.Length/1024.0,1)+' KiB，平均 '+[Math]::Round($sent/1024.0/[Math]::Max(0.1,$watch.Elapsed.TotalSeconds),1)+' KiB/s');$nextProgress=$watch.Elapsed.TotalSeconds+2}
 }
 }
 $null=Remote "echo '$hash  $part' | sha256sum -c - && [ ! -e '$target' ] && [ ! -L '$target' ] && mv '$part' '$target'"
 Write-Host ('传输完成并通过 SHA256：'+$name+'，耗时 '+[Math]::Round($watch.Elapsed.TotalSeconds,1)+' 秒。')
}
function Assert-Payload {
 $manifest=Get-Content "$root/../f7005/payload/manifest.json" -Raw|ConvertFrom-Json
 foreach($name in @('control.sh','run.sh','service.sh','uuplugin','xuplugin-guardian')){
  $hash=if($name -in @('uuplugin','xuplugin-guardian')){$manifest.$name}else{HashBytes ([IO.File]::ReadAllBytes("$root/$name"))}
  $null=Remote "[ ! -L '$base' ] && [ -f '$base/$name' ] && [ ! -L '$base/$name' ] && echo '$hash  $base/$name' | sha256sum -c -"
 }
}
function Resume-StagedPayload($payload){
 # Only a fully uploaded, unregistered installation is eligible. Never overwrite
 # a running/registered service, private binding, symlink, or unknown file.
 $guard="[ -d '$base' ] && [ ! -L '$base' ]"
 foreach($path in @('etc/init.d/uu-wol-g7615','etc/rc.d/S99uu-wol-g7615','etc/rc.d/K10uu-wol-g7615')){
  $guard+=" && [ ! -e '$framework/$path' ] && [ ! -L '$framework/$path' ]"
 }
 $null=Remote $guard
 $names=($payload.Keys|Sort-Object) -join '|'
 $null=Remote ("for f in '$base'/* '$base'/.[!.]* '$base'/..?*; do [ -e " + '"$f"' + " ] || [ -L " + '"$f"' + " ] || continue; case " + '"${f##*/}"' + " in $names) ;; *) echo UNKNOWN_STAGED_FILE; exit 1;; esac; done")
 $null=Remote 'for f in /proc/[0-9]*/exe; do e=$(readlink "$f" 2>/dev/null) || continue; case "$e" in */uuplugin|*/xuplugin-guardian) echo UU_ALREADY_RUNNING; exit 1;; esac; done'
 $legacy=@{
  'control.sh'='5e9d4fe94d6bfb3332de7c82731b62082409b91974b2d126ee66112a813a457f'
  'run.sh'='977dcd4a45f0d2bdb3a676a7f3ad232af96c5ea581c6246abd4be9ae9ee3dd6a'
  'payload.sha256'='b70e1cd8af0682410b0537925e9fef7c539a3b9df948c3f1fe9303fedfaaed2d'
 }
 $replace=@{}
 # Validate every file before making any changes. Completed binaries are reused.
 foreach($name in ($payload.Keys|Sort-Object)){
  $r=Remote "[ -f '$base/$name' ] && [ ! -L '$base/$name' ] && sha256sum '$base/$name'"
  if($r.Text -notmatch '^([0-9a-f]{64})[ \t]+'){throw "暂存文件校验响应异常：$name"}
  $actual=$Matches[1];$wanted=HashBytes $payload[$name]
  if($actual -ceq $wanted){Write-Host ("校验通过，复用："+$name);continue}
  if(!$legacy.ContainsKey($name) -or $actual -cne $legacy[$name]){throw "暂存文件与已知版本不匹配，未覆盖：$name"}
  $replace[$name]=$actual
 }
 foreach($name in ($replace.Keys|Sort-Object)){
  Upload ($name+'.repair') $payload[$name]
  $old=$replace[$name]
  $null=Remote "[ ! -L '$base/$name' ] && echo '$old  $base/$name' | sha256sum -c - && mv '$base/$name.repair' '$base/$name'"
 }
 Write-Host '已核验并接续上传完成的安装；无需重传 UU 程序。'
}
function Control([string]$operation){
 if((Find-Framework) -cne $framework){throw '框架进程发生变化，请重新检查状态。'}
 Assert-Payload
 return (Remote "/usr/sbin/chroot '$framework' /bin/sh /opt/uu-wol-g7615/control.sh '$operation'" 45000).Text
}
function Show-Status {
 $state=Control status
 foreach($line in ($state -split "`n")){Write-Host $line}
 Write-Host 'UU 云连接：待 UU App 验证'
 Write-Host '日志由 CU 框架管理，可在框架内使用 logread 查看。'
}
try{
 $session=New-Object ZteUuInstaller.TelnetSession($RouterAddress,23,5000)
 $hello=$session.ReadUntil('(?im)(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
 if($hello -match '(?im)(?:login|username)\s*:\s*$'){
  $session.SendLine($Username);$null=$session.ReadUntil('(?im)password\s*:\s*$',15000);$session.SendSecureLine($Password)
  $hello=$session.ReadUntil('(?im)access denied|login incorrect|(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
  if($hello -match '(?im)access denied|login incorrect|(?:login|username)\s*:\s*$'){throw '登录失败'}
 }
 $framework=Find-Framework;$base="$framework/opt/uu-wol-g7615"
 Write-Host 'G7615V2：CU 框架服务；参考固件已收到用户本轮测试及重启测试成功反馈。'
 $absent=Remote "[ ! -e '$base' ] && [ ! -L '$base' ] && [ ! -e '$framework/etc/init.d/uu-wol-g7615' ] && [ ! -L '$framework/etc/init.d/uu-wol-g7615' ] && [ ! -e '$framework/etc/rc.d/S99uu-wol-g7615' ] && [ ! -L '$framework/etc/rc.d/S99uu-wol-g7615' ] && [ ! -e '$framework/etc/rc.d/K10uu-wol-g7615' ] && [ ! -L '$framework/etc/rc.d/K10uu-wol-g7615' ]" -AllowFailure
 if($Action -eq 'Status' -and $absent.Code -eq 0){
  Write-Host '光猫端版本：未安装';Write-Host '服务：未安装';Write-Host '自启：未安装';Write-Host 'UU 云连接：未连接';Write-Host '日志管道：未安装';return
 }
 if($Action -eq 'Install'){
  if($absent.Code -ne 0){Write-Host '检测到已有文件，先核验是否为可接续的未登记安装。'}
  $null=Remote ("/usr/sbin/chroot '$framework' /bin/sh -c " + (ShellLiteral '[ ! -e /var/run/uuplugin.pid ] && [ ! -L /var/run/uuplugin.pid ] && [ ! -e /tmp/uu ] && [ ! -L /tmp/uu ]'))
  # Reuse the already pinned static ARM64 payload, not the F7005 installer.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $manifest=Get-Content "$root/../f7005/payload/manifest.json" -Raw|ConvertFrom-Json
  $jar="$root/../f7005/payload/service.jar"
  if((Get-FileHash $jar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.'service.jar'){throw '内置程序包校验失败'}
  $payload=@{};$zip=[IO.Compression.ZipFile]::OpenRead($jar)
  try{foreach($name in @('uuplugin','xuplugin-guardian')){
   $entry=$zip.GetEntry("payload/$name");if(!$entry -or $entry.Length -gt 8388608){throw '程序包条目异常'}
   $stream=$entry.Open();$mem=New-Object IO.MemoryStream
   try{$stream.CopyTo($mem);$bytes=$mem.ToArray()}finally{$stream.Dispose();$mem.Dispose()}
   if((HashBytes $bytes) -cne $manifest.$name){throw '内置程序校验失败'};$payload[$name]=$bytes
  }}finally{$zip.Dispose()}
  foreach($name in @('control.sh','service.sh','run.sh')){$payload[$name]=[IO.File]::ReadAllBytes("$root/$name")}
  $sums=($payload.Keys|Sort-Object|ForEach-Object{(HashBytes $payload[$_])+'  '+$_}) -join "`n"
  $payload['payload.sha256']=[Text.Encoding]::ASCII.GetBytes($sums+"`n")
  $payload['uu.conf']=[Text.Encoding]::ASCII.GetBytes("log_level=info`nversion=v14.10.6`nlan_ifname=br0`nsn_no_mac_prefix=1`n")
  $payload['managed-v1']=[Text.Encoding]::ASCII.GetBytes("G7615V2 0.1.0-rc1`n")
  # No package-manager calls, remounts, firmware writes or factory file replacement.
  $free=Get-CuFreeKiB
  if($absent.Code -eq 0){
   $null=Remote "umask 077; mkdir '$base'"
   foreach($name in ($payload.Keys|Sort-Object)){Upload $name $payload[$name]}
  }else{Resume-StagedPayload $payload}
  $null=Remote "chmod 700 '$base/uuplugin' '$base/xuplugin-guardian' '$base/run.sh'; /usr/sbin/chroot '$framework' /bin/sh -n /opt/uu-wol-g7615/control.sh"
  $null=Control register
  # Start and verify first. Failure leaves autostart disabled for diagnosis.
  $null=Control start
  $null=Control enable
  Show-Status
  Write-Host '服务已启动并登记自启。请在 UU App 验证绑定、远程开机，再手动重启验证；工具不会自动重启光猫。'
 }else{
  $operation=switch($Action){'Status'{'status'} 'Start'{'start'} 'Stop'{'stop'} 'EnableAutostart'{'enable'} 'DisableAutostart'{'disable'} 'Restore'{'restore'} 'Uninstall'{'uninstall'} 'UninstallFull'{'purge'}}
  $result=Control $operation;if($result){Write-Host $result}
  if($Action -eq 'UninstallFull'){Write-Host '光猫端已卸载 G7615 项目程序、绑定和自启入口。'}
  elseif($Action -eq 'Uninstall'){Write-Host '光猫端已卸载服务；程序及绑定保留，可用“恢复服务”。'}
  elseif($Action -ne 'Status'){Show-Status}
 }
}finally{if($session){$session.Dispose()};if($ownsPassword){$Password.Dispose()}}
