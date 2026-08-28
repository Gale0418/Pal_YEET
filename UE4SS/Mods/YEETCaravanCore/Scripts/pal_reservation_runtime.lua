-- YEET Pal reservation runtime boundary
--
-- This module owns only the logical, GUID-keyed reservation ledger.  It does
-- not enumerate UObjects, write reflected properties, or guess a Palworld
-- worker/party/condensing array.  All native access is supplied explicitly by
-- an injected runtime and is enabled only after a complete, host-authority
-- probe reports real evidence.

local Runtime = {}
Runtime.__index = Runtime
Runtime.VERSION = "0.1.0"

local CAPABILITIES = {
    "discovery", "snapshot", "authority", "reserve", "release", "reconcile", "verified",
}

local function text(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function copy_table(source)
    local result = {}
    if type(source) ~= "table" then return result end
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function capability_set(result)
    local capabilities = {}
    for _, name in ipairs(CAPABILITIES) do
        capabilities[name] = type(result) == "table" and result[name] == true
    end
    return capabilities
end

local function capability_complete(capabilities)
    for _, name in ipairs(CAPABILITIES) do
        if capabilities[name] ~= true then return false end
    end
    return true
end

local function call(options, name, payload)
    local callback = options and options[name]
    if type(callback) ~= "function" then return nil, "callback-unavailable:" .. name end
    local ok, first, second = pcall(callback, payload)
    if not ok then return nil, "callback-error:" .. name end
    return first, second
end

local function native_success(value)
    return value == true or (type(value) == "table" and value.ok == true)
end

local function snapshot_shape(guid, snapshot)
    if type(snapshot) ~= "table" then return nil, "snapshot-invalid" end
    if snapshot.pal_guid ~= guid then return nil, "snapshot-guid-mismatch" end
    if snapshot.fresh ~= true then return nil, "snapshot-stale" end
    if type(snapshot.present) ~= "boolean" then return nil, "snapshot-presence-unknown" end
    if type(snapshot.condensed) ~= "boolean" then return nil, "snapshot-condensed-unknown" end
    if type(snapshot.base_exists) ~= "boolean" then return nil, "snapshot-base-unknown" end
    if type(snapshot.reserved) ~= "boolean" then return nil, "snapshot-reservation-unknown" end
    if snapshot.reserved and not text(snapshot.reserved_by) then
        return nil, "snapshot-reserver-unknown"
    end
    if snapshot.base_exists and not text(snapshot.base_guid) then
        return nil, "snapshot-base-guid-unknown"
    end
    return snapshot
end

local function unavailable_reason(snapshot)
    if snapshot.present ~= true then return "pal-missing" end
    if snapshot.condensed == true then return "pal-condensed" end
    if snapshot.base_exists ~= true then return "base-deleted" end
    return nil
end

local function reservation_id(spec)
    if type(spec) ~= "table" then return nil end
    return text(spec.reservation_id) and spec.reservation_id or nil
end

function Runtime.new(options)
    options = type(options) == "table" and options or {}
    local self = setmetatable({
        options = options,
        ready = false,
        capabilities = capability_set(nil),
        reservations = {},
        reservation_ids = {},
        last_probe = nil,
        revision = 0,
    }, Runtime)

    self.probe = function() return Runtime.probe(self) end
    self.resolve_pal_callback = function(first, second)
        return Runtime.resolve_pal(self, second or first)
    end
    self.snapshot_pal_callback = function(first, second)
        return Runtime.snapshot_pal(self, second or first)
    end
    self.has_authority_callback = function(first, second)
        return Runtime.has_authority(self, second or first)
    end
    self.native_reserve_callback = function(first, second)
        return Runtime.native_reserve(self, second or first)
    end
    self.native_release_callback = function(first, second)
        return Runtime.native_release(self, second or first)
    end
    return self
end

Runtime.create = Runtime.new

function Runtime:probe()
    local result, reason = call(self.options, "probe")
    if type(result) ~= "table" then
        result = { error = reason or "probe-invalid" }
    end
    self.capabilities = capability_set(result)
    self.last_probe = copy_table(result)
    for _, name in ipairs(CAPABILITIES) do self.last_probe[name] = self.capabilities[name] end
    self.ready = capability_complete(self.capabilities)
    return self.ready, copy_table(self.last_probe)
end

function Runtime:resolve_pal(spec)
    if type(spec) ~= "table" or not text(spec.pal_guid) then
        return nil, "pal-guid-required"
    end
    local resolved, reason = call(self.options, "resolve_pal", spec)
    if type(resolved) ~= "table" then return nil, reason or "pal-unresolved" end
    if resolved.pal_guid ~= spec.pal_guid then return nil, "pal-guid-mismatch" end
    return resolved
end

function Runtime:snapshot_pal(spec)
    if type(spec) ~= "table" or not text(spec.pal_guid) then
        return nil, "pal-guid-required"
    end
    local snapshot, reason = call(self.options, "snapshot_pal", spec)
    local shaped, shape_reason = snapshot_shape(spec.pal_guid, snapshot)
    if shaped then return shaped end
    return nil, shape_reason or reason or "snapshot-invalid"
end

function Runtime:has_authority(spec)
    local authority, reason = call(self.options, "has_authority", spec)
    if authority ~= true then return false, reason or "host-authority-required" end
    return true
end

function Runtime:native_reserve(payload)
    return call(self.options, "native_reserve", payload)
end

function Runtime:native_release(payload)
    return call(self.options, "native_release", payload)
end

function Runtime:_inspect(spec)
    local resolved, resolve_reason = self:resolve_pal(spec)
    if not resolved then return nil, nil, resolve_reason end
    local snapshot, snapshot_reason = self:snapshot_pal({
        pal_guid = spec.pal_guid,
        resolved = resolved,
    })
    if not snapshot then return resolved, nil, snapshot_reason end
    return resolved, snapshot
end

function Runtime:_preflight(spec)
    if not self.ready then return nil, nil, nil, "runtime-not-ready" end
    local resolved, snapshot, reason = self:_inspect(spec)
    if not resolved or not snapshot then return resolved, snapshot, nil, reason end
    local unavailable = unavailable_reason(snapshot)
    if unavailable then return resolved, snapshot, nil, unavailable end
    local authority, authority_reason = self:has_authority({
        pal_guid = spec.pal_guid,
        resolved = resolved,
        snapshot = snapshot,
    })
    if not authority then return resolved, snapshot, nil, authority_reason end
    return resolved, snapshot, true
end

local function result_record(record)
    return {
        pal_guid = record.pal_guid,
        reservation_id = record.reservation_id,
        base_guid = record.base_guid,
        state = record.state,
        revision = record.revision,
    }
end

function Runtime:reserve(spec)
    if type(spec) ~= "table" or not text(spec.pal_guid) then
        return false, "pal-guid-required"
    end
    local id = reservation_id(spec)
    if not id then return false, "reservation-id-required" end

    local existing = self.reservations[spec.pal_guid]
    if existing then
        if existing.reservation_id == id and existing.state == "reserved" then
            return true, result_record(existing)
        end
        return false, "pal-already-reserved"
    end
    local other_guid = self.reservation_ids[id]
    if other_guid and other_guid ~= spec.pal_guid then return false, "reservation-id-in-use" end

    local resolved, snapshot, authority, reason = self:_preflight(spec)
    if not resolved or not snapshot then return false, reason end
    if authority ~= true then return false, reason or "host-authority-required" end
    if snapshot.reserved then return false, "pal-already-native-reserved" end
    if self.capabilities.reserve ~= true then return false, "native-reserve-unverified" end

    local payload = {
        pal_guid = spec.pal_guid,
        reservation_id = id,
        base_guid = snapshot.base_guid,
        resolved = resolved,
        snapshot = snapshot,
    }
    local native_result, native_reason = self:native_reserve(payload)
    if not native_success(native_result) then return false, native_reason or "native-reserve-rejected" end

    local _, post_snapshot, post_reason = self:_inspect(spec)
    if not post_snapshot or post_snapshot.reserved ~= true
        or post_snapshot.reserved_by ~= id then
        local uncertain = {
            pal_guid = spec.pal_guid, reservation_id = id,
            base_guid = snapshot.base_guid, state = "unknown", revision = self.revision + 1,
        }
        self.reservations[spec.pal_guid], self.reservation_ids[id] = uncertain, spec.pal_guid
        self.revision = self.revision + 1
        return false, post_reason or "reserve-unverified"
    end

    local record = {
        pal_guid = spec.pal_guid, reservation_id = id,
        base_guid = post_snapshot.base_guid, state = "reserved",
        revision = self.revision + 1,
    }
    self.reservations[spec.pal_guid], self.reservation_ids[id] = record, spec.pal_guid
    self.revision = self.revision + 1
    return true, result_record(record)
end

local function remove_record(self, guid, id)
    self.reservations[guid] = nil
    if id and self.reservation_ids[id] == guid then self.reservation_ids[id] = nil end
end

function Runtime:release(spec)
    if type(spec) ~= "table" or not text(spec.pal_guid) then
        return false, "pal-guid-required"
    end
    local record = self.reservations[spec.pal_guid]
    if not record then return false, "reservation-not-found" end
    if text(spec.reservation_id) and spec.reservation_id ~= record.reservation_id then
        return false, "reservation-owner-mismatch"
    end

    if not self.ready then return false, "runtime-not-ready" end
    local resolved, snapshot, inspect_reason = self:_inspect(spec)
    if not snapshot then
        -- Resolution can legitimately fail after destruction.  Ask for an
        -- explicit fresh missing snapshot before deciding whether to clean
        -- our ledger; never infer loss from a nil value alone.
        local observed, observed_reason = self:snapshot_pal({ pal_guid = spec.pal_guid })
        if observed then
            snapshot = observed
        else
            return false, inspect_reason or observed_reason or "snapshot-invalid"
        end
    end

    local unavailable = unavailable_reason(snapshot)
    if unavailable then
        remove_record(self, spec.pal_guid, record.reservation_id)
        self.revision = self.revision + 1
        return true, { status = "cleared-unavailable", reason = unavailable, pal_guid = spec.pal_guid }
    end
    if snapshot.reserved ~= true then
        remove_record(self, spec.pal_guid, record.reservation_id)
        self.revision = self.revision + 1
        return true, { status = "already-released", pal_guid = spec.pal_guid }
    end
    if snapshot.reserved_by ~= record.reservation_id then
        return false, "native-reservation-owner-mismatch"
    end
    local authority, authority_reason = self:has_authority({
        pal_guid = spec.pal_guid, resolved = resolved, snapshot = snapshot,
    })
    if not authority then return false, authority_reason or "host-authority-required" end
    if self.capabilities.release ~= true then return false, "native-release-unverified" end

    local native_result, native_reason = self:native_release({
        pal_guid = spec.pal_guid, reservation_id = record.reservation_id,
        base_guid = snapshot.base_guid, resolved = resolved, snapshot = snapshot,
    })
    if not native_success(native_result) then return false, native_reason or "native-release-rejected" end
    local _, post_snapshot, post_reason = self:_inspect(spec)
    if not post_snapshot then return false, post_reason or "release-unverified" end
    if post_snapshot.reserved == true and post_snapshot.reserved_by == record.reservation_id then
        return false, "release-unverified"
    end
    remove_record(self, spec.pal_guid, record.reservation_id)
    self.revision = self.revision + 1
    return true, { status = "released", pal_guid = spec.pal_guid }
end

function Runtime:reconcile(observations)
    if not self.ready then return false, "runtime-not-ready" end
    if observations ~= nil and type(observations) ~= "table" then
        return false, "observations-table-required"
    end
    local summary = { cleared = {}, healthy = {}, conflicts = {}, unresolved = {}, mutations = 0 }
    local guids = {}
    for guid in pairs(self.reservations) do guids[#guids + 1] = guid end
    table.sort(guids)
    for _, guid in ipairs(guids) do
        local record = self.reservations[guid]
        if record then
        local snapshot = observations and observations[guid] or nil
        local reason
        if snapshot == nil then
            snapshot, reason = self:snapshot_pal({ pal_guid = guid })
        else
            snapshot, reason = snapshot_shape(guid, snapshot)
        end
        if not snapshot then
            summary.unresolved[#summary.unresolved + 1] = { pal_guid = guid, reason = reason }
        else
            local unavailable = unavailable_reason(snapshot)
            if unavailable then
                remove_record(self, guid, record.reservation_id)
                summary.cleared[#summary.cleared + 1] = { pal_guid = guid, reason = unavailable }
            elseif snapshot.reserved == true and snapshot.reserved_by == record.reservation_id then
                summary.healthy[#summary.healthy + 1] = guid
            elseif snapshot.reserved == true then
                summary.conflicts[#summary.conflicts + 1] = { pal_guid = guid, reason = "foreign-owner" }
            else
                remove_record(self, guid, record.reservation_id)
                summary.cleared[#summary.cleared + 1] = { pal_guid = guid, reason = "native-unreserved" }
            end
        end
        end
    end
    self.revision = self.revision + 1
    return true, summary
end

function Runtime:status()
    local reservations = {}
    for guid, record in pairs(self.reservations) do reservations[guid] = result_record(record) end
    return {
        version = Runtime.VERSION,
        ready = self.ready,
        revision = self.revision,
        capabilities = copy_table(self.capabilities),
        reservations = reservations,
        last_probe = copy_table(self.last_probe),
    }
end

-- PascalCase aliases make the boundary convenient for a later YEET bridge
-- without changing the lower-case Lua method contract used by tests.
Runtime.Probe = Runtime.probe
Runtime.Reserve = Runtime.reserve
Runtime.Release = Runtime.release
Runtime.Reconcile = Runtime.reconcile
Runtime.Status = Runtime.status

return Runtime
