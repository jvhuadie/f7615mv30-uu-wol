param([string]$RouterAddress='192.168.1.1',[int]$Port=23,[string]$Username='root',
 [Parameter(Mandatory=$true)][Security.SecureString]$Password,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [ValidateSet('All','Filesystem','Firmware')][string]$Mode='All',
 [ValidateRange(128,65536)][int]$MaxArchiveMiB=8192,
 [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/tools/Network.ps1"
$session=$null;$items=New-Object Collections.Generic.List[object]
$state='FAILED';$failure='';$directory='';$model='';$arch='';$mounts='';$mtd='';$activeItem=$null
function Read-BackupValue([string]$Command,[int]$Timeout=30000){
    $CancellationToken.ThrowIfCancellationRequested()
    $token=[Guid]::NewGuid().ToString('N');$start='__BACKUP_START_'+$token+'__';$end='__BACKUP_END_'+$token+'__'
    $session.SendLine("echo $start; ( $Command ); rc=`$?; echo; echo ${end}:`$rc")
    $raw=$session.ReadUntilCancelable('(?m)^'+$end+':([0-9]+)\r*\n',$Timeout,$CancellationToken)
    $begin=[regex]::Match($raw,'(?m)^(?:[^\r\n]{0,80}[#$] )?'+$start+'\r*\n')
    $finish=[regex]::Match($raw,'(?m)^'+$end+':([0-9]+)\r*\n')
    if(!$begin.Success -or !$finish.Success -or $finish.Groups[1].Value -ne '0'){throw 'BACKUP_READ_FAILED'}
    return [regex]::Replace($raw.Substring($begin.Index+$begin.Length,$finish.Index-$begin.Index-$begin.Length),'\r+\n',"`n").Trim()
}
function Receive-BackupItem([string]$SourceCommand,[string]$Name,[long]$Limit,[long]$Expected=-1){
    $CancellationToken.ThrowIfCancellationRequested()
    $active=[ordered]@{name=$Name;state='TRANSFERRING';bytes=0;sha256='';remoteSha256='';sourceExitCode=$null;readExitCode=$null;expectedBytes=$Expected;note=''}
    $script:activeItem=$active;$items.Add($active)
    $token=[Guid]::NewGuid().ToString('N');$start='__DATA_START_'+$token+'__'
    # Source errors are represented by a separate status, not mixed with binary data.
    $cmd="echo $start; ( $SourceCommand 2>/dev/null; rc=`$?; printf '\n__SOURCE_RC_${token}:%s\n' `"`$rc`" >&2 ) | busybox hexdump -v -e '32/1 `"%02x`" `"\n`"'; rc=`$?; printf '\n__READ_RC_${token}:%s\n__DATA_END_${token}__\n' `"`$rc`""
    Write-Host ('正在导出：'+$Name+'；可点击「取消备份」停止，已收到的数据保留为 .partial。')
    $session.SendLine($cmd)
    $null=$session.ReadUntilCancelable('(?m)^(?:[^\r\n]{0,80}[#$] )?'+$start+'\r*\n',30000,$CancellationToken)
    $part=Join-Path $directory ($Name+'.partial')
    $progress=[Action[long]]{param($bytes) Write-Host ('已接收 '+[Math]::Round($bytes/1MB,1)+' MiB；正在继续传输。')}
    $result=$session.ReceiveHexFile($part,$token,$Limit,120000,$CancellationToken,$progress)
    $active.bytes=$result.Bytes;$active.sha256=$result.Sha256
    $active.sourceExitCode=$result.SourceExitCode;$active.readExitCode=$result.ReadExitCode
    if($result.SourceExitCode -ne 0 -or $result.ReadExitCode -ne 0){$active.state='PARTIAL';$active.note='读取命令异常，或文件在打包时变化；不是完整备份。';return $active}
    if($Expected -ge 0 -and $result.Bytes -ne $Expected){$active.state='PARTIAL';$active.note='实际读取大小与块设备声明大小不符。';return $active}
    if($result.Bytes -eq 0){$active.state='PARTIAL';$active.note='没有收到数据。';return $active}
    $active.state='RECEIVED'
    return $active
}
try{
    if(!(Test-UuLanIPv4 $RouterAddress.Trim()) -or $Port -lt 1 -or $Port -gt 65535 -or $Username -notmatch '^[A-Za-z0-9_.-]{1,32}$' -or !$Password.Length){throw 'INVALID_CONNECTION'}
    $base=[IO.Path]::GetFullPath($OutputDirectory);$null=[IO.Directory]::CreateDirectory($base)
    $directory=Join-Path $base ('PRIVATE-full-backup-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))
    $null=[IO.Directory]::CreateDirectory($directory)
    if(!('ZteUuInstaller.TelnetSession' -as [type])){Add-Type -Path @("$PSScriptRoot/tools/TelnetSession.cs","$PSScriptRoot/tools/BackupTransfer.cs")}
    $session=New-Object ZteUuInstaller.TelnetSession($RouterAddress.Trim(),$Port,5000)
    $reply=$session.ReadUntilCancelable('(?im)(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000,$CancellationToken)
    if($reply -match '(?im)(?:login|username)\s*:\s*$'){
        $session.SendLine($Username)
        $null=$session.ReadUntilCancelable('(?im)password\s*:\s*$',15000,$CancellationToken)
        $session.SendSecureLine($Password)
        $reply=$session.ReadUntilCancelable('(?im)access denied|login incorrect|(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000,$CancellationToken)
        if($reply -match '(?im)access denied|login incorrect|(?:login|username)\s*:\s*$'){throw 'LOGIN_FAILED'}
    }
    if((Read-BackupValue 'id -u') -cne '0'){throw 'ROOT_REQUIRED'}
    $model=Read-BackupValue 'uname -n';$arch=Read-BackupValue 'uname -m'
    $mounts=Read-BackupValue 'cat /proc/mounts'
    $applets=Read-BackupValue 'busybox --list'
    if($applets -notmatch '(?m)^hexdump$'){throw 'HEXDUMP_REQUIRED'}
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($directory))
    if($drive.AvailableFreeSpace -lt 128MB){throw 'DISK_SPACE_REQUIRED'}
    if($Mode -in @('All','Filesystem')){
        $help=Read-BackupValue 'tar --help 2>&1 || true'
        if($help -notmatch '--exclude' -or $help -notmatch '(?m)-C|\s-C\s'){throw 'TAR_OPTIONS_REQUIRED'}
        $exclude=New-Object Collections.Generic.List[string]
        foreach($p in @('/proc','/sys','/dev','/run','/tmp','/mnt','/media','/upgtempfile','/usr/cpkTmp','/CuInform/tmp')){$exclude.Add($p)}
        foreach($line in ($mounts -split "`n")){
            $fields=$line -split '\s+'
            if($fields.Length -ge 3 -and $fields[2] -in @('proc','sysfs','tmpfs','devtmpfs','devpts','cgroup','cgroup2','debugfs','tracefs','securityfs','configfs','pstore','mqueue','hugetlbfs','fusectl','usbfs','rpc_pipefs')){
                $p=$fields[1].Replace('\040',' ')
                if($p -ceq '/'){throw 'VOLATILE_ROOT_UNSUPPORTED'}
                if($p -notmatch '^/[A-Za-z0-9_./+ -]{1,200}$'){throw 'MOUNT_PATH_UNSUPPORTED'}
                if(!$exclude.Contains($p)){$exclude.Add($p)}
            }
        }
        $arguments=@($exclude | ForEach-Object {"--exclude='."+$_+"'"}) -join ' '
        $command='tar -c -f - -C / '+$arguments+' .'
        $item=Receive-BackupItem $command 'filesystem.tar' ([long]$MaxArchiveMiB*1MB)
        $item.note+=' 归档包含可见的持久化文件和敏感配置；排除虚拟/运行时目录与外接介质。不跟随符号链接，无文件系统冻结或一致性快照。'
        if($item.state -eq 'RECEIVED'){
            Move-Item -LiteralPath (Join-Path $directory 'filesystem.tar.partial') -Destination (Join-Path $directory 'filesystem.tar')
            $item.state='COMPLETE_UNSNAPSHOTTED'
        }
        [IO.File]::WriteAllText((Join-Path $directory 'filesystem-excludes.json'),(ConvertTo-Json -InputObject @($exclude.ToArray())),(New-Object Text.UTF8Encoding($false)))
    }
    if($Mode -in @('All','Firmware')){
        $devices=New-Object Collections.Generic.List[object]
        $mtd=Read-BackupValue 'if [ -r /proc/mtd ]; then cat /proc/mtd; fi'
        foreach($line in ($mtd -split "`n")){
            if($line -match '^mtd([0-9]+):\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+"([^"]*)"\s*$'){
                $devices.Add([pscustomobject]@{path=('/dev/mtdblock'+$Matches[1]);name=$Matches[3];bytes=[Convert]::ToInt64($Matches[2],16)})
            }
        }
        if($devices.Count -eq 0){
            $emmc=Read-BackupValue 'for d in /sys/block/mmcblk*; do [ -f "$d/size" ] || continue; echo "${d##*/} $(cat "$d/size")"; done'
            foreach($line in ($emmc -split "`n")){
                if($line -match '^(mmcblk[0-9]+(?:boot[01])?)\s+([0-9]+)$'){$devices.Add([pscustomobject]@{path=('/dev/'+$Matches[1]);name=$Matches[1];bytes=([long]$Matches[2]*512)})}
            }
        }
        if($devices.Count -eq 0){throw 'NO_SUPPORTED_FLASH_DEVICE'}
        $whole=@($devices | Where-Object {$_.name -match '^(?i:whole[ _-]*(?:flash|nand)|full[ _-]*(?:flash|nand)|all)$'})
        $largest=($devices | Measure-Object -Property bytes -Maximum).Maximum
        $selected=if($whole.Count -eq 1 -and $whole[0].bytes -ge $largest){@($whole[0])}else{@($devices.ToArray())}
        $required=($selected | Measure-Object -Property bytes -Sum).Sum
        if($required -gt 64GB -or $drive.AvailableFreeSpace -lt ($required+128MB)){throw 'FIRMWARE_SIZE_OR_DISK_LIMIT'}
        [IO.File]::WriteAllText((Join-Path $directory 'flash-layout.json'),(ConvertTo-Json -InputObject @{discovered=@($devices.ToArray());selected=@($selected)} -Depth 6),(New-Object Text.UTF8Encoding($false)))
        foreach($device in $selected){
            $name=($device.path -split '/')[-1]+'.img'
            $item=Receive-BackupItem ('cat '+$device.path) $name $device.bytes $device.bytes
            $item.note='逻辑块设备原始读取；不含 NAND OOB/ECC 或 eMMC RPMB，不是厂商升级包；运行中分区可能变化。'
            if($item.state -eq 'RECEIVED'){
                Write-Host ('正在校验设备端 SHA-256：'+$name)
                $hashTimeout=[int][Math]::Min(3600000,[Math]::Max(120000,[Math]::Ceiling($device.bytes/1MB)*2000))
                $remote=Read-BackupValue ('sha256sum '+$device.path) $hashTimeout
                if($remote -notmatch '^([0-9a-fA-F]{64})\s+'){$item.state='PARTIAL';$item.note+=' 设备端指纹无法确认。'}
                else{
                    $item.remoteSha256=$Matches[1].ToLowerInvariant()
                    if($item.remoteSha256 -cne $item.sha256){$item.state='PARTIAL';$item.note+=' 与导出后设备指纹不同，可能发生源变化；保留 .partial。'}
                    else{
                        Move-Item -LiteralPath (Join-Path $directory ($name+'.partial')) -Destination (Join-Path $directory $name)
                        $item.state='COMPLETE_HASH_VERIFIED'
                    }
                }
            }
        }
    }
    $state=if(@($items | Where-Object {$_.state -notlike 'COMPLETE_*'}).Count -eq 0 -and $items.Count -gt 0){'COMPLETE'}else{'PARTIAL'}
}catch{
    $state=if($CancellationToken.IsCancellationRequested){'CANCELLED'}elseif($items.Count -gt 0){'PARTIAL'}else{'FAILED'}
    # Never store raw socket responses, exception strings, login data or credentials.
    $known=@('ROOT_REQUIRED','HEXDUMP_REQUIRED','TAR_OPTIONS_REQUIRED','VOLATILE_ROOT_UNSUPPORTED','MOUNT_PATH_UNSUPPORTED','NO_SUPPORTED_FLASH_DEVICE','DISK_SPACE_REQUIRED','FIRMWARE_SIZE_OR_DISK_LIMIT','LOGIN_FAILED')
    $failure=if($_.Exception.Message -in $known){$_.Exception.Message}elseif($state -eq 'CANCELLED'){'用户取消；已收到的部分保留。'}else{'导出未完成：连接、读取、大小限制、磁盘或协议校验失败；仅保留已收到的数据。'}
    if($activeItem -and $activeItem.state -in @('TRANSFERRING','RECEIVED')){$activeItem.state='PARTIAL';$activeItem.note+=' 导出或校验中断。'}
}finally{
    if($session){$session.Dispose()}
    if($directory -and [IO.Directory]::Exists($directory)){
        foreach($item in $items){
            $part=Join-Path $directory ($item.name+'.partial')
            if(Test-Path -LiteralPath $part){
                $item.bytes=(Get-Item -LiteralPath $part).Length
                $file=[IO.File]::OpenRead($part);$hash=[Security.Cryptography.SHA256]::Create()
                try{$item.sha256=[BitConverter]::ToString($hash.ComputeHash($file)).Replace('-','').ToLowerInvariant()}finally{$file.Dispose();$hash.Dispose()}
            }
        }
        $manifest=[ordered]@{tool='中兴光猫完整备份 v0.6';privateBackup=$true;collectedAt=[DateTimeOffset]::Now.ToString('o');mode=$Mode;state=$state;model=$model;architecture=$arch;failure=$failure;items=@($items.ToArray());note='含未脱敏配置、账号、密钥或绑定资料，仅保存本机。运行中读取无一致性快照；不代表可直接刷回。';mounts=$mounts;mtd=$mtd}
        [IO.File]::WriteAllText((Join-Path $directory 'backup-manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 8),(New-Object Text.UTF8Encoding($false)))
        $summary="私有完整备份：$state`r`n模式：$Mode`r`n$failure`r`n包含未脱敏敏感资料，请勿上传到公开仓库、Issue 或适配资料收集页面。`r`n详见 backup-manifest.json；.partial 均是不完整或校验未通过的数据，不可作为完整映像。`r`n运行中读取不保证一致性，也不包含 NAND OOB/ECC、eMMC RPMB 等硬件特殊区域。`r`n"
        [IO.File]::WriteAllText((Join-Path $directory '请勿上传-备份说明.txt'),$summary,(New-Object Text.UTF8Encoding($true)))
    }
}
[pscustomobject]@{Kind='BackupResult';State=$state;PrivateBackup=$true;Directory=$directory;Summary=$summary;Completed=@($items | Where-Object {$_.state -like 'COMPLETE_*'}).Count;Total=$items.Count}
