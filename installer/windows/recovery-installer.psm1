#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PartitionBytes = [long]104857600
$script:RollbackSha256 = 'e65c58d1bc27a78b8618a03b95c53bcc81a61dd213cad3f4c8639a68806476d4'

function Get-RequiredPackageFiles([string]$Layout = 'full') {
    if ($Layout -cnotin @('full', 'minimal')) { throw 'Unsupported package layout.' }
    $image = if ($Layout -ceq 'minimal') { 'recovery.img' } else { 'Images/OrangeFox-popsicle.img' }
    @('flash.cmd', 'restore-twrp.cmd', 'install-recovery.ps1', 'recovery-installer.psm1', 'README.txt', 'DEVICE-TEST.md',
      $image, 'Images/TWRP-popsicle.img',
      'platform-tools/adb.exe', 'platform-tools/fastboot.exe',
      'platform-tools/AdbWinApi.dll', 'platform-tools/AdbWinUsbApi.dll',
      'platform-tools/libwinpthread-1.dll', 'platform-tools/NOTICE.txt',
      'platform-tools/source.properties')
}

function Get-FileSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RecoveryImage([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or $item.Length -ne $script:PartitionBytes) {
        throw "Recovery image must be exactly 100 MiB: $Path"
    }
    $stream = [IO.File]::OpenRead($item.FullName)
    try {
        $header = New-Object byte[] 44
        if ($stream.Read($header, 0, $header.Length) -ne $header.Length -or
            [Text.Encoding]::ASCII.GetString($header, 0, 8) -cne 'ANDROID!' -or
            [BitConverter]::ToUInt32($header, 40) -ne 4) {
            throw "Expected an Android boot image with header v4: $Path"
        }
    } finally { $stream.Dispose() }
}

function Assert-PackageIntegrity([string]$PackageRoot) {
    $root = (Get-Item -LiteralPath $PackageRoot -Force).FullName
    $metadata = Get-Content -LiteralPath (Join-Path $root 'metadata.json') -Raw | ConvertFrom-Json
    if ($metadata.schema_version -ne 1 -or $metadata.device.product -cne 'popsicle' -or
        [long]$metadata.partition_size_bytes -ne $script:PartitionBytes -or
        $metadata.platform_tools_version -cne '36.0.2') {
        throw 'Unsupported package metadata, device, platform-tools version or partition size.'
    }
    # Old packages omit layout and retain the original fixed image path.
    $layoutProperty = $metadata.PSObject.Properties['layout']
    $layout = if ($null -eq $layoutProperty) { 'full' } else { $layoutProperty.Value }
    if ($layout -isnot [string] -or $layout -cnotin @('full', 'minimal')) { throw 'Unsupported package layout.' }
    $expected = @(Get-RequiredPackageFiles $layout)
    $seen = @{}
    foreach ($entry in @($metadata.files)) {
        $name = [string]$entry.path
        if ($name -cnotin $expected -or $seen.ContainsKey($name) -or
            [string]$entry.sha256 -cnotmatch '^[a-f0-9]{64}$') {
            throw "Unexpected or duplicate package file: $name"
        }
        $seen[$name] = $true
        $path = Join-Path $root ($name.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $file = Get-Item -LiteralPath $path -Force
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $file.Length -ne [long]$entry.bytes -or (Get-FileSha256 $path) -cne [string]$entry.sha256) {
            throw "SHA256/size validation failed: $name"
        }
    }
    if ($seen.Count -ne $expected.Count) { throw 'The package file list is incomplete.' }
    $orangefox = Join-Path $root $(if ($layout -ceq 'minimal') { 'recovery.img' } else { 'Images/OrangeFox-popsicle.img' })
    $rollback = Join-Path $root 'Images/TWRP-popsicle.img'
    Assert-RecoveryImage $orangefox
    Assert-RecoveryImage $rollback
    if ((Get-FileSha256 $rollback) -cne $script:RollbackSha256) {
        throw 'The rollback is not the pinned, previously working TWRP image.'
    }
    $properties = Get-Content -LiteralPath (Join-Path $root 'platform-tools/source.properties') -Raw
    if ($properties -notmatch '(?m)^Pkg\.Revision\s*=\s*36\.0\.2\s*$') {
        throw 'Bundled platform-tools source.properties does not declare 36.0.2.'
    }
    [pscustomobject]@{ Root = $root; Metadata = $metadata; OrangeFox = $orangefox; Rollback = $rollback }
}

function ConvertTo-NativeArgument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    '"' + $escaped + '"'
}

function New-DeviceProcess([string]$PackageRoot, [string]$Tool, [string[]]$Arguments) {
    if ($Tool -cnotin @('adb', 'fastboot')) { throw "Unknown device tool: $Tool" }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PackageRoot ('platform-tools/' + $Tool + '.exe')
    $info.WorkingDirectory = $PackageRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $process
}

