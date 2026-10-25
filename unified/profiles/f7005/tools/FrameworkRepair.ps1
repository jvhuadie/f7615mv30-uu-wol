# F7005 only; loaded by its guarded backend. Never used by the F7615 profile.
$script:AndlinkOriginal='9e919ac97b6421d20701bc6eccf1f52a6a64fbcf352cfdcb39b2b05a9e16f363'
$script:AndlinkFixed='579c3d851e8e16b81a68f99c74705677be57d69ec49cf4c0e04685e0a68e4936'
function Get-AndlinkState {
 $cmd='count=0; for f in /usr/plugin/bundlecache/bundle*/bundle.info; do [ -f "$f" ] || continue; if [ "$(sed -n 2p "$f")" = file:/usr/plugin/bdl/com.chinamobile.smartgateway.andlink.jar ]; then count=$((count+1)); target=${f%/bundle.info}/version0.0/bundle.jar; fi; done; [ "$count" = 1 ] || exit 1; p="$target"; while [ "$p" != / ]; do [ ! -L "$p" ] || exit 1; p=${p%/*}; [ -n "$p" ] || p=/; done; sha256sum "$target"'
 $value=(Remote $cmd).Text
 if($value -notmatch '^([0-9a-f]{64})  (/usr/plugin/bundlecache/bundle[0-9]{1,6}/version0.0/bundle.jar)$'){throw 'Andlink 登记不唯一、路径异常或不是普通缓存文件'}
 $hash=$Matches[1];$target=$Matches[2]
 if($hash -notin @($script:AndlinkOriginal,$script:AndlinkFixed)){throw '未知 Andlink 版本，不执行自动修复或 UU 安装'}
 return [pscustomobject]@{Target=$target;Hash=$hash;Repaired=($hash -eq $script:AndlinkFixed)}
}
function Test-FrameworkStable {
 param([switch]$Probe)
 $last='';$healthy=$true
 for($i=0;$i -lt 4;$i++){
  if($i){Start-Sleep -Seconds 10}
  $cmd='pid=; count=0; for d in /proc/[0-9]*; do [ "$(readlink "$d/exe" 2>/dev/null)" = /usr/java/bin/java ] || continue; count=$((count+1)); pid=${d##*/}; done; [ "$count" = 1 ] || exit 1; netstat -lntp | grep ":5080" | grep -q "$pid/java" || exit 1; for name in andlink cmccdpi appcore; do count=0; for f in /usr/plugin/bundlecache/bundle*/bundle.info; do [ -f "$f" ] || continue; if [ "$(sed -n 2p "$f")" = "file:/usr/plugin/bdl/com.chinamobile.smartgateway.$name.jar" ]; then [ "$(sed -n 3p "$f")" = 32 ] || exit 1; count=$((count+1)); fi; done; [ "$count" = 1 ] || exit 1; done; set -- $(cat /proc/$pid/stat); shift 21; echo "$pid:$1"'
  $reply=Remote $cmd -AllowFailure
  if($reply.Code -eq 1){$healthy=$false;continue}
  if($reply.Code -ne 0){throw '框架检查命令执行异常，停止，不尝试修复'}
  $sample=$reply.Text
  if($sample -notmatch '^\d+:\d+$'){throw '框架检查响应异常，停止，不尝试修复'}
  if($last -and $last -cne $sample){$healthy=$false}
  $last=$sample
 }
 if(!$healthy){if($Probe){return $false};throw 'Java 框架不稳定或原厂插件未就绪，停止 UU 安装'}
 Write-Host 'Java 进程持续稳定 30 秒、5080 监听及三项原厂插件状态检查通过。'
 if($Probe){return $true}
}
function New-AndlinkPatchedBytes([byte[]]$original) {
 if((HashBytes $original) -ne $script:AndlinkOriginal){throw '原始 JAR 校验不符'}
 $delta=[IO.File]::ReadAllBytes("$root/payload/andlink.delta")
 if((HashBytes $delta) -ne 'b4d7319dfc29c2eaa7d64faef0ab2aef2b8eeda0ee281ae559e3ea006cf66e92'){throw '修复差分校验不符'}
 $stream=New-Object IO.MemoryStream(,$delta);$reader=New-Object IO.BinaryReader($stream);$output=New-Object IO.MemoryStream
 try{
  if([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'F7D1'){throw '差分格式错误'}
  while($true){
   $op=$reader.ReadByte();if($op -eq 2){break}
   if($op -eq 0){$offset=$reader.ReadUInt32();$length=$reader.ReadUInt32();if([long]$offset+$length -gt $original.Length){throw '差分范围异常'};$output.Write($original,$offset,$length)}
   elseif($op -eq 1){$length=$reader.ReadUInt32();if($length -gt 1071971){throw '差分长度异常'};$data=$reader.ReadBytes($length);if($data.Length -ne $length){throw '差分不完整'};$output.Write($data,0,$length)}
   else{throw '未知差分操作'}
   if($output.Length -gt 1071971){throw '修复结果过大'}
  }
  $result=$output.ToArray()
  if($stream.Position -ne $stream.Length -or (HashBytes $result) -ne $script:AndlinkFixed){throw '修复结果 SHA-256 不匹配'}
  return ,$result
 }finally{$reader.Dispose();$stream.Dispose();$output.Dispose()}
}
function Ensure-F7005Framework {
 param([switch]$CheckOnly)
 $state=Get-AndlinkState
 if($state.Repaired){Write-Host 'Andlink 已修复，跳过文件修改和 Java 重启。';Test-FrameworkStable;return}
 Write-Host '检测到原始 Andlink，先只读检查框架运行状态。'
 if(Test-FrameworkStable -Probe){
  $confirmed=Get-AndlinkState
  if($confirmed.Target -cne $state.Target -or $confirmed.Hash -cne $state.Hash){throw '健康检查期间 Andlink 文件状态变化，停止，不修复'}
  Write-Host '原始 Andlink 运行正常，跳过修复，保留原厂 JAR 和 Java 进程。'
  return
 }
 if($CheckOnly){throw '原始 Andlink 运行异常；本次仅检查，未执行修复'}
 Write-Host '原始 Andlink 运行检查未通过，将备份后进入限定版本修复流程。'
 $environmentGuard="echo '7c4cc96aaaafc766d1d0b558672487b3532eae3b2df11111a51160a071455f21  /etc/default/S01userconfig' | sha256sum -c - && echo 'bc17f1505ca85ddbf9acf972b0731ca9b892f4fde5c04f9c803af302f7ca0547  /usr/java/conf/config.properties' | sha256sum -c - && echo '957ea62ed0d97bf0da5a6b7a2f54766f696357df1b22886727e2c9db2c98629e  /usr/java/lib/security/private.policy' | sha256sum -c - && echo '9c38a8ee524e95b09b76b9dc656601502c35d9f4e4c240c543ca7fc134d4021d  /usr/java/security/cpa.txt' | sha256sum -c - && echo '9c38a8ee524e95b09b76b9dc656601502c35d9f4e4c240c543ca7fc134d4021d  /usr/java/conf/cpa.txt' | sha256sum -c - && echo '9e919ac97b6421d20701bc6eccf1f52a6a64fbcf352cfdcb39b2b05a9e16f363  /usr/java/bundle/com.chinamobile.smartgateway.andlink.default.jar' | sha256sum -c -"
 $null=Remote $environmentGuard
 $null=Snapshot 'framework-before-repair' '-C /usr/plugin bundlecache bdl security'
 $local=Join-Path $backupDir 'andlink-original.jar';Download $state.Target $local
 $patched=New-AndlinkPatchedBytes ([IO.File]::ReadAllBytes($local))
 $again=Get-AndlinkState
 if($again.Target -cne $state.Target -or $again.Hash -cne $state.Hash){throw '备份后 Andlink 状态变化，未修复'}
 $repair='/usr/plugin/ont-andlink-auto-'+[Guid]::NewGuid().ToString('N').Substring(0,12)
 $target=$state.Target;$bundle=$target.Substring(0,$target.LastIndexOf('/version0.0/'))
 $null=Remote "[ ! -e '$repair' ] && [ ! -L '$repair' ] && mkdir -m 700 '$repair' && cp -p '$target' '$repair/andlink-original.jar' && cp -p '$bundle/bundle.info' '$repair/bundle.info' && echo '$script:AndlinkOriginal  $repair/andlink-original.jar' | sha256sum -c -"
 $template=[IO.File]::ReadAllText("$root/tools/framework-repair.sh").Replace('@BASE@',$repair).Replace('@TARGET@',$target)
 $rollback=Join-Path $backupDir 'framework-repair.sh';[IO.File]::WriteAllText($rollback,$template,(New-Object Text.UTF8Encoding($false)))
 $receipt="光猫修复备份：$repair`r`n原始 SHA-256：$script:AndlinkOriginal`r`n修复后 SHA-256：$script:AndlinkFixed`r`n独立回退命令：sh $repair/framework-repair.sh rollback`r`n回退会停止当前原厂 Java 进程，由原厂管理程序重启；不改 LAN、权限规则或只读原厂 JAR。UU 若仍安装，请先卸载。`r`n"
 [IO.File]::WriteAllText((Join-Path $backupDir 'Java框架修复回退说明.txt'),$receipt,(New-Object Text.UTF8Encoding($true)))
 Write-Host $receipt
 Upload 'framework-repair.sh' "$repair/framework-repair.sh" ([IO.File]::ReadAllBytes($rollback))
 Upload 'andlink-fixed.jar' "$repair/andlink-fixed.jar" $patched
 $null=Remote "chmod 700 '$repair/framework-repair.sh'; sh -n '$repair/framework-repair.sh'"
 try{
  $null=Remote "sh '$repair/framework-repair.sh' arm"
  Write-Host (Remote "sh '$repair/framework-repair.sh' apply" 60000).Text
  Start-Sleep -Seconds 8
  for($ready=0;$ready -lt 12;$ready++){ $r=Remote 'netstat -lntp | grep -q ":5080"' -AllowFailure; if($r.Code -eq 0){break}; Start-Sleep -Seconds 3 }
  Test-FrameworkStable
  $null=Remote $environmentGuard
  $final=Get-AndlinkState
  if(!$final.Repaired -or $final.Target -cne $target){throw '修复后文件检查失败'}
  $null=Remote "sh '$repair/framework-repair.sh' accept"
  Write-Host 'Andlink 修复验收通过，原件和独立回退脚本已保留。继续 UU 安装。'
 }catch{
  $failure=$_
  try{Write-Host (Remote "sh '$repair/framework-repair.sh' watch-rollback" 45000).Text}catch{Write-Host '未确认即时回退；已设置光猫端超时回退，请按备份目录中的说明检查。'}
  throw $failure
 }
}
