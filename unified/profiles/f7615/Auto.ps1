param(
    [string]$RouterAddress = '',
    [int]$Port = 23,
    [string]$Username = '',
    [Security.SecureString]$Password,
    [switch]$CheckOnly,
    [ValidateSet('', 'Check', 'Install', 'EnableAutostart', 'DisableAutostart', 'Start', 'Stop', 'Uninstall', 'UninstallFull', 'Restore')]
    [string]$Action = '',
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
$session = $null
$ownsPassword = $false
$temporaryScript = $null
. (Join-Path $PSScriptRoot 'tools/Manage.ps1')
function Invoke-RemoteCommand([string]$Command, [int]$TimeoutSeconds = 30) {
    $marker = '__UU_AUTO_' + [Guid]::NewGuid().ToString('N') + '__'
    $session.SendLine($Command)
    $session.SendLine('echo ' + $marker + ':$?')
    $pattern = '(?m)' + [regex]::Escape($marker) + ':([0-9]+)\r?\n'
    $text = $session.ReadUntil($pattern, $TimeoutSeconds * 1000)
    $match = [regex]::Match($text, $pattern)
    return [PSCustomObject]@{ Code = [int]$match.Groups[1].Value; Text = $text }
}
function Send-UuVerifiedScript([string]$RelativePath, [string]$Purpose) {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $RelativePath), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
        if (!$text.EndsWith("`n")) { $text += "`n" }
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $token = [Guid]::NewGuid().ToString('N')
        $temporaryScript = '/tmp/uu-f7615-' + $Purpose + '-' + $token + '.sh'
        $delimiter = 'UU_UPLOAD_' + $token
        Write-Host '正在通过 Telnet 传送操作脚本，无需启动 HTTP 服务……'
        $session.SendLine("umask 077; cat > '$temporaryScript' <<'$delimiter'")
        foreach ($line in $text.Substring(0, $text.Length - 1).Split([char]10)) {
            $session.SendLine($line)
        }
        $session.SendLine($delimiter)
        $uploadMarker = '__UU_UPLOAD_DONE_' + $token + '__'
        $session.SendLine('echo ' + $uploadMarker + ':$?')
        $uploadPattern = '(?m)' + [regex]::Escape($uploadMarker) + ':([0-9]+)\r?\n'
        $uploadResult = $session.ReadUntil($uploadPattern, 60000)
        if ([regex]::Match($uploadResult, $uploadPattern).Groups[1].Value -ne '0') {
            throw '脚本传送失败，未执行脚本。'
        }
        $verified = Invoke-RemoteCommand ("echo '" + $hash + "  " + $temporaryScript + "' | sha256sum -c -")
        if ($verified.Code -ne 0) {
            $null = Invoke-RemoteCommand ("rm -f '" + $temporaryScript + "'")
            $temporaryScript = $null
            throw 'SHA-256 校验失败，未执行脚本。'
        }
        return $temporaryScript
}
function Show-RemoteStatus {
    $state = Invoke-RemoteCommand (Get-UuStateCommand)
    if ($state.Code -ne 0) { throw '无法读取服务安装状态。' }
    $installState = [regex]::Match($state.Text, '(?m)^UU_INSTALL=(MISSING|UNINSTALLED|INSTALLED)\r?$').Groups[1].Value
    $running = [regex]::Match($state.Text, '(?m)^UU_RUNNING=(YES|NO)\r?$').Groups[1].Value
    $autostart = [regex]::Match($state.Text, '(?m)^UU_AUTOSTART=(ENABLED|DISABLED|HOOK_CHANGED)\r?$').Groups[1].Value
    if (!$installState) { throw '服务状态无法确认，请保留现场检查。' }
    if ($installState -ne 'INSTALLED') {
        if ($installState -eq 'UNINSTALLED') {
            $version = [regex]::Match($state.Text, '(?m)^UU_VERSION=([0-9.]+)\r?$')
            if ($version.Success) { Write-Host ('光猫端版本：' + $version.Groups[1].Value) }
            if ($running -ne 'NO') {
                Write-Host '服务：状态异常（存在卸载标记，进程状态未确认）'
                Write-Host '自启：已卸载'
                Write-Host '日志管道：未确认'
                Write-Host 'UU 云连接：未确认'
                return
            }
            Write-Host '服务：已停止（已卸载，保留文件）'
            Write-Host '自启：已卸载'
            Write-Host '日志管道：服务已停止，当前无需日志管道。'
            Write-Host 'UU 云连接：未连接（服务已卸载）'
            Write-Host '绑定文件保留在光猫原安装目录，可点击“恢复服务”重新启用。'
        }
        else {
            Write-Host '光猫端版本：未安装'
            Write-Host '服务：未安装'
            Write-Host '自启：未安装'
            Write-Host '日志管道：未安装'
            Write-Host 'UU 云连接：未连接（未安装）'
        }
        return
    }
    $result = Invoke-RemoteCommand 'sh /usr/plugin/uu-wol-f7615/control.sh status'
    if ($result.Code -ne 0) { throw '无法读取安装状态，请先检查光猫上的安装目录。' }
    $version = [regex]::Match($result.Text, '(?m)^VERSION=([0-9.]+)\r?$')
    if ($version.Success) { Write-Host ('光猫端版本：' + $version.Groups[1].Value) }
    else { Write-Host '光猫端未显示版本号，可能为旧版管理脚本。' }
    if ($running -eq 'YES') { Write-Host '服务：运行中' }
    elseif ($running -eq 'NO') { Write-Host '服务：已停止' }
    else { Write-Host '服务：未确认' -ForegroundColor Yellow }
    if ($autostart -eq 'ENABLED') { Write-Host '自启：已启用' }
    elseif ($autostart -eq 'DISABLED') { Write-Host '自启：已停用' }
    else { Write-Host '自启：入口已改变，请检查' -ForegroundColor Yellow }
    $logger = [regex]::Match($result.Text, 'Log writer PID:\s*([0-9]+)')
    if ($running -eq 'NO') { Write-Host '日志管道：服务已停止，当前无需日志管道。' }
    elseif ($logger.Success) { Write-Host ('日志管道：运行中（PID ' + $logger.Groups[1].Value + '）') }
    else {
        # Inspect only the managed UU executable; a stale PID file is not proof
        # of a live reader. Missing/unreadable descriptors stay unconfirmed.
        $inspectOutput = 'seen=0; other=0; for e in /proc/[0-9]*; do exe=$(readlink "$e/exe" 2>/dev/null) || continue; if [ "$exe" = /usr/plugin/uu-wol-f7615/files/uuplugin ]; then seen=1; for fd in 1 2; do dest=$(readlink "$e/fd/$fd" 2>/dev/null) || dest=UNKNOWN; [ "$dest" = /dev/null ] || other=1; done; fi; done; if [ "$seen" = 0 ]; then echo UU_OUTPUT=NOT_FOUND; elif [ "$other" = 0 ]; then echo UU_OUTPUT=DEV_NULL; else echo UU_OUTPUT=UNCONFIRMED; fi'
        $output = Invoke-RemoteCommand $inspectOutput
        if ($output.Code -eq 0 -and $output.Text -match '(?m)^UU_OUTPUT=DEV_NULL\r?$') {
            Write-Host '日志管道：未运行；UU 标准输出和错误输出均指向 /dev/null，当前不写入管道日志。'
        }
        elseif ($output.Code -eq 0 -and $output.Text -match '(?m)^UU_OUTPUT=NOT_FOUND\r?$') {
            Write-Host '日志管道：未运行；未找到本项目的 UU 主进程，请检查服务状态。' -ForegroundColor Yellow
        }
        else {
            Write-Host '日志管道：未运行；UU 输出去向未确认，请进一步检查。' -ForegroundColor Yellow
        }
    }
    if ($running -eq 'NO') { Write-Host 'UU 云连接：未连接（服务已停止）' }
    elseif ($result.Text -match '(?m)^tcp[^\r\n]*:16000\s+[^\r\n]*ESTABLISHED[^\r\n]*uuplugin') {
        Write-Host 'UU 云连接：已建立'
    }
    else { Write-Host 'UU 云连接：尚未检测到，请稍后运行 Check.cmd 再检查' -ForegroundColor Yellow }
    Write-Host '请在 App 确认原设备在线；远程开机仍需用手机移动数据实际验证。'
}
function Invoke-Management([string]$Operation) {
    $firmware = Invoke-RemoteCommand 'echo "58a5a48a3bfb5bd38209ffa58e3fb5b635623d4a2125799cd8e7e897e3a6a58f  /bin/cspd" | sha256sum -c -'
    if ($firmware.Code -ne 0) { throw '固件指纹不匹配，未执行管理操作。' }
    $guard = Invoke-RemoteCommand (Get-UuManagementGuard)
    if ($guard.Code -ne 0) { throw '不是已验证的 v0.3 管理脚本，或文件已被修改；未执行管理操作。' }
    $state = Invoke-RemoteCommand (Get-UuStateCommand)
    if ($state.Code -ne 0) { throw '无法确认当前安装状态。' }
    $installState = [regex]::Match($state.Text, '(?m)^UU_INSTALL=(MISSING|UNINSTALLED|INSTALLED)\r?$').Groups[1].Value
    if ($installState -eq 'UNINSTALLED' -and $Operation -eq 'Uninstall') { Write-Host '服务已卸载，无需重复操作。'; return }
    if ($installState -eq 'INSTALLED' -and $Operation -eq 'Restore') { Write-Host '服务尚未卸载，无需恢复；已停止时可点击“启动服务”。'; return }
    if ($Operation -eq 'UninstallFull') {
        if ($installState -notin @('INSTALLED', 'UNINSTALLED')) { throw '未找到可识别的项目安装，未执行删除。' }
        $temporaryScript = Send-UuVerifiedScript 'src/full-uninstall.sh' 'full'
        $command = "sh '$temporaryScript' --confirmed-full"
    }
    elseif ($Operation -eq 'Restore') {
        if ($installState -ne 'UNINSTALLED') { throw '没有可恢复的已卸载安装，请先检查状态。' }
        $command = Get-UuRestoreCommand
    }
    else {
        if ($installState -ne 'INSTALLED') { throw '服务未安装或已卸载，请先安装或恢复服务。' }
        $verbs = @{ EnableAutostart = 'enable'; DisableAutostart = 'disable'; Start = 'start'; Stop = 'stop'; Uninstall = 'uninstall' }
        $command = 'sh /usr/plugin/uu-wol-f7615/control.sh ' + $verbs[$Operation]
    }
    $protected = Protect-UuManagementCommand $command
    if ($Operation -eq 'UninstallFull') {
        $protected = "( $protected; UU_FULL_RC=" + '$?' + "; rm -f '$temporaryScript'; exit " + '$UU_FULL_RC' + ' )'
    }
    $result = Invoke-RemoteCommand $protected 120
    if ($result.Code -ne 0) {
        if ($result.Text -match '(?m)^MANAGEMENT_BUSY\r?$') { throw '管理锁存在，可能有操作正在执行或上次异常中断；未重复执行。' }
        if ($result.Text -match '(?m)^HOOK_CHANGED\r?$') { throw '自启入口已被其他程序修改，未覆盖入口。' }
        if ($result.Text -match '(?m)^RESTORE_ROLLED_BACK\r?$') { throw '恢复启动失败，已回退为卸载状态，绑定文件保留。' }
        if ($Operation -eq 'UninstallFull') { throw '完全卸载未完成。预检拒绝时不会停止服务；删除阶段失败时可能已部分清理，请先检查状态，不要重复执行。' }
        throw '管理命令未完成，请先检查状态；不会自动重复执行。'
    }
    if ($Operation -eq 'UninstallFull' -and $result.Text -notmatch '(?m)^FULL_UNINSTALL_COMPLETE\r?$') { throw '未收到完全卸载完成标记，请先检查状态。' }
    $after = Invoke-RemoteCommand (Get-UuStateCommand)
    $checks = switch ($Operation) {
        'EnableAutostart' { @('UU_AUTOSTART=ENABLED') }
        'DisableAutostart' { @('UU_AUTOSTART=DISABLED') }
        'Start' { @('UU_RUNNING=YES') }
        'Stop' { @('UU_RUNNING=NO') }
        'Uninstall' { @('UU_INSTALL=UNINSTALLED', 'UU_RUNNING=NO', 'UU_AUTOSTART=DISABLED') }
        'UninstallFull' { @('UU_INSTALL=MISSING', 'UU_RUNNING=NO', 'UU_AUTOSTART=DISABLED') }
        'Restore' { @('UU_INSTALL=INSTALLED', 'UU_RUNNING=YES', 'UU_AUTOSTART=ENABLED') }
    }
    if ($after.Code -ne 0) { throw '命令已发送，但无法核对结果，请先检查状态。' }
    foreach ($expected in $checks) {
        if ($after.Text -notmatch ('(?m)^' + [regex]::Escape($expected) + '\r?$')) { throw '管理后的状态与预期不一致，请先检查状态；未自动重试。' }
    }
    $messages = @{
        EnableAutostart = '已启用光猫重启后 UU 自启；未执行服务启动。'
        DisableAutostart = '已停用光猫重启后 UU 自启；未执行服务停止。'
        Start = '启动命令已完成，正在读取实际状态。'
        Stop = 'UU 已停止；自启开关保持原样。'
        Uninstall = '服务已卸载，恢复了安装前入口；原程序和绑定文件保留。'
        UninstallFull = '完全卸载完成：光猫上的项目程序、绑定、日志和已识别的项目备份已删除。电脑备份及 App 设备记录保留；再次使用需重新安装和绑定。'
        Restore = '服务已恢复并启用自启，原绑定文件保留。'
    }
    Write-Host $messages[$Operation]
}
try {
    # A GUI host may have no console handle; it reads Information records instead.
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
    Write-Host 'F7615MV30 安装工具 v0.6.1（光猫端管理脚本仍为 v0.3）'
    $effectiveAction = if ($Action) { $Action } elseif ($CheckOnly) { 'Check' } else { 'Install' }
    if ($CheckOnly -and $effectiveAction -ne 'Check') { throw '只读模式不允许安装或管理操作。' }
    if (!$RouterAddress) {
        if ($NonInteractive) { throw '缺少光猫地址。' }
        $RouterAddress = Read-Host '光猫 IP 地址 [192.168.1.1]'
        if ([string]::IsNullOrWhiteSpace($RouterAddress)) { $RouterAddress = '192.168.1.1' }
    }
    . (Join-Path $PSScriptRoot 'tools/Network.ps1')
    $RouterAddress = $RouterAddress.Trim()
    if (!(Test-UuLanIPv4 $RouterAddress)) {
        throw '请填写光猫的局域网 IPv4 地址。'
    }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'Telnet 端口无效。' }
    if (!$Username) {
        if ($NonInteractive) { throw '缺少用户名。' }
        $Username = Read-Host 'Telnet 用户名 [root]'
        if ([string]::IsNullOrWhiteSpace($Username)) { $Username = 'root' }
    }
    if ($Username -notmatch '^[A-Za-z0-9_.-]{1,32}$') { throw '用户名格式不支持。' }
    if (!$Password) {
        if ($NonInteractive) { throw '缺少密码。' }
        . (Join-Path $PSScriptRoot 'tools/Prompts.ps1')
        $Password = Read-UuPassword (Join-Path $PSScriptRoot 'defaults.json')
        $ownsPassword = $true
    }
    if (-not ('ZteUuInstaller.TelnetSession' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'tools/TelnetSession.cs')
    }
    Write-Host '正在连接光猫并登录……'
    $session = New-Object ZteUuInstaller.TelnetSession($RouterAddress, $Port, 5000)
    $loginPattern = '(?im)(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$'
    $prompt = $session.ReadUntil($loginPattern, 15000)
    if ($prompt -match '(?im)(?:login|username)\s*:\s*$') {
        $session.SendLine($Username)
        $reply = $session.ReadUntil('(?im)password\s*:\s*$|access denied|login incorrect|(?:^|\n)[^\n]{0,100}[#$]\s*$', 15000)
        if ($reply -match '(?im)password\s*:\s*$') {
            $session.SendSecureLine($Password)
            $reply = $session.ReadUntil('(?im)access denied|login incorrect|(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$', 15000)
        }
        if ($reply -match '(?im)access denied|login incorrect|(?:login|username)\s*:\s*$') {
            throw '登录失败，请检查用户名和密码；工具不会反复重试。'
        }
    }
    $identity = Invoke-RemoteCommand 'id -u'
    if ($identity.Code -ne 0 -or $identity.Text -notmatch '(?m)^0\r?$') {
        throw '当前账户不是 root，已停止，不会上传或安装。'
    }
    Write-Host 'root 身份确认通过。'
    if ($effectiveAction -eq 'Install') {
        $temporaryScript = Send-UuVerifiedScript 'install.sh' 'auto'
        Write-Host 'SHA-256 校验通过，正在安装或升级；请保持窗口打开……'
        $installed = Invoke-RemoteCommand ("( sh '" + $temporaryScript + "'; UU_AUTO_RC=" + '$?' + "; rm -f '" + $temporaryScript + "'; exit " + '$UU_AUTO_RC' + ' )') 300
        $temporaryScript = $null
        if ($installed.Code -ne 0) {
            if ($installed.Text -match 'Unverified firmware|fingerprint differs') { throw '固件指纹不匹配，安装器已停止。' }
            throw ('安装器返回错误码 ' + $installed.Code + '。请先检查状态；需要详细排查时使用源码包的 Manual.cmd。')
        }
        Write-Host '安装器执行完成，正在核对运行状态……'
    }
    elseif ($effectiveAction -ne 'Check') { Invoke-Management $effectiveAction }
    Show-RemoteStatus
    Write-Host '操作完成。未记录本次输入的密码或远程会话，也未重启光猫。'
}
catch {
    Write-Host ('操作未完成：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '如连接在安装或管理期间中断，结果可能未知，请先检查状态；不要反复执行操作。'
    exit 1
}
finally {
    if ($session) { $session.Dispose() }
    if ($ownsPassword -and $Password) { $Password.Dispose() }
    $Password = $null
}
