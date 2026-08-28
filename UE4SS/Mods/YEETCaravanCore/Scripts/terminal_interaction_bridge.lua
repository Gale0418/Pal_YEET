-- YEET terminal native-F interaction bridge
--
-- The bridge deliberately does not guess a UE4SS hook callback signature.  A
-- host may inject its known-good RegisterHook/UnregisterHook wrappers and mark
-- the signature as verified after a read-only runtime probe.  Until then,
-- Probe is observational and Install remains fail-closed.

local Bridge = {}
Bridge.__index = Bridge
Bridge.VERSION = "0.1.0"

local function valid_text(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function safe_call(callback, ...)
    if type(callback) ~= "function" then return false, nil end
    local ok, first, second = pcall(callback, ...)
    if not ok then return false, nil end
    return true, first, second
end

local function unwrap(value)
    if value == nil then return nil end
    for _ = 1, 2 do
        local getter
        local ok = pcall(function() getter = value.get end)
        if not ok or type(getter) ~= "function" then break end
        local unwrapped
        ok, unwrapped = pcall(getter, value)
        if not ok or unwrapped == nil or unwrapped == value then break end
        value = unwrapped
    end
    return value
end

local function valid_object(object)
    if object == nil then return false end
    local checker
    local ok = pcall(function() checker = object.IsValid end)
    if not ok or type(checker) ~= "function" then return false end
    local result
    ok, result = pcall(checker, object)
    return ok and result == true
end

local function call0(object, name)
    if object == nil then return nil end
    local method
    local ok = pcall(function() method = object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    local result
    ok, result = pcall(method, object)
    return ok and unwrap(result) or nil
end

local function normalize_class_name(value)
    if not valid_text(value) then return nil end
    local name = value:match("^%s*(.-)%s*$")
    -- UClass:GetFullName() may include the reflected type prefix (or the
    -- equivalent quoted export form).  Strip only known prefixes so the
    -- subsequent comparison remains an exact class-path match.
    for _, prefix in ipairs({ "BlueprintGeneratedClass", "Class" }) do
        local quoted = name:match("^" .. prefix .. "%s*['\"](.-)['\"]$")
        if quoted then return quoted end
        local unquoted = name:match("^" .. prefix .. "%s+(.+)$")
        if unquoted then return unquoted end
    end
    return name
end

local function class_full_name(object)
    if not valid_object(object) then return nil end
    local class = call0(object, "GetClass")
    if not valid_object(class) then return nil end
    return normalize_class_name(call0(class, "GetFullName"))
end

function Bridge.new(options)
    options = type(options) == "table" and options or {}
    local self = setmetatable({
        class_path = options.class_path,
        function_path = options.function_path,
        signature_verified = options.signature_verified == true,
        resolve_terminal = options.resolve_terminal,
        register_hook = options.register_hook,
        unregister_hook = options.unregister_hook,
        installed = false,
        hook_pre = nil,
        hook_post = nil,
        last_probe = nil,
    }, Bridge)
    return self
end

Bridge.create = Bridge.new

function Bridge:is_exact_terminal(object)
    if not valid_text(self.class_path) then return false end
    return class_full_name(object) == self.class_path
end

function Bridge:probe()
    -- This function intentionally never calls RegisterHook or any reflected
    -- gameplay function.  It only reports the injected/runtime API shape.
    local register_hook = self.register_hook
    local unregister_hook = self.unregister_hook
    if type(register_hook) ~= "function" and type(RegisterHook) == "function" then
        register_hook = RegisterHook
    end
    if type(unregister_hook) ~= "function" and type(UnregisterHook) == "function" then
        unregister_hook = UnregisterHook
    end
    local result = {
        version = Bridge.VERSION,
        class_path = self.class_path,
        function_path = self.function_path,
        exact_class_filter = valid_text(self.class_path),
        register_hook_available = type(register_hook) == "function",
        unregister_hook_available = type(unregister_hook) == "function",
        callback_signature_verified = self.signature_verified == true,
        callback_context_resolver_available = type(self.resolve_terminal) == "function",
        installed = self.installed == true,
        read_only = true,
        ready = false,
        reason = "hook-signature-unverified",
    }
    if not result.exact_class_filter then
        result.reason = "terminal-class-required"
    elseif not valid_text(self.function_path) then
        result.reason = "terminal-function-required"
    elseif self.function_path:sub(1, #self.class_path + 1) ~= self.class_path .. ":" then
        result.reason = "terminal-function-class-mismatch"
    elseif not result.register_hook_available or not result.unregister_hook_available then
        result.reason = "reversible-hook-api-unavailable"
    elseif not result.callback_signature_verified then
        result.reason = "hook-signature-unverified"
    elseif not result.callback_context_resolver_available then
        result.reason = "callback-context-resolver-required"
    else
        result.ready = true
        result.reason = "verified-by-injected-host"
    end
    self.last_probe = result
    return result.ready, result
end

function Bridge:install(callback)
    if type(callback) ~= "function" then return false, "callback-required" end
    local ready, status = self:probe()
    if not ready then return false, status.reason end
    if self.installed then return true, status end

    local register_hook = self.register_hook or RegisterHook
    local unregister_hook = self.unregister_hook or UnregisterHook
    if type(register_hook) ~= "function" or type(unregister_hook) ~= "function" then
        return false, "reversible-hook-api-unavailable"
    end

    -- Only self is used.  Additional callback parameters are intentionally
    -- opaque because the real function signature is host/version-specific.
    local post = function(...)
        local resolved, object = safe_call(self.resolve_terminal, ...)
        if not resolved then return end
        if not self:is_exact_terminal(object) then return end
        safe_call(callback, object)
    end
    local pre = function() end
    local ok, pre_id, post_id = pcall(register_hook, self.function_path, pre, post)
    if not ok or type(pre_id) ~= "number" or type(post_id) ~= "number" then
        return false, "hook-registration-failed"
    end
    self.hook_pre = pre_id
    self.hook_post = post_id
    self.installed = true
    return true, self:probe()
end

function Bridge:uninstall()
    if not self.installed then return true, "not-installed" end
    local unregister_hook = self.unregister_hook or UnregisterHook
    if type(unregister_hook) ~= "function" then
        return false, "unregister-hook-unavailable"
    end
    local ok = pcall(unregister_hook, self.function_path, self.hook_pre, self.hook_post)
    if not ok then return false, "hook-unregister-failed" end
    self.hook_pre = nil
    self.hook_post = nil
    self.installed = false
    return true, "uninstalled"
end

function Bridge:status()
    local status = self.last_probe
    if type(status) ~= "table" then
        local _, probed = self:probe()
        status = probed
    end
    local copy = {}
    for key, value in pairs(status) do copy[key] = value end
    copy.installed = self.installed == true
    copy.simulation_only = true
    return copy
end

return Bridge
