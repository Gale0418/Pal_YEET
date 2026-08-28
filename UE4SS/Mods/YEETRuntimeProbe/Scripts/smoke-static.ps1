[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lua = Join-Path $root 'Scripts\runtime_probe.lua'
$main = Join-Path $root 'Scripts\main.lua'
$info = Join-Path $root 'Info.json'
$readme = Join-Path $root 'README.md'
foreach ($file in @($lua, $main, $info, $readme)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing required file: $file" }
}

$source = Get-Content -Raw -Encoding UTF8 -LiteralPath $lua
$required = @(
    'EVENT_CAP = 24',
    'WATCHDOG_MAX_TICKS = 30',
    'GetItemContainerModule',
    'GetContainer',
    'RequestFixedAssign',
    'RequestUnassign',
    'OnEnterBaseCamp',
    'OnExitBaseCamp',
    'function_availability',
    'out_param_shapes',
    'before = before',
    'after = selected',
    'schema = "yeet-runtime-probe/v1"',
    'JSONL ',
    'RegisterHook',
    'UnregisterHook',
    'LoopAsync',
    'return true',
    'pcall(require, "UEHelpers")'
)
$forbidden = @(
    'ProcessEvent',
    'FindAllOf',
    'ExecuteInGameThread',
    'StaticConstructObject',
    'SpawnActor',
    'DestroyActor',
    'SetActorTransform',
    'SetActorLocation',
    'SetActorRotation',
    'Teleport',
    'SetEnableTick',
    'ItemSlotArray',
    'StackCount',
    'RequestMove_ToServer',
    'native_reserve',
    'native_release'
)
foreach ($needle in $required) {
    if (-not $source.Contains($needle)) { throw "Required evidence/safety marker missing: $needle" }
}
foreach ($needle in $forbidden) {
    if ($source.Contains($needle)) { throw "Forbidden mutation, enumeration, or unverified API found: $needle" }
}
foreach ($pattern in @('pcall\(RegisterHook,', 'pcall\(UnregisterHook,', 'pcall\(RegisterKeyBind,', 'pcall\(require, "UEHelpers"')) {
    if ($source -notmatch $pattern) { throw "Expected guarded call missing: $pattern" }
}
if ($source -notmatch 'state\.sequence >= EVENT_CAP') { throw 'Event cap guard missing.' }
if ($source -notmatch 'release_hooks\(') { throw 'Automatic unregister path missing.' }
if ($source -notmatch 'state\.used') { throw 'One-shot arm guard missing.' }

$mainText = Get-Content -Raw -Encoding UTF8 -LiteralPath $main
if ($mainText -notmatch 'require\("runtime_probe"\)') { throw 'main.lua does not load runtime_probe.' }
Write-Output 'PASS: YEETRuntimeProbe static read-only/host/bounded smoke completed.'
