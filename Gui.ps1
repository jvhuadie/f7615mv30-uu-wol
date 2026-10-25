param([switch]$CheckOnly, [string]$PreviewImage = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'tools/Network.ps1')
. (Join-Path $PSScriptRoot 'tools/GuiWorker.ps1')

$script:toolRoot = $PSScriptRoot
$script:work = $null
$script:defaultPassword = ''
$script:warningSeen = $false
$script:lastAction = 'Check'
$script:ink = [Drawing.ColorTranslator]::FromHtml('#172C3C')
$script:muted = [Drawing.ColorTranslator]::FromHtml('#607481')
$script:teal = [Drawing.ColorTranslator]::FromHtml('#087F82')
$script:amber = [Drawing.ColorTranslator]::FromHtml('#966512')
try {
    $defaults = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'defaults.json')) | ConvertFrom-Json
    $script:defaultPassword = [string]$defaults.Password
    $defaults = $null
}
catch { $script:defaultPassword = '' }

function New-Label([string]$Text, [single]$Size = 9.5, [bool]$Bold = $false) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleLeft'
    $label.AutoEllipsis = $true
    $label.ForeColor = $script:ink
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI', $Size, $style)
    return $label
}
function New-Button([string]$Text, [bool]$Primary = $false) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Width = 130
    $button.Height = 40
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderColor = [Drawing.ColorTranslator]::FromHtml('#CBD8DD')
    $button.BackColor = [Drawing.Color]::White
    $button.ForeColor = $script:ink
    $button.Cursor = 'Hand'
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 12, 0)
    if ($Primary) {
        $button.BackColor = $script:teal
        $button.ForeColor = [Drawing.Color]::White
        $button.FlatAppearance.BorderSize = 0
    }
    return $button
}
function Set-Banner([string]$Text, [string]$Kind = 'info') {
    $script:banner.Text = $Text
    $script:banner.ForeColor = switch ($Kind) {
        'error' { [Drawing.Color]::Firebrick }
        'warning' { $script:amber }
        default { $script:teal }
    }
}
function Add-Message([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $script:log.AppendText(('[' + [DateTime]::Now.ToString('HH:mm:ss') + '] ' + $Text + [Environment]::NewLine))
    if ($script:log.TextLength -gt 60000) { $script:log.Text = $script:log.Text.Substring($script:log.TextLength - 45000) }
    $script:log.SelectionStart = $script:log.TextLength
    $script:log.ScrollToCaret()
    if ($Text -match '^光猫端版本：(.+)$') {
        $value = $Matches[1]
        $script:cards.version.Text = if ($value -match '^[0-9.]+$') { 'v' + $value } else { $value }
    }
    if ($Text -match '^服务：(.+)$') { $script:cards.service.Text = $Matches[1] }
    if ($Text -match '^自启：(.+)$') { $script:cards.boot.Text = $Matches[1] }
    if ($Text -match '^UU 云连接：(.+)$') { $script:cards.cloud.Text = $Matches[1] }
    if ($Text -match '^日志管道：(.+)$') {
        $value = $Matches[1]
        $script:cards.log.Text = if ($value -match '/dev/null') { '输出已转向 /dev/null' } elseif ($value -match '^运行中') { '日志管道运行中' } elseif ($value -match '服务已停止') { '服务已停止' } elseif ($value -eq '未安装') { '未安装' } else { '待进一步确认' }
        $script:tips.SetToolTip($script:cards.log, $value)
    }
    if ($Text -match '未确认|未找到|尚未检测到|自启：未启用|入口已改变|状态异常|光猫端未显示') { $script:warningSeen = $true }
}
function Set-Busy([bool]$Busy) {
    $script:address.Enabled = !$Busy
    $script:username.Enabled = !$Busy
    $script:password.Enabled = !$Busy
    $script:port.Enabled = !$Busy
    $script:checkButton.Enabled = !$Busy
    $script:installButton.Enabled = !$Busy -and !$CheckOnly
    $script:resetButton.Enabled = !$Busy
    foreach ($button in $script:manageButtons) { $button.Enabled = !$Busy -and !$CheckOnly }
    $script:progress.Visible = $Busy
}
function Show-UninstallChoice {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = '选择卸载方式'
    $dialog.ClientSize = New-Object Drawing.Size(620, 370)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $dialog.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
    $retain = New-Object Windows.Forms.RadioButton
    $retain.SetBounds(24, 20, 570, 30); $retain.Text = '保留数据（默认，可恢复）'; $retain.Checked = $true
    $keepText = New-Label "停止 UU 并取消自启；保留程序、绑定和备份。`n以后可点击「恢复服务」，沿用原绑定。"
    $keepText.Dock = 'None'; $keepText.SetBounds(46, 54, 550, 54)
    $full = New-Object Windows.Forms.RadioButton
    $full.SetBounds(24, 120, 570, 30); $full.Text = '完全卸载（不保留光猫上的项目数据）'
    $fullText = New-Label "删除本项目程序、绑定、日志及可识别的项目备份。`n电脑上的备份、UU App 中的设备记录保留。`n再次使用需重新安装并绑定；遇到未知备份会拒绝操作。"
    $fullText.Dock = 'None'; $fullText.SetBounds(46, 154, 550, 85)
    $ack = New-Object Windows.Forms.CheckBox
    $ack.SetBounds(24, 250, 575, 30); $ack.Text = '我确认删除光猫上的项目数据，理解完全卸载无法直接恢复。'; $ack.Enabled = $false
    $ok = New-Button '确认卸载'; $ok.SetBounds(324, 310, 130, 40)
    $cancel = New-Button '取消'; $cancel.SetBounds(466, 310, 130, 40)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $full.Add_CheckedChanged({ $ack.Enabled = $full.Checked; $ok.Enabled = !$full.Checked -or $ack.Checked })
    $ack.Add_CheckedChanged({ $ok.Enabled = !$full.Checked -or $ack.Checked })
    $ok.Add_Click({ $dialog.Tag = if ($full.Checked) { 'UninstallFull' } else { 'Uninstall' }; $dialog.DialogResult = [Windows.Forms.DialogResult]::OK })
    $dialog.Controls.AddRange(@($retain, $keepText, $full, $fullText, $ack, $ok, $cancel))
    $dialog.AcceptButton = $cancel; $dialog.CancelButton = $cancel
    try { if ($dialog.ShowDialog($script:form) -eq [Windows.Forms.DialogResult]::OK) { return [string]$dialog.Tag }; return '' }
    finally { $dialog.Dispose() }
}
function Start-Operation([string]$Action = 'Check') {
    if ($script:work) { return }
    if ($CheckOnly -and $Action -ne 'Check') { Set-Banner '只读窗口不执行安装或管理操作。' 'error'; return }
    $hostAddress = $script:address.Text.Trim()
    if (!$hostAddress) { $hostAddress = '192.168.1.1'; $script:address.Text = $hostAddress }
    $user = $script:username.Text.Trim()
    if (!$user) { $user = 'root'; $script:username.Text = $user }
    if (!(Test-UuLanIPv4 $hostAddress)) { Set-Banner '请填写有效的局域网 IPv4 地址。' 'error'; return }
    if ($user -notmatch '^[A-Za-z0-9_.-]{1,32}$') { Set-Banner '用户名格式不支持，请检查输入。' 'error'; return }
    if ($Action -eq 'Uninstall') {
        $Action = Show-UninstallChoice
        if (!$Action) { Set-Banner '已取消，没有连接光猫或执行操作。'; return }
    }
    if ($Action -eq 'Stop') {
        $answer = [Windows.Forms.MessageBox]::Show($script:form, '停止后暂时不能远程开机，自启开关不变。是否停止 UU？', '确认停止', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning, [Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }
    $secret = New-Object Security.SecureString
    $entered = $script:password.Text
    if (!$entered) { $entered = $script:defaultPassword }
    if (!$entered) { $secret.Dispose(); Set-Banner '请输入 Telnet 密码。' 'error'; return }
    foreach ($character in $entered.ToCharArray()) { $secret.AppendChar($character) }
    $secret.MakeReadOnly()
    $entered = $null
    try {
        $script:warningSeen = $false
        foreach ($card in $script:cards.Values) { $card.Text = '正在检查…' }
        Set-Busy $true
        $script:lastAction = $Action
        $labels = @{ Check='检查状态'; Install='安装 / 升级'; EnableAutostart='启用光猫自启'; DisableAutostart='停用光猫自启'; Start='启动服务'; Stop='停止服务'; Uninstall='保留数据卸载'; UninstallFull='完全卸载'; Restore='恢复服务' }
        Add-Message ('开始' + $labels[$Action] + '。')
        Set-Banner '正在连接光猫，请稍候…'
        $script:work = Start-UuGuiWorker -ToolRoot $script:toolRoot -Address $hostAddress -Port ([int]$script:port.Value) -Username $user -Password $secret -ReadOnly ($Action -eq 'Check') -Action $Action
        $script:timer.Start()
    }
    catch {
        $secret.Dispose()
        Set-Busy $false
        Set-Banner '无法启动操作，请检查安装包是否完整。' 'error'
    }
}

$script:form = New-Object Windows.Forms.Form
$script:form.Text = 'ZTE ONT · UU 远程开机助手 · F7615MV30 v0.6.1 实验版'
$script:form.Size = New-Object Drawing.Size(970, 850)
$script:form.MinimumSize = New-Object Drawing.Size(890, 790)
$script:form.StartPosition = 'CenterScreen'
$script:form.AutoScaleMode = 'Dpi'
$script:form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9.5)
$script:form.BackColor = [Drawing.ColorTranslator]::FromHtml('#F4F7F8')
$script:form.Padding = New-Object Windows.Forms.Padding(24)

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 10
foreach ($height in @(46, 30, 118, 32, 48, 90, 92, 42)) {
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height)))
}
$null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 34)))
$script:form.Controls.Add($layout)
$title = New-Label 'ZTE ONT · UU 远程开机助手' 22 $true
$layout.Controls.Add($title, 0, 0)
$subtitle = New-Label 'F7615MV30  ·  单文件工具 v0.6.1 实验版  ·  光猫端管理脚本 v0.3' 9.5
$subtitle.ForeColor = $script:muted
$layout.Controls.Add($subtitle, 0, 1)

