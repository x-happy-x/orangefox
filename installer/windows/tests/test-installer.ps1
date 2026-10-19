#requires -Version 5.1
# Offline tests only. Every adb/fastboot call is replaced before invoking any installer flow.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'recovery-installer.psm1'
Import-Module $modulePath -Force
$module = Get-Module 'recovery-installer'
$script:Passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-Scenario {
    @{
        Transport = 'fastboot'; Serial = 'TEST123'; Product = 'popsicle'; AdbProduct = 'popsicle'
        AdbState = 'device'; ExtraDevice = $false; Slot = 'a'; Unlocked = 'yes'; Userspace = 'no'
        Size = '0x6400000'; Uid = '2000'; FlashResult = 'success'; FlashExit = 0
        ChangeSlot = $false; SlotReads = 0
    }
}

& $module {
    function script:Assert-PackageIntegrity {
        param([string]$PackageRoot)
        [pscustomobject]@{
            Root = 'MOCK_PACKAGE'; OrangeFox = 'MOCK_ORANGEFOX.img'; Rollback = 'MOCK_TWRP.img'
            Metadata = [pscustomobject]@{ device = [pscustomobject]@{ reference_firmware = 'OS3.0.319.0.WPBCNXM'; recovery_boot_tested = $false } }
        }
    }
    function script:Invoke-DeviceTool {
        param([string]$PackageRoot, [string]$Tool, [string[]]$Arguments, [int]$TimeoutSeconds)
        $command = $Tool + ' ' + ($Arguments -join ' ')
        $script:Calls.Add($command) | Out-Null
        $scenario = $script:Scenario
        $stdout = ''; $stderr = ''; $exit = 0
        if ($command -eq 'adb devices') {
            $stdout = "List of devices attached`n"
            if ($scenario.Transport -eq 'adb') { $stdout += $scenario.Serial + "`t" + $scenario.AdbState + "`n" }
            if ($scenario.ExtraDevice) { $stdout += "OTHER999`tdevice`n" }
        } elseif ($command -eq 'fastboot devices') {
            if ($scenario.Transport -eq 'fastboot') { $stdout = $scenario.Serial + "`tfastboot`n" }
        } elseif ($Tool -eq 'fastboot' -and $Arguments.Count -eq 4 -and $Arguments[2] -eq 'getvar') {
            $name = $Arguments[3]
            $value = switch ($name) {
                'product' { $scenario.Product }
                'unlocked' { $scenario.Unlocked }
                'is-userspace' { $scenario.Userspace }
                'current-slot' {
                    $scenario.SlotReads++
                    if ($scenario.ChangeSlot -and $scenario.SlotReads -gt 1) { 'b' } else { $scenario.Slot }
                }
                'partition-size:recovery_a' { $scenario.Size }
                'partition-size:recovery_b' { $scenario.Size }
                default { throw "Unexpected mock variable: $name" }
            }
            $stderr = $name + ': ' + $value + "`nFinished. Total time: 0.001s`n"
        } elseif ($command -eq ('adb -s ' + $scenario.Serial + ' shell getprop ro.product.device')) {
            $stdout = $scenario.AdbProduct + "`n"
        } elseif ($command -eq ('adb -s ' + $scenario.Serial + ' shell id -u')) {
            $stdout = $scenario.Uid + "`n"
        } elseif ($command -eq ('adb -s ' + $scenario.Serial + ' reboot bootloader')) {
            $scenario.Transport = 'fastboot'
        } elseif ($Tool -eq 'fastboot' -and $Arguments.Count -eq 5 -and $Arguments[2] -eq 'flash') {
            if ($Arguments[3] -notmatch '^recovery_[ab]$') { throw 'Installer attempted a forbidden partition.' }
            $target = $Arguments[3]
            $stderr = "Sending '$target' (102400 KB) OKAY [1.000s]`n"
            if ($scenario.FlashResult -eq 'success') { $stderr += "Writing '$target' OKAY [1.000s]`nFinished.`n" }
            elseif ($scenario.FlashResult -eq 'failed') { $stderr += "Writing '$target' FAILED (remote: write error)`n" }
            elseif ($scenario.FlashResult -ne 'sending-only') { throw 'Unknown flash scenario.' }
            $exit = $scenario.FlashExit
        } elseif ($command -eq ('fastboot -s ' + $scenario.Serial + ' reboot recovery')) {
            $stderr = 'Rebooting into recovery OKAY'
        } else { throw "Unexpected device call (real tools are never allowed): $command" }
        [pscustomobject]@{ ExitCode = $exit; Stdout = $stdout; Stderr = $stderr }
    }
    function script:Start-Sleep { param([int]$Seconds) }
}

