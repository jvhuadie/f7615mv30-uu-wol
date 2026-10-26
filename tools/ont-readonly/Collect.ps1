param([string]$RouterAddress='192.168.1.1',[int]$Port=23,[string]$Username='root',[Security.SecureString]$Password,[Parameter(Mandatory=$true)][string]$OutputDirectory,
 [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._()+ -]{0,63}$')][string]$DeclaredModel='',
 [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._()+ -]{0,63}$')][string]$DeclaredHardware='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'tools/Network.ps1')
. (Join-Path $PSScriptRoot 'tools/Identity.ps1')
function Protect-ProbeText([string]$Value) {
    if($script:redactionPassword){$Value=$Value.Replace($script:redactionPassword,'[输入密码已隐藏]')}
    $Value=$Value.Replace([string][char]0,'')
    $Value=[regex]::Replace($Value,'\x1B\[[0-?]*[ -/]*[@-~]','')
    $Value=[regex]::Replace($Value,'(?im)^.*(?:password|passwd|username|user_name|psk|secret|token|credential|api[_-]?key|access[_-]?key|serial(?:number)?|(?:^|[^\r\na-z])(?:pass|user|login|sn|ssid|bssid|uuid|loid)[ \t]*[:=]|authorization|private.?key|key[0-9]*[ \t]*=).*$','[敏感字段行已隐藏]')
    $Value=[regex]::Replace($Value,'(?i)(?<![a-z0-9+.-])([a-z][a-z0-9+.-]{0,31}://)[^/\s@]+@','$1[凭据已隐藏]@')
    $Value=[regex]::Replace($Value,'(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])','[MAC]')
    $Value=[regex]::Replace($Value,'(?i)\b[0-9a-f]{4}\.[0-9a-f]{12}\b','[BRIDGE_ID]')
    # Preserve dotted versions only in explicit version fields.
    $versionValues=New-Object Collections.Generic.List[string]
    $Value=[regex]::Replace($Value,'(?m)^(?:SOFTWARE_VERSION|FIRMWARE_VERSION_EVIDENCE|DISTRIB_RELEASE|VERSION|VERSION_ID)=["'']?[A-Za-z0-9][A-Za-z0-9._()+ -]{0,95}["'']?\r?$', [Text.RegularExpressions.MatchEvaluator]{param($m)
        $index=$versionValues.Count;$versionValues.Add($m.Value);return "__PROBE_VERSION_FIELD_${index}__"
    })
    $Value=[regex]::Replace($Value,'(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])','[IPv4]')
    # Match a complete address token and validate it; timestamps and init fields
    # can contain colons without being IPv6 addresses.
    $ipv6='(?<![0-9A-Za-z_:.])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*(?:%[A-Za-z0-9_.-]+)?(?![0-9A-Za-z_:.])'
    $Value=[regex]::Replace($Value,$ipv6,[Text.RegularExpressions.MatchEvaluator]{param($m)
        $parsed=$null
        if([Net.IPAddress]::TryParse($m.Value,[ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6){return '[IPv6]'}
        return $m.Value
    },[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $Value=[regex]::Replace($Value,'(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b','[UUID]')
    for($i=0;$i -lt $versionValues.Count;$i++){$Value=$Value.Replace("__PROBE_VERSION_FIELD_${i}__",$versionValues[$i])}
    return $Value
}
function Read-ProbeCommand([string]$Command) {
    $token=[Guid]::NewGuid().ToString('N')
    $start='__PROBE_START_'+$token+'__'; $end='__PROBE_END_'+$token+'__'
    $session.SendLine("echo $start; ( $Command )")
    $session.SendLine('echo '+$end+':$?')
    $pattern='(?m)'+[regex]::Escape($end)+':([0-9]+)\r?\n'
    $raw=$session.ReadUntil($pattern,30000)
    $finish=[regex]::Match($raw,$pattern)
    $begin=[regex]::Match($raw,'(?m)^(?:[^\r\n]{0,80}[#$] )?'+[regex]::Escape($start)+'\r?\n')
    if(!$begin.Success -or $finish.Index -lt $begin.Index){throw '检测响应不完整'}
    $body=$raw.Substring($begin.Index+$begin.Length,$finish.Index-$begin.Index-$begin.Length)
    # Discard only known protocol echo/prompt lines, then redact before retention.
    # Remove the known echoed command only; retain an unterminated output line before it.
    $body=[regex]::Replace($body,'(?:/ # )?echo '+[regex]::Escape($end)+':\$\?\r?\n?','')
    $body=[regex]::Replace($body,'(?m)^/ #\s*$','')
    $body=[regex]::Replace($body,'\r+\n',"`n")
    return [PSCustomObject]@{code=[int]$finish.Groups[1].Value;text=(Protect-ProbeText $body).Trim()}
}
$session=$null; $sections=New-Object Collections.Generic.List[object]
$commands=@();$interruptedGroup=''
$state='FAILED';$failure='';$attempted=0
try {
    if(!(Test-UuLanIPv4 $RouterAddress.Trim())){throw '请填写局域网 IPv4 地址'}
    if($Port -lt 1 -or $Port -gt 65535){throw 'Telnet 端口无效'}
    if($Username -notmatch '^[A-Za-z0-9_.-]{1,32}$'){throw '用户名格式不支持'}
    if(!$Password -or $Password.Length -eq 0){throw '缺少 Telnet 密码'}
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
    try{$script:redactionPassword=[Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)}
    $commands=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'commands.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if(-not ('ZteUuInstaller.TelnetSession' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'tools/TelnetSession.cs')}
    Write-Host '正在连接并登录；不记录密码或登录会话。'
    $session=New-Object ZteUuInstaller.TelnetSession($RouterAddress.Trim(),$Port,5000)
    $reply=$session.ReadUntil('(?im)(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
    if($reply -match '(?im)(?:login|username)\s*:\s*$') {
        $session.SendLine($Username)
        $reply=$session.ReadUntil('(?im)password\s*:\s*$|access denied|login incorrect|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
        if($reply -match '(?im)password\s*:\s*$'){
            $session.SendSecureLine($Password)
            $reply=$session.ReadUntil('(?im)access denied|login incorrect|(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
        }
        if($reply -match '(?im)access denied|login incorrect|(?:login|username)\s*:\s*$'){throw '登录失败；请核对实际用户名和密码，不会自动重试'}
    }
    foreach($cmd in $commands){
        $attempted++
        Write-Host ('['+$attempted+'/'+$commands.Count+'] '+$cmd.title)
        $interruptedGroup=$cmd.id;$clock=[Diagnostics.Stopwatch]::StartNew()
        $r=Read-ProbeCommand $cmd.command
        $warnings=New-Object Collections.Generic.List[string]
        if($r.code -ne 0){$warnings.Add('NONZERO_SHELL_STATUS')}
        if($r.text -match '(?im)not found|no such file|not supported|permission denied|operation not permitted'){$warnings.Add('MISSING_OR_UNREADABLE_ITEMS')}
        if($r.text -match 'ENTRY_LIMIT_REACHED'){$warnings.Add('ENTRY_LIMIT_REACHED')}
        $truncated=$r.text.Length -gt $cmd.outputLimitChars
        if($truncated){$r.text=$r.text.Substring(0,$cmd.outputLimitChars)+"`n[OUTPUT_LIMIT_REACHED]";$warnings.Add('OUTPUT_LIMIT_REACHED')}
        $sections.Add([PSCustomObject]@{id=$cmd.id;title=$cmd.title;exitCode=$r.code;elapsedMs=$clock.ElapsedMilliseconds;warnings=@($warnings.ToArray());truncated=$truncated;scope=$cmd.scope;output=$r.text})
        $interruptedGroup=''
    }
    $state='COMPLETE'
} catch {
    # Only fixed messages are retained; never persist socket responses or login text.
    $failure=if($_.Exception.Message -match '^登录失败'){ '登录失败；请核对实际账号密码。' } elseif($attempted -gt 0){'采集中断或响应超时，保留已完成的部分；未修改设备。'} else {'未能开始采集，请检查局域网地址、Telnet 权限和连接信息。'}
    if($sections.Count -gt 0){$state='PARTIAL'}
} finally {
    if($session){$session.Dispose()}
    $DeclaredModel=Protect-ProbeText $DeclaredModel.Trim();$DeclaredHardware=Protect-ProbeText $DeclaredHardware.Trim()
    $script:redactionPassword=$null
}
# All output below is written on the PC, never on the modem.
$directory=[IO.Path]::GetFullPath($OutputDirectory)
$null=[IO.Directory]::CreateDirectory($directory)
$stamp=[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)
$identity=Get-ProbeIdentity $sections.ToArray() $DeclaredModel $DeclaredHardware
$safeLabel=[regex]::Replace($identity.fileLabel,'[^A-Za-z0-9\u4e00-\u9fff_.-]','_')
$archLabel=if($identity.architecture){$identity.architecture}else{'架构未知'}
$name='ZTE-'+$safeLabel+'-'+$archLabel+'-readonly-'+$stamp
$coverage=[ordered]@{planned=$commands.Count;completed=$sections.Count;interruptedGroup=$interruptedGroup;notCompleted=@($commands | Select-Object -Skip $sections.Count | ForEach-Object {$_.id});warningSections=@($sections | Where-Object {$_.warnings.Count -gt 0}).Count;truncatedSections=@($sections | Where-Object {$_.truncated}).Count;note='COMPLETE 只表示所有分组返回；分组返回码不保证每个子命令成功，未命中和有界输出不证明不存在。'}
$report=[ordered]@{tool='中兴光猫只读检测 v0.6.1';schemaVersion=3;collectedAt=[DateTimeOffset]::Now.ToString('o');status=$state;identity=$identity;coverage=$coverage;note='型号线索与用户填写信息分别保留，待核对机身标签；本工具不判断已兼容、不修改设备。地址及常见敏感字段已自动隐藏，发送前仍请检查。';failure=$failure;attempted=$attempted;sections=@($sections.ToArray())}
$json=ConvertTo-Json -InputObject $report -Depth 8
$lines=New-Object Collections.Generic.List[string]
$lines.Add('中兴光猫只读检测报告 v0.6.1');$lines.Add('状态：'+$state);$lines.Add((Format-ProbeIdentity $identity));$lines.Add('本报告仅含只读采集结果，不代表 UU 已适配；没有安装、上传脚本、重启或修改光猫。')
$lines.Add('未采集账号配置、固件镜像、UU 绑定文件或完整进程命令行。已隐藏常见地址与敏感字段，发送前请自行检查。')
$lines.Add(('采集覆盖：'+$sections.Count+'/'+$commands.Count+'；有提示分组：'+$coverage.warningSections+'；输出截断：'+$coverage.truncatedSections))
$lines.Add($coverage.note)
if($interruptedGroup){$lines.Add('中断分组：'+$interruptedGroup)}
if($failure){$lines.Add($failure)}
foreach($s in $sections){$lines.Add("`r`n===== "+$s.title+'；返回码 '+$s.exitCode+" =====`r`n提示："+($s.warnings -join ', ')+"`r`n"+$s.output)}
$text=[string]::Join("`r`n",$lines)
$zipPath=Join-Path $directory ($name+'.zip')
Add-Type -AssemblyName System.IO.Compression
$stream=New-Object IO.FileStream($zipPath,[IO.FileMode]::CreateNew)
try {
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{
        foreach($pair in @(@('report.txt',$text),@('report.json',$json))){
            $entry=$zip.CreateEntry($pair[0]);$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($true)))
            try{$writer.Write([string]$pair[1])}finally{$writer.Dispose()}
        }
    }finally{$zip.Dispose()}
}finally{$stream.Dispose()}
[IO.File]::WriteAllText((Join-Path $directory ($name+'.txt')),$text,(New-Object Text.UTF8Encoding($true)))
Write-Host ('结果状态：'+$state)
if($failure){Write-Host $failure}
[PSCustomObject]@{Kind='ProbeResult';State=$state;Identity=$identity;IdentitySummary=(Format-ProbeIdentity $identity);Zip=$zipPath;Directory=$directory;Completed=$sections.Count;Total=$commands.Count}
