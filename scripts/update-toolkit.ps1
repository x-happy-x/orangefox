[CmdletBinding()]
param([string]$DistroName = 'android-dev')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = Split-Path -Parent $PSScriptRoot
$archivePath = Join-Path $env:TEMP ('android-dev-toolkit-' + [guid]::NewGuid().ToString('N') + '.tar')
try {
    & tar.exe -cf $archivePath --exclude=.git --exclude=.staging --exclude=logs --exclude=artifacts '--exclude=*.log' -C $repoRoot .
    # Keep binary archive input out of PowerShell's text pipeline.
    $linuxArchive = (& wsl.exe -d $DistroName -u root --exec wslpath -a ($archivePath.Replace('\', '/'))).Trim()
    & wsl.exe -d $DistroName -u root -- tar -xf $linuxArchive -C /home/android/android-dev
    & wsl.exe -d $DistroName -u root -- chown -R android:android /home/android/android-dev
    & wsl.exe -d $DistroName -u root -- bash -c 'chmod +x /home/android/android-dev/scripts/android-dev /home/android/android-dev/scripts/*.sh; if test -d /home/android/android-dev/port; then find /home/android/android-dev/port -name "*.sh" -exec chmod +x {} +; fi; ln -sfn /home/android/android-dev/scripts/android-dev /usr/local/bin/android-dev'
} finally {
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath }
}
Write-Output "Toolkit updated in $DistroName."
