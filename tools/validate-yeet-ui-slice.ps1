#requires -Version 7.0
# validate-yeet-ui-slice.ps1
# YEET MOD 路線面板與終端互動切片靜態驗證腳本
[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [Version]'7.0') {
    throw '此驗證器需要 PowerShell 7.0 或更新版本（請使用 pwsh）。'
}
$repo = Resolve-Path $RepoRoot

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [YEET] 路線面板與終端互動切片靜態驗證" -ForegroundColor Cyan
Write-Host " Repo Root: $repo" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Assert-Check {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Details = ""
    )
    if ($Condition) {
        Write-Host " [PASS] $Name" -ForegroundColor Green
        if ($Details) { Write-Host "        $Details" -ForegroundColor DarkGray }
        $script:passed++
    } else {
        Write-Host " [FAIL] $Name" -ForegroundColor Red
        if ($Details) { Write-Host "        $Details" -ForegroundColor Yellow }
        $script:failed++
    }
}

# 1. 驗證 ROUTE-UI-CONTRACT.json
$routeContractPath = Join-Path $repo 'LogicMods\YEET\ROUTE-UI-CONTRACT.json'
$hasRouteContract = Test-Path $routeContractPath
Assert-Check -Name "ROUTE-UI-CONTRACT.json 檔案存在" -Condition $hasRouteContract
if ($hasRouteContract) {
    try {
        $json = Get-Content -Raw -Encoding utf8 $routeContractPath | ConvertFrom-Json
        $hasWidgetAsset = $json.widget_asset -eq "/Game/Mods/YEET/UI/WBP_YEETRouteMenu.WBP_YEETRouteMenu_C"
        $hasComponents = ($null -ne $json.widget_specification.components.origin_base_camp) -and `
                         ($null -ne $json.widget_specification.components.destination_base_camp) -and `
                         ($null -ne $json.widget_specification.components.pal_assignment_slot) -and `
                         ($null -ne $json.widget_specification.components.create_route_button) -and `
                         ($null -ne $json.widget_specification.components.close_button)
        $palSlotStatus = $json.widget_specification.components.pal_assignment_slot.status
        $hasSafePalSlotStatus = $palSlotStatus -in @("disabled", "enabled_when_host_reservation_adapter_ready")
        Assert-Check -Name "ROUTE-UI-CONTRACT 符合介面元件契約且 Pal 區處於安全狀態" -Condition ($hasWidgetAsset -and $hasComponents -and $hasSafePalSlotStatus)
    } catch {
        Assert-Check -Name "ROUTE-UI-CONTRACT JSON 解析" -Condition $false -Details $_.Exception.Message
    }
}

# 2. 驗證 BUILD-CONTRACT.json
$buildContractPath = Join-Path $repo 'LogicMods\YEET\BUILD-CONTRACT.json'
$hasBuildContract = Test-Path $buildContractPath
Assert-Check -Name "BUILD-CONTRACT.json 檔案存在" -Condition $hasBuildContract
if ($hasBuildContract) {
    try {
        $bjson = Get-Content -Raw -Encoding utf8 $buildContractPath | ConvertFrom-Json
        $hasTermAsset = $bjson.terminal_asset -eq "/Game/Mods/YEET/Buildings/BP_YEETTerminal.BP_YEETTerminal_C"
        Assert-Check -Name "BUILD-CONTRACT 終端資產契約正確" -Condition $hasTermAsset
    } catch {
        Assert-Check -Name "BUILD-CONTRACT JSON 解析" -Condition $false -Details $_.Exception.Message
    }
}

# 3. 驗證 UI-SPECIFICATION.md
$uiSpecPath = Join-Path $repo 'LogicMods\YEET\UI-SPECIFICATION.md'
$hasUiSpec = Test-Path $uiSpecPath
Assert-Check -Name "UI-SPECIFICATION.md 規格文件存在" -Condition $hasUiSpec
if ($hasUiSpec) {
    $uiSpecContent = Get-Content -Raw -Encoding utf8 $uiSpecPath
        $hasRequiredUiTerms = ($uiSpecContent -match "來源基地") -and ($uiSpecContent -match "目的基地") -and `
                          ($uiSpecContent -match "指派 Pal|Pal 編制") -and ($uiSpecContent -match "建立路線|建立航線") -and `
                          ($uiSpecContent -match "關閉")
    Assert-Check -Name "UI-SPECIFICATION 涵蓋所有必要 UI 區域與事件圖規格" -Condition $hasRequiredUiTerms
}

