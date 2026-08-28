[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DonorAsset,

    [string] $UnrealPak = 'D:\EPIC\UE_5.1\Engine\Binaries\Win64\UnrealPak.exe',

    [string] $TargetPackage = 'BP_YEETTerminal',

    [switch] $KeepStaging
)

$ErrorActionPreference = 'Stop'

function Resolve-File([string] $Path) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "Not a file: $Path"
    }
    return $resolved.Path
}

function Read-AsciiTokens([string] $Path) {
    # Cooked packages keep useful object/import names as ASCII/UTF-8 byte runs.
    # This is intentionally a read-only probe, not an attempt to patch package bytes.
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    return @([regex]::Matches($text, '[A-Za-z0-9_./-]{4,}') | ForEach-Object Value | Select-Object -Unique)
}

$donor = Resolve-File $DonorAsset
$donorUexp = [IO.Path]::ChangeExtension($donor, '.uexp')
if (-not (Test-Path -LiteralPath $donorUexp -PathType Leaf)) {
    throw "Cooked Blueprint sidecar is missing: $donorUexp"
}
$pakTool = Resolve-File $UnrealPak

$staging = Join-Path ([IO.Path]::GetTempPath()) ('yeet-terminal-probe-' + [guid]::NewGuid().ToString('N'))
$sourceDir = Join-Path $staging 'source-preserved'
$renameDir = Join-Path $staging 'rename-probe\Pal\Content\Mods\YEET\Buildings'
New-Item -ItemType Directory -Path $sourceDir,$renameDir -Force | Out-Null

$donorName = [IO.Path]::GetFileNameWithoutExtension($donor)
$donorTokens = Read-AsciiTokens $donor
$internalClasses = @($donorTokens | Where-Object {
    $_ -match '^BP_[A-Za-z0-9_]+_C$' -and
    $_ -notmatch '_GEN_VARIABLE$'
})
$palReferences = @($donorTokens | Where-Object { $_ -eq '/Script/Pal' -or $_ -match '^PalBuildObject' })
$assetInfo = Get-Item -LiteralPath $donor
$uexpInfo = Get-Item -LiteralPath $donorUexp

# Preserve a donor copy for inspection, and separately stage a filename/path rename.
# The latter deliberately does not rewrite the package's internal FNames. This makes
# the common unsafe "just rename .uasset" shortcut measurable and fail-closed.
Copy-Item -LiteralPath $donor -Destination (Join-Path $sourceDir ($donorName + '.uasset'))
Copy-Item -LiteralPath $donorUexp -Destination (Join-Path $sourceDir ($donorName + '.uexp'))
Copy-Item -LiteralPath $donor -Destination (Join-Path $renameDir ($TargetPackage + '.uasset'))
Copy-Item -LiteralPath $donorUexp -Destination (Join-Path $renameDir ($TargetPackage + '.uexp'))

$renameTokens = Read-AsciiTokens (Join-Path $renameDir ($TargetPackage + '.uasset'))
$renameClasses = @($renameTokens | Where-Object {
    $_ -match '^BP_[A-Za-z0-9_]+_C$' -and
    $_ -notmatch '_GEN_VARIABLE$'
})
$internalTargetClass = $renameClasses -contains ($TargetPackage + '_C')

$fileList = Join-Path $staging 'rename-probe.txt'
$pakPath = Join-Path $staging ($TargetPackage + '-rename-probe.pak')
$uassetForPak = Join-Path $renameDir ($TargetPackage + '.uasset')
$uexpForPak = Join-Path $renameDir ($TargetPackage + '.uexp')
$fileListLines = @(
    ('"{0}" "../../../Pal/Content/Mods/YEET/Buildings/{1}.uasset"' -f $uassetForPak, $TargetPackage),
    ('"{0}" "../../../Pal/Content/Mods/YEET/Buildings/{1}.uexp"' -f $uexpForPak, $TargetPackage)
)
[IO.File]::WriteAllLines($fileList, $fileListLines, [Text.UTF8Encoding]::new($false))

$createOutput = (& $pakTool $pakPath "-create=$fileList" 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pakPath -PathType Leaf)) {
    throw "UnrealPak failed to create rename probe.`n$createOutput"
}
$listOutput = (& $pakTool $pakPath '-List' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "UnrealPak failed to list rename probe.`n$listOutput"
}
$packagedUasset = $listOutput -match ('{0}\.uasset' -f [regex]::Escape($TargetPackage))
$packagedUexp = $listOutput -match ('{0}\.uexp' -f [regex]::Escape($TargetPackage))

$blockers = [Collections.Generic.List[string]]::new()
if (-not $palReferences) {
    $blockers.Add('donor does not expose /Script/Pal or PalBuildObject in the readable name map')
}
if (-not $internalTargetClass) {
    $blockers.Add("filesystem rename leaves internal class name(s) [$($renameClasses -join ', ')] instead of $TargetPackage`_C")
}
$blockers.Add('no Palworld runtime is installed on this host, so class resolution and native F/placement cannot be verified')
$blockers.Add('this probe does not rewrite FNames, imports, generated class metadata, or dependent package references')

$result = [ordered]@{
    schema = 'yeet.terminal-cooked-asset-probe.v1'
    status = if ($internalTargetClass -and $packagedUasset -and $packagedUexp) { 'candidate' } else { 'blocked-safe-rename' }
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    donor = [ordered]@{
        path = $donor
        packageName = $donorName
        uassetBytes = $assetInfo.Length
        uexpBytes = $uexpInfo.Length
        palReferences = $palReferences
        internalClasses = $internalClasses
    }
    renameProbe = [ordered]@{
        targetPackage = $TargetPackage
        stagedUasset = $uassetForPak
        stagedUexp = $uexpForPak
        pak = $pakPath
        packagedUasset = $packagedUasset
        packagedUexp = $packagedUexp
        internalClasses = $renameClasses
        internalTargetClass = $internalTargetClass
        gameLoadable = $false
    }
    blockers = @($blockers)
    cleanup = if ($KeepStaging) { 'caller retains staging' } else { 'staging is left for manual inspection; remove this unique temp directory when done' }
}

$reportPath = Join-Path $staging 'probe-result.json'
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8
Write-Output "REPORT=$reportPath"
Write-Output "STAGING=$staging"
