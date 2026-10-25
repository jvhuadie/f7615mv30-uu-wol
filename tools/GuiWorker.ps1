# Background PowerShell runspace. Credentials are passed as in-process objects,
# never as process arguments, files or UI transcript text.
function Start-UuGuiWorker {
    param([string]$ToolRoot, [string]$Address, [int]$Port,
          [string]$Username, [Security.SecureString]$Password, [bool]$ReadOnly, [string]$Action = '')
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $ps = [PowerShell]::Create()
    try {
        $runspace.Open()
        $ps.Runspace = $runspace
        $script = {
            param($Path, $Address, $Port, $User, $Secret, $ReadOnly, $Action)
            $global:LASTEXITCODE = 0
            & $Path -RouterAddress $Address -Port $Port -Username $User -Password $Secret -CheckOnly:$ReadOnly -Action $Action -NonInteractive
            [PSCustomObject]@{ Kind = 'UuGuiCompletion'; ExitCode = $LASTEXITCODE }
        }
        $null = $ps.AddScript($script.ToString()).AddArgument((Join-Path $ToolRoot 'Auto.ps1')).AddArgument($Address).AddArgument($Port).AddArgument($Username).AddArgument($Password).AddArgument($ReadOnly).AddArgument($Action)
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
        $output = @($Work.PowerShell.EndInvoke($Work.Async))
        $messages = @(Receive-UuGuiMessages $Work)
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
