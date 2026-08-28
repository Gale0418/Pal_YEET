-- M0 Expedition Anatomy Probe: observation-only UE4SS staging mod.
-- It never writes UObjects, invokes gameplay, changes transforms, or enumerates objects per frame.

local MOD = "YEETAnatomyProbe"
local EVENT_CAP = 256
-- v3 deliberately excludes generic map Spawner actors: the fifth runtime pass
-- showed that MainWorld streaming can fill the cap before an expedition event.
local TARGET_TERMS = {
    "ObjectPool", "Expedition", "CharacterTeamMission", "BuildObject",
    "Dispatch", "MissionStation", "ExpeditionStation", "PalExpedition",
}
-- Do not match the generic "/Game/Pal/" namespace: it contains almost every asset.
local PAL_TERMS = { "BP_Pal_", "PalCharacter", "PalAI", "PalActor", "/Pal/Character/" }
local EVENT_TERMS = { "Spawn", "Pool", "Dispose", "Destroy", "MoveTo", "Goal", "BeginPlay" }
local BEGIN_PLAY_PATH = "/Script/Engine.Actor:BeginPlay"

local state = {
    armed = false,
    sequence = 0,
    captured = 0,
    session_id = nil,
    started_clock = nil,
    hooks = {},
    observer_registered = false,
    begin_play_fallback_registered = false,
    session_counter = 0,
    class_counts = {},
}

local function log(message)
    if type(Log) == "function" then
        Log("[" .. MOD .. "] " .. message .. "\n")
    else
        print("[" .. MOD .. "] " .. message)
    end
end

local function safe_call(fn, fallback)
    local ok, result = pcall(fn)
    if ok then return result end
    return fallback
end

local function contains_any(text, terms)
    if type(text) ~= "string" then return false end
    local lowered = string.lower(text)
    for _, term in ipairs(terms) do
        if string.find(lowered, string.lower(term), 1, true) then return true end
    end
    return false
end

local function json_string(value)
    if value == nil then return "null" end
    value = tostring(value)
    local control_escapes = {
        ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
        ["\r"] = "\\r", ["\t"] = "\\t",
    }
    value = value:gsub("\\", "\\\\"):gsub("\"", "\\\"")
    value = value:gsub("[%z\1-\31]", function(character)
        return control_escapes[character] or string.format("\\u%04x", string.byte(character))
    end)
    return "\"" .. value .. "\""
end

local function get_object_name(object)
    if not object then return nil end
    local valid = safe_call(function() return object:IsValid() end, false)
    if not valid then return nil end
    return safe_call(function() return object:GetFullName() end, nil)
end

local function get_class_name(object)
    if not object then return nil end
    return safe_call(function()
        local class = object:GetClass()
        if class and class:IsValid() then return class:GetFullName() end
        return nil
    end, nil)
end

local function new_session_id()
    state.session_counter = state.session_counter + 1
    return string.format("m0-%d-%d-%d", os.time(), math.floor(os.clock() * 1000000), state.session_counter)
end

local function capture(event_kind, function_path, subject)
    if not state.armed or state.captured >= EVENT_CAP then return end

    local object = safe_call(function() return subject:get() end, subject)
    local path = get_object_name(object)
    local class_name = get_class_name(object)
    if not contains_any(event_kind, EVENT_TERMS) then return end
    local target_hit = contains_any(path, TARGET_TERMS)
        or contains_any(class_name, TARGET_TERMS)
        or contains_any(path, PAL_TERMS)
        or contains_any(class_name, PAL_TERMS)
    if not target_hit then return end

    -- Keep one noisy class from consuming the whole session. Strong expedition
    -- terms are exempt because repeated callbacks can be the useful signal.
    local class_key = class_name or path or "<unknown>"
    local class_count = state.class_counts[class_key] or 0
    local strong_hit = contains_any(path, { "Expedition", "CharacterTeamMission", "ObjectPool" })
        or contains_any(class_name, { "Expedition", "CharacterTeamMission", "ObjectPool" })
    if class_count >= 8 and not strong_hit then return end
    state.class_counts[class_key] = class_count + 1

    state.sequence = state.sequence + 1
    state.captured = state.captured + 1
    local relative_ms = math.floor((os.clock() - state.started_clock) * 1000)
    local record = {
        "{\"session_id\":" .. json_string(state.session_id),
        "\"sequence\":" .. state.sequence,
        "\"utc\":" .. json_string(os.date("!%Y-%m-%dT%H:%M:%SZ")),
        "\"relative_ms\":" .. relative_ms,
        "\"event_kind\":" .. json_string(event_kind),
        "\"class\":" .. json_string(class_name),
        "\"path\":" .. json_string(path),
        "\"function\":" .. json_string(function_path),
        "\"transform\":null",
        "\"owner\":null",
        "\"instigator\":null",
        "\"confidence\":\"medium\"}"
    }
    log("M0JSON:" .. table.concat(record, ","))

    if state.captured == EVENT_CAP then
        -- Keep the Notify observer registered until its next construction callback returns true.
        -- This is the documented self-unregister path and avoids speculative unregister APIs.
        state.armed = false
        log("event cap reached (256); observer will self-release on next construction; press F5 to release hooks now")
    end
