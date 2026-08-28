[CmdletBinding()]
param([string]$Workspace = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$scripts = Join-Path $Workspace 'UE4SS\Mods\YEETCaravanCore\Scripts'
$required = @('main.lua', 'config.lua', 'domain.lua', 'inventory_policy.lua', 'inventory_adapter.lua', 'inventory_runtime.lua', 'pal_reservation_runtime.lua', 'terminal_interaction_bridge.lua', 'json.lua', 'state_store.lua')
foreach ($file in $required) {
    $path = Join-Path $scripts $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing core file: $file" }
}

$main = Get-Content -LiteralPath (Join-Path $scripts 'main.lua') -Raw -Encoding UTF8
$config = Get-Content -LiteralPath (Join-Path $scripts 'config.lua') -Raw -Encoding UTF8
$domain = Get-Content -LiteralPath (Join-Path $scripts 'domain.lua') -Raw -Encoding UTF8
$runtime = Get-Content -LiteralPath (Join-Path $scripts 'inventory_runtime.lua') -Raw -Encoding UTF8
$palRuntime = Get-Content -LiteralPath (Join-Path $scripts 'pal_reservation_runtime.lua') -Raw -Encoding UTF8
$terminalBridge = Get-Content -LiteralPath (Join-Path $scripts 'terminal_interaction_bridge.lua') -Raw -Encoding UTF8

foreach ($requiredToken in @(
    'RegisterTerminal', 'BindTerminalTradeContainer', 'BindTerminalEscrowContainer', 'CreateNetworkRoute', 'SetCargoRule',
    'CreateCaravan', 'PlanCaravanLeg', 'ConfirmCaravanLoad', 'ConfirmNetworkActivation', 'CommitCaravanUnload',
    'BuildNativeLoadRequests', 'ResolveCargoDestination', 'ReconcileObservedUnload',
    'pal_reservations', 'processed_arrivals',
    'InjectInventoryRuntime', 'ProbeInventoryRuntime', 'RegisterContainer', 'CaptureActor',
    'InventoryRuntimeStatus', 'GetInventoryRuntimeStatus',
    'InjectPalReservationRuntime', 'ProbePalReservationRuntime', 'RegisterPal',
    'ReservePal', 'ReleasePal', 'ReconcilePalReservations', 'PalReservationStatus',
    'Inject', 'Probe', 'Reserve', 'Release', 'Reconcile', 'Status',
    'InjectTerminalInteractionBridge', 'ProbeTerminalInteractionBridge',
    'InstallTerminalInteractionHook', 'UninstallTerminalInteractionHook')) {
    if (($main + $domain) -notmatch [regex]::Escape($requiredToken)) { throw "Missing core contract token: $requiredToken" }
}
if ($main -notmatch 'require\("inventory_runtime"\)') { throw 'Inventory runtime bridge is not loaded by core.' }
if ($runtime -notmatch 'function Runtime:register_container' -or
    $runtime -notmatch 'function Runtime:capture_actor|Runtime\.capture_actor') {
    throw 'Inventory runtime registration/capture API is missing.'
}
if ($main -notmatch 'require\("pal_reservation_runtime"\)') { throw 'Pal reservation runtime bridge is not loaded by core.' }
if ($main -notmatch 'require\("terminal_interaction_bridge"\)') { throw 'Terminal interaction bridge is not loaded by core.' }
if ($palRuntime -notmatch 'function Runtime:probe' -or
    $palRuntime -notmatch 'function Runtime:reserve' -or
    $palRuntime -notmatch 'function Runtime:release' -or
    $palRuntime -notmatch 'function Runtime:reconcile' -or
    $palRuntime -notmatch 'function Runtime:status') {
    throw 'Pal reservation runtime API is incomplete.'
}
if ($config -notmatch 'development_mode\s*=\s*false') { throw 'Production debug keys must be disabled by default.' }
if ($config -notmatch 'inventory_runtime_enabled\s*=\s*true') { throw 'Inventory runtime must be explicitly configurable.' }
if ($config -match 'BP_BuildObject_WorkBench') { throw 'WorkBench placeholder cannot remain in production config.' }
if ($main -match 'WBP_PalExpedition|PalHUDDispatchParameter_MapObjectCharacterTeamMission|YEETEXPOPEN') {
    throw 'Native expedition UI code is forbidden in the YEET product payload.'
}
if ($main -match '(?m)^\s*InventoryAdapterReady\s*=\s*(true|inventory_adapter)|(?m)^\s*(PalReservationAdapterReady|ArrivalActivationAdapterReady)\s*=\s*true') {
    throw 'Unverified runtime adapters cannot claim readiness.'
}
if ($main -match '(?m)^\s*InventoryAdapterReady\s*=') { throw 'InventoryAdapterReady must not be a static readiness snapshot.' }
if ($main -notmatch 'SimulationOnly\s*=\s*true') { throw 'SimulationOnly must remain true until all bridges are verified.' }
if ($main -match '(?m)^\s*SimulationOnly\s*=\s*false') { throw 'SimulationOnly cannot be disabled in product core.' }
if ($config -notmatch 'pal_reservation_runtime_enabled\s*=\s*true') { throw 'Pal reservation runtime must be explicitly configurable.' }
if ($terminalBridge -match 'ProcessEvent') { throw 'Terminal bridge cannot guess or call ProcessEvent.' }
if ($terminalBridge -notmatch 'callback_signature_verified' -or
    $terminalBridge -notmatch 'read_only\s*=\s*true' -or
    $terminalBridge -notmatch 'exact_class_filter') {
    throw 'Terminal bridge must expose read-only probe and exact-class guard.'
}

Write-Output 'YEETCORE: PASS'
