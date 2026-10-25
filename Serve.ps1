param([string]$BindAddress = '', [int]$Port = 18765, [string]$Token = '')
$ErrorActionPreference = 'Stop'
if (!$Token) { $Token = [Guid]::NewGuid().ToString('N') }
if ($Token -notmatch '^[a-zA-Z0-9_-]{16,64}$') { throw 'Invalid token.' }
if (!$BindAddress) {
    $ips = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and !$_.Address.Equals([Net.IPAddress]::Loopback) } |
        ForEach-Object { $_.Address.ToString() })
    $candidates = @($ips | Where-Object { $_ -like '192.168.1.*' })
    if ($candidates.Count -eq 1) { $BindAddress = $candidates[0] }
    else {
        Write-Host ('IPv4 addresses: ' + ($ips -join ', '))
        $BindAddress = Read-Host 'Enter this PC LAN IPv4 address, NOT router 192.168.1.1'
    }
}
if ($BindAddress -ne '127.0.0.1' -and $BindAddress -notmatch '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)') { throw 'Use a private LAN IPv4 address.' }
$ip = [Net.IPAddress]::Parse($BindAddress)
if ($ip.AddressFamily -ne 'InterNetwork') { throw 'IPv4 required.' }
$body = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'install.sh'))
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($sha.ComputeHash($body)).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
$url = "http://${BindAddress}:$Port/$Token/install.sh"
$listener = New-Object Net.Sockets.TcpListener($ip, $Port)
function Read-RequestLine($stream) {
    $buffer = New-Object 'Collections.Generic.List[byte]'
    while ($true) {
        $v = $stream.ReadByte()
        if ($v -lt 0) { throw 'Unexpected end of request.' }
        if ($v -eq 10) { break }
        if ($buffer.Count -ge 8192) { throw 'Header too long.' }
        if ($v -ne 13) { $buffer.Add([byte]$v) }
    }
    return [Text.Encoding]::ASCII.GetString($buffer.ToArray())
}
$listener.Start()
try {
    Write-Host 'UU F7615MV30 installer delivery. No router password is requested on this PC.'
    Write-Host 'If prompted by Windows Firewall, allow Private networks only.'
    Write-Host 'Copy these THREE lines into the router root Telnet window, one at a time:'
    Write-Host "curl -f --connect-timeout 10 --max-time 30 '$url' -o /tmp/uu-f7615-install.sh"
    Write-Host "echo '$hash  /tmp/uu-f7615-install.sh' | sha256sum -c -"
    Write-Host 'sh /tmp/uu-f7615-install.sh'
    Write-Host 'Run the third line ONLY if the second line reports OK.'
    Write-Host 'Keep this PC window open until the first download finishes. Ctrl+C closes the server.'
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    $served = $false
    while (!$served -and [DateTime]::UtcNow -lt $deadline) {
        if (!$listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 15000
        $client.SendTimeout = 30000
        try {
            $stream = $client.GetStream()
            $first = Read-RequestLine $stream
            $n = 0
            while ((Read-RequestLine $stream) -ne '') { if (++$n -gt 64) { throw 'Too many headers.' } }
            if ($first -ceq "GET /$Token/install.sh HTTP/1.1" -or $first -ceq "GET /$Token/install.sh HTTP/1.0") {
                $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($header, 0, $header.Length)
                $stream.Write($body, 0, $body.Length)
                $stream.Flush()
                $served = $true
                Write-Host 'SCRIPT_SENT. Complete checksum and installation in Telnet. This server is now closed.'
            }
            else {
                $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($header, 0, $header.Length)
            }
        }
        catch { Write-Warning $_.Exception.Message }
        finally { $client.Close() }
    }
    if (!$served) { throw 'Timed out. Run Start.cmd again.' }
}
finally { $listener.Stop() }
