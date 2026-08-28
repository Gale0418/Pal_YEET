[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lua = Join-Path $root 'Scripts\main.lua'
$readme = Join-Path $root 'README.md'

foreach ($file in @($lua, $readme)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing required file: $file"
    }
}

$source = Get-Content -Raw -Encoding utf8 -LiteralPath $lua
$required = @(
    'EVENT_CAP = 256',
    'Key.F5',
    'press F5',
    'RegisterKeyBind',
    'RegisterHook',
    'UnregisterHook',
    'NotifyOnNewObject',
    'RegisterBeginPlayPostHook',
    'begin_play_fallback_registered',
    '/Script/Engine.Actor:BeginPlay',
    'observer_registered',
    '/Script/Engine.Actor:Destroyed',
    'ObjectPool',
    'Expedition',
    'CharacterTeamMission',
    'BuildObject',
    'Spawner',
    'Pal',
    'PAL_TERMS',
    'BP_Pal_',
    'PalCharacter',
    'PalAI',
    'PalActor',
    'Spawn',
    'Pool',
    'Dispose',
    'Destroy',
    'MoveTo',
    'Goal',
    'BeginPlay'
)
$forbidden = @(
    'ExecuteInGameThread',
    'StaticConstructObject',
    'SpawnActor',
    'DestroyActor',
    'SetActorTransform',
    'SetActorLocation',
    'SetActorRotation',
    'ForEachUObject',
    'LoopAsync'
)

foreach ($needle in $required) {
    if (-not $source.Contains($needle)) { throw "Required safety/evidence marker missing: $needle" }
}
foreach ($needle in $forbidden) {
    if ($source.Contains($needle)) { throw "Forbidden mutation or enumeration API found: $needle" }
}
foreach ($guardedPattern in @(
    'pcall\(RegisterHook,',
    'pcall\(UnregisterHook,',
    'pcall\(NotifyOnNewObject,',
    'pcall\(RegisterBeginPlayPostHook,',
    'pcall\(RegisterKeyBind,'
)) {
    if ($source -notmatch $guardedPattern) {
        throw "Expected guarded runtime call missing: $guardedPattern"
    }
}

Write-Output 'PASS: YEETAnatomyProbe keyword/structure safety smoke completed.'
