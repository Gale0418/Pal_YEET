[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PalworldRoot = 'D:\Program Files (x86)\Steam\steamapps\common\Palworld',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repoRoot 'UE4SS\Mods\YEETRuntimeProbe'
$palworldFull = [IO.Path]::GetFullPath($PalworldRoot)
$modsRoot = Join-Path $palworldFull 'Mods'
$ue4ssModsRoot = Join-Path $modsRoot 'NativeMods\UE4SS\Mods'
$targetRoot = Join-Path $ue4ssModsRoot 'YEETRuntimeProbe'
$modsTextPath = Join-Path $ue4ssModsRoot 'mods.txt'
$backupPath = "$modsTextPath.YEETRuntimeProbe-backup"

function Resolve-SafeChildPath {
    param([string]$Path, [string]$Parent, [string]$Label)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not $full.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped its expected parent: $full"
    }
    return $full
}

function Remove-SafeDirectory {
    param([string]$Path, [string]$Parent, [string]$Label)
    $safePath = Resolve-SafeChildPath $Path $Parent $Label
    if (Test-Path -LiteralPath $safePath -PathType Container) {
        Remove-Item -LiteralPath $safePath -Recurse -Force
    }
}

$ue4ssModsRoot = [IO.Path]::GetFullPath($ue4ssModsRoot).TrimEnd('\')
$targetRoot = Resolve-SafeChildPath $targetRoot $ue4ssModsRoot 'Probe target directory'
$modsTextPath = Resolve-SafeChildPath $modsTextPath $ue4ssModsRoot 'UE4SS mods.txt'
$backupPath = Resolve-SafeChildPath $backupPath $ue4ssModsRoot 'Probe backup'

function Assert-PalworldClosed {
    $running = Get-Process -Name 'Palworld', 'PalServer-Win64-Shipping' -ErrorAction SilentlyContinue
    if ($null -ne $running) {
        throw 'Palworld 必須完全關閉後才能部署或還原 YEETRuntimeProbe。'
    }
}

Assert-PalworldClosed
if (-not (Test-Path -LiteralPath $modsTextPath -PathType Leaf)) {
    throw "找不到 UE4SS mods.txt：$modsTextPath"
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "找不到 probe backup：$backupPath"
    }
    if ($PSCmdlet.ShouldProcess($modsTextPath, 'Restore mods.txt from YEETRuntimeProbe backup')) {
        Copy-Item -LiteralPath $backupPath -Destination $modsTextPath -Force
        Write-Output "YEETRUNTIMEPROBE: RESTORED mods.txt from $backupPath"
    } else {
        Write-Output "YEETRUNTIMEPROBE: WhatIf restore=$backupPath"
    }
    return
}

foreach ($required in @(
    (Join-Path $sourceRoot 'Scripts\main.lua'),
    (Join-Path $sourceRoot 'Scripts\runtime_probe.lua'),
    (Join-Path $sourceRoot 'Info.json')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少 probe payload：$required" }
}

$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Sort-Object FullName)
if ($sourceFiles.Count -eq 0) { throw 'Probe payload is empty.' }

function Get-PayloadRows([string]$base, [object[]]$files) {
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        [PSCustomObject]@{ RelativePath = $relative; Hash = $hash }
    }
}

function Get-PayloadDigest([object[]]$rows) {
    $canonical = (($rows | Sort-Object RelativePath | ForEach-Object { "$($_.RelativePath)=$($_.Hash)" }) -join "`n") + "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    } finally { $sha.Dispose() }
}

$sourceRows = @(Get-PayloadRows $sourceRoot $sourceFiles)
$payloadDigest = Get-PayloadDigest $sourceRows
$modsText = [IO.File]::ReadAllText($modsTextPath, [Text.Encoding]::UTF8)
$updatedMods = $modsText
if ($updatedMods -match '(?m)^\s*YEETRuntimeProbe\s*:') {
    $updatedMods = [regex]::Replace($updatedMods, '(?m)^\s*YEETRuntimeProbe\s*:\s*[01]\s*$', 'YEETRuntimeProbe : 1')
} else {
    if ($updatedMods.Length -gt 0 -and -not $updatedMods.EndsWith("`n")) { $updatedMods += "`r`n" }
    $updatedMods += 'YEETRuntimeProbe : 1' + "`r`n"
}