function Run-Scenario {
    param([string]$Name, [hashtable]$Scenario, [bool]$ExpectedSuccess, [switch]$Write, [string]$SelectedSerial = 'TEST123', [string]$Mode = 'OrangeFox')
    & $module {
        param($State)
        $script:Scenario = $State
        $script:Calls = New-Object 'System.Collections.Generic.List[string]'
    } $Scenario
    $failed = $false
    $result = $null
    try {
        $arguments = @{ PackageRoot = 'MOCK_PACKAGE'; Serial = $SelectedSerial; Mode = $Mode; PreflightOnly = -not $Write }
        $result = Invoke-RecoveryInstaller @arguments
    } catch { $failed = $true }
    Assert-True ($failed -ne $ExpectedSuccess) ($Name + ': unexpected outcome')
    $calls = @(& $module { $script:Calls.ToArray() })
    $writes = @($calls | Where-Object { $_ -match ' flash ' })
    $reboots = @($calls | Where-Object { $_ -match ' reboot recovery$' })
    if (-not $Write) {
        Assert-True (@($calls | Where-Object { $_ -match ' (?:flash|reboot|erase|format|set_active) ' }).Count -eq 0) ($Name + ': preflight attempted a mutation')
    }
    if ($Write -and $ExpectedSuccess) {
        Assert-True ($writes.Count -eq 1 -and $reboots.Count -eq 1) ($Name + ': expected one write followed by one recovery reboot')
        Assert-True ($calls.IndexOf($writes[0]) -lt $calls.IndexOf($reboots[0])) ($Name + ': reboot preceded flash')
        Assert-True ($result.Partition -eq ('recovery_' + $Scenario.Slot)) ($Name + ': wrong slot')
    }
    if (-not $ExpectedSuccess) { Assert-True ($reboots.Count -eq 0) ($Name + ': rebooted after failed validation/write') }
    Assert-True (@($calls | Where-Object { $_ -match ' (?:erase|format|set_active|flashing|oem) ' }).Count -eq 0) ($Name + ': forbidden mutation')
    $script:Passed++
    Write-Host ('PASS: ' + $Name)
    [pscustomobject]@{ Name = $Name; Calls = $calls; Writes = $writes; Result = $result }
}

Run-Scenario 'fastboot slot a preflight' (New-Scenario) $true | Out-Null
$s = New-Scenario; $s.Slot = 'b'; $s.Size = '104857600'
Run-Scenario 'fastboot slot b decimal size preflight' $s $true | Out-Null
$s = New-Scenario; $s.Transport = 'adb'
Run-Scenario 'authorized Android read-only model check' $s $true | Out-Null
$s = New-Scenario; $s.Transport = 'adb'; $s.AdbState = 'recovery'
Run-Scenario 'authorized recovery read-only model check' $s $true | Out-Null
foreach ($state in @('unauthorized', 'offline', 'sideload')) {
    $s = New-Scenario; $s.Transport = 'adb'; $s.AdbState = $state
    Run-Scenario ('reject ADB ' + $state) $s $false | Out-Null
}
$s = New-Scenario; $s.ExtraDevice = $true
Run-Scenario 'reject multiple transports/devices' $s $false | Out-Null
$s = New-Scenario; $s.Transport = 'none'
Run-Scenario 'reject no device' $s $false | Out-Null
Run-Scenario 'reject wrong selected serial' (New-Scenario) $false -SelectedSerial 'WRONG123' | Out-Null
Run-Scenario 'reject unsafe selected serial' (New-Scenario) $false -SelectedSerial 'unsafe serial' | Out-Null
foreach ($test in @(
    @('Product', 'pandora', 'wrong fastboot product'),
    @('Unlocked', 'no', 'locked bootloader'),
    @('Userspace', 'yes', 'fastbootd'),
    @('Slot', 'c', 'unknown slot'),
    @('Size', '0x3200000', 'wrong partition size'),
    @('Size', 'nonsense', 'malformed partition size')
)) {
    $s = New-Scenario; $s[$test[0]] = $test[1]
    Run-Scenario ('reject ' + $test[2]) $s $false | Out-Null
}
$s = New-Scenario; $s.Transport = 'adb'; $s.AdbProduct = 'pandora'
Run-Scenario 'reject wrong ADB product' $s $false | Out-Null
Run-Scenario 'write current slot a and reboot after OKAY' (New-Scenario) $true -Write | Out-Null
$s = New-Scenario; $s.Slot = 'b'
Run-Scenario 'restore TWRP to current slot b' $s $true -Write -Mode RestoreTwrp | Out-Null
$s = New-Scenario; $s.Transport = 'adb'
Run-Scenario 'authorized unrooted ADB to bootloader then recovery write' $s $true -Write | Out-Null
$s = New-Scenario; $s.ChangeSlot = $true
$case = Run-Scenario 'reject slot change immediately before write' $s $false -Write
Assert-True ($case.Writes.Count -eq 0) 'Slot change must be rejected before any write.'
foreach ($kind in @('failed', 'sending-only')) {
    $s = New-Scenario; $s.FlashResult = $kind
    Run-Scenario ('reject flash ' + $kind + ' without recovery reboot') $s $false -Write | Out-Null
}
$s = New-Scenario; $s.FlashExit = 1
Run-Scenario 'reject nonzero exit despite OKAY output' $s $false -Write | Out-Null

