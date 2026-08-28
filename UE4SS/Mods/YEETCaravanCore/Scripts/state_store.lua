local Json = require('json')
local Store = {}

local function sanitize(value)
    value = tostring(value or 'unknown-world'):gsub('[^%w_-]', '_')
    return value:sub(1, 96)
end

function Store.path_for(world_id, prefix)
    return string.format('%s.%s.json', prefix or 'YEET.state', sanitize(world_id))
end

local function read_json(path)
    local file = io.open(path, 'rb')
    if not file then return nil, 'not found' end
    local text = file:read('*a'); file:close()
    local ok, value = pcall(Json.decode, text)
    if not ok or type(value) ~= 'table' then return nil, 'invalid state: ' .. tostring(value) end
    return value, path
end

function Store.load(world_id, prefix)
    if type(io) ~= 'table' or type(io.open) ~= 'function' then return nil, 'io unavailable' end
    local path = Store.path_for(world_id, prefix)
    local value, result = read_json(path)
    if value then return value, result end

    local backup_value, backup_result = read_json(path .. '.bak')
    if backup_value then return backup_value, backup_result end
    return nil, string.format('primary=%s; backup=%s', tostring(result), tostring(backup_result))
end

function Store.save(world_id, value, prefix)
    if type(io) ~= 'table' or type(io.open) ~= 'function' then return false, 'io unavailable' end
    local path = Store.path_for(world_id, prefix)
    local temporary, backup = path .. '.tmp', path .. '.bak'
    local ok, text = pcall(Json.encode, value)
    if not ok then return false, 'encode failed: ' .. tostring(text) end
    local file, err = io.open(temporary, 'wb')
    if not file then return false, tostring(err) end
    file:write(text, '\n'); file:flush(); file:close()
    os.remove(backup)
    local current = io.open(path, 'rb')
    if current then
        current:close()
        local backed_up, backup_error = os.rename(path, backup)
        if not backed_up then
            os.remove(temporary)
            return false, 'backup failed: ' .. tostring(backup_error)
        end
    end
    local renamed, rename_error = os.rename(temporary, path)
    if not renamed then os.rename(backup, path); return false, tostring(rename_error) end
    return true, path
end

return Store
