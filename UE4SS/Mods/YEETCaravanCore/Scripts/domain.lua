local Domain = {}
Domain.SCHEMA_VERSION = 1

local function text(value) return type(value) == 'string' and value:match('%S') ~= nil end
local function integer(value, minimum, maximum)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
    value = math.floor(value)
    if value < minimum or value > maximum then return nil end
    return value
end
local function copy_list(values)
    local result = {}; for index, value in ipairs(values or {}) do result[index] = value end; return result
end
local function ensure_unique(values)
    local seen = {}
    for _, value in ipairs(values or {}) do
        if not text(value) or seen[value] then return false end
        seen[value] = true
    end
    return true
end

function Domain.new(world_id, now)
    return {
        schema_version = Domain.SCHEMA_VERSION,
        world_id = text(world_id) and world_id or 'unknown-world',
        updated_at = tonumber(now) or os.time(),
        terminals = {}, routes = {}, caravans = {}, pal_reservations = {},
        escrow = {}, processed_arrivals = {},
    }
end

function Domain.migrate(model)
    if type(model) ~= 'table' then return nil, 'state table required' end
    local version = tonumber(model.schema_version)
    if version == nil then
        if type(model.world_id) ~= 'string' or model.world_id == '' then return nil, 'legacy state missing world_id' end
        version = 0
    end
    if version == 0 then
        model.schema_version = 1
        model.created_at = tonumber(model.created_at) or os.time()
        model.updated_at = tonumber(model.updated_at) or model.created_at
    elseif version ~= Domain.SCHEMA_VERSION then
        return nil, 'unsupported schema: ' .. tostring(version)
    end
    return model
end

function Domain.normalize(model)
    local migrated, migrate_error = Domain.migrate(model)
    if not migrated then return nil, migrate_error end
    model = migrated
    for _, key in ipairs({ 'terminals', 'routes', 'caravans', 'pal_reservations', 'escrow', 'processed_arrivals' }) do
        if type(model[key]) ~= 'table' then model[key] = {} end
    end
    return model
end

function Domain.register_terminal(model, spec)
    if type(spec) ~= 'table' or not text(spec.id) or not text(spec.base_guid) or not text(spec.name) then
        return false, 'terminal id/base_guid/name required'
    end
    local existing = model.terminals[spec.id]
    if existing and existing.base_guid ~= spec.base_guid then return false, 'terminal id belongs to another base' end
    model.terminals[spec.id] = {
        id = spec.id, base_guid = spec.base_guid, name = spec.name,
        trade_container_guid = spec.trade_container_guid,
        escrow_container_guid = spec.escrow_container_guid,
        active = spec.active ~= false,
    }
    return true, model.terminals[spec.id]
end

function Domain.bind_escrow_container(model, terminal_id, escrow_container_guid)
    local terminal = model.terminals[terminal_id]
    if not terminal then return false, 'terminal not found' end
    if not text(escrow_container_guid) then return false, 'hidden escrow container GUID required' end
    if terminal.trade_container_guid == escrow_container_guid then
        return false, 'public trade and hidden escrow containers must differ'
    end
    terminal.escrow_container_guid = escrow_container_guid
    return true, terminal
end

function Domain.bind_trade_container(model, terminal_id, trade_container_guid)
    local terminal = model.terminals[terminal_id]
    if not terminal then return false, 'terminal not found' end
    if not text(trade_container_guid) then return false, 'interactive trade container GUID required' end
    terminal.trade_container_guid = trade_container_guid
    return true, terminal
end

function Domain.create_route(model, spec)
    if type(spec) ~= 'table' or not text(spec.id) then return false, 'route id required' end
    if model.routes[spec.id] then return false, 'route id already exists' end
    if spec.terminal_a == spec.terminal_b or not model.terminals[spec.terminal_a] or not model.terminals[spec.terminal_b] then
        return false, 'two distinct registered terminals required'
    end
    model.routes[spec.id] = {
        id = spec.id, terminal_a = spec.terminal_a, terminal_b = spec.terminal_b,
        enabled = spec.enabled ~= false, repeat_route = spec.repeat_route ~= false,
        cargo_rules = { a_to_b = {}, b_to_a = {} },
    }
    return true, model.routes[spec.id]
end

