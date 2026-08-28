"""Core UI wiring checks for the real widget mount result and payload state."""

from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("main_ui_integration_spec.py: SKIP (Lupa is not installed)")
    raise SystemExit(0)


ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
scripts = str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/?.lua").replace("\\", "/")
lua.execute("package.path = " + repr(scripts) + " .. ';' .. package.path")
lua.execute(
    r'''
local controller = { alive = true }
function controller:IsValid() return self.alive end

local widget_class = { alive = true }
function widget_class:IsValid() return self.alive end

local widget = { alive = true, mount_fails = false, mounted = false }
function widget:IsValid() return self.alive end
function widget:AddToViewport()
    if self.mount_fails then return false end
    self.mounted = true
end
function widget:RemoveFromParent() self.mounted = false end

local widget_library = { alive = true }
function widget_library:IsValid() return self.alive end
function widget_library:Create() return widget end
function widget_library:SetInputMode_UIOnlyEx() end
function widget_library:SetInputMode_GameOnly() end
test_widget = widget

package.loaded['UEHelpers'] = {
    GetPlayerController = function() return controller end,
}
StaticFindObject = function(path)
    if path == '/Script/UMG.Default__WidgetBlueprintLibrary' then return widget_library end
    if path == '/Game/Mods/YEET/UI/WBP_YEETRouteMenu.WBP_YEETRouteMenu_C' then return widget_class end
    return nil
end
'''
)
lua.execute(
    "dofile(" + repr(str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/main.lua").replace("\\", "/")) + ")"
)
lua.execute(
    r'''
local core = YEET.CaravanCore
local mounted, mounted_payload = core.OpenRouteMenu('ui-test')
assert(mounted == true)
assert(mounted_payload:find('"open":true', 1, true))
assert(mounted_payload:find('"widget_asset_ready":true', 1, true))
core.CloseRouteMenu('ui-test')

test_widget.mount_fails = true
local failed, failed_payload = core.OpenRouteMenu('ui-test')
assert(failed == false)
assert(failed_payload:find('"open":false', 1, true))
'''
)

print("main_ui_integration_spec.py: UI mount/payload tests passed")
