$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../tools/Prompts.ps1')
$path=Join-Path ([IO.Path]::GetTempPath()) ('uu-default-test-'+[Guid]::NewGuid().ToString('N')+'.json')
try {
    [IO.File]::WriteAllText($path, '{"Password":"synthetic-default"}')
    function Read-Host { param($Prompt,[switch]$AsSecureString); $p=New-Object Security.SecureString; foreach($c in $script:typed.ToCharArray()) { $p.AppendChar($c) }; return $p }
    foreach($case in @(@('','synthetic-default'),@('synthetic-custom','synthetic-custom'))) {
        $script:typed=$case[0]
        $p=Read-UuPassword $path
        try { if ([Net.NetworkCredential]::new('', $p).Password -cne $case[1]) { throw 'Password selection failed' } } finally { $p.Dispose() }
    }
    Remove-Item -LiteralPath $path
    $script:typed='synthetic-custom'
    $p=Read-UuPassword $path
    try { if ([Net.NetworkCredential]::new('', $p).Password -cne 'synthetic-custom') { throw 'No-config password failed' } } finally { $p.Dispose() }
    Write-Host 'PASS: Enter default, explicit override, and no-config password prompts'
} finally { if(Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
