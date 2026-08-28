-- YEET Caravan Core local configuration.
-- This file intentionally has no gameplay side effects; values are read once at startup.
return {
    enabled = true,
    development_mode = false,
    loop_ms = 1000,
    max_routes = 32,
    simulation_eta_seconds = 10,
    inspect_distance = 5000.0,
    default_repeat_route = true,
    arrival_activation_required = true,
    terminal_class = "/Game/Mods/YEET/Buildings/BP_YEETTerminal.BP_YEETTerminal_C",
    terminal_placeholder_class = "",
    terminal_interaction_function = "/Game/Mods/YEET/Buildings/BP_YEETTerminal.BP_YEETTerminal_C:YEET_RequestRouteMenu",
    ui_bridge_enabled = true,
    -- 0.4.0 已部署 cooked WBP；失敗時 resolver 會自動 fail closed。
    ui_widget_runtime_enabled = true,
    ui_debug_key = "F8",
    -- 僅載入 runtime bridge；沒有明確 capture + probe 時仍維持 fail-closed。
    inventory_runtime_enabled = true,
    -- 僅載入 Pal reservation boundary；沒有明確 Host probe 時仍維持 fail-closed。
    pal_reservation_runtime_enabled = true,
    -- 2026-08-26 原版遠征 UI 探針觸發 native access violation；不是產品功能，保持停用。
}
