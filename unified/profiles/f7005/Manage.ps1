param([ValidateSet('Install','ResumeStaged','Status','Start','Stop','EnableService','Uninstall','UninstallFull','CheckFramework')][string]$Action='Status',
 [string]$RouterAddress='192.168.2.1',[string]$Username='root',[Security.SecureString]$Password,
 [string]$BindingArchive='', [switch]$PidOnly)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$base='/usr/plugin/uu-wol-f7005';$session=$null;$server=$null;$ownedPassword=$false
. "$root/tools/Network.ps1"
. "$root/tools/FrameworkRepair.ps1"
if(!(Test-UuLanIPv4 $RouterAddress) -or $Username -notmatch '^[A-Za-z0-9_.-]{1,32}$'){throw '地址或用户名格式不正确'}
if(!$Password){$Password=Read-Host 'Telnet 密码（回车使用 Zte521）' -AsSecureString;$ownedPassword=$true;if($Password.Length -eq 0){$Password.Dispose();$Password=ConvertTo-SecureString 'Zte521' -AsPlainText -Force}}
if(!('ZteUuInstaller.TelnetSession' -as [type])){Add-Type -Path "$root/tools/TelnetSession.cs"}
if(!('F7005Files' -as [type])){Add-Type -Path "$root/tools/LanFiles.cs"}
function Remote([string]$command,[int]$timeout=30000,[switch]$AllowFailure){
 $id=[Guid]::NewGuid().ToString('N');$start='START_'+$id;$end='END_'+$id
 $session.SendLine("echo '$start'; ( $command ); rc=`$?; echo; echo '${end}:'`$rc")
 $raw=$session.ReadUntil('(?m)^'+$end+':([0-9]+)\r?$', $timeout)
 $begin=[regex]::Match($raw,'(?m)^'+$start+'\r?\n');$finish=[regex]::Match($raw,'(?m)^'+$end+':([0-9]+)\r?$')
 if(!$begin.Success -or !$finish.Success){throw '远端响应不完整，保留现场，不重复安装'}
 $body=$raw.Substring($begin.Index+$begin.Length,$finish.Index-$begin.Index-$begin.Length).Trim();$code=[int]$finish.Groups[1].Value
 if($code -ne 0 -and !$AllowFailure){throw ('远端操作失败，代码 '+$code+'；'+$body)}
 return [pscustomobject]@{Text=$body;Code=$code}
}
function HashBytes([byte[]]$bytes){$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Upload([string]$name,[string]$target,[byte[]]$bytes){
 # Transfer through the existing authenticated connection; no inbound firewall rule.
 if($target -notmatch '^/usr/plugin/(uu-wol-f7005|ont-andlink-auto-[a-f0-9]{12}|bundlecache/bundle[0-9]+/data)/[A-Za-z0-9_.-]+$'){throw '传输目标不符合限制'}
 $part=$target+'.part';$hash=HashBytes $bytes
 $null=Remote "[ ! -e '$part' ] && [ ! -L '$part' ] && [ ! -L '$target' ] && (umask 077; set -C; : > '$part')"
 $nextProgress=0
 for($offset=0;$offset -lt $bytes.Length;$offset+=768){
  $take=[Math]::Min(768,$bytes.Length-$offset);$encoded=New-Object Text.StringBuilder
  for($j=0;$j -lt $take;$j++){$null=$encoded.Append('\').Append([Convert]::ToString($bytes[$offset+$j],8).PadLeft(3,'0'))}
  $null=Remote ("printf '"+$encoded.ToString()+"' >> '$part'")
  if($offset -ge $nextProgress){Write-Host ('传输 '+$name+'：'+[int](100*$offset/$bytes.Length)+'%');$nextProgress+=131072}
 }
 $null=Remote "echo '$hash  $part' | sha256sum -c - && mv '$part' '$target'"
}
function Download([string]$remote,[string]$local){
 $size=[long](Remote ("wc -c < '$remote'")).Text;if($size -le 0 -or $size -gt 25165824){throw '备份大小异常'}
 $before=(Remote ("sha256sum '$remote'")).Text.Split(' ')[0];$out=[IO.File]::Create($local)
 try{for($off=0L;$off -lt $size;$off+=32768){$take=[Math]::Min(32768,$size-$off);$hex=(Remote ("busybox hexdump -v -s $off -n $take -e '1/1 `"%02x`"' '$remote'")).Text;if($hex -notmatch '^[0-9a-f]+$' -or $hex.Length -ne 2*$take){throw '备份传输不完整'};$b=[F7005Files]::Hex($hex);$out.Write($b,0,$b.Length)}}finally{$out.Dispose()}
 $after=(Remote ("sha256sum '$remote'")).Text.Split(' ')[0];if($before -ne $after -or (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant() -ne $before){throw '备份校验失败'}
 Write-Host ('备份已校验：'+$local)
}
function Snapshot([string]$kind,[string]$tarArguments){
 $remote='/tmp/f7005-'+[Guid]::NewGuid().ToString('N')+'.tgz';$local=Join-Path $backupDir ($kind+'.tgz')
 $null=Remote ("umask 077; tar -czf '$remote' $tarArguments")
 Download $remote $local;$null=Remote ("rm '$remote'");return $local
}
function RemoveProjectConfig {
 # Resolve ConfigAdmin by registration, not bundle number. Only run after removal.
 $probe=@'
[ ! -e /usr/plugin/uu-wol-f7005 ] && [ ! -L /usr/plugin/uu-wol-f7005 ] || exit 1
for p in /proc/[0-9]*/exe; do e=$(readlink "$p" 2>/dev/null) || continue; case "$e" in *uuplugin*|*xuplugin-guardian*|*pid-prepare*) exit 1;; esac; done
for f in /usr/plugin/bundlecache/bundle*/bundle.info; do
 [ -f "$f" ] || continue
 case "$(sed -n 2p "$f")" in *uuwol*|*uu-wol*|*lifecycle*) echo PROJECT_REGISTRATION_REMAINS; exit 1;; esac
done
count=0
for f in /usr/plugin/bundlecache/bundle*/bundle.info; do
 [ -f "$f" ] || continue
 [ "$(sed -n 2p "$f")" = file:/usr/java/bundle/org.apache.felix.configadmin-1.8.8.jar ] || continue
 count=$((count+1)); cache=${f%/bundle.info}
done
[ "$count" = 1 ] || exit 1
for kind in uuwol uuwolprobe; do
 d="$cache/data/config/local/ont/$kind/f7005"
 p="$d"; while [ "$p" != / ]; do [ ! -L "$p" ] || exit 1; p=${p%/*}; [ -n "$p" ] || p=/; done
 f="$d/SetMsgConfig.config"
 if [ -e "$f" ] || [ -L "$f" ]; then
  [ -f "$f" ] && [ ! -L "$f" ] || exit 1
  tr -d '\r' < "$f" | grep -q "^service[.]pid=\"local[.]ont[.]$kind[.]f7005[.]SetMsgConfig\"$" || exit 1
  sha256sum "$f" || exit 1
 fi
done
'@
 $probe=(($probe -split '\r?\n') -join '; ') -replace '\b(do|then); ', '$1 '
 $found=(Remote $probe).Text
 if(!$found){Write-Host '项目配置残留检查通过：没有残留。';return}
 $entries=@()
 foreach($line in ($found -split '\r?\n')){
  if($line -notmatch '^([0-9a-f]{64})  (/usr/plugin/bundlecache/bundle[0-9]{1,6}/data/config/local/ont/(uuwol|uuwolprobe)/f7005/SetMsgConfig\.config)$'){throw '配置残留清单异常，未删除'}
  $entries+=@{Hash=$Matches[1];Path=$Matches[2]}
 }
 $args=($entries|ForEach-Object{"'"+$_.Path.Substring(1)+"'"}) -join ' '
 $null=Snapshot 'project-config-before-cleanup' ("-C / "+$args)
 if((Remote $probe).Text -cne $found){throw '备份后配置变化，保留现场，未删除'}
 foreach($entry in $entries){
  $path=$entry.Path;$dir=$path.Substring(0,$path.LastIndexOf('/'));$parent=$dir.Substring(0,$dir.LastIndexOf('/'))
  $null=Remote ("echo '"+$entry.Hash+"  $path' | sha256sum -c - >/dev/null && rm '$path' && { rmdir '$dir' 2>/dev/null || true; } && { rmdir '$parent' 2>/dev/null || true; }")
 }
 if((Remote $probe).Text){throw '配置仍有残留，未宣告清理成功'}
 Write-Host '项目配置缓存已备份并清理；Andlink 修复及备份保持不变。'
}

function Get-F7005InstallState {
 $cmd=@'
b=0; c=0; r=0; p=0; q=0; t=0; x=0
if [ -e /usr/plugin/uu-wol-f7005 ] || [ -L /usr/plugin/uu-wol-f7005 ]; then b=1; fi
if [ -f /usr/plugin/uu-wol-f7005/control.sh ] && [ ! -L /usr/plugin/uu-wol-f7005/control.sh ]; then c=1; fi
for f in /usr/plugin/bundlecache/bundle*/bundle.info; do [ -f "$f" ] || continue; if [ "$(sed -n 2p "$f")" = file:/usr/plugin/uu-wol-f7005/service.jar ]; then r=$((r+1)); fi; done
for f in /proc/[0-9]*/exe; do e=$(readlink "$f" 2>/dev/null) || continue; case "$e" in *uuplugin*|*xuplugin-guardian*|*pid-prepare*) p=1;; esac; done
if [ -e /var/run/uuplugin.pid ] || [ -L /var/run/uuplugin.pid ]; then q=1; fi
if [ -e /tmp/uu ] || [ -L /tmp/uu ]; then t=1; fi
for f in /usr/plugin/bundlecache/bundle*/data/config/local/ont/uuwol/f7005/SetMsgConfig.config /usr/plugin/bundlecache/bundle*/data/config/local/ont/uuwolprobe/f7005/SetMsgConfig.config; do if [ -e "$f" ] || [ -L "$f" ]; then x=1; fi; done
echo "$b:$c:$r:$p:$q:$t:$x"
'@
 $cmd=(($cmd -split '\r?\n') -join '; ') -replace '\b(do|then); ', '$1 '
 $raw=(Remote $cmd).Text
 if($raw -notmatch '^([01]):([01]):([0-9]+):([01]):([01]):([01]):([01])$'){throw '安装状态检查响应异常，不能判断为未安装'}
 if($raw -eq '0:0:0:0:0:0:0'){return 'ABSENT'}
 if($Matches[1] -eq '1' -and $Matches[2] -eq '1' -and $Matches[3] -eq '1'){return 'PRESENT'}
 return 'INCOMPLETE'
}

function FindData{
 $s=(Remote 'for f in /usr/plugin/bundlecache/bundle*/bundle.info; do [ -f "$f" ] || continue; if [ "$(sed -n 2p "$f")" = file:/usr/plugin/uu-wol-f7005/service.jar ]; then echo "${f%/bundle.info}/data"; fi; done').Text
 if($s -notmatch '^/usr/plugin/bundlecache/bundle[0-9]{1,6}/data$'){throw '插件登记位置不唯一或尚未完成'};return $s
}
function PatchCapability([string]$template,[string]$target,[ValidateSet('cap','flags')][string]$kind='cap'){
 if($target -notmatch '^/usr/plugin/bundlecache/bundle[0-9]{1,6}/data/(uuplugin|pid-prepare)$'){throw '授权路径不符合限制'}
 $b=[IO.File]::ReadAllBytes("$root/payload/$kind-$template.template");$tag=[Text.Encoding]::ASCII.GetBytes('__F7005_TARGET_PATH__');$pos=-1
 for($i=0;$i -le $b.Length-$tag.Length;$i++){if($b[$i] -ne $tag[0]){continue};$same=$true;for($j=1;$j -lt $tag.Length;$j++){if($b[$i+$j] -ne $tag[$j]){$same=$false;break}};if($same){if($pos -ne -1){throw '模板标记重复'};$pos=$i}}
 if($pos -lt 0 -or $pos+256 -gt $b.Length){throw '模板标记错误'};[Array]::Clear($b,$pos,256);$v=[Text.Encoding]::ASCII.GetBytes($target);[Array]::Copy($v,0,$b,$pos,$v.Length);return ,$b
}
function ReadBinding([string]$archive){
 # Accept only three small regular files. No links, paths, devices or GNU extensions.
 $input=[IO.File]::OpenRead((Resolve-Path -LiteralPath $archive));$gz=New-Object IO.Compression.GZipStream($input,[IO.Compression.CompressionMode]::Decompress);$mem=New-Object IO.MemoryStream
 try{$buf=New-Object byte[] 4096;while(($n=$gz.Read($buf,0,$buf.Length)) -gt 0){$mem.Write($buf,0,$n);if($mem.Length -gt 65536){throw '绑定备份过大'}};$all=$mem.ToArray()}finally{$gz.Dispose();$input.Dispose();$mem.Dispose()}
 $result=New-Object 'Collections.Generic.Dictionary[string,byte[]]'
 for($off=0;$off+512 -le $all.Length;){if($all[$off] -eq 0){break};$name=[Text.Encoding]::ASCII.GetString($all,$off,100).Trim([char]0);$type=$all[$off+156]
  if($name -notin @('.sn','.uuplugin_uuid','uu.conf') -or $type -notin @(0,48) -or $result.ContainsKey($name)){throw '绑定备份包含不允许的条目'}
  $stored=[Convert]::ToInt32([Text.Encoding]::ASCII.GetString($all,$off+148,8).Trim([char]0,[char]32),8);$sum=0;for($i=0;$i -lt 512;$i++){if($i -ge 148 -and $i -lt 156){$sum+=32}else{$sum+=$all[$off+$i]}};if($sum -ne $stored){throw 'tar 校验错误'}
  $len=[Convert]::ToInt32([Text.Encoding]::ASCII.GetString($all,$off+124,12).Trim([char]0,[char]32),8);if($len -lt 1 -or $len -gt 4096 -or $off+512+$len -gt $all.Length){throw '绑定条目大小错误'}
  $b=New-Object byte[] $len;[Array]::Copy($all,$off+512,$b,0,$len);$result.Add($name,$b);$off+=512+[int]([Math]::Ceiling($len/512.0)*512)
 };if($result.Count -ne 3){throw '绑定备份缺少文件'};return ,$result
}
try{
 $socket=New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Dgram,[Net.Sockets.ProtocolType]::Udp)
 try{$socket.Connect($RouterAddress,23);$localIP=$socket.LocalEndPoint.Address.ToString()}finally{$socket.Dispose()}
 $session=New-Object ZteUuInstaller.TelnetSession($RouterAddress,23,5000)
 $hello=$session.ReadUntil('(?im)(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
 if($hello -match '(?im)(?:login|username)\s*:\s*$'){$session.SendLine($Username);$null=$session.ReadUntil('(?im)password\s*:\s*$',15000);$session.SendSecureLine($Password);$hello=$session.ReadUntil('(?im)access denied|login incorrect|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000);if($hello -match 'access denied|login incorrect'){throw '登录失败'}}
 $guard=(Remote 'id -u; uname -n; uname -m; sha256sum /bin/cspd').Text
 if($guard -notmatch '(?m)^0\r?$' -or $guard -notmatch '(?m)^F7005MV3\r?$' -or $guard -notmatch '(?m)^aarch64\r?$' -or $guard -notmatch '453c47535b274071a5ae83d533d825e5072c8b562857e51eeefa8826953180ed'){throw '仅支持已验证的 F7005MV3 固件，目标不匹配'}
 if($Action -eq 'Status'){
  $installation=Get-F7005InstallState
  if($installation -eq 'ABSENT'){
   Write-Host '光猫端版本：未安装';Write-Host '服务：未安装';Write-Host '自启：未安装';Write-Host 'UU 云连接：未连接';Write-Host '日志管道：未安装'
   Write-Host '已确认没有 UU 安装及相关运行残留，可以点击“安装 / 升级”。';return
  }
  if($installation -eq 'INCOMPLETE'){
   Write-Host '光猫端版本：待检查';Write-Host '服务：安装不完整或有残留';Write-Host '自启：待检查';Write-Host 'UU 云连接：待检查';Write-Host '日志管道：待检查'
   throw '安装目录、插件登记或运行残留不一致，请保留现场；未当作正常未安装'
  }
 }
 if($Action -notin @('Status','CheckFramework')){$backupDir=Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('F7005MV3-UU-WOL/'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6));$null=New-Item -ItemType Directory -Path $backupDir -Force}
 if($Action -eq 'CheckFramework'){ Ensure-F7005Framework -CheckOnly;return }
 if($Action -eq 'UninstallFull'){
  $absent=Remote "[ ! -e '$base' ] && [ ! -L '$base' ]" -AllowFailure
  if($absent.Code -eq 0){RemoveProjectConfig;Write-Host '插件主体已不存在，配置残留检查完成；已有电脑备份未删除。';return}
 }
 if($Action -in @('Install','ResumeStaged')){
  $null=Remote "echo '7c4cc96aaaafc766d1d0b558672487b3532eae3b2df11111a51160a071455f21  /etc/default/S01userconfig' | sha256sum -c -"
  $null=Remote '[ ! -e /var/run/uuplugin.pid ] && [ ! -L /var/run/uuplugin.pid ] && [ ! -e /tmp/uu ] || exit 1; for p in /proc/[0-9]*/exe; do e=$(readlink "$p" 2>/dev/null) || continue; case "$e" in */uuplugin|*/xuplugin-guardian) exit 1;; esac; done'
  if($Action -eq 'Install'){$null=Remote "[ ! -e '$base' ] && [ ! -L '$base' ]"}else{
   $data=FindData;$bundle=$data.Substring(0,$data.Length-5);$jarHash=HashBytes ([IO.File]::ReadAllBytes("$root/payload/service.jar"))
   $null=Remote "[ ! -e '$data/enabled' ] && [ ! -L '$base' ] && [ ! -L '$base/control.sh' ] && grep -q '^state=STAGED$' '$data/temp/status.properties' && echo '$jarHash  $base/service.jar' | sha256sum -c - && echo '$jarHash  $bundle/version0.0/bundle.jar' | sha256sum -c -"
  }
  Ensure-F7005Framework
  $binding=$null;if($BindingArchive){$binding=ReadBinding $BindingArchive}
  $null=Snapshot 'framework-before' '-C /usr/plugin bundlecache bdl security'
  if($Action -eq 'Install'){
   $null=Remote ('mkdir -m 755 '+$base)
   Upload 'service.jar' "$base/service.jar" ([IO.File]::ReadAllBytes("$root/payload/service.jar"))
  }
  Upload 'control.sh' "$base/control.sh" ([IO.File]::ReadAllBytes("$root/control.sh"))
  $null=Remote "chmod 644 $base/service.jar; chmod 700 $base/control.sh; sh -n $base/control.sh"
  if($Action -eq 'Install'){$null=Remote "sendcmd 74 osgidcomm install local.ont.uuwol.f7005 file:$base/service.jar"}
  $data=$null;for($i=0;$i -lt 30;$i++){Start-Sleep -Milliseconds 1000;try{$data=FindData;break}catch{}};if(!$data){throw '登记未完成；保留现场，不重复安装'}
  for($i=0;$i -lt 30;$i++){$r=Remote "[ -f '$data/temp/status.properties' ] && grep -q 'state=STAGED' '$data/temp/status.properties'" -AllowFailure;if($r.Code -eq 0){break};Start-Sleep -Milliseconds 1000};if($r.Code -ne 0){throw '准备阶段未完成'}
  $null=Remote "sh $base/control.sh stop"
  $m=Get-Content "$root/payload/manifest.json" -Raw|ConvertFrom-Json
  foreach($role in @('uu','pid')){$name=if($role -eq 'uu'){'uuplugin'}else{'pid-prepare'};$expected=$m.$name
   $null=Remote "[ ! -L '$data/$name' ] && echo '$expected  $data/$name' | sha256sum -c - && chown 0:0 '$data/$name' && chmod 555 '$data/$name'"
   foreach($mode in @('set','get','remove')){$template=if($mode -eq 'set'){"$role-set"}else{$mode};Upload "$role-$mode" "$base/$role-$mode" (PatchCapability $template "$data/$name");$null=Remote "chmod 700 '$base/$role-$mode'"}
   foreach($mode in @('get','lock','unlock')){Upload "$role-flags-$mode" "$base/$role-flags-$mode" (PatchCapability $mode "$data/$name" 'flags');$null=Remote "chmod 700 '$base/$role-flags-$mode'"}
   $none=Remote "$base/$role-get >/dev/null" -AllowFailure;if($none.Code -ne 61){throw '文件已有未知权限属性，停止'}
   $null=Remote "$base/$role-set"
   $hex=(Remote "$base/$role-get | busybox hexdump -v -e '1/1 `"%02x`"'").Text;$wanted=if($role -eq 'uu'){'0100000200200000000000000000000000000000'}else{'0100000202000000000000000000000000000000'};if($hex -ne $wanted){throw '权限读回不匹配'}
   $null=Remote "$base/$role-flags-lock >/dev/null"
   $flags=[int](Remote "$base/$role-flags-get | busybox hexdump -v -e '1/4 `"%u`"'").Text
   if(($flags -band 16) -eq 0){throw '文件保护未生效，不能保证重启保留授权'}
  }
  if($binding){foreach($name in $binding.Keys){Upload $name "$data/$name" $binding[$name];$null=Remote "chown 58327:0 '$data/$name'; chmod 600 '$data/$name'"}}
  if($PidOnly){$null=Remote ": > '$data/pid-only'; chmod 644 '$data/pid-only'"}
  $null=Remote ": > '$data/enabled'; chmod 644 '$data/enabled'; sh $base/control.sh start"
  Start-Sleep -Seconds 4;$state=(Remote "sh $base/control.sh status").Text;Write-Host $state
  $requiredState=if($PidOnly){'PID_READY'}else{'RUNNING'}
  if($state -notmatch ('(?m)^state='+$requiredState+'\r?$')){throw '插件已登记，但运行验收未通过；请查看状态，必要时卸载回退'}
  Write-Host '候选版已安装。完整重启和远程开机验收仍待完成；不会自动重启光猫。'
 }else{
  $expected=HashBytes ([IO.File]::ReadAllBytes("$root/control.sh"));$null=Remote "echo '$expected  $base/control.sh' | sha256sum -c -"
  $data=FindData
  foreach($role in @('uu','pid')){
   $name=if($role -eq 'uu'){'uuplugin'}else{'pid-prepare'}
   foreach($mode in @('set','get','remove')){$template=if($mode -eq 'set'){"$role-set"}else{$mode};$h=HashBytes (PatchCapability $template "$data/$name");$null=Remote "echo '$h  $base/$role-$mode' | sha256sum -c -"}
   foreach($mode in @('get','lock','unlock')){$h=HashBytes (PatchCapability $mode "$data/$name" 'flags');$null=Remote "echo '$h  $base/$role-flags-$mode' | sha256sum -c -"}
  }
  if($Action -eq 'EnableService'){
   $data=FindData
   $null=Remote "[ -f '$data/pid-only' ] && sh $base/control.sh stop && rm '$data/pid-only' && sh $base/control.sh start" 45000
   Start-Sleep -Seconds 4;Write-Host (Remote "sh $base/control.sh status").Text
  }elseif($Action -in @('Uninstall','UninstallFull')){
   $data=FindData
   if($Action -eq 'Uninstall'){$have=Remote "[ -f '$data/.sn' ] && [ -f '$data/.uuplugin_uuid' ] && [ -f '$data/uu.conf' ]" -AllowFailure;if($have.Code -eq 0){$null=Snapshot 'binding' "-C '$data' .sn .uuplugin_uuid uu.conf"}else{Write-Host '尚无完整绑定资料，跳过绑定备份'}}
   Write-Host (Remote "sh $base/control.sh uninstall" 60000).Text
   $null=Remote "rm $base/service.jar $base/control.sh $base/uu-set $base/uu-get $base/uu-remove $base/pid-set $base/pid-get $base/pid-remove $base/uu-flags-get $base/uu-flags-lock $base/uu-flags-unlock $base/pid-flags-get $base/pid-flags-lock $base/pid-flags-unlock && rmdir $base"
   if($Action -eq 'UninstallFull'){RemoveProjectConfig}
   Write-Host '光猫端已卸载；已有电脑备份未删除。'
  }else{Write-Host (Remote ("sh $base/control.sh "+$Action.ToLowerInvariant())).Text}
 }
}catch{
 Write-Host '操作未完成。请保留现场，不要重复安装；先检查状态，再按使用说明回退。'
 if($backupDir){Write-Host ('本次电脑备份目录：'+$backupDir)}
 throw
}finally{if($session){$session.Dispose()};if($server){$server.Dispose()};if($ownedPassword){$Password.Dispose()}}