function Domain.set_cargo_rule(model, route_id, direction, rule)
    local route = model.routes[route_id]
    if not route then return false, 'route not found' end
    if direction ~= 'a_to_b' and direction ~= 'b_to_a' then return false, 'invalid direction' end
    local source_keep = integer(rule and rule.source_keep, 0, 999999999)
    local destination_target = integer(rule and rule.destination_target, 0, 999999999)
    local per_trip_cap = integer(rule and rule.per_trip_cap, 1, 999999999)
    local destination_kind = rule and rule.destination_kind or 'trade_box'
    if destination_kind ~= 'trade_box' and destination_kind ~= 'feed_box' then return false, 'invalid destination kind' end
    if destination_kind == 'feed_box' and not text(rule and rule.destination_container_guid) then
        return false, 'feed_box destination requires an exact container GUID'
    end
    if not text(rule and rule.item_id) or not source_keep or not destination_target or not per_trip_cap then
        return false, 'invalid cargo rule'
    end
    route.cargo_rules[direction][rule.item_id] = {
        item_id = rule.item_id, source_keep = source_keep,
        destination_target = destination_target, per_trip_cap = per_trip_cap,
        destination_kind = destination_kind,
        destination_container_guid = rule.destination_container_guid,
    }
    return true, route.cargo_rules[direction][rule.item_id]
end

function Domain.create_caravan(model, spec, now)
    if type(spec) ~= 'table' or not text(spec.id) or model.caravans[spec.id] then return false, 'unique caravan id required' end
    if not model.routes[spec.route_id] then return false, 'route not found' end
    if not ensure_unique(spec.pal_guids) or #(spec.pal_guids or {}) == 0 then return false, 'unique Pal GUIDs required' end
    for _, guid in ipairs(spec.pal_guids) do if model.pal_reservations[guid] then return false, 'Pal already reserved: ' .. guid end end
    local capacity = integer(spec.capacity, 1, 999999999)
    local eta_seconds = integer(spec.eta_seconds, 1, 604800)
    if not capacity or not eta_seconds then return false, 'capacity and eta_seconds required' end
    local caravan = {
        id = spec.id, route_id = spec.route_id, pal_guids = copy_list(spec.pal_guids),
        capacity = capacity, speed = tonumber(spec.speed) or 1, eta_seconds = eta_seconds,
        direction = spec.direction == 'b_to_a' and 'b_to_a' or 'a_to_b',
        state = 'scheduled', leg_sequence = 0, deadline = nil, error = nil,
    }
    model.caravans[spec.id] = caravan
    for _, guid in ipairs(caravan.pal_guids) do model.pal_reservations[guid] = spec.id end
    model.updated_at = tonumber(now) or os.time()
    return true, caravan
end

function Domain.release_caravan(model, caravan_id, allow_loaded)
    local caravan = model.caravans[caravan_id]
    if not caravan then return false, 'caravan not found' end
    if caravan.state == 'loading' then return false, 'caravan load recovery required' end
    if not allow_loaded and model.escrow[caravan_id] and next(model.escrow[caravan_id]) then return false, 'caravan has cargo escrow' end
    for _, guid in ipairs(caravan.pal_guids) do if model.pal_reservations[guid] == caravan_id then model.pal_reservations[guid] = nil end end
    model.caravans[caravan_id], model.escrow[caravan_id] = nil, nil
    return true
end

function Domain.plan_load(rule, source_count, destination_count, remaining_capacity)
    if type(rule) ~= 'table' then return 0 end
    return math.max(0, math.min(
        math.max(0, (tonumber(source_count) or 0) - rule.source_keep),
        math.max(0, rule.destination_target - (tonumber(destination_count) or 0)),
        rule.per_trip_cap,
        math.max(0, tonumber(remaining_capacity) or 0)))
end