if ($PSCmdlet.ShouldProcess($modsTextPath, 'Stage, verify, and safely swap YEETRuntimeProbe; then enable its mods.txt line')) {
    $stageRoot = Resolve-SafeChildPath (Join-Path $ue4ssModsRoot ('.YEETRuntimeProbe-stage-' + [guid]::NewGuid().ToString('N'))) $ue4ssModsRoot 'Probe staging directory'
    $previousRoot = Resolve-SafeChildPath (Join-Path $ue4ssModsRoot ('.YEETRuntimeProbe-previous-' + [guid]::NewGuid().ToString('N'))) $ue4ssModsRoot 'Probe previous directory'
    $oldMoved = $false
    $targetSwapped = $false
    $modsUpdated = $false
    $modsStagePath = $null
    try {
        $modsStagePath = Resolve-SafeChildPath (Join-Path $ue4ssModsRoot ('.mods.txt.YEETRuntimeProbe-stage-' + [guid]::NewGuid().ToString('N'))) $ue4ssModsRoot 'mods.txt staging file'
        [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
        foreach ($file in $sourceFiles) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
            $destination = Join-Path $stageRoot $relative
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }

        # Verify the clean sibling stage before touching either targetRoot or mods.txt.
        $stageFiles = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Sort-Object FullName)
        $stageRows = @(Get-PayloadRows $stageRoot $stageFiles)
        $stageDigest = Get-PayloadDigest $stageRows
        if ($stageDigest -ne $payloadDigest) { throw "Staged payload hash mismatch: source=$payloadDigest stage=$stageDigest" }

        # Prepare the replacement separately; the live mods.txt remains untouched.
        [IO.File]::WriteAllText($modsStagePath, $updatedMods, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::ReadAllText($modsStagePath, [Text.Encoding]::UTF8) -ne $updatedMods) {
            throw 'Staged mods.txt content verification failed.'
        }

        # The first backup is immutable: an existing backup is intentionally never overwritten.
        if ((Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            throw "Refusing non-file probe backup path: $backupPath"
        }
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $modsTextPath -Destination $backupPath
        }
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Failed to create immutable probe backup: $backupPath" }

        if (Test-Path -LiteralPath $targetRoot) {
            if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
                throw "Refusing to replace non-directory probe target: $targetRoot"
            }
            Move-Item -LiteralPath $targetRoot -Destination $previousRoot
            $oldMoved = $true
        }
        Move-Item -LiteralPath $stageRoot -Destination $targetRoot
        $targetSwapped = $true

        $targetFiles = @(Get-ChildItem -LiteralPath $targetRoot -File -Recurse | Sort-Object FullName)
        $targetRows = @(Get-PayloadRows $targetRoot $targetFiles)
        $targetDigest = Get-PayloadDigest $targetRows
        if ($targetDigest -ne $payloadDigest) { throw "部署後 payload hash mismatch: source=$payloadDigest target=$targetDigest" }

        # mods.txt is changed only after the clean payload has been swapped and verified.
        Move-Item -LiteralPath $modsStagePath -Destination $modsTextPath -Force
        $modsUpdated = $true

        if ($oldMoved) {
            try { Remove-SafeDirectory $previousRoot $ue4ssModsRoot 'Probe previous directory' }
            catch { Write-Warning "Probe deployment completed, but old payload cleanup failed: $($_.Exception.Message)" }
        }
        Write-Output 'YEETRUNTIMEPROBE: PASS Palworld closed; mods.txt backed up; probe enabled; existing Mod lines preserved.'
        Write-Output "backup=$backupPath"
        Write-Output "payload_sha256=$payloadDigest"
        foreach ($row in $sourceRows) { Write-Output ("payload_file={0} sha256={1}" -f $row.RelativePath, $row.Hash) }
    } catch {
        if ($modsUpdated) {
            [IO.File]::WriteAllText($modsTextPath, $modsText, (New-Object Text.UTF8Encoding($false)))
        }
        if ($targetSwapped -and (Test-Path -LiteralPath $targetRoot -PathType Container)) {
            Remove-SafeDirectory $targetRoot $ue4ssModsRoot 'Probe target directory during rollback'
        }
        if ($oldMoved -and (Test-Path -LiteralPath $previousRoot -PathType Container)) {
            Move-Item -LiteralPath $previousRoot -Destination $targetRoot
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $stageRoot -PathType Container) {
            Remove-SafeDirectory $stageRoot $ue4ssModsRoot 'Probe staging directory'
        }
        if ($null -ne $modsStagePath -and (Test-Path -LiteralPath $modsStagePath -PathType Leaf)) {
            Remove-Item -LiteralPath $modsStagePath -Force
        }
    }
} else {
    Write-Output "YEETRUNTIMEPROBE: WhatIf would backup=$backupPath and enable YEETRuntimeProbe only"
    Write-Output "payload_sha256=$payloadDigest"
}
