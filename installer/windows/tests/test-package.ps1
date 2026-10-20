#requires -Version 5.1
# Real hidden files and ZIP extraction, with synthetic images; never run device tools.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$templates = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $templates 'recovery-installer.psm1') -Force
Import-Module (Join-Path $templates 'package-layout.psm1') -Force
$module = Get-Module 'recovery-installer'
$script:Passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Pass([string]$Message) { $script:Passed++; Write-Host ('PASS: ' + $Message) }
function Assert-IntegrityFailure([string]$Root, [string]$Expected) {
    $failure = ''
    try { & $module { param($path) Assert-PackageIntegrity $path } $Root | Out-Null }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like $Expected) ('Unexpected integrity outcome: ' + $failure)
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('android-dev-package-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $root = Join-Path $temporary 'portable fixture'
    New-Item -ItemType Directory -Path $root | Out-Null
    $names = @(& $module { Get-RequiredPackageFiles })
    foreach ($name in $names) {
        $path = Join-Path $root $name
        $parent = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
        if ($name.EndsWith('.img')) {
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            try {
                $stream.SetLength(104857600)
                $header = New-Object byte[] 44
                [Text.Encoding]::ASCII.GetBytes('ANDROID!').CopyTo($header, 0)
                [BitConverter]::GetBytes([uint32]4).CopyTo($header, 40)
                $stream.Write($header, 0, $header.Length)
            } finally { $stream.Dispose() }
        } elseif ($name -ceq 'platform-tools/source.properties') {
            [IO.File]::WriteAllText($path, "Pkg.Revision=36.0.2`n")
        } else { [IO.File]::WriteAllText($path, 'Not executable: synthetic offline package ' + $name) }
    }
    $records = @()
    foreach ($name in $names) {
        $path = Join-Path $root $name
        $records += @{ path = $name; bytes = (Get-Item -LiteralPath $path -Force).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $metadata = @{
        schema_version = 2; device = @{ product = 'popsicle' }
        partition_size_bytes = 104857600; platform_tools_version = '36.0.2'; files = $records
    }
    $metadataPath = Join-Path $root 'metadata.json'
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    Set-InstallerPackageVisibility $root
    $visible = @(Get-ChildItem -LiteralPath $root | Sort-Object Name | ForEach-Object { $_.Name })
    Assert-True (($visible -join ',') -ceq 'flash.cmd,recovery.img') 'Package has unexpected visible root entries.'
    $package = & $module { param($path) Assert-PackageIntegrity $path } $root
    Assert-True ($package.OrangeFox -ceq (Join-Path $root 'recovery.img')) 'Package selected an arbitrary image path.'
    Assert-True (@($names | Where-Object { $_ -like '*.img' }).Count -eq 1) 'Package must contain exactly one recovery image.'
    Pass 'single-image package exposes two files and validates every real Hidden payload'

    $process = & $module { param($path) New-DeviceProcess $path 'fastboot' @('-s', 'MOCK123', 'devices') } $root
    try { Assert-True ($process.StartInfo.FileName -ceq (Join-Path $root 'platform-tools/fastboot.exe')) 'Package changed the checked bundled executable path.' }
    finally { $process.Dispose() }
    Pass 'hidden bundled tool resolves without starting a native process'

    $loaderRoot = Join-Path $temporary 'hidden-loader'
    New-Item -ItemType Directory -Path $loaderRoot | Out-Null
    $loaderModule = Join-Path $loaderRoot 'recovery-installer.psm1'
    Copy-Item -LiteralPath (Join-Path $templates 'recovery-installer.psm1') -Destination $loaderModule
    $loaderScript = Join-Path $loaderRoot 'load.ps1'
    [IO.File]::WriteAllText($loaderScript, @'
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'recovery-installer.psm1') -Force
if (-not (Get-Command Invoke-RecoveryInstaller -ErrorAction Stop)) { throw 'Missing runtime entry point.' }
Write-Output 'HIDDEN_RUNTIME_LOADED'
'@)
    [IO.File]::SetAttributes($loaderScript, [IO.FileAttributes]::Hidden)
    [IO.File]::SetAttributes($loaderModule, [IO.FileAttributes]::Hidden)
    $loaderHost = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $loaderHost)) { $loaderHost = Join-Path $PSHOME 'pwsh.exe' }
    $loaderOutput = & $loaderHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $loaderScript 2>&1
    Assert-True ($LASTEXITCODE -eq 0 -and ($loaderOutput -join "`n") -like '*HIDDEN_RUNTIME_LOADED*') 'Hidden PowerShell -File/module loading failed.'
    Pass 'actual PowerShell host can load Hidden script and runtime module without device calls'

    foreach ($schema in @(1, 99)) {
        $metadata.schema_version = $schema
        $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8 -Force
        Assert-IntegrityFailure $root '*Unsupported package metadata*'
    }
    $metadata.schema_version = 2
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8 -Force
    Pass 'legacy and unknown package schemas are rejected'

    $hiddenRuntime = Join-Path $root 'install-recovery.ps1'
    [IO.File]::AppendAllText($hiddenRuntime, 'tampered')
    Assert-IntegrityFailure $root '*SHA256/size validation failed: install-recovery.ps1*'
    [IO.File]::SetAttributes($hiddenRuntime, [IO.FileAttributes]::Normal)
    [IO.File]::WriteAllText($hiddenRuntime, 'Not executable: synthetic offline package install-recovery.ps1')
    [IO.File]::SetAttributes($hiddenRuntime, [IO.FileAttributes]::Hidden)
    Pass 'Hidden runtime tampering is rejected before any device command'

    $zip = Join-Path $temporary 'portable fixture.zip'
    $archiveFiles = $names + @('metadata.json')
    New-InstallerPackageArchive -PackageRoot $root -Files $archiveFiles -DestinationPath $zip
    $zipStream = [IO.File]::OpenRead($zip)
    $zipArchive = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        $payloadNames = @($zipArchive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName })
        Assert-True (@($payloadNames | Where-Object { $_ -match '(?i)\.md$|README|TWRP|restore' }).Count -eq 0) 'ZIP contains documentation or another recovery payload.'
        Assert-True (@($payloadNames | Where-Object { $_ -like '*.img' }).Count -eq 1) 'ZIP must contain exactly one image.'
        Assert-True (@($payloadNames | Where-Object { $_ -like '*/platform-tools/NOTICE.txt' }).Count -eq 1) 'ZIP lost required tool notices.'
    } finally { $zipArchive.Dispose(); $zipStream.Dispose() }
    Pass 'allowlist ZIP verifies all hashes/attributes and contains one image, tool notices and no documentation or restore payload'

    $badZip = Join-Path $temporary 'must-not-exist.zip'
    foreach ($badFiles in @(@('flash.cmd', '../outside'), @('flash.cmd', 'flash.cmd'))) {
        $failure = ''
        try { New-InstallerPackageArchive -PackageRoot $root -Files $badFiles -DestinationPath $badZip }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*Invalid or duplicate archive path*' -and -not (Test-Path -LiteralPath $badZip)) 'Unsafe ZIP allowlist was not rejected before creation.'
    }
    Pass 'ZIP traversal and duplicate entry names are rejected'

    # Windows Explorer's actual ZIP extractor retains DOS Hidden attributes.
    $extraction = Join-Path $temporary 'explorer-extracted'
    New-Item -ItemType Directory -Path $extraction | Out-Null
    $shell = New-Object -ComObject Shell.Application
    $zipFolder = $shell.NameSpace([string]$zip)
    $destinationFolder = $shell.NameSpace([string]$extraction)
    Assert-True ($null -ne $zipFolder -and $null -ne $destinationFolder) 'Explorer ZIP namespaces could not be opened.'
    $destinationFolder.CopyHere($zipFolder.Items(), 1556)
    $extractedRoot = Join-Path $extraction 'portable fixture'
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 200
        $complete = $true
        foreach ($name in $archiveFiles) {
            $sourcePath = Join-Path $root $name
            $destinationPath = Join-Path $extractedRoot $name
            if (-not [IO.File]::Exists($destinationPath) -or
                ([IO.FileInfo]$destinationPath).Length -ne ([IO.FileInfo]$sourcePath).Length) {
                $complete = $false; break
            }
        }
    } while (-not $complete -and [DateTime]::UtcNow -lt $deadline)
    Assert-True $complete 'Explorer extraction did not finish before the deadline.'
    & $module { param($path) Assert-PackageIntegrity $path } $extractedRoot | Out-Null
    $visible = @(Get-ChildItem -LiteralPath $extractedRoot | Sort-Object Name | ForEach-Object { $_.Name })
    Assert-True (($visible -join ',') -ceq 'flash.cmd,recovery.img') 'Explorer extraction lost the root visibility.'
    foreach ($name in @('platform-tools', 'install-recovery.ps1', 'metadata.json')) {
        Assert-True (((Get-Item -LiteralPath (Join-Path $extractedRoot $name) -Force).Attributes -band [IO.FileAttributes]::Hidden) -ne 0) ('Explorer lost Hidden: ' + $name)
    }
    Pass 'actual Explorer ZIP extraction preserves Hidden directories/files and full integrity'

    $alternate = Join-Path $temporary 'powershell-extracted'
    Expand-Archive -LiteralPath $zip -DestinationPath $alternate
    & $module { param($path) Assert-PackageIntegrity $path } (Join-Path $alternate 'portable fixture') | Out-Null
    Pass 'PowerShell extraction remains usable even when its extractor strips Hidden'

    $image = Join-Path $root 'recovery.img'
    $stream = [IO.File]::Open($image, [IO.FileMode]::Open, [IO.FileAccess]::Write)
    try { $stream.WriteByte(0) } finally { $stream.Dispose() }
    Assert-IntegrityFailure $root '*SHA256/size validation failed: recovery.img*'
    Pass 'single recovery image tampering is rejected before native tools can run'

    $metadata.files += @{ path = 'DEVICE-TEST.md'; bytes = 0; sha256 = '0' * 64 }
    # Put the prohibited path first so allowlist rejection precedes the deliberately damaged image.
    $metadata.files = @($metadata.files[-1]) + @($metadata.files | Select-Object -SkipLast 1)
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8 -Force
    Assert-IntegrityFailure $root '*Unexpected or duplicate package file: DEVICE-TEST.md*'
    Pass 'extra documentation in metadata cannot extend the fixed single-image payload'
} finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'android-dev-package-tests-*') { throw 'Unsafe temporary cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host ("All $script:Passed package checks passed. No builder or device tool was run.")