$inputs = New-Object Windows.Forms.TableLayoutPanel
$inputs.Dock = 'Fill'
$inputs.BackColor = [Drawing.Color]::White
$inputs.Padding = New-Object Windows.Forms.Padding(14, 10, 14, 10)
$inputs.ColumnCount = 4
$inputs.RowCount = 2
foreach ($spec in @(@('Absolute', 110), @('Percent', 50), @('Absolute', 110), @('Percent', 50))) {
    $null = $inputs.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle($spec[0], $spec[1])))
}
foreach ($i in 1..2) { $null = $inputs.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 50))) }
$script:address = New-Object Windows.Forms.TextBox
$script:address.Text = '192.168.1.1'
$script:address.AccessibleName = '光猫 IP 地址'
$script:username = New-Object Windows.Forms.TextBox
$script:username.Text = 'root'
$script:username.AccessibleName = 'Telnet 用户名'
$script:password = New-Object Windows.Forms.TextBox
$script:password.UseSystemPasswordChar = $true
$script:password.Text = $script:defaultPassword
$script:password.AccessibleName = 'Telnet 密码'
$script:port = New-Object Windows.Forms.NumericUpDown
$script:port.Minimum = 1
$script:port.Maximum = 65535
$script:port.Value = 23
$script:port.AccessibleName = 'Telnet 端口'
foreach ($control in @($script:address, $script:username, $script:password, $script:port)) {
    $control.Dock = 'Fill'
    $control.Margin = New-Object Windows.Forms.Padding(0, 9, 18, 5)
}
$inputs.Controls.Add((New-Label '光猫 IP 地址'), 0, 0)
$inputs.Controls.Add($script:address, 1, 0)
$inputs.Controls.Add((New-Label 'Telnet 用户名'), 2, 0)
$inputs.Controls.Add($script:username, 3, 0)
$inputs.Controls.Add((New-Label 'Telnet 密码'), 0, 1)
$inputs.Controls.Add($script:password, 1, 1)
$inputs.Controls.Add((New-Label 'Telnet 端口'), 2, 1)
$inputs.Controls.Add($script:port, 3, 1)
$layout.Controls.Add($inputs, 0, 2)
$hint = New-Label '默认信息已填入。已安装光猫端 v0.3 的用户，只需点击「检查状态」。' 9
$hint.ForeColor = $script:muted
$layout.Controls.Add($hint, 0, 3)

