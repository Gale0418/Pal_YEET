"""Core/runtime wiring checks.

This intentionally uses plain Lua callbacks: the real inventory_runtime has
the same adapter boundary, while this test verifies that main.lua does not
probe or submit a move implicitly during injection/capture.
"""

from pathlib import Path
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    print("main_inventory_integration_spec.py: SKIP (Lupa is not installed)")
    raise SystemExit(0)


ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
scripts = str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/?.lua").replace("\\", "/")
lua.execute("package.path = " + repr(scripts) + " .. ';' .. package.path")
lua.execute("dofile(" + repr(str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/main.lua").replace("\\", "/")) + ")")

lua.execute(
    r'''
local core = YEET.CaravanCore
assert(type(core.InjectInventoryRuntime) == 'function')
assert(type(core.ProbeInventoryRuntime) == 'function')
assert(type(core.RegisterContainer) == 'function')
assert(type(core.CaptureActor) == 'function')
assert(type(core.GetInventoryRuntimeStatus) == 'function')
assert(core.SimulationOnly == true)
assert(core.GetInventoryAdapterStatus().ready == false)

local move_calls = 0
local function reference(first, second)
    return second or first
end
local runtime = {
    probe = function()
        return {
            discovery = true, snapshot = true, authority = true,
            native_move = true, out_params = true,
        }
    end,
    register_container = function(first, second)
        local ref = reference(first, second)
        return { ready = true, container_guid = ref.container_guid or 'captured',
            base_guid = 'base-a', guild_guid = 'guild-a', container_kind = 'ordinary' }
    end,
    capture_actor = function(first, second)
        local ref = reference(first, second)
        return { ready = true, container_guid = ref.container_guid or 'captured',
            base_guid = 'base-a', guild_guid = 'guild-a', container_kind = 'ordinary' }
    end,
    resolve_container = function(reference_value) return reference_value end,
    snapshot_container = function(snapshot)
        return { valid = true, container_guid = snapshot.container_guid,
            fresh = true, slots = {{ container_guid = snapshot.container_guid,
                slot_index = 0, count = 1, item_id = 'IronOre' }}}
    end,
    has_authority = function() return true end,
    new_guid = function() return 'request-1' end,
    request_move = function() move_calls = move_calls + 1; return true end,
}

local injected = assert(core.InjectInventoryRuntime(runtime))
assert(injected.ready == false)
assert(core.RegisterContainer({ container_guid = 'container-a' }).ready == true)
assert(core.CaptureActor({ container_guid = 'container-a' }).ready == true)
assert(core.GetInventoryRuntimeStatus().ready == false)
assert(core.ProbeInventoryRuntime() == true)
assert(core.GetInventoryRuntimeStatus().ready == true)
assert(move_calls == 0)
assert(core.GetInventoryRuntimeStatus().simulation_only == true)
'''
)

print("main_inventory_integration_spec.py: core/runtime wiring tests passed")