function Invoke-DeviceTool {
    param([string]$PackageRoot, [string]$Tool, [string[]]$Arguments, [int]$TimeoutSeconds = 45)
    $process = New-DeviceProcess $PackageRoot $Tool $Arguments
    try {
        if (-not $process.Start()) { throw "Cannot start bundled $Tool." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "$Tool timed out. Check the device and cable; no retry is attempted."
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult()
            Stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

function Get-CheckedToolResult {
    param([string]$PackageRoot, [string]$Tool, [string[]]$Arguments, [int]$TimeoutSeconds = 45)
    $result = Invoke-DeviceTool -PackageRoot $PackageRoot -Tool $Tool -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "$Tool failed (exit $($result.ExitCode)): $($result.Stderr) $($result.Stdout)"
    }
    $result
}

function Assert-Serial([string]$Serial) {
    if ($Serial -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'The device serial contains unexpected characters.' }
}

function Get-SingleConnectedDevice([string]$PackageRoot, [string]$ExpectedSerial) {
    $adb = Get-CheckedToolResult $PackageRoot 'adb' @('devices')
    $fastboot = Get-CheckedToolResult $PackageRoot 'fastboot' @('devices')
    $devices = @()
    foreach ($line in ($adb.Stdout -split '\r?\n')) {
        $line = $line.Trim()
        if (-not $line -or $line -eq 'List of devices attached') { continue }
        if ($line -cnotmatch '^(\S+)\s+(\S+)(?:\s+.*)?$') { throw "Unexpected adb device listing: $line" }
        $devices += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2]; Transport = 'adb' }
    }
    foreach ($line in ($fastboot.Stdout -split '\r?\n')) {
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line -cnotmatch '^(\S+)\s+fastboot$') { throw "Unexpected fastboot device listing: $line" }
        $devices += [pscustomobject]@{ Serial = $Matches[1]; State = 'fastboot'; Transport = 'fastboot' }
    }
    if ($devices.Count -ne 1) { throw "Connect exactly one device; found $($devices.Count) adb/fastboot entries." }
    $device = $devices[0]
    Assert-Serial $device.Serial
    if ($ExpectedSerial -and $device.Serial -cne $ExpectedSerial) { throw 'Connected serial differs from the explicitly selected serial.' }
    if ($device.Transport -eq 'adb' -and $device.State -cnotin @('device', 'recovery')) {
        throw "ADB is $($device.State). Authorize the phone in Android before starting."
    }
    $device
}

function Get-AdbValue([string]$PackageRoot, [string]$Serial, [string[]]$Command) {
    (Get-CheckedToolResult $PackageRoot 'adb' (@('-s', $Serial, 'shell') + $Command)).Stdout.Trim()
}

function Get-AdbPartitionSha256([string]$PackageRoot, [string]$Serial, [string]$DevicePath) {
    $output = Get-AdbValue $PackageRoot $Serial @('sha256sum', $DevicePath)
    $pattern = '^([a-fA-F0-9]{64})\s+\*?' + [regex]::Escape($DevicePath) + '$'
    if ($output -cnotmatch $pattern) { throw 'ADB did not return an unambiguous SHA256 for the recovery partition.' }
    $Matches[1].ToLowerInvariant()
}

function Get-FastbootVariable([string]$PackageRoot, [string]$Serial, [string]$Name) {
    $result = Get-CheckedToolResult $PackageRoot 'fastboot' @('-s', $Serial, 'getvar', $Name)
    $text = $result.Stdout + "`n" + $result.Stderr
    $pattern = '(?m)^\s*(?:\(bootloader\)\s*)?' + [regex]::Escape($Name) + ':\s*([^\r\n]+?)\s*$'
    $values = [regex]::Matches($text, $pattern)
    if ($values.Count -ne 1) { throw "Missing or ambiguous fastboot variable: $Name" }
    $values[0].Groups[1].Value.Trim()
}

function Get-FastbootPreflight([string]$PackageRoot, [string]$Serial) {
    if ((Get-FastbootVariable $PackageRoot $Serial 'product') -cne 'popsicle') { throw 'Fastboot product is not popsicle.' }
    if ((Get-FastbootVariable $PackageRoot $Serial 'unlocked') -cne 'yes') { throw 'The bootloader must already be unlocked.' }
    if ((Get-FastbootVariable $PackageRoot $Serial 'is-userspace') -cne 'no') { throw 'Use bootloader fastboot, not userspace fastbootd.' }
    $slot = Get-FastbootVariable $PackageRoot $Serial 'current-slot'
    if ($slot -cnotin @('a', 'b')) { throw 'The bootloader current-slot must be a or b.' }
    $target = 'recovery_' + $slot
    $sizeText = Get-FastbootVariable $PackageRoot $Serial ('partition-size:' + $target)
    if ($sizeText -cmatch '^0x[0-9a-fA-F]+$') { $size = [Convert]::ToInt64($sizeText.Substring(2), 16) }
    elseif ($sizeText -cmatch '^[0-9]+$') { $size = [long]::Parse($sizeText, [Globalization.CultureInfo]::InvariantCulture) }
    else { throw "Unexpected partition size: $sizeText" }
    if ($size -ne $script:PartitionBytes) { throw "$target is not a 100 MiB recovery partition." }
    [pscustomobject]@{ Serial = $Serial; Slot = $slot; Target = $target; PartitionBytes = $size }
}

