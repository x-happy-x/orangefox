#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('OrangeFox', 'RestoreTwrp')]
    [string]$Mode,
    [string]$Serial,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'recovery-installer.psm1') -Force
    $parameters = @{ PackageRoot = $PSScriptRoot; Mode = $Mode; PreflightOnly = $PreflightOnly }
    if ($Serial) { $parameters.Serial = $Serial }
    Invoke-RecoveryInstaller @parameters | Format-List
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'No automatic retry or alternate partition is attempted.'
    exit 1
}
