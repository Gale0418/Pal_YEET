-- YEET Caravan Core 0.5.0-alpha
-- 台灣社群在地化核心：路線狀態機、低頻倒數、終端互動橋接、焦點物件觀測與安全測試入口。
-- 嚴格遵循硬性限制：不偽造二進位資產、不擅自改動庫存、不調用未證實之基地喚醒 API。

local Domain = require("domain")
local Store = require("state_store")
local InventoryPolicy = require("inventory_policy")
local InventoryAdapter = require("inventory_adapter")
local InventoryRuntime = require("inventory_runtime")
local PalReservationRuntime = require("pal_reservation_runtime")
local TerminalInteractionBridge = require("terminal_interaction_bridge")
local MOD = "YEET"
local VERSION = "0.5.0-alpha"
local LEGACY_SAVE_FILE = "YEETCaravanCore.routes.json"
local DEFAULT_TERMINAL_CLASS = "/Game/Mods/YEET/Buildings/BP_YEETTerminal.BP_YEETTerminal_C"
local DEFAULT_TERMINAL_PLACEHOLDER_CLASS = ""
local DEFAULT_TERMINAL_INTERACTION_FUNCTION = DEFAULT_TERMINAL_CLASS .. ":YEET_RequestRouteMenu"
local WIDGET_ASSET_CLASS = "/Game/Mods/YEET/UI/WBP_YEETRouteMenu.WBP_YEETRouteMenu_C"
local WIDGET_ASSET_PATH = "/Game/Mods/YEET/UI/WBP_YEETRouteMenu.WBP_YEETRouteMenu"

local function log(message)
    print(string.format("[%s] %s", MOD, tostring(message)))
end

