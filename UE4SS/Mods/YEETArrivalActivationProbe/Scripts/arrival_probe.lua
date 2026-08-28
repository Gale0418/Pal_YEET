-- YEET Arrival Activation Probe (development-only, observation-only).
--
-- The probe records the proven player-camp boundary used by existing prior art:
-- UPalBuilderComponent::OnEnterBaseCamp / OnExitBaseCamp.  It never attempts to
-- make a caravan look like a player, never moves a player, and never changes a
-- UObject or a tick policy.  A future native bridge must be implemented only
-- after this evidence is correlated with an authoritative base-camp state delta.

local MOD = "YEETArrivalActivationProbe"
local KEY_NAME = "F5"
local EVENT_CAP = 12
local WATCHDOG_INTERVAL_MS = 1000
local WATCHDOG_MAX_TICKS = 30
local ENTER_PATH = "/Script/Pal.PalBuilderComponent:OnEnterBaseCamp"
local EXIT_PATH = "/Script/Pal.PalBuilderComponent:OnExitBaseCamp"

local state = {
    armed = false,
    used = false,
    event_count = 0,
    watchdog_ticks = 0,
    watchdog_started = false,
    hooks = {},
    pending = {},
    session_id = nil,
    authority = false,
}

local function log(message)
    local text = string.format("[%s] %s", MOD, tostring(message))
    if type(Log) == "function" then Log(text .. "\n") else print(text) end
end

local function safe_call(fn, fallback)
    local ok, result = pcall(fn)
    if ok then return result end
    return fallback
end

local function unwrap(value)
    if value == nil then return nil end
    if type(value.get) == "function" then
        return safe_call(function() return value:get() end, nil)
    end
    return value
end

local function valid_object(value)
    local object = unwrap(value)
    return object ~= nil and safe_call(function() return object:IsValid() end, false) == true
end

local function object_name(value)
    local object = unwrap(value)
    if not valid_object(object) then return nil end
    return safe_call(function() return object:GetFullName() end, nil)
end

local function class_name(value)
    local object = unwrap(value)
    if not valid_object(object) then return nil end
    return safe_call(function()
        local class = object:GetClass()
        return valid_object(class) and class:GetFullName() or nil
    end, nil)
end

local function call_method(value, method_name)
    local object = unwrap(value)
    if not valid_object(object) then return nil end
    return safe_call(function()
        local method = object[method_name]
        if type(method) ~= "function" then return nil end
        return method(object)
    end, nil)
end

local function json_string(value)
    if value == nil then return "null" end
    local text = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
    text = text:gsub("[%z\1-\31]", function(character)
        return string.format("\\u%04x", string.byte(character))
    end)
    return '"' .. text .. '"'
end

local function json_bool(value)
    return value == true and "true" or "false"
end

local function json_field(value)
    if type(value) == "boolean" then return json_bool(value) end
    return json_string(value)
end

local function base_snapshot(value)
    local model = unwrap(value)
    if not valid_object(model) then return nil end
    local work_collection = call_method(model, "GetWorkCollection")
    return {
        id = call_method(model, "GetId"),
        name = call_method(model, "GetBaseCampName"),
        state = call_method(model, "GetState"),
        available = call_method(model, "IsAvailable"),
        range = call_method(model, "GetRange"),
        group_id = call_method(model, "GetGroupIdBelongTo"),
        work_collection = object_name(work_collection),
        work_collection_class = class_name(work_collection),
    }
end

local function snapshot_json(snapshot)
    if snapshot == nil then return "null" end
    return table.concat({
        "{",
        "\"id\":", json_field(snapshot.id), ",",
        "\"name\":", json_field(snapshot.name), ",",
        "\"state\":", json_field(snapshot.state), ",",
        "\"available\":", json_field(snapshot.available), ",",
        "\"range\":", json_field(snapshot.range), ",",
        "\"group_id\":", json_field(snapshot.group_id), ",",
        "\"work_collection\":", json_field(snapshot.work_collection), ",",
        "\"work_collection_class\":", json_field(snapshot.work_collection_class),
        "}",
    })
end

local function authority_status()
    local ok, helpers = pcall(require, "UEHelpers")
    if not ok or type(helpers) ~= "table" then return false, "UEHelpers unavailable" end

    local game_mode = safe_call(helpers.GetGameModeBase, nil)
    if not valid_object(game_mode) then return false, "AuthorityGameMode unavailable" end

    local controller = safe_call(helpers.GetPlayerController, nil)
    if not valid_object(controller) then return false, "local PlayerController unavailable" end

    local has_authority = call_method(controller, "HasAuthority")
    if has_authority ~= true then return false, "local PlayerController is not authority" end
    return true, "host authority confirmed"
end

local function callback_key(self, path)
    return path .. "|" .. (object_name(self) or tostring(self))
