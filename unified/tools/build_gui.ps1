param([string]$OutputPath = '')
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputPath) { $OutputPath = Join-Path $root 'ZteOntUuWol.exe' }
$references = @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll',
    [System.Management.Automation.PowerShell].Assembly.Location)
$files = @('Gui.ps1','Manage.ps1','INSTALL.txt','VALIDATION.txt','tools/Network.ps1','tools/TelnetSession.cs','tools/Profiles.ps1','tools/GuiWorker.ps1','profiles/f7615/Auto.ps1','profiles/f7615/install.sh','profiles/f7615/tools/Network.ps1','profiles/f7615/tools/Prompts.ps1','profiles/f7615/tools/TelnetSession.cs','profiles/f7615/tools/Manage.ps1','profiles/f7615/src/full-uninstall.sh','profiles/f7615/defaults.json','profiles/f7005/Manage.ps1','profiles/f7005/tools/FrameworkRepair.ps1','profiles/f7005/tools/framework-repair.sh','profiles/f7005/payload/andlink.delta','profiles/f7005/control.sh','profiles/f7005/tools/Network.ps1','profiles/f7005/tools/TelnetSession.cs','profiles/f7005/tools/LanFiles.cs','profiles/f7005/payload/service.jar','profiles/f7005/payload/manifest.json','profiles/f7005/payload/cap-uu-set.template','profiles/f7005/payload/cap-pid-set.template','profiles/f7005/payload/cap-get.template','profiles/f7005/payload/cap-remove.template','profiles/f7005/payload/flags-get.template','profiles/f7005/payload/flags-lock.template','profiles/f7005/payload/flags-unlock.template')
$buildRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ZteOntUuWol-build-' + [Guid]::NewGuid().ToString('N'))))
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
        $payload = Join-Path $buildRoot 'ZteOntUuWol.Payload'
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
    if ([IO.Path]::GetDirectoryName($buildRoot) -eq $temp -and [IO.Path]::GetFileName($buildRoot).StartsWith('ZteOntUuWol-build-')) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
}
Write-Output $OutputPath
