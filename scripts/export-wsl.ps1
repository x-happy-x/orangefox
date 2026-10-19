[CmdletBinding()]
param(
    [string]$DistroName = 'android-dev',
    [string]$OutputPath = 'R:\vm\wsl\android-dev.tar'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to replace $OutputPath" }
& wsl.exe -d $DistroName -- sync
& wsl.exe --terminate $DistroName
& wsl.exe --export $DistroName $OutputPath
$hash = Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
"$($hash.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($OutputPath))" |
    Set-Content -LiteralPath "$OutputPath.sha256" -Encoding ascii
Write-Output "Import: wsl --import android-dev-restored R:\vm\wsl\android-dev-restored $OutputPath --version 2"
