$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/Network.ps1')
$cases = @(
    @('192.168.1.1', $true),
    @('192.168.255.254', $true),
    @('10.0.0.1', $true),
    @('10.255.255.254', $true),
    @('172.16.0.1', $true),
    @('172.31.255.254', $true),
    @('127.0.0.1', $true),
    @(' 192.168.1.1 ', $true),
    @('172.15.0.1', $false),
    @('172.32.0.1', $false),
    @('192.167.255.254', $false),
    @('192.169.1.1', $false),
    @('8.8.8.8', $false),
    @('0.0.0.0', $false),
    @('255.255.255.255', $false),
    @('127.0.0.2', $false),
    @('localhost', $false),
    @('example.com', $false),
    @('::1', $false),
    @('fe80::1', $false),
    @('not-an-ip', $false),
    @('192.168.1.999', $false),
    @('', $false),
    @($null, $false),
    @('10.1', $false),
    @('192.168.1', $false),
    @('0xc0.0xa8.1.1', $false),
    @('010.0.0.1', $false),
    @('192.168.001.1', $false),
    @('192.168.1.1;reboot', $false)
)
foreach ($case in $cases) {
    $actual = Test-UuLanIPv4 $case[0]
    if ($actual -ne $case[1]) { throw ('Unexpected IPv4 validation result for: ' + $case[0]) }
}
Write-Output ('PASS: ' + $cases.Count + ' private IPv4 boundary and malformed-input cases')
