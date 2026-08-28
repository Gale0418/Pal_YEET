-- Small dependency-free JSON codec used only for YEET-owned state files.
local Json = {}

local function escape(value)
    return value:gsub('[%z\1-\31\\"]', function(char)
        local map = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f',
            ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[char] or string.format('\\u%04x', string.byte(char))
    end)
end

local function is_array(value)
    local size = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false, 0 end
        size = math.max(size, key)
    end
    for index = 1, size do if value[index] == nil then return false, 0 end end
    return true, size
end

local function encode(value, seen)
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' then return value and 'true' or 'false' end
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then error('non-finite JSON number') end
        return tostring(value)
    end
    if kind == 'string' then return '"' .. escape(value) .. '"' end
    if kind ~= 'table' then error('unsupported JSON type: ' .. kind) end
    if seen[value] then error('cyclic JSON table') end
    seen[value] = true
    local array, size = is_array(value)
    local parts = {}
    if array then
        for index = 1, size do parts[index] = encode(value[index], seen) end
        seen[value] = nil
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for key, child in pairs(value) do
        if type(key) ~= 'string' then error('JSON object keys must be strings') end
        parts[#parts + 1] = encode(key, seen) .. ':' .. encode(child, seen)
    end
    table.sort(parts)
    seen[value] = nil
    return '{' .. table.concat(parts, ',') .. '}'
end

function Json.encode(value) return encode(value, {}) end

function Json.decode(text)
    if type(text) ~= 'string' then error('JSON input must be text') end
    local cursor, length = 1, #text
    local function skip() while cursor <= length and text:sub(cursor, cursor):match('%s') do cursor = cursor + 1 end end
    local parse_value
    local function parse_string()
        cursor = cursor + 1
        local out = {}
        while cursor <= length do
            local char = text:sub(cursor, cursor)
            if char == '"' then cursor = cursor + 1; return table.concat(out) end
            if char == '\\' then
                cursor = cursor + 1
                local escaped = text:sub(cursor, cursor)
                local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if escaped == 'u' then
                    local hex = text:sub(cursor + 1, cursor + 4)
                    local code = tonumber(hex, 16)
                    if not code then error('invalid unicode escape') end
                    if code < 128 then out[#out + 1] = string.char(code)
                    elseif code < 2048 then out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
                    else out[#out + 1] = string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64) end
                    cursor = cursor + 4
                elseif map[escaped] then out[#out + 1] = map[escaped]
                else error('invalid string escape') end
            else out[#out + 1] = char end
            cursor = cursor + 1
        end
        error('unterminated JSON string')
    end
    local function parse_array()
        cursor = cursor + 1; skip()
        local result = {}
        if text:sub(cursor, cursor) == ']' then cursor = cursor + 1; return result end
        while true do
            result[#result + 1] = parse_value(); skip()
            local char = text:sub(cursor, cursor); cursor = cursor + 1
            if char == ']' then return result end
            if char ~= ',' then error('expected array comma') end
            skip()
        end
    end
    local function parse_object()
        cursor = cursor + 1; skip()
        local result = {}
        if text:sub(cursor, cursor) == '}' then cursor = cursor + 1; return result end
        while true do
            if text:sub(cursor, cursor) ~= '"' then error('expected object key') end
            local key = parse_string(); skip()
            if text:sub(cursor, cursor) ~= ':' then error('expected object colon') end
            cursor = cursor + 1; skip(); result[key] = parse_value(); skip()
            local char = text:sub(cursor, cursor); cursor = cursor + 1
            if char == '}' then return result end
            if char ~= ',' then error('expected object comma') end
            skip()
        end
    end
    parse_value = function()
        skip(); local char = text:sub(cursor, cursor)
        if char == '"' then return parse_string() end
        if char == '{' then return parse_object() end
        if char == '[' then return parse_array() end
        local literals = { ['true'] = true, ['false'] = false }
        for literal, value in pairs(literals) do
            if text:sub(cursor, cursor + #literal - 1) == literal then cursor = cursor + #literal; return value end
        end
        if text:sub(cursor, cursor + 3) == 'null' then cursor = cursor + 4; return nil end
        local number = text:sub(cursor):match('^-?%d+%.?%d*[eE]?[+-]?%d*')
        if number and #number > 0 then cursor = cursor + #number; return tonumber(number) end
        error('invalid JSON value at byte ' .. cursor)
    end
    local result = parse_value(); skip()
    if cursor <= length then error('trailing JSON data') end
    return result
end

return Json
