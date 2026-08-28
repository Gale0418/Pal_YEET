"""Lupa contract tests for the fail-closed Pal reservation boundary.

The fake Pal exposes getter-shaped methods only.  Native mutation is an
explicit injected callback so the module cannot accidentally write a reflected
array, party, work list, or condensing state.  A passing fake test is not real
game evidence; the probe's ``verified`` flag is deliberately part of the
runtime contract and must come from a separately documented host experiment.
"""

from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("pal_reservation_runtime_spec.py: SKIP (Lupa is not installed)")
    raise SystemExit(0)

ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
scripts_path = str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/?.lua").replace("\\", "/")
lua.execute("package.path = " + repr(scripts_path) + " .. ';' .. package.path")
lua.execute(
    r'''
local Runtime = require('pal_reservation_runtime')

local function valid(self) return self.alive == true end
local native_calls = { reserve = 0, release = 0 }
local pals = {}

local function fake_pal(guid, base)
    local pal = {
        alive = true, guid = guid, base = base, base_exists = true,
        condensed = false, reserved_by = nil,
    }
    function pal:IsValid() return valid(self) end
    function pal:GetIndividualID() return self.guid end
    function pal:GetBaseCampId() return self.base end
    function pal:IsCondensed() return self.condensed end
    function pal:IsBaseCampValid() return self.base_exists end
    function pal:IsReserved() return self.reserved_by ~= nil end
    function pal:GetReservedBy() return self.reserved_by end
    pals[guid] = pal
    return pal
end

local pal1 = fake_pal('pal-001', 'base-a')
local pal2 = fake_pal('pal-002', 'base-a')

local function snapshot(spec)
    local pal = pals[spec.pal_guid]
    if not pal or not pal:IsValid() then
        return { pal_guid = spec.pal_guid, fresh = true, present = false,
            condensed = false, base_exists = false, reserved = false }
    end
    return {
        pal_guid = pal:GetIndividualID(), fresh = true, present = true,
        condensed = pal:IsCondensed(), base_exists = pal:IsBaseCampValid(),
        base_guid = pal:GetBaseCampId(), reserved = pal:IsReserved(),
        reserved_by = pal:GetReservedBy(),
    }
end

local function resolve(spec)
    local pal = pals[spec.pal_guid]
    if not pal or not pal:IsValid() then return nil end
    return { pal_guid = pal:GetIndividualID(), object = pal }
end

local runtime = Runtime.new({
    probe = function()
        return { discovery = true, snapshot = true, authority = true,
            reserve = true, release = true, reconcile = true, verified = true }
    end,
    resolve_pal = resolve,
    snapshot_pal = snapshot,
    has_authority = function(spec)
        return spec.resolved and spec.resolved.object:IsValid()
    end,
    native_reserve = function(payload)
        native_calls.reserve = native_calls.reserve + 1
        payload.resolved.object.reserved_by = payload.reservation_id
        return true
    end,
    native_release = function(payload)
        native_calls.release = native_calls.release + 1
        payload.resolved.object.reserved_by = nil
        return true
    end,
})

local status = runtime:status()
assert(status.ready == false, 'runtime is not ready before probe')
assert(runtime:reserve({ pal_guid = 'pal-001', reservation_id = 'caravan-1' }) == false,
    'unprobed runtime refuses reserve')
local probed = assert(runtime:probe())
assert(probed == true and runtime:status().ready == true, 'complete probe enables runtime')

local ok, reservation = runtime:reserve({ pal_guid = 'pal-001', reservation_id = 'caravan-1' })
assert(ok and reservation.state == 'reserved', 'reserve requires exact post-readback')
assert(native_calls.reserve == 1, 'one explicit native reserve')
assert(runtime:reserve({ pal_guid = 'pal-001', reservation_id = 'caravan-2' }) == false,
    'same Pal GUID cannot be reserved twice')
assert(runtime:reserve({ pal_guid = 'pal-002', reservation_id = 'caravan-1' }) == false,
    'reservation id cannot own another Pal')

local released, release_result = runtime:release({ pal_guid = 'pal-001', reservation_id = 'caravan-1' })
assert(released and release_result.status == 'released', 'release requires exact post-readback')
assert(native_calls.release == 1, 'one explicit native release')

assert(runtime:reserve({ pal_guid = 'pal-001', reservation_id = 'caravan-3' }))
pal1.alive = false
local lost, lost_result = runtime:release({ pal_guid = 'pal-001', reservation_id = 'caravan-3' })
assert(lost and lost_result.status == 'cleared-unavailable', 'lost Pal clears stale ledger')
assert(native_calls.release == 1, 'lost Pal does not call native release')

assert(runtime:reserve({ pal_guid = 'pal-002', reservation_id = 'caravan-4' }))
pal2.condensed = true
local reconcile_ok, reconcile_result = runtime:reconcile()
assert(reconcile_ok and #reconcile_result.cleared == 1, 'condensed Pal is reconciled away')
assert(native_calls.reserve == 3 and native_calls.release == 1,
    'reconcile never reserves, releases, or copies')
assert(runtime:status().reservations['pal-002'] == nil, 'condensed Pal cannot remain reserved')

-- An authority-negative or stale snapshot must stop before native mutation.
pal1.alive = true
pal1.condensed = false
-- The unavailable release above intentionally leaves native state untouched;
-- clear that fake native owner before isolating the authority case.
pal1.reserved_by = nil
local authority_enabled = false
local original_authority = runtime.options.has_authority
runtime.options.has_authority = function(spec)
    return authority_enabled and original_authority(spec) or false
end
local denied = runtime:reserve({ pal_guid = 'pal-001', reservation_id = 'denied' })
assert(denied == false and native_calls.reserve == 3, 'non-Host refuses native reserve')
authority_enabled = true
local stale = false
local original_snapshot = runtime.options.snapshot_pal
runtime.options.snapshot_pal = function(spec)
    local value = original_snapshot(spec)
    if stale then value.fresh = false end
    return value
end
stale = true
assert(runtime:reserve({ pal_guid = 'pal-001', reservation_id = 'stale' }) == false,
    'stale readback refuses native reserve')
assert(native_calls.reserve == 3, 'stale snapshot does not call native reserve')
stale = false
runtime.options.snapshot_pal = original_snapshot

local base_deleted = runtime:reserve({ pal_guid = 'pal-001', reservation_id = 'base-delete' })
assert(base_deleted, 'healthy Pal can be reserved after stale probe')
pal1.base_exists = false
local base_ok, base_result = runtime:reconcile()
assert(base_ok and #base_result.cleared == 1 and base_result.cleared[1].reason == 'base-deleted',
    'deleted base clears stale ledger')
assert(native_calls.reserve == 4 and native_calls.release == 1,
    'deleted base does not trigger native mutation')

local empty = Runtime.new()
local empty_ok, empty_probe = empty:probe()
assert(empty_ok == false and empty_probe.discovery == false and empty_probe.verified == false,
    'missing runtime stays fail-closed')
'''
)

print("pal_reservation_runtime_spec.py: all Lupa fake-UObject tests passed")