local function valid_text(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local DEFAULT_CONFIG = {
    enabled = true,
    development_mode = false,
    loop_ms = 1000,
    max_routes = 32,
    simulation_eta_seconds = 10,
    inspect_distance = 5000.0,
    default_repeat_route = true,
    arrival_activation_required = true,
    terminal_class = DEFAULT_TERMINAL_CLASS,
    terminal_placeholder_class = DEFAULT_TERMINAL_PLACEHOLDER_CLASS,
    terminal_interaction_function = DEFAULT_TERMINAL_INTERACTION_FUNCTION,
    ui_bridge_enabled = true,
    -- 0.4.0 cooked widget 已封裝；仍由 fail-closed resolver 驗證後才掛載。
    ui_widget_runtime_enabled = true,
    ui_debug_key = "F8",
    -- Runtime bridge 預設啟用模組但仍須明確注入、capture、probe 才會 ready。
    inventory_runtime_enabled = true,
    -- Pal reservation bridge 只接受明確注入；沒有 Host probe 時維持 fail-closed。
    pal_reservation_runtime_enabled = true,
}

local function load_config()
    local ok, candidate = pcall(require, "config")
    if not ok or type(candidate) ~= "table" then return DEFAULT_CONFIG end
    local config = {}
    for key, fallback in pairs(DEFAULT_CONFIG) do
        config[key] = candidate[key] ~= nil and candidate[key] or fallback
    end
    config.enabled = config.enabled == true
    config.development_mode = config.development_mode == true
    config.loop_ms = math.max(250, math.floor(tonumber(config.loop_ms) or DEFAULT_CONFIG.loop_ms))
    config.max_routes = math.max(1, math.min(128, math.floor(tonumber(config.max_routes) or DEFAULT_CONFIG.max_routes)))
    config.simulation_eta_seconds = math.max(1, math.min(86400, math.floor(tonumber(config.simulation_eta_seconds) or DEFAULT_CONFIG.simulation_eta_seconds)))
    config.inspect_distance = math.max(500.0, math.min(100000.0, tonumber(config.inspect_distance) or DEFAULT_CONFIG.inspect_distance))
    config.default_repeat_route = config.default_repeat_route ~= false
    config.arrival_activation_required = config.arrival_activation_required ~= false
    config.terminal_class = valid_text(config.terminal_class) and config.terminal_class or DEFAULT_CONFIG.terminal_class
    config.terminal_placeholder_class = valid_text(config.terminal_placeholder_class) and config.terminal_placeholder_class or DEFAULT_CONFIG.terminal_placeholder_class
    config.terminal_interaction_function = valid_text(config.terminal_interaction_function)
        and config.terminal_interaction_function or DEFAULT_CONFIG.terminal_interaction_function
    config.ui_bridge_enabled = config.ui_bridge_enabled ~= false
    config.ui_widget_runtime_enabled = config.ui_widget_runtime_enabled == true
    config.ui_debug_key = valid_text(config.ui_debug_key) and config.ui_debug_key or DEFAULT_CONFIG.ui_debug_key
    config.inventory_runtime_enabled = config.inventory_runtime_enabled == true
    config.pal_reservation_runtime_enabled = config.pal_reservation_runtime_enabled == true
    return config
end

local CONFIG = load_config()
local inventory_runtime = CONFIG.inventory_runtime_enabled and InventoryRuntime.new() or nil
local inventory_adapter = InventoryAdapter.new(inventory_runtime)
local pal_reservation_runtime = CONFIG.pal_reservation_runtime_enabled and PalReservationRuntime.new() or nil
local terminal_interaction_bridge = TerminalInteractionBridge.new({
    class_path = CONFIG.terminal_class,
    function_path = CONFIG.terminal_interaction_function,
})

local UEHelpers = nil
local state = {
    ready = false,
    loop_started = false,
    observer_registered = false,
    terminal_observed = false,
    terminal_placeholder_observed = false,
    terminal_interaction_bridge_probe = nil,
    terminal_interaction_hook_installed = false,
    routes = {},
    world_id = "unknown-world",
    network = Domain.new("unknown-world", os.time()),
    focus = nil,
    ui = {
        open = false,
        revision = 0,
        pending_event = nil,
        widget_asset_ready = false,
        arrival_activation_bridge_ready = false,
        widget_instance = nil,
    },
    inventory_runtime_injected = false,
    inventory_runtime_probe = nil,
    pal_reservation_bridge_ready = false,
    pal_registry = {},
}
local pal_reservation_status

local function safe_call(func, fallback)
    local ok, result = pcall(func)
    if ok then return result end
    return fallback
end

-- Inventory UObject access is intentionally supplied by an explicit runtime
-- bridge.  The built-in instance has no captured UObject and therefore stays
-- fail-closed until a caller captures a live container and runs a probe.
local function set_inventory_adapter_runtime(runtime)
    if type(runtime) ~= "table" then
        return false, "runtime-table-required"
    end
    inventory_runtime = runtime
    inventory_adapter = InventoryAdapter.new(runtime)
    state.inventory_runtime_injected = true
    state.inventory_runtime_probe = nil
    return inventory_adapter:status()
end

local function call_runtime(runtime, method_name, argument)
    if type(runtime) ~= "table" then return nil, "runtime-unavailable" end
    local method = runtime[method_name]
    if type(method) ~= "function" then return nil, "runtime-method-unavailable" end

    -- Runtime.new() exposes regular colon methods for capture/register while
    -- its adapter callbacks are bound plain functions.  Try the explicit
    -- object receiver first; plain custom callbacks remain a safe fallback.
    local ok, first, second = pcall(method, runtime, argument)
    if ok then return first, second end
    ok, first, second = pcall(method, argument)
    if ok then return first, second end
    return nil, "runtime-call-failed"
end

local function call_runtime_plain(runtime, method_name, argument)
    if type(runtime) ~= "table" then return nil, "runtime-unavailable" end
    local method = runtime[method_name]
    if type(method) ~= "function" then return nil, "runtime-method-unavailable" end
    local ok, first, second = pcall(method, argument)
    if ok then return first, second end
    return nil, "runtime-call-failed"
end

local function probe_inventory_adapter()
    local ok, result = inventory_adapter:run_probe()
    state.inventory_runtime_probe = ok and result or inventory_adapter:status().probe
    log(string.format("YEETINV:probe ready=%s reason=%s",
        tostring(ok), ok and "complete" or tostring(result)))
    return ok, result
end

local function probe_inventory_runtime()
    -- Probe 只讀取 UObject shape 與 GUID/out-param 可用性，不呼叫
    -- request_move，也不能自行提交任何 inventory transfer。
    return probe_inventory_adapter()
end

-- The native F -> Blueprint event boundary is intentionally injected.  The
-- core can inspect hook API availability, but it must not guess a callback
-- signature or arm a hook before a host-side probe has verified one.
local function set_terminal_interaction_bridge(runtime)
    if type(runtime) ~= "table" then
        return false, "runtime-table-required"
    end
    local options = {}
    for key, value in pairs(runtime) do options[key] = value end
    options.class_path = valid_text(options.class_path) and options.class_path or CONFIG.terminal_class
    options.function_path = valid_text(options.function_path)
        and options.function_path or CONFIG.terminal_interaction_function
    terminal_interaction_bridge = TerminalInteractionBridge.new(options)
    state.terminal_interaction_hook_installed = false
    local _, status = terminal_interaction_bridge:probe()
    state.terminal_interaction_bridge_probe = status
    return status
end

local function probe_terminal_interaction_bridge()
    local ready, status = terminal_interaction_bridge:probe()
    state.terminal_interaction_bridge_probe = status
    log(string.format("YEETTERM:probe ready=%s reason=%s exact_class=%s function=%s",
        tostring(ready), tostring(status.reason), tostring(status.exact_class_filter),
        tostring(status.function_path)))
    return ready, status
end

local function terminal_interaction_bridge_status()
    local status = terminal_interaction_bridge:status()
    state.terminal_interaction_bridge_probe = status
    status.simulation_only = true
    return status
end

local function inventory_runtime_status()
    local adapter_status = inventory_adapter:status()
    adapter_status.runtime_injected = state.inventory_runtime_injected == true
    adapter_status.runtime_probe = state.inventory_runtime_probe
    local pal_status = pal_reservation_status and pal_reservation_status() or { ready = false }
    adapter_status.simulation_only = not (
        adapter_status.ready == true
        and pal_status.ready == true
        and state.ui.arrival_activation_bridge_ready == true)
    return adapter_status
end

local function inventory_adapter_status()
    local result = inventory_runtime_status()
    log(string.format("YEETINV:status ready=%s pending=%s pass=%d",
        tostring(result.ready), tostring(result.pending), result.pass))
    return result
end

local function submit_inventory_move(spec)
    return inventory_adapter:submit(spec)
end

local function verify_inventory_move(observation)
    return inventory_adapter:verify_pending(observation)
end

local function advance_inventory_pass()
    return inventory_adapter:advance_pass()
end

-- Pal reservation is an explicit boundary.  Injection, registration and
-- probing only establish/read a callback-backed bridge; native mutation can
-- happen only when a caller explicitly invokes Reserve/Release on a runtime
-- that has passed its complete Host-side probe.
local function call_pal_runtime(method_name, argument)
    if type(pal_reservation_runtime) ~= "table" then
        return nil, "pal-reservation-runtime-unavailable"
    end
    local method = pal_reservation_runtime[method_name]
    if type(method) ~= "function" then
        return nil, "pal-reservation-method-unavailable:" .. method_name
    end
    -- Select callback style before invocation.  Never retry a callback after
    -- an exception: a native reserve/release callback could have partially
    -- mutated state before reporting an error.  Runtime.new uses colon
    -- methods for payload operations and a bound zero-argument probe.
    local receiver = pal_reservation_runtime
    local debug_lib = rawget(_G, "debug")
    if debug_lib and type(debug_lib.getinfo) == "function" then
        local info = safe_call(function() return debug_lib.getinfo(method, "u") end, nil)
        if type(info) == "table" and type(info.nparams) == "number" then
            if info.nparams <= 1 and method_name ~= "status" then receiver = nil end
        end
    end
    local ok, first, second
    if receiver then
        ok, first, second = pcall(method, receiver, argument)
    else
        ok, first, second = pcall(method, argument)
    end
    if ok then return first, second end
    return nil, "pal-reservation-runtime-call-failed:" .. method_name
end

local function set_pal_reservation_runtime(runtime)
    if type(runtime) ~= "table" then
        return false, "runtime-table-required"
    end
    pal_reservation_runtime = runtime
    state.pal_reservation_bridge_ready = false
    state.pal_registry = {}
    local status = call_pal_runtime("status")
    if type(status) ~= "table" then
        status = { ready = false, capabilities = {}, reservations = {} }
    end
    status.runtime_injected = true
    status.simulation_only = true
    return status
end

pal_reservation_status = function()
    -- Never return the probe result as a cached readiness snapshot.  The
    -- runtime owns the live ledger and status() is intentionally queried on
    -- every call so external callback/runtime changes are visible immediately.
    local status = call_pal_runtime("status")
    if type(status) ~= "table" then
        status = {
            version = PalReservationRuntime.VERSION,
            ready = false,
            revision = 0,
            capabilities = {},
            reservations = {},
            last_probe = nil,
        }
    end
    status.runtime_injected = pal_reservation_runtime ~= nil
    status.simulation_only = true
    state.pal_reservation_bridge_ready = status.ready == true
    return status
end

local function probe_pal_reservation_runtime()
    local ready, result = call_pal_runtime("probe")
    state.pal_reservation_bridge_ready = ready == true
    if type(result) ~= "table" then result = pal_reservation_status() end
    log(string.format("YEETPAL:probe ready=%s reason=%s", tostring(ready),
        ready and "complete" or tostring(result)))
    return ready == true, result
end

local function register_pal(reference)
    if type(reference) ~= "table" or not valid_text(reference.pal_guid) then
        return false, "pal-guid-required"
    end
    -- A custom host bridge may provide an explicit registration operation.
    -- Runtime.new intentionally does not: resolve_pal is the read-only
    -- fallback and does not retain or mutate any UObject state.
    local resolved, reason = call_pal_runtime("register_pal", reference)
    if type(resolved) ~= "table" then
        resolved, reason = call_pal_runtime("RegisterPal", reference)
    end
    if type(resolved) ~= "table" then
        resolved, reason = call_pal_runtime("resolve_pal", reference)
    end
    if type(resolved) ~= "table" or resolved.pal_guid ~= reference.pal_guid then
        return false, reason or "pal-unresolved"
    end
    state.pal_registry[reference.pal_guid] = true
    return true, { pal_guid = reference.pal_guid, registered = true }
end

local function reserve_pal(spec)
    return call_pal_runtime("reserve", spec)
end

local function release_pal(spec)
    return call_pal_runtime("release", spec)
end

local function reconcile_pal_reservations(observations)
    return call_pal_runtime("reconcile", observations)
end

local function register_inventory_container(reference)
    local resolved, reason = call_runtime(inventory_runtime, "register_container", reference)
    if type(resolved) ~= "table" or resolved.ready ~= true then
        resolved, reason = call_runtime_plain(inventory_runtime, "register_container", reference)
    end
    if type(resolved) ~= "table" or resolved.ready ~= true then
        return nil, reason or "container-unresolved"
    end
    return resolved
end

local function capture_inventory_actor(reference)
    -- Public CaptureActor accepts either a staging reference table or the
    -- actor UObject itself; normalize the latter without scanning the world.
    local capture_reference = reference
    if type(reference) ~= "table"
        or (reference.actor == nil and reference.model == nil
            and reference.container == nil and reference.object == nil
            and reference.container_guid == nil) then
        capture_reference = { actor = reference }
    end
    local resolved, reason = call_runtime(inventory_runtime, "capture_actor", capture_reference)
    if type(resolved) ~= "table" or resolved.ready ~= true then
        resolved, reason = call_runtime_plain(inventory_runtime, "capture_actor", capture_reference)
    end
    if type(resolved) == "table" and resolved.ready == true then return resolved end
    -- 相容只提供 register_actor 或 canonical register_container 的 runtime。
    resolved, reason = call_runtime(inventory_runtime, "register_actor", capture_reference)
    if type(resolved) ~= "table" or resolved.ready ~= true then
        resolved, reason = call_runtime_plain(inventory_runtime, "register_actor", capture_reference)
    end
    if type(resolved) == "table" and resolved.ready == true then return resolved end
    return register_inventory_container(capture_reference)
end

local function is_valid(object)
    return object ~= nil and safe_call(function() return object:IsValid() end, false)
end

local function object_name(object)
    if not is_valid(object) then return nil end
    return safe_call(function() return object:GetFullName() end, nil)
end

local function class_name(object)
    if not is_valid(object) then return nil end
    return safe_call(function()
        local class = object:GetClass()
        return is_valid(class) and class:GetFullName() or nil
    end, nil)
end

local function json_string(value)
    if value == nil then return "null" end
    local text = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
    text = text:gsub("[%z\1-\31]", function(c) return string.format("\\u%04x", string.byte(c)) end)
    return '"' .. text .. '"'
end

local function bool_text(value)
    return value == true and "true" or "false"
end

local function ui_payload(event, source)
    return string.format(
        "{\"event\":%s,\"source\":%s,\"revision\":%d,\"open\":%s,\"ui_bridge_ready\":true,\"widget_asset_ready\":%s,\"arrival_activation_bridge_ready\":%s}",
        json_string(event), json_string(source or "unknown"), state.ui.revision,
        bool_text(state.ui.open), bool_text(state.ui.widget_asset_ready),
        bool_text(state.ui.arrival_activation_bridge_ready))
end

local function widget_library()
    if type(StaticFindObject) ~= "function" then return nil end
    return safe_call(function()
        return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end, nil)
end

local function resolve_widget_class()
    if type(StaticFindObject) ~= "function" then return nil end
    local widget_class = safe_call(function() return StaticFindObject(WIDGET_ASSET_CLASS) end, nil)
    if is_valid(widget_class) then return widget_class end
    if type(LoadAsset) == "function" then
        safe_call(function() return LoadAsset(WIDGET_ASSET_PATH) end, nil)
        widget_class = safe_call(function() return StaticFindObject(WIDGET_ASSET_CLASS) end, nil)
    end
    return is_valid(widget_class) and widget_class or nil
end

-- 關閉路線面板
local function close_route_menu(source)
    state.ui.revision = state.ui.revision + 1
    state.ui.open = false
    state.ui.pending_event = "close"

    -- 若已有實例化的 UMG Widget 且處於開啟狀態，執行生命週期清理
    if is_valid(state.ui.widget_instance) then
        safe_call(function() state.ui.widget_instance:RemoveFromParent() end, nil)
        state.ui.widget_instance = nil
    end

    -- 恢復遊戲操作輸入焦點（GameOnly）
    if UEHelpers then
        local controller = safe_call(UEHelpers.GetPlayerController, nil)
        if is_valid(controller) then
            local library = widget_library()
            safe_call(function()
                controller.bShowMouseCursor = false
                if is_valid(library) then
                    library:SetInputMode_GameOnly(controller, false)
                else
                    controller:SetInputModeGameOnly()
                end
            end, nil)
        end
    end

    local payload = ui_payload("close", source)
    log("YEETUI:request=" .. payload)
    return true, payload
end

-- 開啟路線面板（支援來自按鍵除錯 source=debug_key 或終端原生互動 source=terminal_interact）
local function open_route_menu(source)
    if not CONFIG.ui_bridge_enabled then
        log("ui bridge disabled; open request ignored")
        return false, "ui bridge disabled"
    end

    state.ui.revision = state.ui.revision + 1
    state.ui.open = true
    state.ui.pending_event = "open"

    -- 當已烹飪之 UMG Widget 二進位資產就緒時，進行原生 Viewport 掛載與輸入切換
    local mount_required = CONFIG.ui_widget_runtime_enabled and UEHelpers ~= nil
    if mount_required then
        local controller = safe_call(UEHelpers.GetPlayerController, nil)
        if is_valid(controller) then
            local widget_class = resolve_widget_class()
            if is_valid(widget_class) then
                state.ui.widget_asset_ready = true
                local user_widget_lib = widget_library()
                if is_valid(user_widget_lib) then
                    local widget = safe_call(function()
                        return user_widget_lib:Create(controller, widget_class, controller)
                    end, nil)
                    if is_valid(widget) then
                        state.ui.widget_instance = widget
                        local mounted = safe_call(function()
                            local added = widget:AddToViewport(100)
                            if added == false then return false end
                            controller.bShowMouseCursor = true
                            user_widget_lib:SetInputMode_UIOnlyEx(controller, widget, 0, false)
                            return true
                        end, false)
                        if mounted then
                            log("YEETUI:widget_mounted source=" .. tostring(source))
                        else
                            safe_call(function() widget:RemoveFromParent() end, nil)
                            state.ui.widget_instance = nil
                            state.ui.open = false
                            log("YEETUI:widget_mount_failed")
                        end
                    else
                        state.ui.widget_instance = nil
                        state.ui.open = false
                        log("YEETUI:widget_create_failed")
                    end
                end
                if not is_valid(user_widget_lib) then
                    state.ui.widget_instance = nil
                    state.ui.open = false
                    log("YEETUI:widget_library_unavailable")
                end
            else
                state.ui.widget_asset_ready = false
                state.ui.widget_instance = nil
                state.ui.open = false
                log("YEETUI:widget_class_unavailable path=" .. WIDGET_ASSET_CLASS)
            end
        else
            state.ui.widget_instance = nil
            state.ui.open = false
            log("YEETUI:player_controller_unavailable")
        end
    end

    local payload = ui_payload("open", source)
    log("YEETUI:request=" .. payload)
    return state.ui.open == true, payload
end

local function set_widget_asset_ready(ready)
    if ready == true and not CONFIG.ui_widget_runtime_enabled then
        state.ui.widget_asset_ready = false
        log("YEETUI:widget activation refused; ui_widget_runtime_enabled=false")
        return false
    end
    state.ui.widget_asset_ready = ready == true
    log("YEETUI:widget_asset_ready=" .. bool_text(state.ui.widget_asset_ready))
    return state.ui.widget_asset_ready
end

local function dump_ui_state()
    log("YEETUI:state=" .. ui_payload(state.ui.pending_event or "state", "status"))
end

local function route_count()
    local count = 0
    for _ in pairs(state.routes) do count = count + 1 end
    return count
end

local function network_route_count()
    local count = 0
    for _ in pairs(state.network.routes) do count = count + 1 end
    return count
end

local function emit(route, event)
    log(string.format(
        "YEETSTATE:event=%s id=%s phase=%s origin=%s destination=%s remaining=%d repeat=%s",
        event or "update", route.id, route.phase, route.origin, route.destination,
        math.max(0, math.floor((route.deadline or os.time()) - os.time())),
        tostring(route.repeat_route)))
end

local function save_routes()
    if type(io) ~= "table" or type(io.open) ~= "function" then
        log("route save unavailable; keeping state in memory")
        return false
    end
    local file, err = io.open(LEGACY_SAVE_FILE, "w")
    if not file then
        log("route save failed: " .. tostring(err))
        return false
    end
    local items = {}
    for _, route in pairs(state.routes) do
        table.insert(items, string.format(
            "{\"id\":%s,\"origin\":%s,\"destination\":%s,\"eta_seconds\":%d,\"deadline\":%d,\"repeat_route\":%s,\"phase\":%s}",
            json_string(route.id), json_string(route.origin), json_string(route.destination),
            route.eta_seconds, route.deadline or 0, tostring(route.repeat_route), json_string(route.phase)))
    end
    file:write("[\n  " .. table.concat(items, ",\n  ") .. "\n]\n")
    file:close()
    return true
end

local function save_network()
    state.network.updated_at = os.time()
    local ok, result = Store.save(state.world_id, state.network, "YEET.state")
    if not ok then log("network save failed: " .. tostring(result)) end
    return ok, result
end

local function set_world_id(world_id)
    if not valid_text(world_id) or #world_id > 96 then return false, "valid world_id required" end
    state.world_id = world_id
    local loaded, result = Store.load(world_id, "YEET.state")
    if loaded then
        local normalized, reason = Domain.normalize(loaded)
        if not normalized then return false, reason end
        state.network = normalized
        log("network state loaded: " .. tostring(result))
    else
        state.network = Domain.new(world_id, os.time())
        log("network state initialized: " .. tostring(result))
    end
    return true, state.network
end

local function register_terminal(spec)
    local ok, result = Domain.register_terminal(state.network, spec)
    if ok then save_network() end
    return ok, result
end

local function bind_terminal_trade_container(terminal_id, trade_container_guid)
    local ok, result = Domain.bind_trade_container(state.network, terminal_id, trade_container_guid)
    if ok then save_network() end
    return ok, result
end

local function bind_terminal_escrow_container(terminal_id, escrow_container_guid)
    local ok, result = Domain.bind_escrow_container(state.network, terminal_id, escrow_container_guid)
    if ok then save_network() end
    return ok, result
end

local function create_network_route(spec)
    if network_route_count() >= CONFIG.max_routes then return false, "route limit reached" end
    local ok, result = Domain.create_route(state.network, spec)
    if ok then save_network() end
    return ok, result
end

local function set_cargo_rule(route_id, direction, rule)
    local ok, result = Domain.set_cargo_rule(state.network, route_id, direction, rule)
    if ok then save_network() end
    return ok, result
end

local function create_caravan(spec)
    local ok, result = Domain.create_caravan(state.network, spec, os.time())
    if ok then save_network() end
    return ok, result
end

local function release_caravan(caravan_id, allow_loaded)
    local ok, result = Domain.release_caravan(state.network, caravan_id, allow_loaded == true)
    if ok then save_network() end
    return ok, result
end

local function plan_caravan_leg(caravan_id, counts)
    -- counts 只接受 UI/已驗證原生容器 adapter 提供的純數字快照；此函式本身不碰 UObject。
    local ok, result = Domain.prepare_leg(state.network, caravan_id, counts or {}, os.time())
    if ok then save_network() end
    return ok, result
end

local function confirm_caravan_load(caravan_id, confirmed_counts)
    -- 只有 Host 在隱藏 escrow 容器重新快照確認後才能進入 traveling。
    local ok, result = Domain.confirm_load(state.network, caravan_id, confirmed_counts or {}, os.time())
    if ok then save_network() end
    return ok, result
end

local function confirm_network_activation(caravan_id, activation_token)
    if not state.ui.arrival_activation_bridge_ready then return false, "arrival activation bridge not verified" end
    local ok, result = Domain.confirm_activation(state.network, caravan_id, activation_token)
    if ok then save_network() end
    return ok, result
end

local function commit_caravan_unload(caravan_id, accepted)
    -- accepted 必須是目的箱原生 move 完成後重新觀測到的數量，不能用請求數量冒充成功。
    local ok, result = Domain.commit_unload(state.network, caravan_id, accepted or {})
    if ok then save_network() end
    return ok, result
end

local function build_native_load_requests(leg_id, cargo, source_slots)
    return InventoryPolicy.build_load_requests(leg_id, cargo, source_slots)
end

local function resolve_cargo_destination(rule, terminal)
    return InventoryPolicy.resolve_destination(rule, terminal)
end

local function reconcile_observed_unload(before_counts, after_counts, expected)
    return InventoryPolicy.observed_acceptance(before_counts, after_counts, expected)
end

local function network_status()
    local terminals, routes, caravans, reservations, escrow = 0, 0, 0, 0, 0
    for _ in pairs(state.network.terminals) do terminals = terminals + 1 end
    for _ in pairs(state.network.routes) do routes = routes + 1 end
    for _ in pairs(state.network.caravans) do caravans = caravans + 1 end
    for _ in pairs(state.network.pal_reservations) do reservations = reservations + 1 end
    for _ in pairs(state.network.escrow) do escrow = escrow + 1 end
    log(string.format("YEETNETWORK:world=%s terminals=%d routes=%d caravans=%d reserved_pals=%d escrow=%d",
        state.world_id, terminals, routes, caravans, reservations, escrow))
    return state.network
end

local function create_route(id, origin, destination, eta, repeat_route)
    if route_count() >= CONFIG.max_routes then return false, "route limit reached" end
    if not valid_text(id) or not valid_text(origin) or not valid_text(destination) then
        return false, "id/origin/destination required"
    end
    if #id > 64 or #origin > 64 or #destination > 64 then return false, "field length exceeds limit" end
    if state.routes[id] then return false, "route id already exists" end

    local eta_seconds = math.max(1, math.min(86400, math.floor(tonumber(eta) or CONFIG.simulation_eta_seconds)))
    local route = {
        id = id,
        origin = origin,
        destination = destination,
        eta_seconds = eta_seconds,
        repeat_route = repeat_route == nil and CONFIG.default_repeat_route or (repeat_route == true),
        phase = "scheduled",
        created_at = os.time(),
        deadline = nil,
    }
    state.routes[id] = route
    emit(route, "created")
    save_routes()
    return true, route
end

local function set_phase(id, phase)
    local route = state.routes[id]
    if not route then return false, "route not found" end
    if not valid_text(phase) then return false, "phase required" end
    local valid_phases = {
        scheduled = true,
        traveling = true,
        arrival_pending_activation = true,
        arrived = true,
    }
    if not valid_phases[phase] then return false, "invalid phase" end
    if phase == "arrived" and CONFIG.arrival_activation_required then
        return false, "arrival activation required; use ConfirmArrivalActivation"
    end
    if route.phase == "arrival_pending_activation" and phase ~= "arrival_pending_activation" then
        return false, "route is waiting for ConfirmArrivalActivation"
    end
    route.phase = phase
    emit(route, "phase")
    return true, route
end

local function confirm_arrival_activation(id, base_camp_id)
    local route = state.routes[id]
    if not route then return false, "route not found" end
    if route.phase ~= "arrival_pending_activation" then
        return false, "route is not waiting for arrival activation"
    end
    if not valid_text(base_camp_id) then return false, "base_camp_id required" end

    route.base_camp_id = base_camp_id
    route.phase = "arrived"
    route.deadline = os.time()
    emit(route, "arrival_activated")
    if route.repeat_route then
        route.origin, route.destination = route.destination, route.origin
        route.phase = "scheduled"
        route.deadline = os.time() + route.eta_seconds
        emit(route, "return_scheduled")
    end
    save_routes()
    return true, route
end

local function delete_route(id)
    if not state.routes[id] then return false, "route not found" end
    state.routes[id] = nil
    save_routes()
    log("route deleted: " .. id)
    return true
end

local function get_route_list()
    local list = {}
    for _, route in pairs(state.routes) do
        table.insert(list, {
            id = route.id,
            origin = route.origin,
            destination = route.destination,
            eta_seconds = route.eta_seconds,
            phase = route.phase,
            repeat_route = route.repeat_route,
            remaining_seconds = math.max(0, math.floor((route.deadline or os.time()) - os.time())),
        })
    end
    return list
end

local function tick_routes()
    local now = os.time()
    for _, route in pairs(state.routes) do
        if route.phase == "scheduled" then
            route.phase = "traveling"
            route.deadline = now + route.eta_seconds
            emit(route, "departed")
        elseif route.phase == "traveling" and now >= (route.deadline or now) then
            if CONFIG.arrival_activation_required then
                route.phase = "arrival_pending_activation"
                route.deadline = now
                emit(route, "arrival_pending_activation")
            else
                route.phase = "arrived"
                emit(route, "arrived")
                if route.repeat_route then
                    route.origin, route.destination = route.destination, route.origin
                    route.phase = "scheduled"
                    route.deadline = now + route.eta_seconds
                    emit(route, "return_scheduled")
                end
            end
        end
    end
    for _, caravan_id in ipairs(Domain.tick(state.network, now)) do
        local ok, caravan = Domain.mark_arrival(state.network, caravan_id, now)
        if ok then
            log(string.format("YEETCARAVAN:event=arrival_pending_activation id=%s leg=%s",
                caravan.id, tostring(caravan.leg_id)))
            save_network()
        end
    end
end

local function status()
    log(string.format("active_routes=%d", route_count()))
    for _, route in pairs(state.routes) do emit(route, "status") end
    network_status()
    dump_ui_state()
end

local function config_status()
    log(string.format(
        "config: enabled=%s loop_ms=%d max_routes=%d sim_eta=%d inspect_dist=%.1f repeat=%s arrival_act_req=%s term_class=%s term_fn=%s term_seen=%s placeholder_seen=%s ui_bridge=%s widget_ready=%s inventory_runtime=%s",
        tostring(CONFIG.enabled), CONFIG.loop_ms, CONFIG.max_routes, CONFIG.simulation_eta_seconds,
         CONFIG.inspect_distance, tostring(CONFIG.default_repeat_route), tostring(CONFIG.arrival_activation_required),
         CONFIG.terminal_class, CONFIG.terminal_interaction_function,
         tostring(state.terminal_observed), tostring(state.terminal_placeholder_observed),
         tostring(CONFIG.ui_bridge_enabled), tostring(state.ui.widget_asset_ready),
         tostring(CONFIG.inventory_runtime_enabled)))
end

local function player_focus()
    if not UEHelpers then return nil, "UEHelpers unavailable" end
    local controller = safe_call(UEHelpers.GetPlayerController, nil)
    if not is_valid(controller) then return nil, "player controller unavailable" end
    local camera = safe_call(function() return controller.PlayerCameraManager end, nil)
    if not is_valid(camera) then return nil, "camera unavailable" end
    local start = safe_call(function() return camera:GetCameraLocation() end, nil)
    local rotation = safe_call(function() return camera:GetCameraRotation() end, nil)
    if not start or not rotation then return nil, "camera transform unavailable" end
    local mathlib = safe_call(UEHelpers.GetKismetMathLibrary, nil)
    local system = safe_call(UEHelpers.GetKismetSystemLibrary, nil)
    if not is_valid(mathlib) or not is_valid(system) then return nil, "Kismet libraries unavailable" end
    local forward = safe_call(function() return mathlib:GetForwardVector(rotation) end, nil)
    local finish = safe_call(function() return mathlib:Add_VectorVector(start, mathlib:Multiply_VectorInt(forward, CONFIG.inspect_distance)) end, nil)
    if not finish then return nil, "trace endpoint unavailable" end
    local hit = {}
    local colour = { R = 0, G = 0, B = 0, A = 0 }
    local hit_ok = safe_call(function()
        return system:LineTraceSingle(controller, start, finish, 0, false, {}, 0, hit, true, colour, colour, 0.0)
    end, false)
    if not hit_ok then return nil, "nothing in focus" end
    local actor = safe_call(function() return hit.HitActor and hit.HitActor:Get() or nil end, nil)
    if not is_valid(actor) then return nil, "trace actor unavailable" end
    return actor
end

local function inspect_focus()
    local actor, reason = player_focus()
    if not actor then log("focus inspect: " .. reason); return false end
    state.focus = object_name(actor)
    log("focus inspect: class=" .. tostring(class_name(actor)) .. " object=" .. tostring(state.focus))
    return true
end

-- 終端互動處理：由玩家面對終端按 F 或原生互動元件觸發
local function interact_with_terminal(interactor)
    local actor = interactor
    if not is_valid(actor) then
        actor = player_focus()
    end
    if not terminal_interaction_bridge:is_exact_terminal(actor) then
        log("terminal interact rejected: exact YEET terminal class required")
        return false, "exact YEET terminal class required"
    end
    local cname = class_name(actor) or ""
    log("terminal interact triggered with object: " .. tostring(object_name(actor)) .. " class=" .. cname)
    return open_route_menu("terminal_interact")
end

local function install_terminal_interaction_hook()
    local ok, result = terminal_interaction_bridge:install(interact_with_terminal)
    state.terminal_interaction_hook_installed = ok == true
    state.terminal_interaction_bridge_probe = terminal_interaction_bridge:status()
    if not ok then
        log("YEETTERM:hook not installed (fail-closed): " .. tostring(result))
    end
    return ok, result
end

local function uninstall_terminal_interaction_hook()
    local ok, result = terminal_interaction_bridge:uninstall()
    if ok then state.terminal_interaction_hook_installed = false end
    state.terminal_interaction_bridge_probe = terminal_interaction_bridge:status()
    return ok, result
end

local function simulation_route()
    local now = os.time()
    local id = "sim-" .. tostring(now)
    local ok, route = create_route(id, "BaseCamp_Alpha", "BaseCamp_Beta", CONFIG.simulation_eta_seconds, CONFIG.default_repeat_route)
    if not ok then
        log("simulation route creation failed: " .. tostring(route))
        return
    end
    if route then emit(route, "simulation_started") end
end

local function register_terminal_observer()
    if type(NotifyOnNewObject) ~= "function" then
        log("terminal observer unavailable; no YEET LogicMod asset is loaded")
        return false
    end
    local candidates = {
        { path = CONFIG.terminal_class, placeholder = false },
        { path = CONFIG.terminal_placeholder_class, placeholder = true },
    }
    local armed = false
    for _, candidate in ipairs(candidates) do
        if valid_text(candidate.path) then
            local ok = pcall(NotifyOnNewObject, candidate.path, function(object)
                if class_name(object) ~= candidate.path then
                    log("YEET terminal observer ignored non-exact object: " .. tostring(object_name(object)))
                    return false
                end
                if candidate.placeholder then
                    state.terminal_placeholder_observed = true
                else
                    state.terminal_observed = true
                end
                log("YEET terminal observed: class=" .. candidate.path .. " object=" .. tostring(object_name(object)))
            end)
            if ok then armed = true end
        end
    end
    state.observer_registered = armed
    return armed
end

local function bind(key_name, callback)
    if not Key or not Key[key_name] then return false end
    local register = RegisterKeyBindAsync or RegisterKeyBind
    if type(register) ~= "function" then return false end
    return safe_call(function() return register(Key[key_name], {}, callback) end, false)
end

local function start_loop()
    if state.loop_started or type(LoopAsync) ~= "function" then return false end
    state.loop_started = true
    LoopAsync(CONFIG.loop_ms, function()
        if state.ready then tick_routes() end
    end)
    return true
end

local function initialise()
    UEHelpers = safe_call(function() return require("UEHelpers") end, nil)
    state.ready = true
    if not CONFIG.enabled then
        log("disabled by config.lua; no hooks or timers registered")
        return
    end
    register_terminal_observer()
    -- Read-only capability check; installing the native-F hook remains an
    -- explicit injected-host operation and is never guessed at startup.
    probe_terminal_interaction_bridge()
    start_loop()

    if CONFIG.development_mode then
        -- 開發模式才註冊 F8-F12；正式玩家入口只能來自終端原生 F 互動。
        bind("F9", status)
        -- F10 保持既有設定診斷入口，並附帶明確的只讀 inventory probe。
        bind("F10", function()
            config_status()
            probe_inventory_runtime()
        end)
        bind("F11", simulation_route)
        bind("F12", inspect_focus)
        if CONFIG.ui_debug_key and Key and Key[CONFIG.ui_debug_key] then
            bind(CONFIG.ui_debug_key, function()
                if state.ui.open then close_route_menu("debug_key") else open_route_menu("debug_key") end
            end)
        end
    end

    if Key and Key.ESCAPE then
        bind("ESCAPE", function()
            if state.ui.open then close_route_menu("escape_key") end
        end)
    end

    log(string.format(
        "ready v%s; development_mode=%s product_entry=terminal_F observer=%s terminal_seen=%s placeholder_seen=%s config=local",
        VERSION, tostring(CONFIG.development_mode), tostring(state.observer_registered),
        tostring(state.terminal_observed), tostring(state.terminal_placeholder_observed)))
end

initialise()

-- 導出全域 YEET.CaravanCore 介面供 UMG Widget 與外部呼叫
YEET = YEET or {}
YEET.CaravanCore = {
    CreateRoute = create_route,
    SetPhase = set_phase,
    ConfirmArrivalActivation = confirm_arrival_activation,
    DeleteRoute = delete_route,
    DumpStatus = status,
    DumpUIState = dump_ui_state,
    InspectFocus = inspect_focus,
    OpenRouteMenu = open_route_menu,
    CloseRouteMenu = close_route_menu,
    SetWidgetAssetReady = set_widget_asset_ready,
    GetRouteList = get_route_list,
    InteractWithTerminal = interact_with_terminal,
    InjectTerminalInteractionBridge = set_terminal_interaction_bridge,
    InjectTerminalBridge = set_terminal_interaction_bridge,
    ProbeTerminalInteractionBridge = probe_terminal_interaction_bridge,
    ProbeTerminalBridge = probe_terminal_interaction_bridge,
    TerminalInteractionBridgeStatus = terminal_interaction_bridge_status,
    TerminalBridgeStatus = terminal_interaction_bridge_status,
    InstallTerminalInteractionHook = install_terminal_interaction_hook,
    UninstallTerminalInteractionHook = uninstall_terminal_interaction_hook,
    SetWorldId = set_world_id,
    RegisterTerminal = register_terminal,
    BindTerminalTradeContainer = bind_terminal_trade_container,
    BindTerminalEscrowContainer = bind_terminal_escrow_container,
    CreateNetworkRoute = create_network_route,
    SetCargoRule = set_cargo_rule,
    CreateCaravan = create_caravan,
    ReleaseCaravan = release_caravan,
    PlanCaravanLeg = plan_caravan_leg,
    ConfirmCaravanLoad = confirm_caravan_load,
    ConfirmNetworkActivation = confirm_network_activation,
    CommitCaravanUnload = commit_caravan_unload,
    BuildNativeLoadRequests = build_native_load_requests,
    ResolveCargoDestination = resolve_cargo_destination,
    ReconcileObservedUnload = reconcile_observed_unload,
    GetNetworkState = network_status,
    -- Inventory runtime integration is explicit, read-only until callers use
    -- SubmitInventoryMove with a separately validated exact-slot request.
    InjectInventoryRuntime = set_inventory_adapter_runtime,
    ProbeInventoryRuntime = probe_inventory_runtime,
    RegisterContainer = register_inventory_container,
    CaptureActor = capture_inventory_actor,
    InventoryRuntimeStatus = inventory_runtime_status,
    GetInventoryRuntimeStatus = inventory_runtime_status,
    RegisterInventoryContainer = register_inventory_container,
    CaptureInventoryActor = capture_inventory_actor,
    SetInventoryAdapterRuntime = set_inventory_adapter_runtime,
    ProbeInventoryAdapter = probe_inventory_adapter,
    GetInventoryAdapterStatus = inventory_adapter_status,
    IsInventoryAdapterReady = function() return inventory_adapter:status().ready == true end,
    SubmitInventoryMove = submit_inventory_move,
    VerifyInventoryMove = verify_inventory_move,
    AdvanceInventoryPass = advance_inventory_pass,
    -- Pal reservation bridge: all operations are explicit and fail-closed.
    -- RegisterPal is read-only; Reserve/Release delegate to the injected
    -- runtime and can mutate native state only after its own complete probe.
    InjectPalReservationRuntime = set_pal_reservation_runtime,
    InjectPal = set_pal_reservation_runtime,
    ProbePalReservationRuntime = probe_pal_reservation_runtime,
    ProbePal = probe_pal_reservation_runtime,
    RegisterPal = register_pal,
    ReservePal = reserve_pal,
    ReleasePal = release_pal,
    ReconcilePalReservations = reconcile_pal_reservations,
    ReconcilePal = reconcile_pal_reservations,
    PalReservationStatus = pal_reservation_status,
    GetPalReservationStatus = pal_reservation_status,
    PalReservationRuntimeStatus = pal_reservation_status,
    StatusPal = pal_reservation_status,
    -- Short boundary aliases are useful to a later bridge and are kept
    -- separate from the domain's logical CreateCaravan reservation ledger.
    Inject = set_pal_reservation_runtime,
    Probe = probe_pal_reservation_runtime,
    Reserve = reserve_pal,
    Release = release_pal,
    Reconcile = reconcile_pal_reservations,
    Status = pal_reservation_status,
    -- 只有 native inventory／Pal reservation／arrival activation 三個橋都驗證後才可改為 false。
    SimulationOnly = true,
    PalReservationAdapterReady = false,
    ArrivalActivationAdapterReady = false,
    Version = VERSION,
}
