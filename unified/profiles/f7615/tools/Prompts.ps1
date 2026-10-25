function Read-UuPassword([string]$DefaultsPath) {
    $defaults = $null
    if (Test-Path -LiteralPath $DefaultsPath) {
        $defaults = [IO.File]::ReadAllText($DefaultsPath) | ConvertFrom-Json
    }
    $hasDefault = $defaults -and ![string]::IsNullOrEmpty($defaults.Password)
    $prompt = 'Telnet 密码（隐藏输入）'
    if ($hasDefault) { $prompt += ' [回车使用本机默认密码]' }
    $password = Read-Host $prompt -AsSecureString
    if ($password.Length -eq 0 -and $hasDefault) {
        foreach ($character in $defaults.Password.ToCharArray()) {
            $password.AppendChar($character)
        }
    }
    $defaults = $null
    $password.MakeReadOnly()
    return $password
}
