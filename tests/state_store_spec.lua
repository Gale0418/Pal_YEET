package.path = 'UE4SS/Mods/YEETCaravanCore/Scripts/?.lua;' .. package.path

local Store = require('state_store')
local Domain = require('domain')

local function equal(actual, expected, label)
    assert(actual == expected, string.format('%s: expected %s, got %s', label, tostring(expected), tostring(actual)))
end

local prefix = 'YEET.state-store-test'
local world_id = 'world:/unsafe?name'
local path = Store.path_for(world_id, prefix)

os.remove(path)
os.remove(path .. '.tmp')
os.remove(path .. '.bak')

equal(path, prefix .. '.world__unsafe_name.json', 'sanitized world path')

local first = Domain.new(world_id, 100)
assert(Store.save(world_id, first, prefix))
local loaded, loaded_path = Store.load(world_id, prefix)
assert(loaded)
equal(loaded_path, path, 'primary load path')
equal(loaded.world_id, world_id, 'primary world id')

local second = Domain.new(world_id, 200)
second.updated_at = 250
assert(Store.save(world_id, second, prefix))

local corrupt = assert(io.open(path, 'wb'))
corrupt:write('{ definitely-not-json')
corrupt:close()

local recovered, recovered_path = Store.load(world_id, prefix)
assert(recovered)
equal(recovered_path, path .. '.bak', 'backup recovery path')
equal(recovered.updated_at, 100, 'backup recovery content')

local legacy = { world_id = 'legacy-world', terminals = { A = { id = 'A' } } }
local migrated = assert(Domain.normalize(legacy))
equal(migrated.schema_version, Domain.SCHEMA_VERSION, 'legacy schema migration')
assert(type(migrated.routes) == 'table')

local unsupported, reason = Domain.normalize({ schema_version = 99, world_id = 'future' })
equal(unsupported, nil, 'future schema rejected')
assert(tostring(reason):find('unsupported schema', 1, true))

os.remove(path)
os.remove(path .. '.tmp')
os.remove(path .. '.bak')

print('state_store_spec.lua: all tests passed')
