-- YEETRuntimeProbe: one bounded host staging session.
--
-- This module observes normal player actions only.  It never invokes a
-- transfer, assignment, reservation, or object enumeration, or
-- object/property mutation.  Hook callbacks only inspect arguments and public
-- getter results, then emit one JSON object per line through the UE4SS log.

local MOD = "YEETRuntimeProbe"
local KEY_NAME = "F5"
local EVENT_CAP = 24
local WATCHDOG_INTERVAL_MS = 1000
local WATCHDOG_MAX_TICKS = 30

local HOOKS = {
    { kind = "feed_model", path = "/Script/Pal.PalMapObjectConcreteModelBase:GetItemContainerModule" },
    { kind = "feed_container", path = "/Script/Pal.PalMapObjectItemContainerModule:GetContainer" },
    { kind = "assign", path = "/Script/Pal.PalUIBaseCampWorkFixedAssignManageModel:RequestFixedAssign" },
    { kind = "unassign", path = "/Script/Pal.PalUIBaseCampWorkFixedAssignManageModel:RequestUnassign" },
    { kind = "enter", path = "/Script/Pal.PalBuilderComponent:OnEnterBaseCamp" },
    { kind = "exit", path = "/Script/Pal.PalBuilderComponent:OnExitBaseCamp" },
}

local state = {
    armed = false,
    used = false,
    sequence = 0,
    watchdog_ticks = 0,
    watchdog_started = false,
    hooks = {},
    pending = {},
    session_id = nil,
}

local function log(message)
    local line = string.format("[%s] %s", MOD, tostring(message))
    if type(Log) == "function" then Log(line .. "\n") else print(line) end
end

local function safe_call(fn, fallback)
    local ok, first, second, third = pcall(fn)
    if ok then return first, second, third end
    return fallback
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

local function valid_object(value)
    local object = unwrap(value)
    if object == nil then return false end
    local checker = safe_call(function() return object.IsValid end, nil)
    if type(checker) ~= "function" then return false end
    return safe_call(function() return object:IsValid() end, false) == true
end

local function method(value, name)
    local object = unwrap(value)
    if object == nil then return nil end
    return safe_call(function() return object[name] end, nil)
end

local function call0(value, name)
    local object = unwrap(value)
    local fn = method(object, name)
    if type(fn) ~= "function" then return nil end
    return safe_call(function() return fn(object) end, nil)
end

