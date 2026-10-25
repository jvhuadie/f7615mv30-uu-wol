function Test-UuLanIPv4([string]$Address) {
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $Address = $Address.Trim()
    $parsed = $null
    if (![Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    # Reject abbreviated, hexadecimal or octal IPv4 representations.
    if ($parsed.ToString() -cne $Address) { return $false }
    $octets = $parsed.GetAddressBytes()
    return (
        ($octets[0] -eq 10) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168) -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($Address -ceq '127.0.0.1')
    )
}
