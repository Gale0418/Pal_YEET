"""Lupa integration checks for the UE4SS inventory runtime bridge.

The fake objects intentionally expose the same reflected method/property shape
used by Palworld.  No ItemSlotArray or StackCount assignment is present: the
bridge must read through the public getters and preserve native SlotId values.
"""

from pathlib import Path
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    print("inventory_runtime_spec.py: SKIP (Lupa is not installed)")
    raise SystemExit(0)


ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
scripts_path = str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/?.lua").replace("\\", "/")
lua.execute(
    "package.path = "
    + repr(scripts_path)
    + " .. ';' .. package.path"
)

lua.execute(
    r'''
local Runtime = require('inventory_runtime')

local function valid(self) return self.alive == true end
local function guid(value)
    return { ToString = function() return value end }
end
local function class(name)
    return {
        alive = true,
        IsValid = valid,
        GetFName = function() return { ToString = function() return name end } end,
    }
end
local function slot(container_guid, index, id, count)
    local native_id = {
        ContainerId = { ID = guid(container_guid) },
        SlotIndex = index,
    }
    local static = { ToString = function() return id or 'None' end }
    return {
        alive = true,
        IsValid = valid,
        GetSlotId = function() return native_id end,
        GetItemId = function() return { StaticId = static } end,
        GetStackCount = function() return count end,
        GetMaxStack = function() return 100 end,
        IsEmpty = function() return count == 0 end,
    }
end

local source_slot = slot('container-a', 0, 'IronOre', 20)
local empty_slot = slot('container-a', 1, nil, 0)
local container = {
    alive = true,
    IsValid = valid,
    GetId = function() return { ID = guid('container-a') } end,
    Num = function() return 2 end,
    Get = function(_, index) return index == 0 and source_slot or empty_slot end,
    GetFilterOffList = function() return { { ToString = function() return 'Food' end } } end,
}
local actor = {
    alive = true,
    IsValid = valid,
    GetClass = function() return class('BP_BuildObject_PalFoodBox_C') end,
    GetGroupIdBelongTo = function() return guid('guild-a') end,
    HasAuthority = function() return true end,
}
local base = {
    alive = true,
    IsValid = valid,
    GetInstanceId = function() return guid('base-a') end,
}
local model = {
    alive = true,
    IsValid = valid,
    GetItemContainerModule = function()
        return { alive = true, IsValid = valid, GetContainer = function() return container end }
    end,
    GetBaseCampModelBelongTo = function() return base end,
    GetBaseCampIdBelongTo = function() return guid('base-a') end,
    GetActor = function() return actor end,
}

local native_moves = {}
local network_item = {
    alive = true,
    IsValid = valid,
    RequestMove_ToServer = function(self, request_id, to, froms)
        native_moves[#native_moves + 1] = { request_id = request_id, to = to, froms = froms }
    end,
}
local guid_library = {
    alive = true,
    IsValid = valid,
    NewGuid = function() return guid('request-1') end,
}

runtime = Runtime.new({ network_item = network_item, static_find_object = function() return guid_library end })
resolved = assert(runtime:register_container({ actor = actor, model = model }))
assert(resolved.container_guid == 'container-a')
assert(resolved.base_guid == 'base-a')
assert(resolved.guild_guid == 'guild-a')
assert(resolved.container_kind == 'feed_box')

snapshot = assert(runtime:snapshot_container(resolved))
assert(snapshot.valid == true and snapshot.fresh == true)
assert(#snapshot.slots == 2)
assert(snapshot.slots[1].container_guid == 'container-a')
assert(snapshot.slots[1].slot_index == 0)
assert(snapshot.slots[1].item_id == 'IronOre')
assert(snapshot.slots[2].is_empty == true)
assert(snapshot.filter_read_valid == true and snapshot.filter_off.Food == true)

probe = runtime:probe()
assert(probe.discovery and probe.snapshot and probe.authority)
assert(probe.native_move and probe.out_params)

-- These are the exact plain-function calls made by inventory_adapter.
assert(runtime.probe().discovery == true) -- plain callback returns five capabilities
assert(runtime.resolve_container({ container_guid = 'container-a' }).ready == true)
assert(runtime.snapshot_container(resolved).valid == true)
assert(runtime.has_authority({ source = { container_guid = 'container-a' } }) == true)

assert(runtime:new_guid() ~= nil)
assert(runtime:request_move({
    request_id = guid('request-2'),
    to = { container_guid = 'container-a', slot_index = 1 },
    froms = {{ SlotId = { container_guid = 'container-a', slot_index = 0 }, Num = 5 }},
}) == true)
assert(#native_moves == 1)
assert(native_moves[1].to == empty_slot:GetSlotId())
assert(native_moves[1].froms[1].SlotId == source_slot:GetSlotId())
assert(native_moves[1].froms[1].Num == 5)

-- Unknown GUIDs and missing UObject state fail closed.
assert(runtime:request_move({
    request_id = guid('request-3'),
    to = { container_guid = 'unknown', slot_index = 0 },
    froms = {{ SlotId = { container_guid = 'container-a', slot_index = 0 }, Num = 1 }},
}) == false)

-- A valid container can lack GetClass; registration must fail closed rather
-- than calling :find on the nil class name.
local classless_container = {
    alive = true,
    IsValid = valid,
    GetId = function() return { ID = guid('container-without-class') } end,
}
local classless, classless_reason = runtime:register_container({ container = classless_container })
assert(classless == nil and classless_reason == 'container-ownership-unresolved')

local empty_runtime = Runtime.new()
local empty_probe = empty_runtime:probe()
assert(not empty_probe.discovery and not empty_probe.snapshot and not empty_probe.authority)
assert(not empty_probe.native_move and not empty_probe.out_params)
'''
)

print("inventory_runtime_spec.py: all Lupa fake-object tests passed")
