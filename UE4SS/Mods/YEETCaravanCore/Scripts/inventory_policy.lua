local Policy = {}

local function non_negative(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function slot_order(left, right)
    local left_container = tostring(left.container_guid or '')
    local right_container = tostring(right.container_guid or '')
    if left_container ~= right_container then return left_container < right_container end
    return non_negative(left.slot_index) < non_negative(right.slot_index)
end

-- 將已進入 escrow 的抽象貨物，切成可交給原生容器 API 的確定性搬運請求。
-- source_slots 必須是 Host 重新快照後、且已限制在來源基地範圍內的普通儲物箱欄位。
function Policy.build_load_requests(leg_id, cargo, source_slots)
    if type(leg_id) ~= 'string' or leg_id == '' then return nil, 'leg_id required' end
    local slots_by_item = {}
    for _, slot in ipairs(source_slots or {}) do
        if type(slot) == 'table' and type(slot.item_id) == 'string' and
            type(slot.container_guid) == 'string' and non_negative(slot.count) > 0 then
            slots_by_item[slot.item_id] = slots_by_item[slot.item_id] or {}
            slots_by_item[slot.item_id][#slots_by_item[slot.item_id] + 1] = slot
        end
    end
    for _, slots in pairs(slots_by_item) do table.sort(slots, slot_order) end

    local item_ids = {}
    for item_id in pairs(cargo or {}) do item_ids[#item_ids + 1] = item_id end
    table.sort(item_ids)

    local requests = {}
    for _, item_id in ipairs(item_ids) do
        local remaining = non_negative(cargo[item_id])
        for _, slot in ipairs(slots_by_item[item_id] or {}) do
            if remaining == 0 then break end
            local amount = math.min(remaining, non_negative(slot.count))
            if amount > 0 then
                requests[#requests + 1] = {
                    request_key = string.format('%s:load:%s:%d', leg_id, item_id, #requests + 1),
                    item_id = item_id,
                    count = amount,
                    from_container_guid = slot.container_guid,
                    from_slot_index = non_negative(slot.slot_index),
                }
                remaining = remaining - amount
            end
        end
        if remaining > 0 then return nil, 'source snapshot cannot satisfy escrow for ' .. item_id end
    end
    return requests
end

function Policy.resolve_destination(rule, terminal)
    if type(rule) ~= 'table' then return nil, 'cargo rule required' end
    if rule.destination_kind ~= nil and rule.destination_kind ~= 'trade_box' and rule.destination_kind ~= 'feed_box' then
        return nil, 'invalid destination kind'
    end
    if rule.destination_kind == 'feed_box' then
        if type(rule.destination_container_guid) ~= 'string' or rule.destination_container_guid == '' then
            return nil, 'feed_box destination GUID required'
        end
        return rule.destination_container_guid
    end
    if type(terminal) ~= 'table' or type(terminal.trade_container_guid) ~= 'string' or
        terminal.trade_container_guid == '' then
        return nil, 'destination YEET trade container is not bound'
    end
    return terminal.trade_container_guid
end

-- 原生 move 回傳值不足以證明落箱成功；只接受重新快照觀察到的正向差額。
function Policy.observed_acceptance(before_counts, after_counts, expected)
    local accepted = {}
    for item_id, requested in pairs(expected or {}) do
        local delta = non_negative((after_counts or {})[item_id]) - non_negative((before_counts or {})[item_id])
        accepted[item_id] = math.min(non_negative(requested), math.max(0, delta))
    end
    return accepted
end

return Policy
