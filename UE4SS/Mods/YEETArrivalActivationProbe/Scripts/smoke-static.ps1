[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lua = Join-Path $root 'Scripts\arrival_probe.lua'
$main = Join-Path $root 'Scripts\main.lua'
$readme = Join-Path $root 'README.md'

foreach ($file in @($lua, $main, $readme)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing required file: $file"
    }
}

$source = Get-Content -Raw -Encoding UTF8 -LiteralPath $lua
$required = @(
    'EVENT_CAP = 12',
    'WATCHDOG_MAX_TICKS = 30',
    'OnEnterBaseCamp',
    'OnExitBaseCamp',
    'GetWorkCollection',
    'GetState',
    'IsAvailable',
    'HasAuthority',
    'AuthorityGameMode',
    'RegisterHook',
    'UnregisterHook',
    'LoopAsync',
    'return true',
    'ARRIVALPROBE:'
)
$forbidden = @(
    'FindAllOf',
    'ProcessEvent',
    'ExecuteInGameThread',
    'StaticConstructObject',
    'SpawnActor',
    'DestroyActor',
    'SetActorTransform',
    'SetActorLocation',
    'SetActorRotation',
    'Teleport',
    'SetEnableTick',
    'OnPlayerEnterBaseCampArea',
    'ItemSlotArray',
    'StackCount'
)

foreach ($needle in $required) {
    if (-not $source.Contains($needle)) { throw "Required safety/evidence marker missing: $needle" }
}
foreach ($needle in $forbidden) {
    if ($source.Contains($needle)) { throw "Forbidden mutation, enumeration, or unverified API found: $needle" }
}
foreach ($guardedPattern in @(
    'pcall\(RegisterHook,',
    'pcall\(UnregisterHook,',
    'pcall\(RegisterKeyBind,',
    'pcall\(require, "UEHelpers"'
)) {
    if ($source -notmatch $guardedPattern) {
        throw "Expected guarded runtime call missing: $guardedPattern"
    }
}

if ($source -notmatch 'LoopAsync\(WATCHDOG_INTERVAL_MS') { throw 'Watchdog loop missing.' }
if ($source -notmatch 'state\.event_count >= EVENT_CAP') { throw 'Event cap guard missing.' }
if ($source -notmatch 'release_hooks\(\)') { throw 'Automatic release path missing.' }

Write-Output 'PASS: YEETArrivalActivationProbe read-only/authority/lifecycle smoke completed.'
