"""Core wiring checks for exact-class terminal interaction and fail-closed hook setup."""

from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("main_terminal_integration_spec.py: SKIP (Lupa is not installed)")
    raise SystemExit(0)


ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
scripts = str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/?.lua").replace("\\", "/")
lua.execute("package.path = " + repr(scripts) + " .. ';' .. package.path")
lua.execute(
    "dofile(" + repr(str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/main.lua").replace("\\", "/")) + ")"
)

lua.execute(
    r'''
local core = YEET.CaravanCore
local class_path = '/Game/Mods/YEET/Buildings/BP_YEETTerminal.BP_YEETTerminal_C'
local function valid(self) return self.alive == true end
local function actor(class_name)
    local class = { alive = true, IsValid = valid,
        GetFullName = function() return class_name end }
    return { alive = true, IsValid = valid,
        GetClass = function() return class end,
        GetFullName = function() return class_name .. ':Instance_1' end }
end

assert(core.SimulationOnly == true)
assert(type(core.InjectTerminalInteractionBridge) == 'function')
assert(type(core.ProbeTerminalInteractionBridge) == 'function')
assert(type(core.InstallTerminalInteractionHook) == 'function')
assert(core.InteractWithTerminal(actor(class_path)) == true)
local denied, reason = core.InteractWithTerminal(actor('/Script/Pal.BP_BuildObject_WorkBench_C'))
assert(denied == false and reason == 'exact YEET terminal class required')
local injected = assert(core.InjectTerminalInteractionBridge({ class_path = class_path }))
assert(injected.read_only and injected.simulation_only == nil)
local ready, status = core.ProbeTerminalInteractionBridge()
assert(not ready and (status.reason == 'hook-signature-unverified'
    or status.reason == 'reversible-hook-api-unavailable'))
assert(core.InstallTerminalInteractionHook() == false)
assert(core.TerminalInteractionBridgeStatus().simulation_only == true)
assert(core.SimulationOnly == true)

-- Network routes have a separate domain store from legacy simulation routes;
-- the configured limit must count the domain store itself.
assert(core.SetWorldId('network-route-limit-spec'))
assert(core.RegisterTerminal({ id = 'A', base_guid = 'base-a', name = 'A' }))
assert(core.RegisterTerminal({ id = 'B', base_guid = 'base-b', name = 'B' }))
for index = 1, 32 do
    local created, reason = core.CreateNetworkRoute({
        id = 'network-route-' .. index, terminal_a = 'A', terminal_b = 'B',
    })
    assert(created, reason)
end
local over_limit, over_limit_reason = core.CreateNetworkRoute({
    id = 'network-route-over-limit', terminal_a = 'A', terminal_b = 'B',
})
assert(over_limit == false and over_limit_reason == 'route limit reached')
os.remove('YEET.state.network-route-limit-spec.json')
os.remove('YEET.state.network-route-limit-spec.json.bak')
'''
)

print("main_terminal_integration_spec.py: core terminal wiring tests passed")