end

local function disarm()
    local remaining_hooks = {}
    local released = 0
    for _, hook in ipairs(state.hooks) do
        local ok = pcall(UnregisterHook, hook.path, hook.pre, hook.post)
        if ok then
            released = released + 1
        else
            table.insert(remaining_hooks, hook)
            log("hook unregister request failed: " .. hook.path)
        end
    end
    state.hooks = remaining_hooks
    state.armed = false
    local persistent = {}
    if state.observer_registered then
        table.insert(persistent, "Actor construction observer self-releases on the next construction")
    end
    if state.begin_play_fallback_registered then
        table.insert(persistent, "BeginPlay fallback remains registered but inert while disarmed")
    end
    local suffix = #persistent > 0 and ("; " .. table.concat(persistent, "; ")) or ""
    log(string.format("disarmed; %d hook unregister request(s) completed without Lua error%s", released, suffix))
end

local function register_observation_hook(path, event_kind)
    if type(RegisterHook) ~= "function" then
        log("RegisterHook unavailable; no observation hook installed")
        return false
    end
    local ok, pre, post = pcall(RegisterHook, path, function(context)
        capture(event_kind, path, context)
    end)
    if not ok or type(pre) ~= "number" or type(post) ~= "number" then
        log("optional hook unavailable: " .. path)
        return false
    end
    table.insert(state.hooks, { path = path, pre = pre, post = post })
    return true
end

local function register_actor_observer()
    if state.observer_registered then return true end
    if type(NotifyOnNewObject) ~= "function" then
        log("NotifyOnNewObject unavailable; using Destroyed-only observation")
        return false
    end

    local observer_path = "/Script/Engine.Actor"
    local ok = pcall(NotifyOnNewObject, observer_path, function(object)
        if not state.armed then
            state.observer_registered = false
            log("Actor construction observer self-released")
            return true
        end
        capture("Spawn", "NotifyOnNewObject:/Script/Engine.Actor", object)
        return false
    end)
    if ok then
        state.observer_registered = true
        return true
    end
    log("NotifyOnNewObject registration failed; using Destroyed-only observation")
    return false
end

local function register_begin_play_fallback()
    -- RegisterBeginPlayPostHook has no documented unregister counterpart. Keep one
    -- inert callback for the mod lifetime, guarded by state.armed, and never duplicate it.
    if state.begin_play_fallback_registered then return true end
    if type(RegisterBeginPlayPostHook) ~= "function" then
        log("BeginPlay fallback unavailable; generic UFunction hook was not installed")
        return false
    end

    local ok = pcall(RegisterBeginPlayPostHook, function(context)
        if not state.armed then return end
        safe_call(function()
            capture("BeginPlay", "RegisterBeginPlayPostHook", context)
        end, nil)
    end)
    if not ok then
        log("BeginPlay fallback registration failed")
        return false
    end
    state.begin_play_fallback_registered = true
    log("BeginPlay fallback registered once; it remains inert while disarmed")
    return true
end

local function register_begin_play_observer()
    -- Prefer the generic UFunction path because RegisterHook returns ids that
    -- UnregisterHook can remove on F5 disarm. Runtime availability is optional.
    if register_observation_hook(BEGIN_PLAY_PATH, "BeginPlay") then
        log("BeginPlay observer mode=generic; UnregisterHook can release it")
        return true
    end
    return register_begin_play_fallback()
end

local function arm()
    if state.armed then
        log("already armed")
        return
    end
    state.armed = true
    state.sequence = 0
    state.captured = 0
    state.session_id = new_session_id()
    state.started_clock = os.clock()
    state.class_counts = {}

    -- Destroyed is a proven lifecycle hook; construction and BeginPlay are optional.
    local destroyed_installed = register_observation_hook("/Script/Engine.Actor:Destroyed", "Destroy")
    local observer_installed = register_actor_observer()
    local begin_play_installed = register_begin_play_observer()
    if destroyed_installed or observer_installed or begin_play_installed then
        log("armed session=" .. state.session_id .. "; construction, BeginPlay, and Destroyed filters active where available")
    else
        state.armed = false
        log("not armed: no observation API could be installed")
    end
end

local function toggle_arm()
    if state.armed or #state.hooks > 0 then
        disarm()
    else
        -- A pending Actor observer is reused by arm(); it is never registered twice.
        arm()
    end
end

local function register_keybind()
    if type(RegisterKeyBind) ~= "function" or not Key or not Key.F5 then
        log("RegisterKeyBind / Key.F5 unavailable; use no runtime controls")
        return
    end
    local ok = pcall(RegisterKeyBind, Key.F5, {}, toggle_arm)
    if ok then
        log("ready; press F5 to arm/disarm. Default state is disarmed.")
    else
        log("F5 keybind registration failed; probe remains disarmed")
    end
end

-- Required terms are retained as a transparent event taxonomy for later verified hooks.
-- No speculative hooks are registered for Spawn/Pool/Dispose/MoveTo/Goal.
local _event_taxonomy = EVENT_TERMS
register_keybind()
