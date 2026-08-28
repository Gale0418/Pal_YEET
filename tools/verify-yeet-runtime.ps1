[CmdletBinding()]
param(
    [string]$LogPath = 'D:\Program Files (x86)\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\UE4SS.log',
    [string]$MainLuaPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'UE4SS\Mods\YEETCaravanCore\Scripts\main.lua'),
    [string]$InfoPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Workshop\YEET\Info.json')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    throw "UE4SS log not found: $LogPath"
}
foreach ($path in @($MainLuaPath, $InfoPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "YEET runtime identity file not found: $path"
    }
}

$mainText = Get-Content -Raw -Encoding utf8 -LiteralPath $MainLuaPath
$versionMatch = [regex]::Match($mainText, '(?m)^\s*local\s+VERSION\s*=\s*["'']([^"'']+)["'']')
if (-not $versionMatch.Success) { throw "YEET VERSION not found in main.lua: $MainLuaPath" }
$mainVersion = $versionMatch.Groups[1].Value
$info = Get-Content -Raw -Encoding utf8 -LiteralPath $InfoPath | ConvertFrom-Json
$infoVersion = [string]$info.Version
if ([string]::IsNullOrWhiteSpace($infoVersion) -or $mainVersion -ne $infoVersion) {
    throw "YEET version mismatch: main.lua=$mainVersion Info.json=$infoVersion"
}

$text = Get-Content -Raw -Encoding utf8 -LiteralPath $LogPath
$logEntries = [regex]::Matches($text, '\[YEETCaravanCore\].*')
if ($logEntries.Count -eq 0) { throw 'No YEETCaravanCore entries found' }

$readyPattern = 'ready v{0}.*product_entry=terminal_F' -f [regex]::Escape($mainVersion)
$readyEntries = @($logEntries | Where-Object { $_.Value -match $readyPattern })
$latestReady = if ($readyEntries.Count -gt 0) { $readyEntries[-1] } else { $null }
$afterLatestReady = if ($null -ne $latestReady) {
    @($logEntries | Where-Object { $_.Index -gt $latestReady.Index })
} else {
    @()
}
$luaErrors = @($afterLatestReady | Where-Object { $_.Value -match 'Lua.*(error|Error)|YEET Lua error' })

if (-not $latestReady) { throw "YEET $mainVersion terminal_F ready marker not found; relaunch Palworld after deployment" }
if ($luaErrors) { throw ('YEET Lua error detected: ' + ($luaErrors.Value -join ' | ')) }

Write-Output "PASS: YEET $mainVersion terminal_F runtime marker found with no Lua error after latest marker."
$afterLatestReady | Select-Object -Last 8 | ForEach-Object { $_.Value }