# 4. 驗證 UE4SS main.lua
$mainLuaPath = Join-Path $repo 'UE4SS\Mods\YEETCaravanCore\Scripts\main.lua'
$hasMainLua = Test-Path $mainLuaPath
Assert-Check -Name "UE4SS main.lua 檔案存在" -Condition $hasMainLua
if ($hasMainLua) {
    $luaText = Get-Content -Raw -Encoding utf8 $mainLuaPath
    $hasExports = ($luaText -match "YEET\.CaravanCore\s*=") -and `
                  ($luaText -match "CreateRoute") -and `
                  ($luaText -match "DeleteRoute") -and `
                  ($luaText -match "OpenRouteMenu") -and `
                  ($luaText -match "CloseRouteMenu") -and `
                  ($luaText -match "GetRouteList") -and `
                  ($luaText -match "InteractWithTerminal") -and `
                  ($luaText -match "SetWidgetAssetReady")
    $debugBindBlockMatch = [regex]::Match($luaText, '(?s)if CONFIG\.development_mode then(?<block>.*?)\r?\n    end\s*\r?\n\s*if Key and Key\.ESCAPE')
    $debugBindBlock = if ($debugBindBlockMatch.Success) { $debugBindBlockMatch.Groups['block'].Value } else { "" }
    $luaWithoutDebugBindBlock = if ($debugBindBlockMatch.Success) {
        $luaText.Remove($debugBindBlockMatch.Index, $debugBindBlockMatch.Length)
    } else {
        $luaText
    }
    $hasNoUnscopedDebugBinds = ($luaWithoutDebugBindBlock -notmatch 'bind\("F(?:8|9|10|11|12)"') -and `
                               ($luaWithoutDebugBindBlock -notmatch 'bind\(CONFIG\.ui_debug_key')
    $hasKeyBinds = $debugBindBlockMatch.Success -and $hasNoUnscopedDebugBinds -and `
                   ($debugBindBlock -match 'bind\("F9"') -and ($debugBindBlock -match 'bind\("F10"') -and `
                   ($debugBindBlock -match 'bind\("F11"') -and ($debugBindBlock -match 'bind\("F12"') -and `
                   ($debugBindBlock -match 'ui_debug_key') -and ($debugBindBlock -match 'bind\(CONFIG\.ui_debug_key') -and `
                   ($debugBindBlock -match 'open_route_menu\("debug_key"\)')
    $hasTerminalFProductEntry = ($luaText -match 'local function interact_with_terminal') -and `
                                ($luaText -match 'open_route_menu\("terminal_interact"\)') -and `
                                ($luaText -match 'product_entry=terminal_F')
    $hasReadyMarker = $luaText -match 'ready v%s; development_mode=%s product_entry=terminal_F'
    $hasArrivalGuard = ($luaText -match 'phase == "arrived" and CONFIG\.arrival_activation_required') -and `
                       ($luaText -match 'use ConfirmArrivalActivation')
    $hasWidgetRuntimeGate = ($luaText -match 'ui_widget_runtime_enabled = true') -and `
                            ($luaText -match 'CONFIG\.ui_widget_runtime_enabled and UEHelpers') -and `
                            ($luaText -match 'resolve_widget_class') -and `
                            ($luaText -match 'YEETUI:widget_mount_failed')
    $forbiddenLegacyUiTokens = @('WBP_PalExpedition', 'PalHUDDispatchParameter_MapObjectCharacterTeamMission', 'YEETEXPOPEN')
    $legacyUiTokensFound = @()
    foreach ($token in $forbiddenLegacyUiTokens) {
        if ($luaText.Contains($token)) {
            $legacyUiTokensFound += $token
            Write-Host " [VIOLATION] main.lua 包含禁止的原版遠征 UI token: $token" -ForegroundColor Red
        }
    }
    $forbiddenExpeditionCalls = @('RequestStartMission', 'RequestSelectMission', 'RequestSelectAssignedCharacter', 'CloseOverlayUIAll')
    $forbiddenExpeditionFound = $false
    foreach ($pattern in $forbiddenExpeditionCalls) {
        if ($luaText -match [regex]::Escape($pattern)) {
            $forbiddenExpeditionFound = $true
            Write-Host " [VIOLATION] main.lua 包含禁止的遠征原生 API: $pattern" -ForegroundColor Red
        }
    }
    Assert-Check -Name "main.lua 導出完整 CaravanCore API 與終端互動入口" -Condition $hasExports
    Assert-Check -Name "main.lua 僅在 development_mode 註冊 F8-F12 除錯入口" -Condition $hasKeyBinds
    Assert-Check -Name "main.lua 正式產品入口為終端原生 F 互動" -Condition $hasTerminalFProductEntry
    Assert-Check -Name "main.lua 保持 development_mode/product_entry=terminal_F ready marker" -Condition $hasReadyMarker
    Assert-Check -Name "main.lua 禁止 SetPhase 繞過抵達激活確認" -Condition $hasArrivalGuard
    Assert-Check -Name "main.lua 只在 cooked widget resolver 成功後掛載，失敗時 fail closed" -Condition $hasWidgetRuntimeGate
    Assert-Check -Name "main.lua 不含原版遠征 UI、dispatch parameter 與 YEETEXPOPEN" -Condition ($legacyUiTokensFound.Count -eq 0)
    Assert-Check -Name "main.lua 未調用禁止的遠征原生 API" -Condition (-not $forbiddenExpeditionFound)
}

