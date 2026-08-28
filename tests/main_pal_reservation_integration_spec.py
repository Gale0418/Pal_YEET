"""Core wiring checks for the explicit, fail-closed Pal reservation boundary."""

from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("main_pal_reservation_integration_spec.py: SKIP (Lupa is not installed)")
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
assert(core.SimulationOnly == true, 'product SimulationOnly must be fixed true')
assert(core.PalReservationStatus().ready == false, 'default runtime must be fail-closed')
assert(type(core.InjectPalReservationRuntime) == 'function')
assert(type(core.ProbePalReservationRuntime) == 'function')
assert(type(core.RegisterPal) == 'function')
assert(type(core.Reserve) == 'function')
assert(type(core.Release) == 'function')
assert(type(core.Reconcile) == 'function')
assert(type(core.Status) == 'function')
assert(type(core.InjectPal) == 'function')
assert(type(core.ProbePal) == 'function')
assert(type(core.ReservePal) == 'function')
assert(type(core.ReleasePal) == 'function')
assert(type(core.ReconcilePal) == 'function')
assert(type(core.StatusPal) == 'function')

local native_calls = { reserve = 0, release = 0, probe = 0 }
local ready = false
local registered = {}
local runtime = {}
function runtime:status()
    return { ready = ready, revision = native_calls.reserve + native_calls.release,
        capabilities = {}, reservations = registered, last_probe = nil }
end
function runtime:probe()
    native_calls.probe = native_calls.probe + 1
    ready = true
    return true, { verified = true }
end
function runtime:register_pal(spec)
    registered[spec.pal_guid] = { pal_guid = spec.pal_guid }
    return registered[spec.pal_guid]
end
function runtime:reserve(spec)
    if not ready then return false, 'runtime-not-ready' end
    native_calls.reserve = native_calls.reserve + 1
    return true, { pal_guid = spec.pal_guid, reservation_id = spec.reservation_id, state = 'reserved' }
end
function runtime:release(spec)
    if not ready then return false, 'runtime-not-ready' end
    native_calls.release = native_calls.release + 1
    return true, { status = 'released', pal_guid = spec.pal_guid }
end
function runtime:reconcile(observations)
    return ready, { cleared = {}, healthy = {}, conflicts = {}, unresolved = {}, mutations = 0 }
end

local injected = assert(core.InjectPalReservationRuntime(runtime))
assert(injected.ready == false, 'injection must not probe')
assert(native_calls.probe == 0, 'injection must not probe')
assert(native_calls.reserve == 0 and native_calls.release == 0, 'injection must not mutate')
local denied = core.Reserve({ pal_guid = 'pal-1', reservation_id = 'r-1' })
assert(denied == false and native_calls.reserve == 0, 'unprobed reserve must be refused')
local registered_ok, registered_result = core.RegisterPal({ pal_guid = 'pal-1' })
assert(registered_ok and registered_result.pal_guid == 'pal-1', 'RegisterPal delegates exact GUID')
assert(native_calls.reserve == 0 and native_calls.release == 0, 'registration must be read-only')
assert(core.ProbePalReservationRuntime() == true)
assert(core.PalReservationStatus().ready == true, 'probe result must be visible')
local reserve_ok, reserved = core.Reserve({ pal_guid = 'pal-1', reservation_id = 'r-1' })
assert(reserve_ok, 'explicit reserve succeeds after probe')
assert(reserved.state == 'reserved' and native_calls.reserve == 1)
assert(core.Release({ pal_guid = 'pal-1', reservation_id = 'r-1' }))
assert(native_calls.release == 1)
ready = false
assert(core.Status().ready == false, 'Status must query live runtime state')
assert(core.SimulationOnly == true, 'SimulationOnly cannot be changed by runtime readiness')
'''
)

print("main_pal_reservation_integration_spec.py: core/Pal wiring tests passed")
