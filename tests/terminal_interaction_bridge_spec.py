"""Static/runtime shape checks for the fail-closed YEET terminal bridge."""

from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("terminal_interaction_bridge_spec.py: FAIL (Lupa is not installed)")
    raise SystemExit(1)


ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
scripts = str(ROOT / "UE4SS/Mods/YEETCaravanCore/Scripts/?.lua").replace("\\", "/")
lua.execute("package.path = " + repr(scripts) + " .. ';' .. package.path")

lua.execute(
    r'''
local Bridge = require('terminal_interaction_bridge')
local CLASS = '/Game/Mods/YEET/Buildings/BP_YEETTerminal.BP_YEETTerminal_C'
local FUNCTION = CLASS .. ':YEET_RequestRouteMenu'

local function valid(self) return self.alive == true end
local function object(class_name)
    local class = { alive = true, IsValid = valid,
        GetFullName = function() return class_name end }
    return { alive = true, IsValid = valid,
        GetClass = function() return class end }
end

local exact = object(CLASS)
local reflected = object('BlueprintGeneratedClass ' .. CLASS)
local quoted = object("Class'" .. CLASS .. "'")
local wrong = object('/Script/Pal.BP_BuildObject_WorkBench_C')
local malformed = { alive = true, IsValid = valid }

local register_calls = 0
local callback_calls = 0
local post_callback
local unregistered = false
local function register(path, pre, post)
    register_calls = register_calls + 1
    assert(path == FUNCTION and type(pre) == 'function' and type(post) == 'function')
    post_callback = post
    return 11, 12
end
local function unregister(path, pre, post)
    assert(path == FUNCTION and pre == 11 and post == 12)
    unregistered = true
end

local bridge = Bridge.new({ class_path = CLASS, function_path = FUNCTION,
    register_hook = register, unregister_hook = unregister })
assert(bridge:is_exact_terminal(exact))
assert(bridge:is_exact_terminal(reflected))
assert(bridge:is_exact_terminal(quoted))
assert(not bridge:is_exact_terminal(wrong))
assert(not bridge:is_exact_terminal(malformed))
local ready, probe = bridge:probe()
assert(not ready and probe.read_only and probe.exact_class_filter)
assert(probe.reason == 'hook-signature-unverified')
assert(register_calls == 0, 'probe must not register hooks')
assert(not bridge:install(function() callback_calls = callback_calls + 1 end))
assert(register_calls == 0, 'unverified bridge must stay disarmed')

local verified = Bridge.new({ class_path = CLASS, function_path = FUNCTION,
    signature_verified = true, register_hook = register, unregister_hook = unregister,
    resolve_terminal = function(first) return first end })
assert(verified:install(function() callback_calls = callback_calls + 1 end))
assert(register_calls == 1)
post_callback(exact)
post_callback(wrong)
assert(callback_calls == 1, 'hook callback must enforce exact class')
assert(verified:uninstall() and unregistered)
assert(verified:status().simulation_only == true)
'''
)

print("terminal_interaction_bridge_spec.py: bridge tests passed")