# Reimport restores real integrity functions. The tests below never enumerate devices.
Remove-Module 'recovery-installer' -Force
Import-Module $modulePath -Force
$module = Get-Module 'recovery-installer'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('android-dev-installer-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $names = @(& $module { Get-RequiredPackageFiles })
    $records = @()
    foreach ($name in $names) {
        $path = Join-Path $temporary $name
        $parent = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
        [IO.File]::WriteAllText($path, 'offline integrity fixture: ' + $name)
        $records += @{ path = $name; bytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $metadata = @{
        schema_version = 1; device = @{ product = 'popsicle' }; partition_size_bytes = 104857600
        platform_tools_version = '36.0.2'; files = $records
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $temporary 'metadata.json') -Encoding UTF8
    # The corruption must be detected before any executable can run or invalid image headers are inspected.
    [IO.File]::AppendAllText((Join-Path $temporary 'platform-tools/fastboot.exe'), 'tamper')
    $failure = ''
    try { & $module { param($root) Assert-PackageIntegrity $root } $temporary | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*SHA256/size validation failed: platform-tools/fastboot.exe*') 'Tool tampering was not rejected by full-file integrity validation.'
    $script:Passed++
    Write-Host 'PASS: full-file tool SHA256/size tamper detection'
    $metadata.files[0].path = '../outside.exe'
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $temporary 'metadata.json') -Encoding UTF8
    $failure = ''
    try { & $module { param($root) Assert-PackageIntegrity $root } $temporary | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*Unexpected or duplicate package file*') 'Path traversal in metadata was not rejected.'
    $script:Passed++
    Write-Host 'PASS: metadata path traversal rejection'

    # Simulate Process.StandardOutput.BaseStream with non-text bytes, not a native adb executable.
    & $module {
        $script:BackupFixtureBytes = New-Object byte[] 104857600
        $script:BackupFixtureBytes[0] = 0; $script:BackupFixtureBytes[1] = 255
        $script:BackupFixtureBytes[2] = 128; $script:BackupFixtureBytes[3] = 13
        $script:BackupFixtureBytes[4] = 10; $script:BackupFixtureBytes[104857599] = 127
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $script:BackupExpectedHash = ([BitConverter]::ToString($hasher.ComputeHash($script:BackupFixtureBytes))).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        $script:BackupHashBehavior = 'stable'
        $script:BackupHashReads = 0
        function script:Get-AdbValue {
            param([string]$PackageRoot, [string]$Serial, [string[]]$Command)
            if (($Command -join ' ') -ceq 'blockdev --getsize64 /dev/block/by-name/recovery_a') { return '104857600' }
            if (($Command -join ' ') -ceq 'sha256sum /dev/block/by-name/recovery_a') {
                $script:BackupHashReads++
                $hash = $script:BackupExpectedHash
                if ($script:BackupHashBehavior -eq 'mismatch' -or
                    ($script:BackupHashBehavior -eq 'changed' -and $script:BackupHashReads -gt 1)) { $hash = '0' * 64 }
                return $hash + '  /dev/block/by-name/recovery_a'
            }
            throw 'Unexpected backup size/hash query.'
        }
        function script:New-DeviceProcess {
            param([string]$PackageRoot, [string]$Tool, [string[]]$Arguments)
            if ($Tool -cne 'adb' -or ($Arguments -join ' ') -cne '-s TEST123 exec-out cat /dev/block/by-name/recovery_a') {
                throw 'Unexpected backup process arguments.'
            }
            $process = [pscustomobject]@{
                StandardOutput = [pscustomobject]@{ BaseStream = [IO.MemoryStream]::new($script:BackupFixtureBytes, $false) }
                StandardError = [IO.StringReader]::new('')
                ExitCode = 0; HasExited = $true
            }
            $process | Add-Member -MemberType ScriptMethod -Name Start -Value { $true }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Timeout) $true }
            $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { throw 'Completed mock must not be killed.' }
            $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.StandardOutput.BaseStream.Dispose(); $this.StandardError.Dispose() }
            $process
        }
    }
    $backupDirectory = Join-Path $temporary 'binary-backup'
    $backupPath = & $module { param($directory) Save-RecoveryBackup 'MOCK_PACKAGE' 'TEST123' 'a' $directory } $backupDirectory
    Assert-True ((Get-Item -LiteralPath $backupPath).Length -eq 104857600) 'Binary backup length changed.'
    $backupStream = [IO.File]::OpenRead($backupPath)
    try {
        $actual = New-Object byte[] 5
        $backupStream.Read($actual, 0, 5) | Out-Null
        Assert-True (($actual -join ',') -ceq '0,255,128,13,10') 'Binary backup was processed as text.'
        $backupStream.Seek(-1, [IO.SeekOrigin]::End) | Out-Null
        Assert-True ($backupStream.ReadByte() -eq 127) 'Binary backup was truncated.'
    } finally { $backupStream.Dispose() }
    $receipt = Get-Content -LiteralPath (Join-Path $backupDirectory 'metadata.json') -Raw | ConvertFrom-Json
    Assert-True ($receipt.sha256 -ceq (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Binary backup SHA256 receipt differs.'
    Assert-True ($receipt.sha256 -ceq $receipt.device_sha256_before -and $receipt.sha256 -ceq $receipt.device_sha256_after) 'Remote SHA256 before/after differs from the binary backup receipt.'
    $script:Passed++
    Write-Host 'PASS: exec-out cat 100 MiB binary backup preserves bytes and matches remote SHA256 before/after'
    foreach ($behavior in @('changed', 'mismatch')) {
        & $module { param($value) $script:BackupHashBehavior = $value; $script:BackupHashReads = 0 } $behavior
        $failure = ''
        try {
            & $module { param($directory) Save-RecoveryBackup 'MOCK_PACKAGE' 'TEST123' 'a' $directory } (Join-Path $temporary ('binary-backup-' + $behavior)) | Out-Null
        } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*Recovery partition SHA256 changed or differs*') ('Remote backup SHA256 ' + $behavior + ' was not rejected.')
        $script:Passed++
        Write-Host ('PASS: reject recovery backup SHA256 ' + $behavior)
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'android-dev-installer-tests-*') { throw 'Unsafe temporary cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
# Evaluate only the literal metadata assignment AST, never the builder's I/O or packaging flow.
$repository = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$builderPath = Join-Path $repository 'scripts/package-windows-installer.ps1'
$tokens = $null; $parseErrors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$tokens, [ref]$parseErrors)
Assert-True (-not $parseErrors) 'Builder parse failed.'
Assert-True (@($builderAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'KernelSUBootTested' }).Count -eq 1) 'Builder must declare the KernelSUBootTested switch.'
$metadataAssignment = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$metadata'
}, $true)
Assert-True ($null -ne $metadataAssignment) 'Builder metadata assignment not found.'
$metadataOnly = [ScriptBlock]::Create($metadataAssignment.Extent.Text + '; $metadata')
foreach ($enabled in @($false, $true)) {
    $result = & {
        param([scriptblock]$MetadataOnly, [bool]$Enabled)
        $KernelSUBootTested = [System.Management.Automation.SwitchParameter]::new($Enabled)
        $RecoveryBootTested = [System.Management.Automation.SwitchParameter]::new($true)
        $ReferenceFirmware = 'offline-fixture'
        $partitionBytes = [long]104857600
        $rollbackHash = 'offline-fixture'
        $files = @()
        & $MetadataOnly
    } $metadataOnly $enabled
    $device = $result['device']
    Assert-True ($device['root_installation_tested'] -is [bool] -and $device['root_installation_tested'] -eq $enabled) 'Root-test metadata does not follow the explicit KernelSU switch.'
    Assert-True ($device['kernelsu_boot_tested'] -is [bool] -and $device['kernelsu_boot_tested'] -eq $enabled) 'KernelSU boot-test metadata differs from its explicit switch.'
    Assert-True ($device['magisk_boot_tested'] -ceq $false -and $device['full_device_validation_complete'] -ceq $false) 'KernelSU testing must not mark Magisk or full validation complete.'
    Assert-True ($device['recovery_boot_tested'] -ceq $true) 'Recovery boot-test metadata changed unexpectedly.'
    $script:Passed++
    Write-Host ('PASS: metadata-only KernelSUBootTested=' + $enabled + '; no builder I/O')
}
Write-Host ("All $script:Passed offline checks passed. No real adb/fastboot process was started.")
