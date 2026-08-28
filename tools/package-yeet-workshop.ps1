[CmdletBinding()]
param(
    [ValidateSet('Local', 'Release')]
    [string]$Mode = 'Local',
    [string]$Workspace = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\workshop')
)

$ErrorActionPreference = 'Stop'
$workspaceFull = [IO.Path]::GetFullPath($Workspace)
$outputFull = [IO.Path]::GetFullPath($OutputRoot)
$workspacePrefix = $workspaceFull.TrimEnd('\') + '\'
if (-not $outputFull.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot must remain inside the YEET workspace.'
}

$sourceRoot = Join-Path $workspaceFull 'Workshop\YEET'
$luaRoot = Join-Path $workspaceFull 'UE4SS\Mods\YEETCaravanCore\Scripts'
$pakPath = Join-Path $workspaceFull 'dist\YEET.pak'
$info = Get-Content -LiteralPath (Join-Path $sourceRoot 'Info.json') -Raw -Encoding UTF8 | ConvertFrom-Json

if ($info.PackageName -ne 'YEET' -or $info.PackageName -notmatch '^[A-Za-z0-9]+$') {
    throw 'PackageName must be the alphanumeric value YEET.'
}
if ($info.Dependencies.Count -ne 1 -or $info.Dependencies[0] -ne 'UE4SSExperimentalPW') {
    throw 'YEET must declare exactly one runtime dependency: UE4SSExperimentalPW.'
}
$rules = @($info.InstallRule)
if (@($rules | Where-Object Type -eq 'Lua').Count -ne 1 -or
    @($rules | Where-Object Type -eq 'LogicMods').Count -ne 1) {
    throw 'Exactly one Lua and one LogicMods InstallRule are required.'
}
if (-not (Test-Path -LiteralPath $pakPath -PathType Leaf)) { throw 'dist\YEET.pak is missing.' }

$luaFiles = @('main.lua', 'config.lua', 'domain.lua', 'inventory_policy.lua', 'inventory_adapter.lua', 'inventory_runtime.lua', 'pal_reservation_runtime.lua', 'terminal_interaction_bridge.lua', 'json.lua', 'state_store.lua')
$sourceFiles = @('Info.json', 'thumbnail.png')
foreach ($relative in $sourceFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)) {
        throw "Missing Workshop source file: $relative"
    }
}
foreach ($relative in $luaFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $luaRoot $relative) -PathType Leaf)) {
        throw "Missing Lua payload file: $relative"
    }
}

$stageRoot = Join-Path $outputFull ("YEET-{0}" -f $Mode.ToLowerInvariant())
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'Scripts') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'LogicMods') -Force | Out-Null

$stageInfo = $info | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$stageInfo.DebugMode = $Mode -eq 'Local'
$stageInfo | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stageRoot 'Info.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $sourceRoot 'thumbnail.png') -Destination (Join-Path $stageRoot 'thumbnail.png')
Copy-Item -LiteralPath $pakPath -Destination (Join-Path $stageRoot 'LogicMods\YEET.pak')
foreach ($relative in $luaFiles) {
    $sourceLua = Join-Path $luaRoot $relative
    $stagedLua = Join-Path $stageRoot "Scripts\$relative"
    Copy-Item -LiteralPath $sourceLua -Destination $stagedLua
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceLua).Hash
    $stagedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedLua).Hash
    if ($sourceHash -ne $stagedHash) { throw "Staged Lua differs from source: $relative" }
}

$allowed = @('Info.json', 'thumbnail.png', 'LogicMods\YEET.pak') + @($luaFiles | ForEach-Object { "Scripts\$_" })
$actual = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | ForEach-Object {
    $_.FullName.Substring($stageRoot.Length + 1)
})
$unexpected = @($actual | Where-Object { $allowed -notcontains $_ })
$missing = @($allowed | Where-Object { $actual -notcontains $_ })
if ($unexpected.Count) { throw "Unexpected Workshop payload: $($unexpected -join ', ')" }
if ($missing.Count) { throw "Missing Workshop payload: $($missing -join ', ')" }
if ($actual -match '(^|\\)enabled\.txt$|(^|\\)PalSchema($|\\)|YEETCaravanCore\\Info\.json$') {
    throw 'Forbidden nested metadata, enabled.txt, or PalSchema entered the Workshop payload.'
}

$manifest = [ordered]@{
    package = 'YEET'
    version = $stageInfo.Version
    mode = $Mode
    debugMode = $stageInfo.DebugMode
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    files = @($actual | Sort-Object | ForEach-Object {
        $path = Join-Path $stageRoot $_
        [ordered]@{ path = $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }
    })
}
$manifestPath = "$stageRoot.PACKAGE-MANIFEST.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Output "YEETPACKAGE: PASS mode=$Mode"
Write-Output "stage=$stageRoot"
Write-Output "manifest=$manifestPath"
