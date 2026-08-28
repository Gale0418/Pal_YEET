package.path = 'UE4SS/Mods/YEETCaravanCore/Scripts/?.lua;' .. package.path

local Domain = require('domain')
local Json = require('json')
local InventoryPolicy = require('inventory_policy')

local function equal(actual, expected, label)
    assert(actual == expected, string.format('%s: expected %s, got %s', label, tostring(expected), tostring(actual)))
end

local model = Domain.new('world-test', 100)
assert(Domain.register_terminal(model, { id = 'A', base_guid = 'base-a', name = '農場' }))
assert(Domain.register_terminal(model, { id = 'B', base_guid = 'base-b', name = '工廠' }))
assert(Domain.bind_trade_container(model, 'A', 'a-trade-box'))
assert(Domain.bind_trade_container(model, 'B', 'b-trade-box'))
assert(Domain.bind_escrow_container(model, 'A', 'a-hidden-escrow'))
assert(Domain.bind_escrow_container(model, 'B', 'b-hidden-escrow'))
assert(Domain.create_route(model, { id = 'route-1', terminal_a = 'A', terminal_b = 'B', repeat_route = true }))
assert(Domain.set_cargo_rule(model, 'route-1', 'a_to_b', {
    item_id = 'IronOre', source_keep = 500, destination_target = 1000, per_trip_cap = 400,
}))
assert(Domain.set_cargo_rule(model, 'route-1', 'a_to_b', {
    item_id = 'RedBerries', source_keep = 100, destination_target = 2000, per_trip_cap = 500,
    destination_kind = 'feed_box', destination_container_guid = 'b-feed-box',
}))
local invalid_nan = Domain.set_cargo_rule(model, 'route-1', 'a_to_b', {
    item_id = 'InvalidNaN', source_keep = 0 / 0, destination_target = 1, per_trip_cap = 1,
})
equal(invalid_nan, false, 'NaN cargo limits are rejected')
local invalid_infinity = Domain.set_cargo_rule(model, 'route-1', 'a_to_b', {
    item_id = 'InvalidInfinity', source_keep = 0, destination_target = math.huge, per_trip_cap = 1,
})
equal(invalid_infinity, false, 'infinite cargo limits are rejected')
equal(model.routes['route-1'].cargo_rules.a_to_b.RedBerries.destination_kind, 'feed_box',
    'food can target an exact Feed Box')
equal(InventoryPolicy.resolve_destination(
    model.routes['route-1'].cargo_rules.a_to_b.RedBerries, model.terminals.B),
    'b-feed-box', 'food resolves to the exact vanilla Feed Box')
equal(InventoryPolicy.resolve_destination(
    model.routes['route-1'].cargo_rules.a_to_b.IronOre, model.terminals.B),
    'b-trade-box', 'ordinary cargo resolves to the interactive YEET trade box')
local invalid_destination, invalid_reason = InventoryPolicy.resolve_destination({ destination_kind = 'player_inventory' }, model.terminals.B)
equal(invalid_destination, nil, 'unknown destination kinds fail closed')
equal(invalid_reason, 'invalid destination kind', 'unknown destination kind reports an explicit reason')

local ok, caravan = Domain.create_caravan(model, {
    id = 'caravan-1', route_id = 'route-1', pal_guids = { 'pal-1', 'pal-2' },
    capacity = 300, eta_seconds = 10, speed = 2,
}, 100)
assert(ok)
equal(model.pal_reservations['pal-1'], 'caravan-1', 'Pal is formally reserved')
equal(Domain.plan_load(model.routes['route-1'].cargo_rules.a_to_b.IronOre, 900, 600, 300), 300,
    'load is bounded by caravan capacity')

local departed, leg = Domain.prepare_leg(model, 'caravan-1', {
    IronOre = { source = 900, destination = 600 },
}, 100)
assert(departed)
equal(leg.cargo.IronOre, 300, 'planned cargo waits for physical escrow confirmation')
equal(leg.escrow_container_guid, 'a-hidden-escrow', 'departure uses the source terminal hidden escrow')
equal(caravan.state, 'loading', 'caravan cannot depart before escrow snapshot confirmation')
local requests = assert(InventoryPolicy.build_load_requests(leg.leg_id, leg.cargo, {
    { item_id = 'IronOre', count = 120, container_guid = 'source-box-2', slot_index = 4 },
    { item_id = 'IronOre', count = 250, container_guid = 'source-box-1', slot_index = 1 },
}))
equal(#requests, 2, 'base-wide cargo can be collected from multiple source containers')
equal(requests[1].from_container_guid, 'source-box-1', 'load requests have deterministic ordering')
equal(requests[1].count, 250, 'first source slot is consumed up to its observed count')
equal(requests[2].count, 50, 'remaining cargo is collected from the next source slot')
local observed = InventoryPolicy.observed_acceptance({ IronOre = 90 }, { IronOre = 290 }, leg.cargo)
equal(observed.IronOre, 200, 'unload only commits the positive destination snapshot delta')
local load_confirmed, confirmed_leg = Domain.confirm_load(model, 'caravan-1', { IronOre = 300 }, 100)
assert(load_confirmed)
equal(confirmed_leg.cargo.IronOre, 300, 'only physically confirmed cargo enters escrow state')
equal(caravan.state, 'traveling', 'caravan starts traveling')
equal(#Domain.tick(model, 109), 0, 'caravan is not due early')
equal(#Domain.tick(model, 110), 1, 'caravan is due at ETA')
assert(Domain.mark_arrival(model, 'caravan-1', 110))
equal(caravan.state, 'arrival_pending_activation', 'arrival waits for activation')
assert(Domain.confirm_activation(model, 'caravan-1', 'base-b:leg-1'))
assert(Domain.commit_unload(model, 'caravan-1', { IronOre = 200 }))
equal(caravan.state, 'blocked_destination_full', 'partial unload blocks without losing escrow')
equal(model.escrow['caravan-1'].IronOre, 100, 'remaining cargo stays in escrow')
caravan.state = 'unloading'
assert(Domain.commit_unload(model, 'caravan-1', { IronOre = 100 }))
equal(caravan.state, 'scheduled', 'repeating route schedules reverse leg')
equal(caravan.direction, 'b_to_a', 'direction reverses after complete unload')
equal(model.escrow['caravan-1'], nil, 'empty escrow is removed')

local duplicate_ok = Domain.create_caravan(model, {
    id = 'caravan-2', route_id = 'route-1', pal_guids = { 'pal-1' }, capacity = 10, eta_seconds = 10,
}, 120)
equal(duplicate_ok, false, 'reserved Pal cannot join another caravan')

local encoded = Json.encode(model)
local decoded = Json.decode(encoded)
equal(decoded.world_id, 'world-test', 'JSON round trip keeps world id')
equal(decoded.caravans['caravan-1'].direction, 'b_to_a', 'JSON round trip keeps caravan state')

print('domain_spec.lua: all tests passed')