end

local function request_release(reason)
    state.armed = false
    log("release requested: " .. tostring(reason))
end

local function release_hooks()
    local remaining = {}
    local released = 0
    for _, hook in ipairs(state.hooks) do
        local ok = pcall(UnregisterHook, hook.path, hook.pre, hook.post)
        if ok then
            released = released + 1
        else
            table.insert(remaining, hook)
        end
    end
    state.hooks = remaining
    state.pending = {}
    state.watchdog_started = false
    log(string.format("released=%d remaining=%d", released, #remaining))
end

local function record_event(kind, path, self, base_model)
    if not state.armed or state.event_count >= EVENT_CAP then return end
    local authority_ok, authority_reason = authority_status()
    if not authority_ok then
        request_release("authority lost: " .. authority_reason)
        return
    end

    local builder = unwrap(self)
    local model = unwrap(base_model)
    local key = callback_key(self, path)
    local after = base_snapshot(model)
    local before = state.pending[key]
    state.pending[key] = nil
    state.event_count = state.event_count + 1

    local payload = table.concat({
        "ARRIVALPROBE:",
        "{",
        "\"session_id\":", json_string(state.session_id), ",",
        "\"sequence\":", tostring(state.event_count), ",",
        "\"kind\":", json_string(kind), ",",
        "\"hook\":", json_string(path), ",",
        "\"authority\":", json_string("host"), ",",
        "\"builder\":", json_string(object_name(builder)), ",",
        "\"builder_class\":", json_string(class_name(builder)), ",",
        "\"base_after\":", snapshot_json(after), ",",
        "\"base_before\":", snapshot_json(before),
        "}",
    })
    log(payload)

    if state.event_count >= EVENT_CAP then request_release("event cap reached") end
end

local function capture_before(path, self, base_model)
    if not state.armed then return end
    local authority_ok, authority_reason = authority_status()
    if not authority_ok then
        request_release("authority lost: " .. authority_reason)
        return
    end
    state.pending[callback_key(self, path)] = base_snapshot(base_model)
end

local function install_hook(path, kind)
    local pre = function(self, base_model)
        capture_before(path, self, base_model)
    end
    local post = function(self, base_model)
        record_event(kind, path, self, base_model)
    end
    local ok, pre_id, post_id = pcall(RegisterHook, path, pre, post)
    if not ok or type(pre_id) ~= "number" or type(post_id) ~= "number" then
        log("hook unavailable: " .. path)
        return false
    end
    table.insert(state.hooks, { path = path, pre = pre_id, post = post_id })
    return true
end

local function start_watchdog()
    if type(LoopAsync) ~= "function" then
        log("fail-closed: LoopAsync unavailable; no session armed")
        return false
    end
    state.watchdog_started = true
    LoopAsync(WATCHDOG_INTERVAL_MS, function()
        if not state.armed then
            release_hooks()
            return true
        end
        state.watchdog_ticks = state.watchdog_ticks + 1
        if state.watchdog_ticks >= WATCHDOG_MAX_TICKS then
            request_release("watchdog timeout")
            release_hooks()
            return true
        end
        return false
    end)
    return true
end

local function arm_once()
    if state.used then
        log("one-shot session already consumed; restart the game for another sample")
        return
    end
    state.used = true

    local authority_ok, authority_reason = authority_status()
    if not authority_ok then
        log("fail-closed: " .. authority_reason)
        return
    end
    if type(RegisterHook) ~= "function" or type(UnregisterHook) ~= "function" then
        log("fail-closed: reversible hook API unavailable")
        return
    end
    state.authority = true
    state.session_id = string.format("arrival-%d-%d", os.time(), math.floor(os.clock() * 1000000))
    state.event_count = 0
    state.watchdog_ticks = 0
    state.armed = true

    local enter_ok = install_hook(ENTER_PATH, "enter")
    local exit_ok = install_hook(EXIT_PATH, "exit")
    if not enter_ok or not exit_ok then
        request_release("required enter/exit hook unavailable")
        release_hooks()
        return
    end
    if not start_watchdog() then
        request_release("watchdog unavailable")
        release_hooks()
        return
    end
    log("armed one-shot host session=" .. state.session_id .. " cap=12 window_s=30")
end

local function install_keybind()
    if type(RegisterKeyBind) ~= "function" or not Key or not Key[KEY_NAME] then
        log("ready but F5 keybind unavailable; remains disarmed")
        return
    end
    local ok = pcall(RegisterKeyBind, Key[KEY_NAME], {}, arm_once)
    if ok then
        log("ready; development-only, disarmed. Press F5 once on the Host to sample enter/exit")
    else
        log("ready but keybind registration failed; remains disarmed")
    end
end

local function install()
    install_keybind()
end

return { install = install }