$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Fill'
$script:checkButton = New-Button '检查状态' $true
$script:installButton = New-Button '安装 / 升级'
$script:resetButton = New-Button '重置连接信息'
$docsButton = New-Button '使用说明'
$copyButton = New-Button '复制记录'
foreach ($button in @($script:checkButton, $script:installButton, $script:resetButton, $docsButton, $copyButton)) { $buttons.Controls.Add($button) }
$script:checkButton.Add_Click({ Start-Operation 'Check' })
$script:installButton.Add_Click({ Start-Operation 'Install' })
$copyButton.Add_Click({
    if ($script:log.TextLength) {
        try { [Windows.Forms.Clipboard]::SetText($script:log.Text); Set-Banner '已复制操作记录，不包含密码输入框。' }
        catch { Set-Banner '剪贴板暂时不可用，请手动选择记录复制。' 'warning' }
    }
})
$script:resetButton.Add_Click({
    $script:address.Text = '192.168.1.1'; $script:username.Text = 'root'
    $script:password.Text = $script:defaultPassword; $script:port.Value = 23
    Set-Banner '已恢复默认连接信息，尚未连接光猫。'
})
$docsButton.Add_Click({
    try { Start-Process -FilePath (Join-Path $script:toolRoot 'INSTALL.txt') }
    catch { Set-Banner '无法打开说明文件，请直接打开安装目录中的 INSTALL.txt。' 'error' }
})
$script:form.AcceptButton = $script:checkButton
$layout.Controls.Add($buttons, 0, 4)

