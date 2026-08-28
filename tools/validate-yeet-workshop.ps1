[CmdletBinding()]
param(
    [string]$Workspace = (Split-Path -Parent $PSScriptRoot),
    [switch]$ReleaseReady
)

$ErrorActionPreference = 'Stop'
$contractPath = Join-Path $Workspace 'Workshop\YEET\PACKAGE-CONTRACT.json'
$infoPath = Join-Path $Workspace 'Workshop\YEET\Info.json'
$buildContractPath = Join-Path $Workspace 'LogicMods\YEET\BUILD-CONTRACT.json'
$interactionContractPath = Join-Path $Workspace 'LogicMods\YEET\INTERACTION-CONTRACT.json'
$luaPath = Join-Path $Workspace 'UE4SS\Mods\YEETCaravanCore\Scripts\main.lua'
$terminalBridgePath = Join-Path $Workspace 'UE4SS\Mods\YEETCaravanCore\Scripts\terminal_interaction_bridge.lua'
$readmePath = Join-Path $Workspace 'Workshop\YEET\README.md'

foreach ($path in @($contractPath, $infoPath, $buildContractPath, $interactionContractPath, $luaPath, $terminalBridgePath, $readmePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "YEETWORKSHOP: missing required file: $path"
    }
}

$contract = Get-Content -Raw -Encoding UTF8 $contractPath | ConvertFrom-Json
$info = Get-Content -Raw -Encoding UTF8 $infoPath | ConvertFrom-Json
$buildContract = Get-Content -Raw -Encoding UTF8 $buildContractPath | ConvertFrom-Json
$interaction = Get-Content -Raw -Encoding UTF8 $interactionContractPath | ConvertFrom-Json
$lua = Get-Content -Raw -Encoding UTF8 $luaPath
$terminalBridge = Get-Content -Raw -Encoding UTF8 $terminalBridgePath
$readme = Get-Content -Raw -Encoding UTF8 $readmePath

if ($contract.package_name -ne 'YEET') { throw 'YEETWORKSHOP: package_name must be YEET' }
if ($info.PackageName -ne $contract.package_name) { throw 'YEETWORKSHOP: Info.json PackageName mismatch' }
if ($info.ModName -ne $contract.workshop_name) { throw 'YEETWORKSHOP: Info.json ModName mismatch' }
if ($info.Dependencies -notcontains 'UE4SSExperimentalPW') { throw 'YEETWORKSHOP: UE4SS dependency missing from Info.json' }
$expectedTags = @('Gameplay', 'User Interface', 'Utilities')
$actualTags = @($info.Tags | Sort-Object)
if (($actualTags -join '|') -ne (($expectedTags | Sort-Object) -join '|')) {
    throw 'YEETWORKSHOP: Tags must be exactly Gameplay, User Interface, Utilities.'
}
if (($info.InstallRule | Where-Object Type -eq 'Lua').Count -ne 1) { throw 'YEETWORKSHOP: Lua InstallRule missing' }
if (($info.InstallRule | Where-Object Type -eq 'LogicMods').Count -ne 1) { throw 'YEETWORKSHOP: LogicMods InstallRule missing' }
if ($contract.release_gates.own_building_class -notmatch 'BP_YEETTerminal') { throw 'YEETWORKSHOP: own terminal class gate missing' }
if ($contract.release_gates.debug_key_not_product_entry -ne $true) { throw 'YEETWORKSHOP: debug key gate must remain enabled' }
if ($contract.release_gates.native_expedition_ui -ne $false) { throw 'YEETWORKSHOP: native expedition UI must be disabled' }
if ($contract.release_gates.palschema_required -ne $false) { throw 'YEETWORKSHOP: PalSchema cannot be a release requirement' }
if ($contract.release_gates.workbench_placeholder_allowed -ne $false) { throw 'YEETWORKSHOP: WorkBench placeholder must not pass release gate' }
if ($buildContract.terminal_asset -notmatch 'BP_YEETTerminal') { throw 'YEETWORKSHOP: build contract does not name own terminal asset' }
if ($interaction.interaction_component -ne 'UPalInteractiveObjectBoxComponent') { throw 'YEETWORKSHOP: Pal interaction component contract missing' }
if ([string]$interaction.blueprint_wiring.target_call -ne 'BP_YEETTerminal.YEET_RequestRouteMenu(Other)') { throw 'YEETWORKSHOP: Blueprint-only terminal interaction event target_call must be exact' }
if ($interaction.runtime_cpp_dependency -ne $false) { throw 'YEETWORKSHOP: custom runtime C++ dependency is forbidden' }
if ($interaction.input_policy.player_key -ne 'F') { throw 'YEETWORKSHOP: terminal interaction must use F' }
if ($interaction.input_policy.global_debug_key_is_product_entry -ne $false) { throw 'YEETWORKSHOP: F8 cannot be product entry' }
if ($lua -notmatch 'terminal_interact') { throw 'YEETWORKSHOP: Lua interaction bridge missing' }
if ($lua -notmatch 'InjectTerminalInteractionBridge' -or
    $lua -notmatch 'ProbeTerminalInteractionBridge') { throw 'YEETWORKSHOP: injectable terminal bridge API missing' }
if ($terminalBridge -match 'ProcessEvent' -or
    $terminalBridge -notmatch 'exact_class_filter' -or
    $terminalBridge -notmatch 'read_only\s*=\s*true') {
    throw 'YEETWORKSHOP: terminal bridge must remain exact-class and read-only/fail-closed.'
}
if ($readme -notmatch '按原生互動鍵 F') { throw 'YEETWORKSHOP: Workshop README does not describe F interaction' }
if ($readme -notmatch '不得再包一層') { throw 'YEETWORKSHOP: flat official Lua payload rule is undocumented' }

if ($ReleaseReady) {
    $terminalAsset = Join-Path $Workspace 'LogicModBuild\Content\Mods\YEET\Buildings\BP_YEETTerminal.uasset'
    $pakList = Join-Path $Workspace 'LogicModBuild\YEET-PakList.txt'
    if (-not (Test-Path -LiteralPath $terminalAsset -PathType Leaf)) {
        throw 'YEETWORKSHOP: RELEASE BLOCKED — BP_YEETTerminal.uasset is not built.'
    }
    if (-not (Test-Path -LiteralPath $pakList -PathType Leaf) -or
        (Get-Content -LiteralPath $pakList -Raw -Encoding UTF8) -notmatch 'Buildings[/\\]BP_YEETTerminal\.uasset') {
        throw 'YEETWORKSHOP: RELEASE BLOCKED — BP_YEETTerminal is absent from the pak list.'
    }
    if ($buildContract.runtime_readiness.build_registration -ne 'verified') {
        throw 'YEETWORKSHOP: RELEASE BLOCKED — merge-safe build-menu registration is not verified.'
    }
}

Write-Output 'YEETWORKSHOP: PASS'
Write-Output ("package={0} version={1} own_terminal={2}" -f $contract.package_name, $contract.version, $contract.release_gates.own_building_class)
