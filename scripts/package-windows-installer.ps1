#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceImage,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$ToolsDir = 'R:\android\sdk\platform-tools',
    [string]$RollbackImage = 'D:\Downloads\twrp-3.7.1_16-popsicle-YuKongA-2026-09-12\twrp-3.7.1_16-popsicle-YuKongA-2026-09-12\twrp.img',
    [string]$ReferenceFirmware = 'OS3.0.319.0.WPBCNXM',
    [switch]$RecoveryBootTested,
    [switch]$KernelSUBootTested,
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$partitionBytes = [long]104857600
$rollbackHash = 'e65c58d1bc27a78b8618a03b95c53bcc81a61dd213cad3f4c8639a68806476d4'
$templateDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'installer/windows'
$deviceReport = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/ANDROID-3-device-test.md'
Import-Module (Join-Path $templateDir 'recovery-installer.psm1') -Force
$installerModule = Get-Module 'recovery-installer'

$source = (Get-Item -LiteralPath $SourceImage).FullName
$rollback = (Get-Item -LiteralPath $RollbackImage).FullName
$tools = (Get-Item -LiteralPath $ToolsDir).FullName
$output = [IO.Path]::GetFullPath($OutputDir)
if (Test-Path -LiteralPath $output) { throw 'OutputDir already exists. Choose a new directory; existing packages are never overwritten.' }
if ($Zip -and (Test-Path -LiteralPath ($output + '.zip'))) { throw 'The output ZIP already exists.' }
& $installerModule { param($image) Assert-RecoveryImage $image } $source
& $installerModule { param($image) Assert-RecoveryImage $image } $rollback
if ((Get-FileHash -LiteralPath $rollback -Algorithm SHA256).Hash.ToLowerInvariant() -cne $rollbackHash) {
    throw 'RollbackImage does not match the pinned, previously working TWRP SHA256.'
}
$toolFiles = @('adb.exe', 'fastboot.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll', 'libwinpthread-1.dll', 'NOTICE.txt', 'source.properties')
foreach ($name in $toolFiles) {
    $file = Get-Item -LiteralPath (Join-Path $tools $name)
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Expected a regular platform-tools file: $name" }
}
$properties = Get-Content -LiteralPath (Join-Path $tools 'source.properties') -Raw
if ($properties -notmatch '(?m)^Pkg\.Revision\s*=\s*36\.0\.2\s*$') { throw 'Use the pinned Android platform-tools 36.0.2 distribution.' }
foreach ($name in @('flash.cmd', 'restore-twrp.cmd', 'install-recovery.ps1', 'recovery-installer.psm1', 'README.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $templateDir $name) -PathType Leaf)) { throw "Missing installer template: $name" }
}
if (-not (Test-Path -LiteralPath $deviceReport -PathType Leaf)) { throw 'Missing ANDROID-3 device-test report.' }

New-Item -ItemType Directory -Path $output -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path (Join-Path $output 'Images'), (Join-Path $output 'platform-tools') | Out-Null
foreach ($name in @('flash.cmd', 'restore-twrp.cmd', 'install-recovery.ps1', 'recovery-installer.psm1', 'README.txt')) {
    Copy-Item -LiteralPath (Join-Path $templateDir $name) -Destination (Join-Path $output $name)
}
Copy-Item -LiteralPath $deviceReport -Destination (Join-Path $output 'DEVICE-TEST.md')
foreach ($name in $toolFiles) {
    Copy-Item -LiteralPath (Join-Path $tools $name) -Destination (Join-Path $output 'platform-tools')
}
Copy-Item -LiteralPath $source -Destination (Join-Path $output 'Images/OrangeFox-popsicle.img')
Copy-Item -LiteralPath $rollback -Destination (Join-Path $output 'Images/TWRP-popsicle.img')
$files = @()
foreach ($name in (& $installerModule { Get-RequiredPackageFiles })) {
    $path = Join-Path $output $name
    $files += [ordered]@{
        path = $name; bytes = (Get-Item -LiteralPath $path).Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$metadata = [ordered]@{
    schema_version = 1
    created_utc = [DateTime]::UtcNow.ToString('o')
    device = [ordered]@{
        product = 'popsicle'; model = 'Xiaomi 17 Pro Max'; android_version = 16
        reference_firmware = $ReferenceFirmware
        reference_security_patch = '2026-08-01'
        recovery_boot_tested = [bool]$RecoveryBootTested
        root_installation_tested = [bool]$KernelSUBootTested
        kernelsu_boot_tested = [bool]$KernelSUBootTested
        magisk_boot_tested = $false
        full_device_validation_complete = $false
        note = 'Recovery boot, root installation and full device validation are separate checks. See the included DEVICE-TEST.md report.'
    }
    partition_size_bytes = $partitionBytes
    platform_tools_version = '36.0.2'
    rollback_sha256 = $rollbackHash
    install_policy = 'Only recovery_<current-slot>; no erase, format, AVB, boot, root or slot switch.'
    files = $files
}
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'metadata.json') -Encoding UTF8
& $installerModule { param($root) Assert-PackageIntegrity $root | Out-Null } $output
$zipPath = $null
if ($Zip) {
    $zipPath = $output + '.zip'
    Compress-Archive -LiteralPath $output -DestinationPath $zipPath -CompressionLevel Optimal
}
$payloadBytes = [long]0
foreach ($entry in $files) { $payloadBytes += [long]$entry['bytes'] }
[pscustomobject]@{
    PackageDirectory = $output; Zip = $zipPath
    OrangeFoxSha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    RollbackSha256 = $rollbackHash; FirmwareReference = $ReferenceFirmware
    PayloadBytes = $payloadBytes
}