$management = New-Object Windows.Forms.TableLayoutPanel
$management.Dock = 'Fill'; $management.ColumnCount = 1; $management.RowCount = 2
$null = $management.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 30)))
$null = $management.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$management.Controls.Add((New-Label '光猫端服务管理 · 自启针对光猫重启；停用自启不会立即停止 UU。' 9), 0, 0)
$manageFlow = New-Object Windows.Forms.FlowLayoutPanel
$manageFlow.Dock = 'Fill'
$script:manageButtons = @()
foreach ($spec in @(@('EnableAutostart','启用自启'), @('DisableAutostart','停用自启'), @('Start','启动服务'), @('Stop','停止服务'), @('Uninstall','卸载服务'), @('Restore','恢复服务'))) {
    $button = New-Button $spec[1]
    $button.Width = 120; $button.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 0)
    $button.Tag = $spec[0]; $button.Enabled = !$CheckOnly
    $button.Add_Click({ param($sender, $event) Start-Operation ([string]$sender.Tag) })
    if ($spec[0] -eq 'Uninstall') { $button.ForeColor = [Drawing.Color]::Firebrick }
    $script:manageButtons += $button
    $manageFlow.Controls.Add($button)
}
$management.Controls.Add($manageFlow, 0, 1)
$layout.Controls.Add($management, 0, 5)

