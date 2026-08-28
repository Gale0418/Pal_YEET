package.path = 'UE4SS/Mods/YEETCaravanCore/Scripts/?.lua;' .. package.path

local Adapter = require('inventory_adapter')

local function equal(actual, expected, label)
    assert(actual == expected, string.format('%s: expected %s, got %s', label, tostring(expected), tostring(actual)))
end

local requests = {}
local runtime = {
    probe = function()
        return {
            discovery = true, snapshot = true, authority = true,
            native_move = true, out_params = true,
        }
    end,
    resolve_container = function(reference)
        return reference
    end,
    snapshot_container = function(snapshot)
        return snapshot
    end,
    has_authority = function() return true end,
    new_guid = function() return 'request-1' end,
    request_move = function(payload)
        requests[#requests + 1] = payload
        return true
    end,
}

local adapter = Adapter.new(runtime, { cooldown_passes = 2, request_limit = 1000 })
equal(adapter:status().ready, false, 'adapter is not ready before probe')
equal(adapter:submit({}), false, 'unprobed adapter refuses move')
local probed = assert(adapter:run_probe())
equal(probed, true, 'complete probe enables adapter')

local container = assert(adapter:resolve({
    ready = true, container_guid = 'source', base_guid = 'base-a', guild_guid = 'guild-a',
    container_kind = 'ordinary',
}))
equal(container.container_guid, 'source', 'resolved container keeps exact GUID')
local _, unresolved_reason = adapter:resolve({
    ready = true, container_guid = 'feed', base_guid = 'base-a', guild_guid = nil,
    container_kind = 'feed_box',
})
equal(unresolved_reason, 'container-ownership-unresolved', 'unresolved guild is rejected')

local source = {
    container_guid = 'source', slot_index = 1, item_id = 'IronOre', count = 20, max_stack = 100,
    slot_id = { container_guid = 'source', slot_index = 1 },
}
local destination = {
    container_guid = 'destination', slot_index = 2, item_id = 'IronOre', count = 10, max_stack = 100,
    slot_id = { container_guid = 'destination', slot_index = 2 },
}
local moved, pending = adapter:submit({
    route_key = 'route-a', item_id = 'IronOre', count = 15,
    source = source, destination = destination,
})
assert(moved)
equal(#requests, 1, 'one native move is submitted')
equal(requests[1].to.container_guid, 'destination', 'native move targets exact destination container')
equal(requests[1].to.slot_index, 2, 'native move targets exact destination slot')
equal(requests[1].froms[1].SlotId.container_guid, 'source', 'native move carries exact source container')
equal(requests[1].froms[1].SlotId.slot_index, 1, 'native move carries exact source slot')
equal(requests[1].froms[1].Num, 15, 'native move is bounded by requested count')
equal(adapter:submit({
    route_key = 'route-b', item_id = 'IronOre', count = 1,
    source = source, destination = destination,
}), false, 'single in-flight pending blocks duplicate move')

local verification = adapter:verify_pending({
    source_fresh = true, destination_fresh = true,
    source = { container_guid = 'source', slot_index = 1, item_id = 'IronOre', count = 5 },
    destination = { container_guid = 'destination', slot_index = 2, item_id = 'IronOre', count = 25 },
})
equal(verification, 'applied', 'destination increase verifies move')

local _, pending2 = adapter:submit({
    route_key = 'route-a', item_id = 'IronOre', count = 1,
    source = source, destination = destination,
})
assert(pending2)
equal(adapter:verify_pending({
    source_fresh = false, destination_fresh = true,
    source = source, destination = destination,
}), 'awaiting-verification', 'stale source does not complete pending move')
equal(adapter:verify_pending({
    source_fresh = true, destination_fresh = true,
    source = source, destination = destination,
}), 'cooldown', 'unchanged endpoints cool route')
equal(adapter:submit({
    route_key = 'route-a', item_id = 'IronOre', count = 1,
    source = source, destination = destination,
}), false, 'cooled route refuses immediate retry')
adapter:advance_pass(); adapter:advance_pass()
local after_cooldown = adapter:submit({
    route_key = 'route-a', item_id = 'IronOre', count = 1,
    source = source, destination = destination,
})
equal(after_cooldown, true, 'route retry is allowed after cooldown expires')
equal(adapter:verify_pending({
    source_fresh = true, destination_fresh = true,
    source = { container_guid = 'source', slot_index = 1, item_id = 'IronOre', count = 19 },
    destination = { container_guid = 'destination', slot_index = 2, item_id = 'IronOre', count = 11 },
}), 'applied', 'post-cooldown retry can complete')

local bad_slot = adapter:submit({
    route_key = 'bad-slot', item_id = 'IronOre', count = 1,
    source = source,
    destination = {
        container_guid = 'destination', slot_index = 3, item_id = 'IronOre', count = 10,
        max_stack = 100, slot_id = { container_guid = 'wrong', slot_index = 3 },
    },
})
equal(bad_slot, false, 'inconsistent destination SlotId is rejected')

local denied = Adapter.new({
    probe = function() return {
        discovery = true, snapshot = true, authority = true,
        native_move = true, out_params = true,
    } end,
    has_authority = function() return false end,
    new_guid = function() return 'request-denied' end,
    request_move = function() error('must not be called') end,
}, {})
assert(denied:run_probe())
equal(denied:submit({
    item_id = 'IronOre', count = 1, source = source, destination = destination,
}), false, 'non-authority refuses before native call')

print('inventory_adapter_spec.lua: all tests passed')
