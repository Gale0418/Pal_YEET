-- YEET inventory UE4SS runtime bridge
--
-- This module is the only place where inventory_adapter's injected callbacks
-- touch Palworld UObjects.  The adapter deliberately passes plain Lua slot
-- descriptions; this bridge resolves those descriptions back to the exact
-- FPalItemSlotId values returned by UPalItemSlot:GetSlotId().  No replicated
-- ItemSlotArray or StackCount property is ever written.

local Runtime = {}
Runtime.__index = Runtime

local NETWORK_TRANSMITTER_CLASSES = {
    "BP_PalNetworkTransmitter_C",
    "PalNetworkTransmitter",
}
local GUID_LIBRARY_PATH = "/Script/Engine.Default__KismetGuidLibrary"

local function text(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function valid(object)
    if object == nil then return false end
    local ok, checker = pcall(function() return object.IsValid end)
    if not ok or type(checker) ~= "function" then return false end
    ok, checker = pcall(function() return object:IsValid() end)
    return ok and checker == true
end

local function unwrap(value)
    if value == nil then return nil end
    for _ = 1, 2 do
        local unwrapped
        local ok = pcall(function() unwrapped = value:get() end)
        if not ok or unwrapped == nil or unwrapped == value then break end
        value = unwrapped
    end
    return value
end

local function call0(object, name)
    if not valid(object) then return nil end
    local method
    local ok = pcall(function() method = object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    local result
    ok, result = pcall(function() return method(object) end)
    return ok and unwrap(result) or nil
end

-- Reflected UStruct values (FGuid/FName/FPalItemId) are not UObjects and do
-- not expose IsValid().  Their ToString methods still need safe invocation.
local function raw_call0(object, name)
    if object == nil then return nil end
    local method
    local ok = pcall(function() method = object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    local result
    ok, result = pcall(function() return method(object) end)
    return ok and unwrap(result) or nil
end

local function call_first_two(object, name)
    if not valid(object) then return nil, nil end
    local method
    local ok = pcall(function() method = object[name] end)
    if not ok or type(method) ~= "function" then return nil, nil end
    local first, second
    ok, first, second = pcall(function() return method(object) end)
    if not ok then return nil, nil end
    return unwrap(first), unwrap(second)
end

local function first_valid_value(values)
    if type(values) ~= "table" then return nil end
    for _, value in pairs(values) do
        value = unwrap(value)
        if valid(value) then return value end
    end
    return nil
end

local function call_with_out(object, name)
    if not valid(object) then return nil end
    local method
    local ok = pcall(function() method = object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    local out = {}
    local first, second
    ok, first, second = pcall(function() return method(object, out) end)
    if not ok then return nil end
    return first_valid_value(out) or (valid(unwrap(second)) and unwrap(second))
        or (valid(unwrap(first)) and unwrap(first))
end

local function property(object, name)
    if object == nil then return nil end
    local result
    local ok = pcall(function() result = object[name] end)
    return ok and unwrap(result) or nil
end

local function guid_string(value)
    value = unwrap(value)
    if value == nil then return nil end
    if text(value) then return value end

    local rendered = raw_call0(value, "ToString")
    if text(rendered) and rendered ~= "None" then return rendered end

    local a, b, c, d
    local ok = pcall(function()
        a, b, c, d = value.A, value.B, value.C, value.D
    end)
    if ok and type(a) == "number" and type(b) == "number"
        and type(c) == "number" and type(d) == "number" then
        local function uint32(number)
            if number < 0 then return number + 4294967296 end
            return number
        end
        return string.format("%08X-%08X-%08X-%08X",
            uint32(a), uint32(b), uint32(c), uint32(d))
    end
    return nil
end

local function object_key(object)
    if not valid(object) then return nil end
    local full_name = call0(object, "GetFullName")
    return text(full_name) and full_name or tostring(object)
end

local function foreach(values, callback)
    if type(values) == "table" then
        for index, value in ipairs(values) do callback(index - 1, unwrap(value)) end
        return true
    end
    if values == nil then return false end
    local ok = pcall(function() values:ForEach(function(index, value)
        callback(index, unwrap(value))
    end) end)
    return ok
end

local function container_id(container)
    local id = call0(container, "GetId")
    return guid_string(property(id, "ID"))
end

local function class_name(object)
    local class = call0(object, "GetClass")
    if not valid(class) then return nil end
    local full_name = call0(class, "GetFullName")
    if text(full_name) then return full_name end
    local fname = call0(class, "GetFName")
    local name = raw_call0(fname, "ToString")
    return text(name) and name or nil
end

local function item_id(slot)
    local item = call0(slot, "GetItemId")
    local static_id = property(item, "StaticId")
    local rendered = raw_call0(static_id, "ToString")
    if not text(rendered) then rendered = guid_string(static_id) end
    if rendered == "None" then return nil end
    return text(rendered) and rendered or nil
end

local function slot_identity(slot)
    local slot_id = call0(slot, "GetSlotId")
    local id = property(slot_id, "ContainerId")
    local guid = guid_string(property(id, "ID"))
    local index = tonumber(property(slot_id, "SlotIndex"))
    if not guid or not index then return nil end
    index = math.floor(index)
    if index < 0 then return nil end
    return {
        container_guid = guid,
        slot_index = index,
        native = slot_id,
    }
end

local function number_call(object, name)
    local value = call0(object, name)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return math.floor(value)
end

local function read_filter_off(container)
    local filter = call0(container, "GetFilterOffList")
    local result = {}
    if filter == nil then return result, false end
    local seen = foreach(filter, function(_, value)
        value = raw_call0(value, "ToString") or (type(value) == "string" and value)
        if text(value) then result[value] = true end
    end)
    return result, seen
end

local function map_slot(self, identity, native_slot)
    local key = identity.container_guid .. "\n" .. tostring(identity.slot_index)
    self.slots[key] = {
        native = identity.native,
        object = native_slot,
    }
end

local function resolve_container_object(self, reference)
    if type(reference) ~= "table" then return nil end
    local guid = reference.container_guid
    if text(guid) and self.containers[guid] then
        local cached = self.containers[guid]
        if valid(cached.object) then return cached end
        self.containers[guid] = nil
    end

    local object = reference.container or reference.object
        or reference.actor or reference.model
    object = unwrap(object)
    if not valid(object) then return nil end

    local actor = reference.actor
    local model = reference.model
    if not valid(model) then
        local first, second = call_first_two(object, "TryGetConcreteModel")
        model = valid(second) and second or (valid(first) and first or nil)
        model = model or call_with_out(object, "TryGetConcreteModel")
            or call0(object, "GetConcreteModel")
    end
    local object_class = class_name(object)
    if not valid(model) and object_class and object_class:find("ConcreteModel", 1, true) then
        model = object
    end

    local container = object
    if valid(model) then
        local module = call0(model, "GetItemContainerModule")
        container = call0(module, "GetContainer")
            or call0(module, "GetItemContainer_ItemContainerAccessInterface")
            or call_with_out(module, "TryGetContainer")
            or container
    end
    if not valid(container) then return nil end
    guid = container_id(container)
    if not text(guid) then return nil end
    actor = valid(actor) and actor or (valid(model) and call0(model, "GetActor") or nil)
    return {
        object = container,
        actor = actor,
        model = model,
        container_guid = guid,
        source = reference,
    }
end

local function metadata(self, resolved, reference)
    local model = resolved.model
    local actor = resolved.actor
    local base = valid(model) and call0(model, "GetBaseCampModelBelongTo") or nil
    local base_guid = valid(model) and guid_string(call0(model, "GetBaseCampIdBelongTo")) or nil
    if not base_guid and valid(base) then
        base_guid = guid_string(call0(base, "GetInstanceId"))
    end
    local guild = valid(actor) and call0(actor, "GetGroupIdBelongTo") or nil
    if not guild and valid(base) then guild = call0(base, "GetGroupIdBelongTo") end
    local guild_guid = guid_string(guild)
    local class = class_name(actor) or class_name(reference and reference.object)
    local kind = class and (class:find("FoodBox", 1, true) or class:find("FeedBox", 1, true))
        and "feed_box" or "ordinary"
    return {
        ready = text(resolved.container_guid) and text(base_guid) and text(guild_guid),
        container_guid = resolved.container_guid,
        base_guid = base_guid,
        guild_guid = guild_guid,
        container_kind = kind,
        object = resolved.object,
        actor = actor,
        model = model,
    }
end

function Runtime.new(options)
    options = type(options) == "table" and options or {}
    local self = setmetatable({
        options = options,
        containers = {},
        slots = {},
        snapshot_serial = 0,
        network_item = nil,
        guid_library = nil,
    }, Runtime)
    -- inventory_adapter invokes injected callbacks as plain functions (the
    -- runtime object is not passed as an implicit `self`).  Bind each public
    -- callback to this instance while retaining colon-callable diagnostics.
    self.probe = function() return Runtime.probe(self) end
    self.resolve_container = function(first, second)
        return Runtime.resolve_container(self, second or first)
    end
    self.snapshot_container = function(first, second)
        return Runtime.snapshot_container(self, second or first)
    end
    self.has_authority = function(first, second)
        return Runtime.has_authority(self, second or first)
    end
    self.new_guid = function() return Runtime.new_guid(self) end
    self.request_move = function(first, second)
        return Runtime.request_move(self, second or first)
    end
    return self
end

Runtime.create = Runtime.new

function Runtime:register_container(reference)
    local resolved = resolve_container_object(self, reference)
    if not resolved then return nil, "container-unresolved" end
    local result = metadata(self, resolved, reference)
    if result.ready ~= true then return nil, "container-ownership-unresolved" end
    self.containers[result.container_guid] = result
    return {
        ready = true,
        container_guid = result.container_guid,
        base_guid = result.base_guid,
        guild_guid = result.guild_guid,
        container_kind = result.container_kind,
    }
end

-- Names used by discovery hooks and staging probes.  Keeping them as aliases
-- makes the runtime easy to inject without changing main.lua's contract.
Runtime.capture_container = Runtime.register_container
Runtime.register_actor = Runtime.register_container
Runtime.capture_actor = Runtime.register_container

function Runtime:resolve_container(reference)
    local result = self:register_container(reference)
    if result then return result end
    local guid = type(reference) == "table" and reference.container_guid or nil
    local cached = text(guid) and self.containers[guid] or nil
    if cached and valid(cached.object) then
        return {
            ready = true,
            container_guid = cached.container_guid,
            base_guid = cached.base_guid,
            guild_guid = cached.guild_guid,
            container_kind = cached.container_kind,
        }
    end
    return nil
end

function Runtime:snapshot_container(container)
    local guid = type(container) == "table" and container.container_guid or nil
    local cached = text(guid) and self.containers[guid] or nil
    if not cached or not valid(cached.object) then return nil end
    local native = cached.object
    local count = number_call(native, "Num")
    if count == nil or count <= 0 then return nil end

    local slots = {}
    local ok = true
    for index = 0, count - 1 do
        local slot = call0(native, "Get")
        -- UE4SS reflected calls do not reliably support omitted arguments;
        -- call the indexed getter explicitly while keeping all failures safe.
        local method
        pcall(function() method = native.Get end)
        if type(method) == "function" then
            local call_ok, value = pcall(function() return method(native, index) end)
            slot = call_ok and unwrap(value) or nil
        else
            slot = nil
        end
        if not valid(slot) then ok = false break end
        local identity = slot_identity(slot)
        if not identity or identity.container_guid ~= guid then ok = false break end
        if identity.slot_index ~= index then ok = false break end
        local count_value = number_call(slot, "GetStackCount")
        if count_value == nil or count_value < 0 then ok = false break end
        local max_stack = number_call(slot, "GetMaxStack")
        if max_stack and max_stack <= 0 then max_stack = nil end
        local empty = call0(slot, "IsEmpty")
        if type(empty) ~= "boolean" then empty = count_value == 0 end
        slots[#slots + 1] = {
            container_guid = guid,
            slot_index = identity.slot_index,
            slot_id = { container_guid = guid, slot_index = identity.slot_index },
            item_id = item_id(slot),
            count = count_value,
            max_stack = max_stack,
            is_empty = empty or count_value == 0,
        }
        map_slot(self, identity, slot)
    end
    if not ok or #slots == 0 then return nil end
    self.snapshot_serial = self.snapshot_serial + 1
    local filter_off, filter_valid = read_filter_off(native)
    return {
        valid = true,
        container_guid = guid,
        slots = slots,
        fresh = true,
        filter_read_valid = filter_valid,
        filter_off = filter_off,
        serial = self.snapshot_serial,
    }
end

function Runtime:has_authority(spec)
    local guid = type(spec) == "table" and spec.source and spec.source.container_guid or nil
    local cached = text(guid) and self.containers[guid] or nil
    local actor = cached and cached.actor or nil
    if not valid(actor) and cached and valid(cached.model) then actor = call0(cached.model, "GetActor") end
    if not valid(actor) then return false end
    local authority = call0(actor, "HasAuthority")
    return type(authority) == "boolean" and authority == true
end

function Runtime:_network_item()
    if valid(self.network_item) then return self.network_item end
    local supplied = self.options.network_item
    if valid(supplied) then self.network_item = supplied; return supplied end
    local find = self.options.find_first_of or _G.FindFirstOf
    if type(find) ~= "function" then return nil end
    for _, class in ipairs(NETWORK_TRANSMITTER_CLASSES) do
        local transmitter
        local ok = pcall(function() transmitter = find(class) end)
        if ok and valid(transmitter) then
            local item = call0(transmitter, "GetItem") or property(transmitter, "Item")
            if valid(item) then self.network_item = item; return item end
        end
    end
    return nil
end

function Runtime:_guid_library()
    if valid(self.guid_library) then return self.guid_library end
    local find = self.options.static_find_object or _G.StaticFindObject
    if type(find) ~= "function" then return nil end
    local library
    local ok = pcall(function() library = find(GUID_LIBRARY_PATH) end)
    if ok and valid(library) then self.guid_library = library; return library end
    return nil
end

function Runtime:new_guid()
    local library = self:_guid_library()
    local guid = call0(library, "NewGuid")
    return guid
end

local function native_slot(self, slot)
    if type(slot) ~= "table" or not text(slot.container_guid)
        or tonumber(slot.slot_index) == nil then return nil end
    local key = slot.container_guid .. "\n" .. tostring(math.floor(tonumber(slot.slot_index)))
    local cached = self.slots[key]
    if not cached or not valid(cached.object) then return nil end
    local identity = slot_identity(cached.object)
    if not identity or identity.container_guid ~= slot.container_guid
        or identity.slot_index ~= math.floor(tonumber(slot.slot_index)) then return nil end
    return identity.native
end

function Runtime:request_move(payload)
    if type(payload) ~= "table" or payload.request_id == nil
        or type(payload.to) ~= "table" or type(payload.froms) ~= "table"
        or #payload.froms ~= 1 then return false end
    local destination = native_slot(self, payload.to)
    local source = payload.froms[1]
    local source_slot = type(source) == "table" and native_slot(self, source.SlotId) or nil
    local amount = type(source) == "table" and tonumber(source.Num) or nil
    if destination == nil or source_slot == nil or not amount
        or amount <= 0 or amount ~= math.floor(amount) then return false end
    local item = self:_network_item()
    if not valid(item) then return false end
    local method
    local ok = pcall(function() method = item.RequestMove_ToServer end)
    if not ok or type(method) ~= "function" then return false end
    ok = pcall(function()
        method(item, payload.request_id, destination, {
            { SlotId = source_slot, Num = math.floor(amount) },
        })
    end)
    return ok
end

function Runtime:probe()
    local result = {
        discovery = false,
        snapshot = false,
        authority = false,
        native_move = false,
        out_params = false,
    }
    local probe_reference = self.options.probe_reference
    local resolved = probe_reference and self:resolve_container(probe_reference) or nil
    if not resolved then
        for guid, cached in pairs(self.containers) do
            if valid(cached.object) then
                resolved = {
                    ready = true,
                    container_guid = guid,
                    base_guid = cached.base_guid,
                    guild_guid = cached.guild_guid,
                    container_kind = cached.container_kind,
                }
                break
            end
        end
    end
    if resolved then
        result.discovery = true
        local snapshot = self:snapshot_container(resolved)
        result.snapshot = snapshot ~= nil
        result.authority = result.snapshot and self:has_authority({
            source = { container_guid = resolved.container_guid },
        }) or false
        if snapshot and snapshot.slots[1] and snapshot.slots[1].slot_id then
            result.out_params = native_slot(self, snapshot.slots[1]) ~= nil
        end
    end
    local item = self:_network_item()
    if valid(item) then
        local method
        local ok = pcall(function() method = item.RequestMove_ToServer end)
        result.native_move = ok and type(method) == "function"
    end
    -- NewGuid is a non-mutating proof that the request's FGuid parameter can
    -- be created in this UE4SS session; it never makes the adapter ready alone.
    result.out_params = result.out_params and self:new_guid() ~= nil or false
    return result
end

return Runtime