function Save-RecoveryBackup {
    param([string]$PackageRoot, [string]$Serial, [string]$Slot, [string]$BackupDirectory)
    if ($Slot -cnotin @('a', 'b')) { throw 'Cannot back up an ambiguous recovery slot.' }
    $devicePath = '/dev/block/by-name/recovery_' + $Slot
    $size = Get-AdbValue $PackageRoot $Serial @('blockdev', '--getsize64', $devicePath)
    if ($size -cne [string]$script:PartitionBytes) { throw 'ADB recovery backup partition is not exactly 100 MiB.' }
    $deviceHashBefore = Get-AdbPartitionSha256 $PackageRoot $Serial $devicePath
    New-Item -ItemType Directory -Path $BackupDirectory -ErrorAction Stop | Out-Null
    $destination = Join-Path $BackupDirectory ('recovery_' + $Slot + '-before.img')
    # exec-out may merge the remote stderr stream into stdout. cat emits no
    # successful-transfer summary, unlike dd; size and three hashes are still checked.
    $process = New-DeviceProcess $PackageRoot 'adb' @('-s', $Serial, 'exec-out', 'cat', $devicePath)
    $stream = $null
    $started = $false
    try {
        $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        if (-not $process.Start()) { throw 'Cannot start adb backup.' }
        $started = $true
        $stderr = $process.StandardError.ReadToEndAsync()
        # Binary stdout goes directly to a FileStream; PowerShell text redirection corrupts images.
        $copy = $process.StandardOutput.BaseStream.CopyToAsync($stream)
        if (-not $copy.Wait(180000) -or -not $process.WaitForExit(30000)) {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            throw 'ADB recovery backup timed out; no flash was attempted.'
        }
        $copy.GetAwaiter().GetResult() | Out-Null
        $stream.Dispose()
        $stream = $null
        if ($process.ExitCode -ne 0) { throw ('ADB recovery backup failed: ' + $stderr.GetAwaiter().GetResult()) }
        if ((Get-Item -LiteralPath $destination -Force).Length -ne $script:PartitionBytes) { throw 'The recovery backup is incomplete.' }
        $localHash = Get-FileSha256 $destination
        $deviceHashAfter = Get-AdbPartitionSha256 $PackageRoot $Serial $devicePath
        if ($deviceHashBefore -cne $localHash -or $deviceHashAfter -cne $localHash) {
            throw 'Recovery partition SHA256 changed or differs from the binary backup; no flash was attempted.'
        }
        $receipt = [ordered]@{
            serial = $Serial; slot = $Slot; device_path = $devicePath
            created_utc = [DateTime]::UtcNow.ToString('o'); bytes = $script:PartitionBytes
            sha256 = $localHash
            device_sha256_before = $deviceHashBefore; device_sha256_after = $deviceHashAfter
        }
        $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BackupDirectory 'metadata.json') -Encoding UTF8
        $destination
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $process) {
            if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
    }
}

function Assert-SuccessfulFlash([object]$Result, [string]$Target) {
    $text = $Result.Stdout + "`n" + $Result.Stderr
    $name = [regex]::Escape($Target)
    if ($Result.ExitCode -ne 0 -or $text -match '(?im)^\s*(?:FAILED|fastboot:\s*error:)' -or
        $text -notmatch ("(?is)Sending\s+'?" + $name + "'?(?:\s|\().*?OKAY.*?Writing\s+'?" + $name + "'?(?:\s|\().*?OKAY")) {
        throw "Flash was not confirmed by both Sending/OKAY and Writing/OKAY. Do not reboot or retry blindly. $text"
    }
}

