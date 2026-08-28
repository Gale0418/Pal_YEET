-- YEET inventory adapter
--
-- This module deliberately has no direct UE4SS/UObject calls.  The runtime
-- table is an injected boundary which must return plain Lua values only.  A
-- game integration can therefore be probed independently from the pure
-- request/verification state machine below.

local Adapter = {}

local function text(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function integer(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    value = math.floor(value)
    return value >= 0 and value or nil
end

local function copy_slot(slot)
    if type(slot) ~= "table" then return nil end
    local container_guid = slot.container_guid
    local slot_index = integer(slot.slot_index)
    local count = integer(slot.count)
    if not text(container_guid) or slot_index == nil or count == nil then return nil end
    local slot_id = slot.slot_id
    if type(slot_id) ~= "table" then
        slot_id = { container_guid = container_guid, slot_index = slot_index }
    end
    if slot_id.container_guid ~= container_guid
        or integer(slot_id.slot_index) ~= slot_index then
        return nil
    end
    local result = {
        container_guid = container_guid,
        slot_index = slot_index,
        slot_id = { container_guid = container_guid, slot_index = slot_index },
        item_id = text(slot.item_id) and slot.item_id or nil,
        count = count,
        max_stack = integer(slot.max_stack),
        is_empty = slot.is_empty == true or count == 0,
    }
    return result
end

local function copy_snapshot(snapshot)
    if type(snapshot) ~= "table" or snapshot.valid ~= true
        or not text(snapshot.container_guid) then
        return nil, "snapshot-invalid"
    end
    local slots = {}
    for _, source_slot in ipairs(snapshot.slots or {}) do
        local slot = copy_slot(source_slot)
        if not slot then return nil, "slot-identity-invalid" end
        if slot.container_guid ~= snapshot.container_guid then
            return nil, "slot-container-mismatch"
        end
        slots[#slots + 1] = slot
    end
    if #slots == 0 then return nil, "slots-empty" end
    return {
        container_guid = snapshot.container_guid,
        slots = slots,
        fresh = snapshot.fresh == true,
        filter_read_valid = snapshot.filter_read_valid == true,
        filter_off = snapshot.filter_off or {},
    }
end

local function route_key(spec)
    if text(spec.route_key) then return spec.route_key end
    return table.concat({
        tostring(spec.item_id or ""),
        tostring(spec.source.container_guid),
        tostring(spec.destination.container_guid),
    }, "\n")
end

local function valid_probe(result)
    if type(result) ~= "table" then return false end
    for _, key in ipairs({
        "discovery", "snapshot", "authority", "native_move", "out_params",
    }) do
        if result[key] ~= true then return false end
    end
    return true
end

function Adapter.new(runtime, options)
    options = options or {}
    return setmetatable({
        runtime = type(runtime) == "table" and runtime or {},
        cooldown_passes = math.max(1, integer(options.cooldown_passes) or 12),
        request_limit = math.max(1, integer(options.request_limit) or 1000),
        pass = 0,
        pending = nil,
        cooldown_until = {},
        probe = {
            discovery = false,
            snapshot = false,
            authority = false,
            native_move = false,
            out_params = false,
            complete = false,
        },
    }, { __index = Adapter })
end

function Adapter:status()
    return {
        ready = self.probe.complete == true,
        probe = {
            discovery = self.probe.discovery == true,
            snapshot = self.probe.snapshot == true,
            authority = self.probe.authority == true,
            native_move = self.probe.native_move == true,
            out_params = self.probe.out_params == true,
            complete = self.probe.complete == true,
        },
        pending = self.pending ~= nil,
        pass = self.pass,
    }
end

-- The integration must explicitly prove every uncertain UObject/out-param
-- boundary.  There is intentionally no force-ready or optimistic fallback.
function Adapter:run_probe()
    local callback = self.runtime.probe
    local ok, result = false, nil
    if type(callback) == "function" then
        ok, result = pcall(callback)
    end
    self.probe.discovery = ok and type(result) == "table" and result.discovery == true or false
    self.probe.snapshot = ok and type(result) == "table" and result.snapshot == true or false
    self.probe.authority = ok and type(result) == "table" and result.authority == true or false
    self.probe.native_move = ok and type(result) == "table" and result.native_move == true or false
    self.probe.out_params = ok and type(result) == "table" and result.out_params == true or false
    self.probe.complete = ok and valid_probe(result)
    if not self.probe.complete then return false, "probe-incomplete" end
    return true, self:status()
end

function Adapter:resolve(reference)
    if not self.probe.complete then return nil, "adapter-not-ready" end
    if type(self.runtime.resolve_container) ~= "function" then
        return nil, "container-discovery-unavailable"
    end
    local ok, resolved = pcall(self.runtime.resolve_container, reference)
    if not ok or type(resolved) ~= "table" or resolved.ready ~= true then
        return nil, "container-unresolved"
    end
    if not text(resolved.container_guid) or not text(resolved.base_guid)
        or not text(resolved.guild_guid) then
        return nil, "container-ownership-unresolved"
    end
    if resolved.container_kind ~= "ordinary" and resolved.container_kind ~= "feed_box" then
        return nil, "container-kind-unsupported"
    end
    return {
        container_guid = resolved.container_guid,
        base_guid = resolved.base_guid,
        guild_guid = resolved.guild_guid,
        container_kind = resolved.container_kind,
    }
end

function Adapter:snapshot(container)
    if not self.probe.complete then return nil, "adapter-not-ready" end
    if type(container) ~= "table" or not text(container.container_guid) then
        return nil, "container-invalid"
    end
    if type(self.runtime.snapshot_container) ~= "function" then
        return nil, "snapshot-unavailable"
    end
    local ok, result = pcall(self.runtime.snapshot_container, container)
    if not ok then return nil, "snapshot-failed" end
    return copy_snapshot(result)
end

function Adapter:advance_pass()
    self.pass = self.pass + 1
    for key, expiry in pairs(self.cooldown_until) do
        if type(expiry) ~= "number" or expiry <= self.pass then
            self.cooldown_until[key] = nil
        end
    end
    return self.pass
end

local function destination_capacity(destination, source)
    if destination.count > 0 then
        if destination.max_stack == nil then return nil end
        return math.max(0, destination.max_stack - destination.count)
    end
    if destination.max_stack and destination.max_stack > 0 then
        return destination.max_stack
    end
    return source.max_stack
end

function Adapter:submit(spec)
    if not self.probe.complete then return false, "adapter-not-ready" end
    if self.pending then return false, "transfer-pending" end
    if type(spec) ~= "table" or type(spec.source) ~= "table"
        or type(spec.destination) ~= "table" then
        return false, "source-and-destination-required"
    end
    local source = copy_slot(spec.source)
    local destination = copy_slot(spec.destination)
    if not source or not destination then return false, "slot-identity-invalid" end
    if source.container_guid == destination.container_guid
        and source.slot_index == destination.slot_index then
        return false, "source-destination-must-differ"
    end
    if not text(spec.item_id) or source.item_id ~= spec.item_id
        or source.count <= 0 then
        return false, "source-item-invalid"
    end
    if destination.item_id and destination.item_id ~= spec.item_id
        and destination.count > 0 then
        return false, "destination-item-mismatch"
    end
    local capacity = destination_capacity(destination, source)
    local requested = integer(spec.count)
    local count = requested and math.min(requested, source.count, capacity or 0, self.request_limit) or 0
    if count <= 0 then return false, "destination-capacity-unavailable" end
    local key = route_key({
        route_key = spec.route_key,
        item_id = spec.item_id,
        source = source,
        destination = destination,
    })
    if (self.cooldown_until[key] or 0) > self.pass then
        return false, "route-cooldown"
    end
    if type(self.runtime.has_authority) ~= "function" then
        return false, "authority-unavailable"
    end
    local authority_ok, authority = pcall(self.runtime.has_authority, spec)
    if not authority_ok or authority ~= true then return false, "not-authority" end
    if type(self.runtime.new_guid) ~= "function"
        or type(self.runtime.request_move) ~= "function" then
        return false, "native-move-unavailable"
    end
    local guid_ok, request_id = pcall(self.runtime.new_guid)
    if not guid_ok or request_id == nil then return false, "request-id-unavailable" end
    local payload = {
        request_id = request_id,
        to = { container_guid = destination.container_guid, slot_index = destination.slot_index },
        froms = {{
            SlotId = { container_guid = source.container_guid, slot_index = source.slot_index },
            Num = count,
        }},
    }
    local move_ok, move_error = pcall(self.runtime.request_move, payload)
    if not move_ok or move_error == false then return false, "native-move-failed" end
    self.pending = {
        route_key = key,
        item_id = spec.item_id,
        count = count,
        source = source,
        destination = destination,
        source_count_before = source.count,
        destination_count_before = destination.count,
        submit_pass = self.pass,
    }
    return true, self.pending
end

local function endpoint_changed(slot, item_id, before, direction)
    if type(slot) ~= "table" then return false end
    if direction == "decrease" and slot.item_id == nil and slot.count == 0 then
        return before > 0
    end
    if slot.item_id ~= item_id then return false end
    if type(slot.count) ~= "number" then return false end
    if direction == "increase" then return slot.count > before end
    return slot.count < before
end

function Adapter:verify_pending(observation)
    local pending = self.pending
    if not pending then return "idle" end
    if type(observation) ~= "table"
        or observation.source_fresh ~= true
        or observation.destination_fresh ~= true then
        return "awaiting-verification"
    end
    local source = copy_slot(observation.source)
    local destination = copy_slot(observation.destination)
    if not source or not destination then return "awaiting-verification" end
    if source.container_guid ~= pending.source.container_guid
        or source.slot_index ~= pending.source.slot_index
        or destination.container_guid ~= pending.destination.container_guid
        or destination.slot_index ~= pending.destination.slot_index then
        return "awaiting-verification"
    end
    local applied = endpoint_changed(destination, pending.item_id,
        pending.destination_count_before, "increase")
        or (not endpoint_changed(destination, pending.item_id,
            pending.destination_count_before, "increase")
            and endpoint_changed(source, pending.item_id,
                pending.source_count_before, "decrease"))
    self.pending = nil
    if applied then
        self.cooldown_until[pending.route_key] = nil
        return "applied"
    end
    self.cooldown_until[pending.route_key] = self.pass + self.cooldown_passes
    return "cooldown"
end

function Adapter:get_pending()
    return self.pending
end

return Adapter
