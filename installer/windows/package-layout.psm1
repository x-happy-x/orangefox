#requires -Version 5.1
# Build-time helpers only; never invoke device tools.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Set-MinimalPackageVisibility {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    foreach ($item in @(Get-ChildItem -LiteralPath $PackageRoot -Force)) {
        if ($item.Name -cin @('flash.cmd', 'recovery.img')) {
            $attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::Hidden)
        } else {
            $attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
        }
        [IO.File]::SetAttributes($item.FullName, $attributes)
    }
}

function New-InstallerPackageArchive {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    $root = Get-Item -LiteralPath $PackageRoot -Force
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Archive source must be a regular directory.'
    }
    $prefix = $root.Name + '/'
    $entries = @{}
    $directories = @{}
    $directories[$prefix] = $root
    foreach ($name in $Files) {
        if ($name -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or
            @($name.Split('/') | Where-Object { $_ -cin @('.', '..') }).Count -ne 0 -or
            $entries.ContainsKey($prefix + $name)) {
            throw "Invalid or duplicate archive path: $name"
        }
        $item = Get-Item -LiteralPath (Join-Path $root.FullName $name) -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Archive payload must be a regular file: $name"
        }
        $entries[$prefix + $name] = $item
        $relativeParent = $name
        while ($relativeParent.Contains('/')) {
            $relativeParent = $relativeParent.Substring(0, $relativeParent.LastIndexOf('/'))
            $parent = Get-Item -LiteralPath (Join-Path $root.FullName $relativeParent) -Force
            if (-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Archive payload parent must be a regular directory: $relativeParent"
            }
            $directories[$prefix + $relativeParent + '/'] = $parent
        }
    }
    # Explicit allowlist includes Hidden files. Compress-Archive skips them.
    $stream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        foreach ($name in @($directories.Keys | Sort-Object)) {
            $entry = $archive.CreateEntry($name)
            $entry.ExternalAttributes = ([int]$directories[$name].Attributes -band 0x37) -bor 0x10
        }
        foreach ($name in @($entries.Keys | Sort-Object)) {
            $item = $entries[$name]
            $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            # DOS attribute bits are used by Explorer's ZIP extraction on Windows.
            $entry.ExternalAttributes = [int]$item.Attributes -band 0x27
            $input = [IO.File]::OpenRead($item.FullName)
            $output = $entry.Open()
            try { $input.CopyTo($output) }
            finally { $output.Dispose(); $input.Dispose() }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
    # Check every ZIP entry, length and full hash before reporting success.
    $stream = [IO.File]::OpenRead($DestinationPath)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        if ($archive.Entries.Count -ne $entries.Count + $directories.Count) { throw 'ZIP entry list differs from the package allowlist.' }
        foreach ($entry in $archive.Entries) {
            if ($directories.ContainsKey($entry.FullName)) {
                if (($entry.ExternalAttributes -band 0x37) -ne (([int]$directories[$entry.FullName].Attributes -band 0x37) -bor 0x10)) {
                    throw "ZIP directory attributes differ: $($entry.FullName)"
                }
                continue
            }
            if (-not $entries.ContainsKey($entry.FullName)) { throw "Unexpected ZIP entry: $($entry.FullName)" }
            $item = $entries[$entry.FullName]
            if ($entry.Length -ne $item.Length -or ($entry.ExternalAttributes -band 0x27) -ne ([int]$item.Attributes -band 0x27)) {
                throw "ZIP size/attributes differ: $($entry.FullName)"
            }
            $hash = [Security.Cryptography.SHA256]::Create()
            $input = $entry.Open()
            try { $actualHash = ([BitConverter]::ToString($hash.ComputeHash($input))).Replace('-', '') }
            finally { $input.Dispose(); $hash.Dispose() }
            if ($actualHash -cne (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash) {
                throw "ZIP SHA256 differs: $($entry.FullName)"
            }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
}

Export-ModuleMember -Function Set-MinimalPackageVisibility, New-InstallerPackageArchive
