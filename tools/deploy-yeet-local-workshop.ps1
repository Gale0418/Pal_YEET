[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Workspace = (Split-Path -Parent $PSScriptRoot),
    [string]$WorkshopRoot = 'D:\Program Files (x86)\Steam\steamapps\workshop\content\1623730',
    [string]$LocalFolderName = 'YEETLocalDev'
)

$ErrorActionPreference = 'Stop'
if ($LocalFolderName -notmatch '^YEET[A-Za-z0-9]+$') { throw 'LocalFolderName must be a YEET-prefixed alphanumeric folder.' }

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

function Get-TreeRows {
    param([string]$BasePath)
    $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd('\')
    @(Get-ChildItem -LiteralPath $baseFull -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($baseFull.Length).TrimStart('\', '/') -replace '\\', '/'
        [PSCustomObject]@{
            RelativePath = $relative
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        }
    })
}

$workspaceFull = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
$workshopFull = [IO.Path]::GetFullPath($WorkshopRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $workshopFull -PathType Container)) { throw 'Palworld WorkshopRootDir does not exist.' }
$target = Resolve-SafeChildPath (Join-Path $workshopFull $LocalFolderName) $workshopFull 'Workshop target'

if (-not $PSCmdlet.ShouldProcess($target, 'Build, verify, and safely swap YEET local Workshop payload')) {
    Write-Output "YEETLOCALWORKSHOP: WhatIf would stage and swap target=$target"
    return
}

& (Join-Path $PSScriptRoot 'package-yeet-workshop.ps1') -Mode Local -Workspace $workspaceFull
$packageStage = [IO.Path]::GetFullPath((Join-Path $workspaceFull 'dist\workshop\YEET-local'))
if (-not (Test-Path -LiteralPath $packageStage -PathType Container)) { throw "Packaged Workshop stage not found: $packageStage" }

$sourceInfoPath = Join-Path $packageStage 'Info.json'
if (-not (Test-Path -LiteralPath $sourceInfoPath -PathType Leaf)) { throw 'Packaged Workshop Info.json is missing.' }
$sourceInfo = Get-Content -LiteralPath $sourceInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($sourceInfo.PackageName -ne 'YEET') { throw "Refusing to deploy PackageName=$($sourceInfo.PackageName)" }
$sourceRows = @(Get-TreeRows $packageStage)
if ($sourceRows.Count -eq 0) { throw 'Packaged Workshop payload is empty.' }

# Copy into a clean sibling directory so stale files can never survive the swap.
$staging = Resolve-SafeChildPath (Join-Path $workshopFull ('.' + $LocalFolderName + '.stage-' + [guid]::NewGuid().ToString('N'))) $workshopFull 'Workshop staging directory'
$previous = Resolve-SafeChildPath (Join-Path $workshopFull ('.' + $LocalFolderName + '.previous-' + [guid]::NewGuid().ToString('N'))) $workshopFull 'Workshop previous directory'
$oldMoved = $false
$targetSwapped = $false
try {
    Copy-Item -LiteralPath $packageStage -Destination $staging -Recurse
    $stagedInfoPath = Join-Path $staging 'Info.json'
    $stagedInfo = Get-Content -LiteralPath $stagedInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($stagedInfo.PackageName -ne 'YEET') { throw "Staged payload identity mismatch: $($stagedInfo.PackageName)" }
    $stagedRows = @(Get-TreeRows $staging)
    if (($stagedRows.RelativePath -join '|') -ne ($sourceRows.RelativePath -join '|')) {
        throw 'Staged Workshop payload file list differs from package output.'
    }
    for ($i = 0; $i -lt $sourceRows.Count; $i++) {
        if ($sourceRows[$i].Hash -ne $stagedRows[$i].Hash) {
            throw "Staged Workshop payload hash mismatch: $($sourceRows[$i].RelativePath)"
        }
    }

    if (Test-Path -LiteralPath $target) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Refusing to replace non-directory target: $target" }
        $existingInfo = Join-Path $target 'Info.json'
        if (-not (Test-Path -LiteralPath $existingInfo -PathType Leaf)) { throw "Refusing to replace non-YEET directory: $target" }
        $existing = Get-Content -LiteralPath $existingInfo -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($existing.PackageName -ne 'YEET') { throw "Refusing to replace PackageName=$($existing.PackageName)" }
        Move-Item -LiteralPath $target -Destination $previous
        $oldMoved = $true
    }
    Move-Item -LiteralPath $staging -Destination $target
    $targetSwapped = $true

    $targetRows = @(Get-TreeRows $target)
    if (($targetRows.RelativePath -join '|') -ne ($sourceRows.RelativePath -join '|')) { throw 'Swapped Workshop payload file list differs from package output.' }
    for ($i = 0; $i -lt $sourceRows.Count; $i++) {
        if ($sourceRows[$i].Hash -ne $targetRows[$i].Hash) {
            throw "Swapped Workshop payload hash mismatch: $($sourceRows[$i].RelativePath)"
        }
    }

    if ($oldMoved) {
        try { Remove-SafeDirectory $previous $workshopFull 'Workshop previous directory' }
        catch { Write-Warning "Workshop deployment completed, but old payload cleanup failed: $($_.Exception.Message)" }
    }
    Write-Output 'YEETLOCALWORKSHOP: PASS'
    Write-Output "target=$target"
} catch {
    if ($targetSwapped -and (Test-Path -LiteralPath $target -PathType Container)) {
        Remove-SafeDirectory $target $workshopFull 'Workshop target during rollback'
    }
    if ($oldMoved -and (Test-Path -LiteralPath $previous -PathType Container)) {
        Move-Item -LiteralPath $previous -Destination $target
    }
    throw
} finally {
    if (Test-Path -LiteralPath $staging -PathType Container) {
        Remove-SafeDirectory $staging $workshopFull 'Workshop staging directory'
    }
}