function Domain.prepare_leg(model, caravan_id, counts, now)
    local caravan, route = model.caravans[caravan_id], nil
    if caravan then route = model.routes[caravan.route_id] end
    if not caravan or not route or not route.enabled then return false, 'caravan or enabled route missing' end
    if caravan.state ~= 'scheduled' and caravan.state ~= 'arrived' then return false, 'caravan cannot depart from ' .. tostring(caravan.state) end
    local source_terminal_id = caravan.direction == 'a_to_b' and route.terminal_a or route.terminal_b
    local source_terminal = model.terminals[source_terminal_id]
    if not source_terminal or not text(source_terminal.escrow_container_guid) then
        return false, 'source terminal hidden escrow container is not bound'
    end
    local rules = route.cargo_rules[caravan.direction] or {}
    local cargo, remaining = {}, caravan.capacity
    local item_ids = {}
    for item_id in pairs(rules) do item_ids[#item_ids + 1] = item_id end
    table.sort(item_ids)
    for _, item_id in ipairs(item_ids) do
        local rule = rules[item_id]
        local item_counts = counts and counts[item_id] or {}
        local amount = Domain.plan_load(rule, item_counts.source, item_counts.destination, remaining)
        if amount > 0 then cargo[item_id], remaining = amount, remaining - amount end
    end
    caravan.leg_sequence = caravan.leg_sequence + 1
    caravan.leg_id = string.format('%s:%d:%s', caravan.id, caravan.leg_sequence, caravan.direction)
    caravan.state, caravan.deadline, caravan.error = 'loading', nil, nil
    caravan.load_plan = cargo
    caravan.escrow_container_guid = source_terminal.escrow_container_guid
    return true, {
        caravan = caravan, cargo = cargo, leg_id = caravan.leg_id,
        escrow_container_guid = caravan.escrow_container_guid,
    }
end

function Domain.confirm_load(model, caravan_id, confirmed, now)
    local caravan = model.caravans[caravan_id]
    if not caravan or caravan.state ~= 'loading' then return false, 'loading caravan required' end
    local cargo, total = {}, 0
    for item_id, amount in pairs(confirmed or {}) do
        local planned = (caravan.load_plan or {})[item_id] or 0
        local applied = integer(amount, 0, planned)
        if not applied then return false, 'invalid confirmed load for ' .. item_id end
        if applied > 0 then cargo[item_id], total = applied, total + applied end
    end
    if total > caravan.capacity then return false, 'confirmed load exceeds caravan capacity' end
    model.escrow[caravan.id] = cargo
    caravan.load_plan = nil
    caravan.state, caravan.deadline, caravan.error =
        'traveling', (tonumber(now) or os.time()) + caravan.eta_seconds, nil
    return true, { caravan = caravan, cargo = cargo, leg_id = caravan.leg_id }
end

function Domain.mark_arrival(model, caravan_id, now)
    local caravan = model.caravans[caravan_id]
    if not caravan or caravan.state ~= 'traveling' then return false, 'traveling caravan required' end
    if (tonumber(now) or os.time()) < (caravan.deadline or math.huge) then return false, 'not due' end
    if model.processed_arrivals[caravan.leg_id] then return false, 'arrival already processed' end
    caravan.state, caravan.deadline = 'arrival_pending_activation', tonumber(now) or os.time()
    return true, caravan
end

function Domain.confirm_activation(model, caravan_id, activation_token)
    local caravan = model.caravans[caravan_id]
    if not caravan or caravan.state ~= 'arrival_pending_activation' or not text(activation_token) then
        return false, 'pending caravan and activation token required'
    end
    caravan.activation_token, caravan.state = activation_token, 'unloading'
    return true, caravan
end

function Domain.commit_unload(model, caravan_id, accepted)
    local caravan, cargo = model.caravans[caravan_id], model.escrow[caravan_id] or {}
    if not caravan or caravan.state ~= 'unloading' then return false, 'unloading caravan required' end
    for item_id, amount in pairs(accepted or {}) do
        local current = cargo[item_id] or 0
        local applied = integer(amount, 0, current)
        if not applied then return false, 'invalid accepted amount for ' .. item_id end
        cargo[item_id] = current - applied
        if cargo[item_id] == 0 then cargo[item_id] = nil end
    end
    if next(cargo) then caravan.state, caravan.error = 'blocked_destination_full', 'destination_full'; return true, caravan end
    model.processed_arrivals[caravan.leg_id] = true
    model.escrow[caravan_id] = nil
    caravan.state, caravan.error = 'arrived', nil
    local route = model.routes[caravan.route_id]
    if route and route.repeat_route then
        caravan.direction = caravan.direction == 'a_to_b' and 'b_to_a' or 'a_to_b'
        caravan.state = 'scheduled'
    end
    return true, caravan
end

function Domain.tick(model, now)
    local due = {}
    for id, caravan in pairs(model.caravans) do
        if caravan.state == 'traveling' and (tonumber(now) or os.time()) >= (caravan.deadline or math.huge) then due[#due + 1] = id end
    end
    table.sort(due)
    return due
end

return Domain
