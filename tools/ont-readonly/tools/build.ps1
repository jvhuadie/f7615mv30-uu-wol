param([string]$OutputPath = '')
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputPath) {
    $dist = Join-Path $root 'dist'
    $null = [IO.Directory]::CreateDirectory($dist)
    $OutputPath = Join-Path $dist 'ZTE-ONT-readonly-v0.7.2.exe'
}
$references = @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll',
    [System.Management.Automation.PowerShell].Assembly.Location)
$files = @('Gui.ps1','Collect.ps1','commands.json','INSTALL.txt','tools/Network.ps1','tools/Identity.ps1','tools/TelnetSession.cs')
$buildRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('G7615Probe-build-' + [Guid]::NewGuid().ToString('N'))))
$null = [IO.Directory]::CreateDirectory($buildRoot)
try {
    $raw = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter($raw, [Text.Encoding]::UTF8)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('UUW1'))
    $writer.Write([int]$files.Count)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $root $file))
            $writer.Write([string]$file)
            $writer.Write([int]$bytes.Length)
            $writer.Write($sha.ComputeHash($bytes))
            $writer.Write($bytes)
        }
        $writer.Flush()
        $payload = Join-Path $buildRoot 'G7615Probe.Payload'
        $compressed = New-Object IO.MemoryStream
        $gzip = New-Object IO.Compression.GZipStream($compressed, [IO.Compression.CompressionMode]::Compress, $true)
        try { $data=$raw.ToArray(); $gzip.Write($data, 0, $data.Length) }
        finally { $gzip.Dispose() }
        [IO.File]::WriteAllBytes($payload, $compressed.ToArray())
        $compressed.Dispose()
    }
    finally { $sha.Dispose(); $writer.Dispose(); $raw.Dispose() }
    $parameters = New-Object CodeDom.Compiler.CompilerParameters
    $null = $parameters.EmbeddedResources.Add($payload)
    $parameters.ReferencedAssemblies.AddRange($references)
    $parameters.OutputAssembly = $OutputPath
    $parameters.GenerateExecutable = $true
    $parameters.GenerateInMemory = $false
    $parameters.CompilerOptions = '/target:winexe /optimize'
    Add-Type -Path (Join-Path $PSScriptRoot 'GuiLauncher.cs') -CompilerParameters $parameters
}
finally {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($buildRoot) -eq $temp -and [IO.Path]::GetFileName($buildRoot).StartsWith('G7615Probe-build-')) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
}
Write-Output $OutputPath