local function text(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function object_name(value)
    if not valid_object(value) then return nil end
    return call0(value, "GetFullName")
end

local function class_name(value)
    if not valid_object(value) then return nil end
    local class = call0(value, "GetClass")
    return valid_object(class) and object_name(class) or nil
end

local function is_feed(value)
    local name = class_name(value) or object_name(value) or ""
    return name:find("FeedBox", 1, true) ~= nil
        or name:find("FoodBox", 1, true) ~= nil
end

local function json_string(value)
    if value == nil then return "null" end
    local rendered = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
    rendered = rendered:gsub("[%z\1-\31]", function(character)
        return string.format("\\u%04x", string.byte(character))
    end)
    return '"' .. rendered .. '"'
end

local function json_value(value, depth)
    if value == nil then return "null" end
    local value_type = type(value)
    if value_type == "boolean" then return value and "true" or "false" end
    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return tostring(value)
    end
    if value_type == "string" then return json_string(value) end
    if value_type ~= "table" or (depth or 0) > 3 then
        return json_string(value_type)
    end
    local entries = {}
    for key, item in pairs(value) do entries[#entries + 1] = { key = tostring(key), value = item } end
    table.sort(entries, function(left, right) return left.key < right.key end)
    local fields = {}
    for _, entry in ipairs(entries) do
        fields[#fields + 1] = json_string(entry.key) .. ":" .. json_value(entry.value, (depth or 0) + 1)
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function shape(value, depth)
    if value == nil then return { type = "nil" } end
    local value_type = type(value)
    if value_type == "table" then
        if (depth or 0) >= 2 then return { type = "table", truncated = true } end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        return { type = "table", keys = keys, count = #keys }
    end
    local result = { type = value_type }
    if value_type == "string" then result.length = #value end
    if value_type == "number" then result.finite = value == value and value ~= math.huge and value ~= -math.huge end
    if valid_object(value) then
        result.valid = true
        result.class = class_name(value)
        result.full_name = object_name(value)
    end
    return result
end

local function snapshot_value(value)
    value = unwrap(value)
    local value_type = type(value)
    if value_type == "nil" or value_type == "boolean"
        or value_type == "number" or value_type == "string" then
        return value
    end
    return shape(value)
end

local function authority_status(value)
    local subject = unwrap(value)
    local subject_authority = call0(subject, "HasAuthority")
    local ok, helpers = pcall(require, "UEHelpers")
    if not ok or type(helpers) ~= "table" then
        return { subject = subject_authority == true, host = false, reason = "UEHelpers unavailable" }
    end
    local game_mode = safe_call(helpers.GetGameModeBase, nil)
    local controller = safe_call(helpers.GetPlayerController, nil)
    local host = valid_object(game_mode) and valid_object(controller)
        and call0(controller, "HasAuthority") == true
    local reason = host and "host authority confirmed" or "host authority unavailable"
    return { subject = subject_authority == true, host = host, reason = reason }
end

local function method_availability(value)
    local names = {
        "GetItemContainerModule", "GetContainer", "GetId", "Num", "Get",
        "GetFilterOffList", "GetIndividualID", "TryGetIndividualParameter",
        "TryGetIndividualActor", "GetBaseCampId", "IsAssignedToExpedition",
        "IsAssignedToExpeditionIn", "GetBaseCampModelBelongTo", "GetBaseCampIdBelongTo",
        "GetWorkCollection", "GetState", "IsAvailable", "HasAuthority",
    }
    local result = {}
    for _, name in ipairs(names) do result[name] = type(method(value, name)) == "function" end
    return result
end

local function read_only_snapshot(value)
    local object = unwrap(value)
    if not valid_object(object) then return nil end
    local snapshot = {
        valid = true,
        class = class_name(object),
        full_name = object_name(object),
        authority = authority_status(object),
        methods = method_availability(object),
    }
    local getter_names = {
        "GetIndividualID", "GetBaseCampId", "IsAssignedToExpedition",
        "IsAssignedToExpeditionIn", "GetBaseCampIdBelongTo", "GetState",
        "IsAvailable", "Num", "GetId",
    }
    for _, name in ipairs(getter_names) do
        if snapshot.methods[name] then snapshot[name] = snapshot_value(call0(object, name)) end
    end
    return snapshot
end

local function snapshot_candidates(self, args, prefer_feed)
    local values = { self }
    for index = 1, #args do values[#values + 1] = args[index] end
    local selected = nil
    for _, value in ipairs(values) do
        if valid_object(value) and (not prefer_feed or is_feed(value)) then selected = value; break end
    end
    local snapshot = read_only_snapshot(selected)
    if snapshot then snapshot.candidate_count = #values end
    return snapshot
end

local function out_param_shape(value)
    local object = unwrap(value)
    if not valid_object(object) then return {} end
    local result = {}
    for _, name in ipairs({ "TryGetConcreteModel", "TryGetContainer", "TryGetIndividualParameter", "TryGetIndividualActor" }) do
        local fn = method(object, name)
        if type(fn) == "function" then
            local out = {}
            local ok, first, second = pcall(function() return fn(object, out) end)
            result[name] = {
                available = true,
                call_ok = ok,
                return_count = second == nil and (first == nil and 0 or 1) or 2,
                first = shape(first),
                second = shape(second),
                out = shape(out),
            }
        end
    end
    return result
end

local function function_availability(path, self, args)
    local registered = false
    for _, hook in ipairs(state.hooks) do
        if hook.path == path then registered = true; break end
    end
    local result = { hook_path = path, hook_registered = registered, subject = method_availability(self) }
    for index = 1, #args do result["arg_" .. tostring(index)] = method_availability(args[index]) end
    local finder = _G.StaticFindObject
    if type(finder) == "function" then
        result.reflected = safe_call(function() return valid_object(finder(path)) end, false)
    else
        result.reflected = false
    end
    return result
end

local function key_for(path, self)
    return path .. "|" .. (object_name(self) or tostring(self))
end

local function release_hooks(reason)
    local remaining, released = {}, 0
    for _, hook in ipairs(state.hooks) do
        local ok = pcall(UnregisterHook, hook.path, hook.pre, hook.post)
        if ok then released = released + 1 else remaining[#remaining + 1] = hook end
    end
    state.hooks = remaining
    state.pending = {}
    state.watchdog_started = false
    state.armed = false
    log(string.format("released=%d remaining=%d reason=%s", released, #remaining, tostring(reason)))
end

local function record_event(spec, self, args)
    if not state.armed or state.sequence >= EVENT_CAP then return end
    local feed_action = spec.kind == "feed_model" or spec.kind == "feed_container"
    if feed_action and not (is_feed(self) or snapshot_candidates(self, args, true) ~= nil) then return end
    local key = key_for(spec.path, self)
    local before = state.pending[key]
    state.pending[key] = nil
    local selected = snapshot_candidates(self, args, feed_action)
    local out_shapes = { self = out_param_shape(self) }
    for index = 1, #args do out_shapes["arg_" .. tostring(index)] = out_param_shape(args[index]) end
    state.sequence = state.sequence + 1
    local payload = {
        schema = "yeet-runtime-probe/v1",
        session_id = state.session_id,
        sequence = state.sequence,
        kind = spec.kind,
        function_path = spec.path,
        class = class_name(self),
        function_availability = function_availability(spec.path, self, args),
        authority = authority_status(self),
        out_param_shapes = out_shapes,
        before = before,
        after = selected,
        argument_shapes = {},
    }
    for index = 1, #args do payload.argument_shapes[index] = shape(args[index]) end
    log("JSONL " .. json_value(payload))
    if state.sequence >= EVENT_CAP then release_hooks("event cap reached") end
end

local function capture_before(spec, self, args)
    if not state.armed then return end
    local feed_action = spec.kind == "feed_model" or spec.kind == "feed_container"
    if feed_action and not (is_feed(self) or snapshot_candidates(self, args, true) ~= nil) then return end
    state.pending[key_for(spec.path, self)] = snapshot_candidates(self, args, feed_action)
end

local function install_hook(spec)
    local pre = function(self, ...)
        capture_before(spec, self, { ... })
    end
    local post = function(self, ...)
        record_event(spec, self, { ... })
    end
    local ok, pre_id, post_id = pcall(RegisterHook, spec.path, pre, post)
    if not ok or type(pre_id) ~= "number" or type(post_id) ~= "number" then
        log("unavailable function=" .. spec.path)
        return false
    end
    state.hooks[#state.hooks + 1] = { path = spec.path, pre = pre_id, post = post_id }
    return true
end

local function start_watchdog()
    if type(LoopAsync) ~= "function" then return false end
    state.watchdog_started = true
    LoopAsync(WATCHDOG_INTERVAL_MS, function()
        if not state.armed then release_hooks("disarmed"); return true end
        state.watchdog_ticks = state.watchdog_ticks + 1
        if state.watchdog_ticks >= WATCHDOG_MAX_TICKS then
            release_hooks("watchdog timeout")
            return true
        end
        return false
    end)
    return true
end

local function arm_once()
    if state.used then log("one-shot already consumed; restart Palworld for another sample"); return end
    state.used = true
    if type(RegisterHook) ~= "function" or type(UnregisterHook) ~= "function" then
        log("fail-closed: reversible hook API unavailable"); return
    end
    local ok, helpers = pcall(require, "UEHelpers")
    if not ok or type(helpers) ~= "table" then log("fail-closed: UEHelpers unavailable"); return end
    local controller = safe_call(helpers.GetPlayerController, nil)
    if not valid_object(controller) or call0(controller, "HasAuthority") ~= true then
        log("fail-closed: Host authority required"); return
    end
    state.session_id = string.format("runtime-%d-%d", os.time(), math.floor(os.clock() * 1000000))
    state.sequence, state.watchdog_ticks, state.armed = 0, 0, true
    local registered = 0
    for _, spec in ipairs(HOOKS) do if install_hook(spec) then registered = registered + 1 end end
    if registered == 0 then release_hooks("no candidate hooks available"); return end
    if not start_watchdog() then release_hooks("watchdog unavailable"); return end
    log(string.format("armed one-shot host session=%s cap=%d window_s=%d hooks=%d", state.session_id, EVENT_CAP, WATCHDOG_MAX_TICKS, registered))
    log("操作提示：面對並互動一次 Feed Box；正常 assign 再 unassign 一隻 Pal；最後進出基地。只做一次流程。")
end

local function install_keybind()
    if type(RegisterKeyBind) ~= "function" or not Key or not Key[KEY_NAME] then
        log("ready but F5 keybind unavailable; remains disarmed"); return
    end
    local ok = pcall(RegisterKeyBind, Key[KEY_NAME], {}, arm_once)
    if ok then log("ready; development-only, disarmed. Host press F5 once to arm")
    else log("ready but keybind registration failed; remains disarmed") end
end

local function install() install_keybind() end

return { install = install }