$cardGrid = New-Object Windows.Forms.TableLayoutPanel
$cardGrid.Dock = 'Fill'
$cardGrid.ColumnCount = 5
$cardGrid.RowCount = 1
$script:cards = @{}
$script:tips = New-Object Windows.Forms.ToolTip
$cardSpecs = @(@('version', '光猫端版本'), @('service', '服务状态'), @('boot', '重启自启'), @('cloud', 'UU 云连接'), @('log', '日志输出'))
for ($i = 0; $i -lt 5; $i++) {
    $null = $cardGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 20)))
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Dock = 'Fill'; $panel.BackColor = [Drawing.Color]::White
    $panel.Padding = New-Object Windows.Forms.Padding(12, 8, 8, 8)
    $panel.Margin = New-Object Windows.Forms.Padding(0, 4, 10, 4)
    $panel.RowCount = 2; $panel.ColumnCount = 1
    $null = $panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 26)))
    $null = $panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $caption = New-Label $cardSpecs[$i][1] 9
    $caption.ForeColor = $script:muted
    $value = New-Label '未检查' 10 $true
    $script:cards[$cardSpecs[$i][0]] = $value
    $panel.Controls.Add($caption, 0, 0); $panel.Controls.Add($value, 0, 1)
    $cardGrid.Controls.Add($panel, $i, 0)
}
$layout.Controls.Add($cardGrid, 0, 6)
$statusRow = New-Object Windows.Forms.TableLayoutPanel
$statusRow.Dock = 'Fill'; $statusRow.ColumnCount = 2
$null = $statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$null = $statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 120)))
$script:banner = New-Label '准备就绪。点击「检查状态」读取当前设备状态。' 9.5
$script:banner.ForeColor = $script:teal
$script:progress = New-Object Windows.Forms.ProgressBar
$script:progress.Style = 'Marquee'; $script:progress.Dock = 'Fill'
$script:progress.Margin = New-Object Windows.Forms.Padding(4, 12, 4, 12)
$script:progress.Visible = $false
$statusRow.Controls.Add($script:banner, 0, 0); $statusRow.Controls.Add($script:progress, 1, 0)
$layout.Controls.Add($statusRow, 0, 7)
$script:log = New-Object Windows.Forms.TextBox
$script:log.Multiline = $true; $script:log.ReadOnly = $true
$script:log.ScrollBars = 'Vertical'; $script:log.Dock = 'Fill'
$script:log.BackColor = [Drawing.Color]::White
$script:log.BorderStyle = 'FixedSingle'
$script:log.AccessibleName = '操作记录'
$layout.Controls.Add($script:log, 0, 8)
$footer = New-Label '检查状态只读取信息；不重启光猫。远程开机效果请在 UU 远程 App 中实际验证。' 8.5
$footer.ForeColor = $script:muted
$layout.Controls.Add($footer, 0, 9)

$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 120
$script:timer.Add_Tick({
    if (!$script:work) { return }
    foreach ($message in @(Receive-UuGuiMessages $script:work)) { Add-Message $message }
    if (!$script:work.Async.IsCompleted) { return }
    $script:timer.Stop()
    try {
        $result = Complete-UuGuiWorker $script:work
        foreach ($message in $result.Messages) { Add-Message $message }
        if ($result.Success) {
            if ($script:lastAction -eq 'Uninstall') { Set-Banner '服务已卸载，绑定文件保留；需要时点击“恢复服务”。' 'warning' }
            elseif ($script:lastAction -eq 'UninstallFull') { Set-Banner '完全卸载完成；再次使用需要重新安装并绑定。' 'warning' }
            elseif ($script:lastAction -eq 'Stop') { Set-Banner '服务已停止；需要远程开机前请重新启动 UU。' 'warning' }
            elseif ($script:lastAction -eq 'DisableAutostart') { Set-Banner '已关闭光猫重启后的自启，未执行服务停止操作。' }
            elseif ($script:warningSeen) { Set-Banner '操作已完成，部分状态需要确认，请查看下方记录。' 'warning' }
            else { Set-Banner '操作已完成，请在 UU App 中确认原设备在线。' }
        }
        else { Set-Banner '操作未完成，请查看记录；连接中断时应先检查状态。' 'error' }
    }
    catch { Set-Banner '操作未完成。请先检查状态，不要重复执行更改。' 'error' }
    finally {
        foreach ($card in $script:cards.Values) { if ($card.Text -eq '正在检查…') { $card.Text = '未确认' } }
        $script:work = $null; Set-Busy $false
    }
})
$script:form.Add_FormClosing({
    param($sender, $event)
    if ($script:work) { $event.Cancel = $true; Set-Banner '操作正在执行，请等待完成后再关闭窗口。' 'warning' }
})
if ($CheckOnly) { $script:installButton.Enabled = $false; $script:form.Text += ' · 只读检查' }
if ($PreviewImage) {
    # Developer layout preview: render this app's own controls; no connection.
    $script:form.Add_Shown({
        $bitmap = New-Object Drawing.Bitmap($script:form.Width, $script:form.Height)
        try {
            $script:form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $script:form.Width, $script:form.Height)))
            $bitmap.Save($PreviewImage, [Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $bitmap.Dispose(); $script:form.Close() }
    })
}
try { $null = $script:form.ShowDialog() }
finally {
    $script:timer.Stop(); $script:timer.Dispose()
    $script:password.Text = ''; $script:defaultPassword = $null
    $script:tips.Dispose(); $script:form.Dispose()
}