function Invoke-RecoveryInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][ValidateSet('OrangeFox', 'RestoreTwrp')][string]$Mode,
        [string]$Serial,
        [switch]$PreflightOnly
    )
    if ($Serial) { Assert-Serial $Serial }
    $package = Assert-PackageIntegrity $PackageRoot
    $image = if ($Mode -eq 'OrangeFox') { $package.OrangeFox } else { $package.Rollback }
    Write-Host ('Action: ' + $Mode + '; device: Xiaomi 17 Pro Max (popsicle); target: current recovery slot.')
    Write-Host ('Reference firmware: ' + $package.Metadata.device.reference_firmware)
    if ($Mode -eq 'OrangeFox' -and -not $package.Metadata.device.recovery_boot_tested) { Write-Host 'Recovery boot has not yet been verified for this packaged build.' }
    if ($Mode -eq 'OrangeFox') {
        $rootTestedProperty = $package.Metadata.device.PSObject.Properties['root_installation_tested']
        $rootTested = $null -ne $rootTestedProperty -and $rootTestedProperty.Value -is [bool] -and $rootTestedProperty.Value
        if ($rootTested) { Write-Host 'Root installation is marked tested; see DEVICE-TEST.md for the provider and verified checks.' }
        else { Write-Host 'Root installation is not marked tested; see DEVICE-TEST.md for checks and limitations.' }
        Write-Host 'Full device validation is not marked complete.'
    }
    $device = Get-SingleConnectedDevice $package.Root $Serial
    $serialNumber = $device.Serial
    $backup = $null
    $adbSlot = $null
    if ($device.Transport -eq 'adb') {
        $product = Get-AdbValue $package.Root $serialNumber @('getprop', 'ro.product.device')
        if ($product -cne 'popsicle') { throw "ADB product is not popsicle: $product" }
        if ($PreflightOnly) {
            return [pscustomobject]@{ Stage = 'ADB model verified; fastboot checks pending'; Serial = $serialNumber; Product = $product; ReadOnly = $true }
        }
        $uid = Get-AdbValue $package.Root $serialNumber @('id', '-u')
        if ($uid -eq '0') {
            $suffix = Get-AdbValue $package.Root $serialNumber @('getprop', 'ro.boot.slot_suffix')
            if ($suffix -cnotmatch '^_([ab])$') { throw 'ADB cannot determine the active slot for a binary recovery backup.' }
            $adbSlot = $Matches[1]
            $backupRoot = Join-Path $package.Root ('backups/' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $backup = Save-RecoveryBackup $package.Root $serialNumber $adbSlot $backupRoot
            Write-Host ('Binary recovery backup: ' + $backup)
        } else { Write-Host 'ADB is not root; the package includes the pinned working TWRP rollback.' }
        Get-CheckedToolResult $package.Root 'adb' @('-s', $serialNumber, 'reboot', 'bootloader') | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            Start-Sleep -Seconds 2
            $listed = Get-CheckedToolResult $package.Root 'fastboot' @('devices')
            $lines = @($listed.Stdout -split '\r?\n' | Where-Object { $_.Trim() })
            if ($lines.Count -gt 1) { throw 'More than one fastboot device appeared.' }
            if ($lines.Count -eq 1) {
                if ($lines[0].Trim() -cne ($serialNumber + "`tfastboot") -and
                    $lines[0].Trim() -cnotmatch ('^' + [regex]::Escape($serialNumber) + '\s+fastboot$')) {
                    throw 'Fastboot serial differs from the authorized ADB device.'
                }
                break
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($lines.Count -ne 1) { throw 'The selected device did not appear in bootloader fastboot within 90 seconds.' }
    }
    $connected = Get-SingleConnectedDevice $package.Root $serialNumber
    if ($connected.Transport -cne 'fastboot') { throw 'The selected device is not in bootloader fastboot.' }
    $preflight = Get-FastbootPreflight $package.Root $serialNumber
    if ($adbSlot -and $adbSlot -cne $preflight.Slot) { throw 'The active slot changed after the ADB backup.' }
    if ($PreflightOnly) { return $preflight }
    # Repeat identity and slot checks immediately before the single permitted write.
    $connected = Get-SingleConnectedDevice $package.Root $serialNumber
    if ($connected.Transport -cne 'fastboot') { throw 'Fastboot transport changed before flash.' }
    $beforeWrite = Get-FastbootPreflight $package.Root $serialNumber
    if ($beforeWrite.Target -cne $preflight.Target) { throw 'The active recovery slot changed during preflight.' }
    $result = Invoke-DeviceTool $package.Root 'fastboot' @('-s', $serialNumber, 'flash', $preflight.Target, $image) -TimeoutSeconds 180
    Assert-SuccessfulFlash $result $preflight.Target
    Write-Host ("Flash verified: $($preflight.Target); serial: $serialNumber")
    Get-CheckedToolResult $package.Root 'fastboot' @('-s', $serialNumber, 'reboot', 'recovery') | Out-Null
    [pscustomobject]@{ Result = 'Flash verified; recovery reboot requested'; Serial = $serialNumber; Partition = $preflight.Target; Backup = $backup; Mode = $Mode }
}

Export-ModuleMember -Function Invoke-RecoveryInstaller
