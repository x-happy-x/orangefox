[CmdletBinding()]
param(
    [string]$DistroName = 'android-dev',
    [string]$WslRoot = 'R:\vm\wsl',
    [switch]$SkipBootstrap
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$installPath = Join-Path $WslRoot $DistroName
$imageDir = Join-Path $WslRoot '_images'
$imagePath = Join-Path $imageDir 'ubuntu-24.04.5-wsl-amd64.wsl'
$imageUrl = 'https://releases.ubuntu.com/24.04.5/ubuntu-24.04.5-wsl-amd64.wsl'
$imageSha = 'bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e'

$registered = @(& wsl.exe --list --quiet) -replace "`0", '' | ForEach-Object { $_.Trim() }
if ($DistroName -in $registered) {
    throw "WSL '$DistroName' already exists. Refusing to replace an existing distro."
}
if (Test-Path -LiteralPath $installPath) {
    throw "Directory already exists: $installPath. Refusing to overwrite it."
}
New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $imagePath)) {
    & curl.exe --fail --location --retry 3 --output $imagePath $imageUrl
}
$actualSha = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha -ne $imageSha) { throw "Ubuntu rootfs SHA256 mismatch: $actualSha" }

& wsl.exe --import $DistroName $installPath $imagePath --version 2
if ($SkipBootstrap) { return }

# Use stdin rather than relying on drive automounts during first boot.
$bootstrap = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bootstrap.sh')).Replace("`r`n", "`n")
$bootstrap | & wsl.exe -d $DistroName -u root -- bash -c 'set -o pipefail; tr -d "\r" | bash -s'
& (Join-Path $PSScriptRoot 'update-toolkit.ps1') -DistroName $DistroName
& wsl.exe --terminate $DistroName
& wsl.exe -d $DistroName -- /home/android/android-dev/scripts/android-dev doctor
Write-Output "Ready: wsl -d $DistroName"