# 5. 驗證 Blueprint-only YEETTerminal 互動契約
$interactionContractPath = Join-Path $repo 'LogicMods\YEET\INTERACTION-CONTRACT.json'
$hasInteractionContract = Test-Path $interactionContractPath
Assert-Check -Name "INTERACTION-CONTRACT.json 檔案存在" -Condition $hasInteractionContract
if ($hasInteractionContract) {
    try {
        $ijson = Get-Content -Raw -Encoding utf8 $interactionContractPath | ConvertFrom-Json
        $hasBlueprintOnlyInteraction = $ijson.runtime_cpp_dependency -eq $false
        $targetCall = [string]$ijson.blueprint_wiring.target_call
        $hasTargetCall = $targetCall -match 'BP_YEETTerminal\.YEET_RequestRouteMenu'
        $fallbackEntries = @($ijson.blueprint_wiring.bridge_priority | Where-Object { [string]$_ -match 'fallback' })
        $hasExactTerminalFallback = ($fallbackEntries.Count -gt 0) -and `
                                    (($fallbackEntries -join ' ') -match 'accept only exact BP_YEETTerminal_C instances')
        Assert-Check -Name "INTERACTION-CONTRACT 採用 Blueprint-only（runtime_cpp_dependency=false）" -Condition $hasBlueprintOnlyInteraction
        Assert-Check -Name "INTERACTION-CONTRACT target_call 指向 BP_YEETTerminal.YEET_RequestRouteMenu" -Condition $hasTargetCall
        Assert-Check -Name "INTERACTION-CONTRACT fallback 僅接受精確 BP_YEETTerminal_C" -Condition $hasExactTerminalFallback
    } catch {
        Assert-Check -Name "INTERACTION-CONTRACT JSON 解析" -Condition $false -Details $_.Exception.Message
    }
}

# 6. 嚴格檢查未證實之原生 API（禁令清單）
$forbiddenPatterns = @("OnPlayerEnterBaseCampArea", "SetEnableTick")
$forbiddenFound = $false
$codeFiles = Get-ChildItem -Path $repo -Recurse -Include *.lua,*.cpp,*.h -Exclude .git | Where-Object { $_.FullName -notmatch '\\tools\\' }
foreach ($file in $codeFiles) {
    $content = Get-Content -Raw -Encoding utf8 $file.FullName
    foreach ($pattern in $forbiddenPatterns) {
        if ($content -match $pattern) {
            $forbiddenFound = $true
            Write-Host " [VIOLATION] 檔案 $($file.FullName) 包含未證實 API: $pattern" -ForegroundColor Red
        }
    }
}
Assert-Check -Name "無違規調用未證實之原生 API (OnPlayerEnterBaseCampArea / SetEnableTick)" -Condition (-not $forbiddenFound)

# 7. 總結
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " 驗證結果: $passed 通過, $failed 失敗" -ForegroundColor ($failed -eq 0 ? 'Green' : 'Red')
Write-Host "==================================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    exit 1
}
