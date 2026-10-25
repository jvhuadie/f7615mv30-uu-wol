# Background PowerShell runspace. Credentials are passed as in-process objects,
# never as process arguments, files or UI transcript text.
function Start-UuGuiWorker {
    param([string]$ToolRoot, [string]$Address, [int]$Port,
          [string]$Username, [Security.SecureString]$Password, [bool]$ReadOnly, [string]$Action = '', [string]$BindingArchive='', [bool]$PidOnly=$false)
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $ps = [PowerShell]::Create()
    try {
        $runspace.Open()
        $ps.Runspace = $runspace
        $script = {
            param($Path, $Address, $Port, $User, $Secret, $ReadOnly, $Action, $BindingArchive, $PidOnly)
            $global:LASTEXITCODE = 0
            $mapped = switch($Action){'Check' {'Status'} 'Start' {'ServiceStart'} 'Stop' {'ServiceStop'} default {$Action}}
            & $Path -RouterAddress $Address -Username $User -Password $Secret -Action $mapped -BindingArchive $BindingArchive -PidOnly:$PidOnly
            [PSCustomObject]@{ Kind = 'UuGuiCompletion'; ExitCode = $LASTEXITCODE }
        }
        $null = $ps.AddScript($script.ToString()).AddArgument((Join-Path $ToolRoot 'Manage.ps1')).AddArgument($Address).AddArgument($Port).AddArgument($Username).AddArgument($Password).AddArgument($ReadOnly).AddArgument($Action).AddArgument($BindingArchive).AddArgument($PidOnly)
        $async = $ps.BeginInvoke()
        return [PSCustomObject]@{ PowerShell = $ps; Runspace = $runspace; Async = $async; Password = $Password; SeenInfo = 0 }
    }
    catch { $ps.Dispose(); $runspace.Dispose(); throw }
}
function Receive-UuGuiMessages($Work) {
    while ($Work.SeenInfo -lt $Work.PowerShell.Streams.Information.Count) {
        $record = $Work.PowerShell.Streams.Information[$Work.SeenInfo]
        $Work.SeenInfo++
        [string]$record.MessageData
    }
}
function Complete-UuGuiWorker($Work) {
    try {
        $invokeError=''
        try{$output = @($Work.PowerShell.EndInvoke($Work.Async))}catch{$output=@();$invokeError=$_.Exception.Message}
        $messages = @(Receive-UuGuiMessages $Work)
        $messages += @($Work.PowerShell.Streams.Error | ForEach-Object { '错误：' + $_.ToString() })
        if($invokeError -and !$Work.PowerShell.Streams.Error.Count){$messages += '错误：'+$invokeError}
        $done = @($output | Where-Object { $_.Kind -eq 'UuGuiCompletion' })
        $success = $done.Count -eq 1 -and $done[0].ExitCode -eq 0 -and !$Work.PowerShell.HadErrors
        return [PSCustomObject]@{ Success = $success; Messages = $messages }
    }
    finally {
        $Work.PowerShell.Dispose()
        $Work.Runspace.Dispose()
        $Work.Password.Dispose()
    }
}
