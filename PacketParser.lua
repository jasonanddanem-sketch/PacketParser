--[[
    PacketParser - FFXI Trust Data Collector for Windower 4

    Captures trust actions (weapon skills, spells, job abilities, animations)
    from retail FFXI by parsing action packets. Outputs structured JSON files
    per trust for comparison against private server (LSB) implementations.

    Usage:
        //pp start          Start tracking
        //pp stop           Stop tracking and save
        //pp status         Show tracking status
        //pp report         Summary of all collected data
        //pp detail <name>  Detailed data for a specific trust
        //pp save           Force save current data
        //pp scan           Manually scan party for trusts
        //pp reset          Clear all collected data
        //pp help           Show help
]]

_addon.name = 'PacketParser'
_addon.author = 'Claude'
_addon.version = '1.0.0'
_addon.commands = {'pp', 'packetparser'}

require('logger')

local res = require('resources')

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------
local config = {
    auto_save_interval = 60, -- seconds between auto-saves
    output_dir = windower.addon_path .. 'data/',
    party_scan_interval = 5, -- seconds between party scans
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local tracking = true
local trust_entities = {}   -- entity_id -> {name, model_id, index}
local trust_data = {}       -- trust_name -> collected data
local player_id = nil
local last_save = os.clock()
local last_party_scan = 0

-------------------------------------------------------------------------------
-- Action categories from FFXI action packets
-------------------------------------------------------------------------------
local CATEGORY_NAMES = {
    [1]  = 'melee',
    [2]  = 'ranged',
    [3]  = 'weapon_skill',
    [4]  = 'magic',
    [5]  = 'item',
    [6]  = 'job_ability',
    [7]  = 'ws_readying',
    [8]  = 'casting',
    [9]  = 'item_start',
    [11] = 'monster_ability',
    [12] = 'ranged_start',
    [13] = 'pet_ability',
    [14] = 'dance',
    [15] = 'rune',
}

-------------------------------------------------------------------------------
-- Utility functions
-------------------------------------------------------------------------------
local function count_table(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function read_uint32_le(data, pos)
    local b1, b2, b3, b4 = data:byte(pos, pos + 3)
    return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
end

local function sanitize_filename(name)
    return name:gsub('[^%w%s%-]', ''):gsub('%s+', '_')
end

local function ensure_dir(path)
    -- Windows mkdir; suppress error if already exists
    os.execute('mkdir "' .. path:gsub('/', '\\') .. '" 2>nul')
end

-------------------------------------------------------------------------------
-- BitReader - reads bit-packed fields from FFXI action packets
-- FFXI uses LSB-first bit ordering within bytes
-------------------------------------------------------------------------------
local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(data, start_byte)
    local self = setmetatable({}, BitReader)
    self.data = data
    self.bit_pos = (start_byte - 1) * 8
    return self
end

function BitReader:read(num_bits)
    local result = 0
    for i = 0, num_bits - 1 do
        local byte_pos = math.floor(self.bit_pos / 8) + 1
        local bit_offset = self.bit_pos % 8
        if byte_pos <= #self.data then
            local byte_val = self.data:byte(byte_pos)
            local bit_val = math.floor(byte_val / (2 ^ bit_offset)) % 2
            result = result + bit_val * (2 ^ i)
        end
        self.bit_pos = self.bit_pos + 1
    end
    return result
end

function BitReader:skip(num_bits)
    self.bit_pos = self.bit_pos + num_bits
end

-------------------------------------------------------------------------------
-- JSON encoder (minimal, for output files)
-------------------------------------------------------------------------------
local function json_encode(val, indent, cur)
    indent = indent or '  '
    cur = cur or ''
    local nxt = cur .. indent

    if val == nil then
        return 'null'
    elseif type(val) == 'boolean' then
        return val and 'true' or 'false'
    elseif type(val) == 'number' then
        if val ~= val then return 'null' end -- NaN
        if val == math.huge or val == -math.huge then return 'null' end
        return tostring(val)
    elseif type(val) == 'string' then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif type(val) == 'table' then
        -- Detect array vs object
        local is_array = true
        local max_key = 0
        local has_keys = false
        for k, _ in pairs(val) do
            has_keys = true
            if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then
                is_array = false
                break
            end
            if k > max_key then max_key = k end
        end
        if not has_keys then return '[]' end
        if is_array then
            for i = 1, max_key do
                if val[i] == nil then is_array = false; break end
            end
        end

        if is_array then
            local items = {}
            for i = 1, max_key do
                items[i] = nxt .. json_encode(val[i], indent, nxt)
            end
            return '[\n' .. table.concat(items, ',\n') .. '\n' .. cur .. ']'
        else
            local items = {}
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local v = val[k] or val[tonumber(k)]
                items[#items + 1] = nxt .. '"' .. k .. '": ' .. json_encode(v, indent, nxt)
            end
            return '{\n' .. table.concat(items, ',\n') .. '\n' .. cur .. '}'
        end
    end
    return 'null'
end

-------------------------------------------------------------------------------
-- Action packet parser (0x028)
--
-- Structure after 4-byte FFXI header:
--   Bytes 5-8: Actor ID (uint32 LE)
--   Byte 9+:   Bit-packed action data
--
-- Bit fields:
--   target_count: 10, category: 4, param: 16, unknown: 16
--   Per target: target_id: 32, action_count: 4
--   Per action: reaction: 5, animation: 12, effect: 4, stagger: 7,
--               knockback: 3, param: 17, message: 10, unknown: 31
--   If effect != 0: add_anim: 10, add_effect: 4, add_param: 17, add_msg: 10
--   If add_effect != 0: spike_anim: 10, spike_effect: 4, spike_param: 14, spike_msg: 10
-------------------------------------------------------------------------------
local function parse_action_packet(data)
    if #data < 10 then return nil end

    local act = {}
    act.actor_id = read_uint32_le(data, 5)

    local reader = BitReader.new(data, 9)

    act.target_count = reader:read(10)
    act.category     = reader:read(4)
    act.param        = reader:read(16)
    reader:skip(16) -- unknown / recast

    if act.target_count == 0 or act.target_count > 16 then
        return nil
    end

    act.targets = {}
    for i = 1, act.target_count do
        local target = {}
        target.id = reader:read(32)
        target.action_count = reader:read(4)

        if target.action_count > 8 then return nil end

        target.actions = {}
        for j = 1, target.action_count do
            local action = {}
            action.reaction  = reader:read(5)
            action.animation = reader:read(12)
            local effect     = reader:read(4)
            action.stagger   = reader:read(7)
            action.knockback = reader:read(3)
            action.param     = reader:read(17) -- damage / healing value
            action.message   = reader:read(10)
            reader:skip(31) -- unknown

            -- Additional effect (enspell damage, defense down, etc.)
            if effect ~= 0 then
                action.add_effect = {
                    animation = reader:read(10),
                    effect    = reader:read(4),
                    param     = reader:read(17),
                    message   = reader:read(10),
                }
                -- Spike effect
                if action.add_effect.effect ~= 0 then
                    action.spike = {
                        animation = reader:read(10),
                        effect    = reader:read(4),
                        param     = reader:read(14),
                        message   = reader:read(10),
                    }
                end
            end

            target.actions[j] = action
        end
        act.targets[i] = target
    end

    return act
end

-------------------------------------------------------------------------------
-- Trust detection
-------------------------------------------------------------------------------
local function get_player_id()
    local player = windower.ffxi.get_player()
    return player and player.id or nil
end

local function init_trust_data(name, model_id)
    if not trust_data[name] then
        trust_data[name] = {
            name            = name,
            model_id        = model_id or 0,
            weapon_skills   = {},
            spells          = {},
            job_abilities   = {},
            melee_anims     = {},
            ranged_anims    = {},
            dances          = {},
            runes           = {},
            add_effects     = {},
            samples         = 0,
        }
    end
end

local function scan_party_for_trusts()
    local party = windower.ffxi.get_party()
    if not party then return end

    player_id = get_player_id()

    local slots = {'p1', 'p2', 'p3', 'p4', 'p5'}
    for _, slot in ipairs(slots) do
        local member = party[slot]
        if member and member.mob then
            local mob = member.mob
            if mob and mob.is_npc and mob.id and mob.id ~= player_id then
                if not trust_entities[mob.id] then
                    local name = mob.name or 'Unknown'
                    trust_entities[mob.id] = {
                        name     = name,
                        model_id = mob.model_id or 0,
                        index    = mob.index or 0,
                    }
                    init_trust_data(name, mob.model_id)
                    log('Tracking trust: ' .. name .. ' (ID: ' .. mob.id .. ', Model: ' .. tostring(mob.model_id or '?') .. ')')
                end
            end
        end
    end
end

local function is_trust(entity_id)
    if trust_entities[entity_id] then
        return true
    end

    -- Lazy detection: check if this unknown actor is a trust in our party
    local mob = windower.ffxi.get_mob_by_id(entity_id)
    if not mob or not mob.is_npc then return false end

    local party = windower.ffxi.get_party()
    if not party then return false end

    local slots = {'p1', 'p2', 'p3', 'p4', 'p5'}
    for _, slot in ipairs(slots) do
        local member = party[slot]
        if member and member.mob and member.mob.id == entity_id then
            local name = mob.name or 'Unknown'
            trust_entities[entity_id] = {
                name     = name,
                model_id = mob.model_id or 0,
                index    = mob.index or 0,
            }
            init_trust_data(name, mob.model_id)
            log('Tracking trust (lazy): ' .. name .. ' (ID: ' .. entity_id .. ')')
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Data recording
-------------------------------------------------------------------------------
local function resolve_name(category, param)
    if category == 3 then
        local r = res.weapon_skills[param]
        return r and r.en or ('Unknown_WS_' .. param)
    elseif category == 4 then
        local r = res.spells[param]
        return r and r.en or ('Unknown_Spell_' .. param)
    elseif category == 6 or category == 14 or category == 15 then
        local r = res.job_abilities[param]
        return r and r.en or ('Unknown_JA_' .. param)
    end
    return 'Unknown_' .. param
end

local function record_action(trust_name, category, param, animation, damage, add_effect)
    local data = trust_data[trust_name]
    if not data then return end

    data.samples = data.samples + 1
    local key = tostring(param)

    if category == 1 then -- Melee auto-attack
        local akey = tostring(animation)
        if not data.melee_anims[akey] then
            data.melee_anims[akey] = { animation_id = animation, count = 0 }
        end
        data.melee_anims[akey].count = data.melee_anims[akey].count + 1

    elseif category == 2 then -- Ranged auto-attack
        local akey = tostring(animation)
        if not data.ranged_anims[akey] then
            data.ranged_anims[akey] = { animation_id = animation, count = 0 }
        end
        data.ranged_anims[akey].count = data.ranged_anims[akey].count + 1

    elseif category == 3 then -- Weapon Skill
        if not data.weapon_skills[key] then
            data.weapon_skills[key] = {
                id             = param,
                name           = resolve_name(3, param),
                animation_id   = animation,
                count          = 0,
                damage_samples = {},
            }
        end
        local ws = data.weapon_skills[key]
        ws.count = ws.count + 1
        ws.animation_id = animation
        if damage and damage > 0 and #ws.damage_samples < 100 then
            ws.damage_samples[#ws.damage_samples + 1] = damage
        end

    elseif category == 4 then -- Magic
        if not data.spells[key] then
            data.spells[key] = {
                id           = param,
                name         = resolve_name(4, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data.spells[key].count = data.spells[key].count + 1
        data.spells[key].animation_id = animation

    elseif category == 6 then -- Job Ability
        if not data.job_abilities[key] then
            data.job_abilities[key] = {
                id           = param,
                name         = resolve_name(6, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data.job_abilities[key].count = data.job_abilities[key].count + 1
        data.job_abilities[key].animation_id = animation

    elseif category == 14 then -- Dance (steps, waltzes, flourishes)
        if not data.dances[key] then
            data.dances[key] = {
                id           = param,
                name         = resolve_name(14, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data.dances[key].count = data.dances[key].count + 1

    elseif category == 15 then -- Rune Fencer wards/effusions
        if not data.runes[key] then
            data.runes[key] = {
                id           = param,
                name         = resolve_name(15, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data.runes[key].count = data.runes[key].count + 1
    end

    -- Record additional effect data (enspells, defense down procs, etc.)
    if add_effect then
        local ae_key = tostring(add_effect.animation) .. '_' .. tostring(add_effect.param)
        if not data.add_effects[ae_key] then
            data.add_effects[ae_key] = {
                animation = add_effect.animation,
                effect    = add_effect.effect,
                param     = add_effect.param,
                message   = add_effect.message,
                count     = 0,
                source_category = CATEGORY_NAMES[category] or tostring(category),
            }
        end
        data.add_effects[ae_key].count = data.add_effects[ae_key].count + 1
    end
end

-------------------------------------------------------------------------------
-- File I/O
-------------------------------------------------------------------------------
local function table_to_array(t, sort_field)
    local arr = {}
    for _, v in pairs(t) do
        arr[#arr + 1] = v
    end
    if sort_field then
        table.sort(arr, function(a, b) return (a[sort_field] or 0) > (b[sort_field] or 0) end)
    end
    return arr
end

local function save_trust(name, data)
    local output = {
        name           = data.name,
        model_id       = data.model_id,
        total_samples  = data.samples,
        captured_at    = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        weapon_skills  = table_to_array(data.weapon_skills, 'count'),
        spells         = table_to_array(data.spells, 'count'),
        job_abilities  = table_to_array(data.job_abilities, 'count'),
        melee_anims    = table_to_array(data.melee_anims, 'count'),
        ranged_anims   = table_to_array(data.ranged_anims, 'count'),
        dances         = table_to_array(data.dances, 'count'),
        runes          = table_to_array(data.runes, 'count'),
        add_effects    = table_to_array(data.add_effects, 'count'),
    }

    local filename = config.output_dir .. sanitize_filename(name) .. '.json'
    local f = io.open(filename, 'w')
    if f then
        f:write(json_encode(output))
        f:close()
    else
        log('ERROR: Could not write ' .. filename)
    end
end

local function save_all()
    ensure_dir(config.output_dir)

    local n = 0
    for name, data in pairs(trust_data) do
        if data.samples > 0 then
            save_trust(name, data)
            n = n + 1
        end
    end

    -- Write a summary index file
    local summary = {
        saved_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        trusts = {},
    }
    for name, data in pairs(trust_data) do
        summary.trusts[#summary.trusts + 1] = {
            name          = name,
            model_id      = data.model_id,
            samples       = data.samples,
            weapon_skills = count_table(data.weapon_skills),
            spells        = count_table(data.spells),
            job_abilities = count_table(data.job_abilities),
        }
    end
    table.sort(summary.trusts, function(a, b) return a.name < b.name end)

    local sf = io.open(config.output_dir .. '_summary.json', 'w')
    if sf then
        sf:write(json_encode(summary))
        sf:close()
    end

    if n > 0 then
        log('Saved data for ' .. n .. ' trust(s) to: ' .. config.output_dir)
    end
    last_save = os.clock()
end

-------------------------------------------------------------------------------
-- Reporting
-------------------------------------------------------------------------------
local function print_summary()
    local n = count_table(trust_data)
    if n == 0 then
        log('No trust data collected yet. Summon some trusts and fight!')
        return
    end

    log('=== Trust Data Summary ===')
    log('Trusts tracked: ' .. n)
    log('')

    -- Sort by name
    local names = {}
    for name in pairs(trust_data) do names[#names + 1] = name end
    table.sort(names)

    for _, name in ipairs(names) do
        local d = trust_data[name]
        local parts = {}
        local ws_n  = count_table(d.weapon_skills)
        local sp_n  = count_table(d.spells)
        local ja_n  = count_table(d.job_abilities)
        if ws_n > 0 then parts[#parts + 1] = ws_n .. ' WS' end
        if sp_n > 0 then parts[#parts + 1] = sp_n .. ' spells' end
        if ja_n > 0 then parts[#parts + 1] = ja_n .. ' JA' end
        local detail = #parts > 0 and (' [' .. table.concat(parts, ', ') .. ']') or ''
        local status = d.samples > 0 and tostring(d.samples) .. ' actions' or 'waiting...'
        log('  ' .. name .. ': ' .. status .. detail)
    end
    log('==========================')
end

local function print_detail(search_name)
    local data = nil
    local matched_name = nil

    -- Exact match first, then case-insensitive
    for name, d in pairs(trust_data) do
        if name == search_name then
            data = d; matched_name = name; break
        end
    end
    if not data then
        local lower = search_name:lower()
        for name, d in pairs(trust_data) do
            if name:lower() == lower or name:lower():find(lower, 1, true) then
                data = d; matched_name = name; break
            end
        end
    end

    if not data then
        log('No data for: ' .. search_name)
        return
    end

    log('=== ' .. matched_name .. ' ===')
    log('Model ID: ' .. tostring(data.model_id))
    log('Total actions: ' .. data.samples)
    log('')

    if count_table(data.weapon_skills) > 0 then
        log('Weapon Skills:')
        for _, ws in pairs(data.weapon_skills) do
            log('  ' .. ws.name .. ' [ID:' .. ws.id ..
                ' Anim:0x' .. string.format('%03X', ws.animation_id) ..
                ' x' .. ws.count .. ']')
        end
    end

    if count_table(data.spells) > 0 then
        log('Spells:')
        for _, sp in pairs(data.spells) do
            log('  ' .. sp.name .. ' [ID:' .. sp.id ..
                ' Anim:0x' .. string.format('%03X', sp.animation_id) ..
                ' x' .. sp.count .. ']')
        end
    end

    if count_table(data.job_abilities) > 0 then
        log('Job Abilities:')
        for _, ja in pairs(data.job_abilities) do
            log('  ' .. ja.name .. ' [ID:' .. ja.id ..
                ' Anim:0x' .. string.format('%03X', ja.animation_id) ..
                ' x' .. ja.count .. ']')
        end
    end

    if count_table(data.melee_anims) > 0 then
        log('Melee Animations:')
        for _, a in pairs(data.melee_anims) do
            log('  Anim:0x' .. string.format('%03X', a.animation_id) .. ' x' .. a.count)
        end
    end

    if count_table(data.add_effects) > 0 then
        log('Additional Effects:')
        for _, ae in pairs(data.add_effects) do
            log('  Anim:0x' .. string.format('%03X', ae.animation) ..
                ' Param:' .. ae.param ..
                ' Msg:' .. ae.message ..
                ' x' .. ae.count ..
                ' (from ' .. ae.source_category .. ')')
        end
    end

    log('==========================')
end

-------------------------------------------------------------------------------
-- Packet handler
-------------------------------------------------------------------------------
windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if not tracking then return end
    if injected then return end

    if id == 0x028 then
        local ok, act = pcall(parse_action_packet, data)
        if not ok or not act then return end
        if not is_trust(act.actor_id) then return end

        local trust_info = trust_entities[act.actor_id]
        if not trust_info then return end

        local trust_name = trust_info.name
        local cat = act.category

        -- Only record completed actions (not readying/casting start)
        if cat == 7 or cat == 8 or cat == 9 or cat == 12 then return end

        for _, target in ipairs(act.targets) do
            for _, action in ipairs(target.actions) do
                record_action(
                    trust_name,
                    cat,
                    act.param,
                    action.animation,
                    action.param,
                    action.add_effect
                )
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- Periodic: party scan + auto-save
-------------------------------------------------------------------------------
windower.register_event('prerender', function()
    if not tracking then return end

    local now = os.clock()

    if now - last_party_scan > config.party_scan_interval then
        pcall(scan_party_for_trusts)
        last_party_scan = now
    end

    if now - last_save > config.auto_save_interval then
        if count_table(trust_data) > 0 then
            pcall(save_all)
        end
    end
end)

-------------------------------------------------------------------------------
-- Zone change: trust entity IDs change per zone
-------------------------------------------------------------------------------
windower.register_event('zone change', function()
    trust_entities = {}
    log('Zone changed. Trust entity IDs cleared; will re-detect automatically.')
end)

-------------------------------------------------------------------------------
-- Login / logout
-------------------------------------------------------------------------------
windower.register_event('login', function()
    player_id = get_player_id()
    log('Player logged in. Tracking is ' .. (tracking and 'ON' or 'OFF') .. '.')
end)

windower.register_event('logout', function()
    if count_table(trust_data) > 0 then
        pcall(save_all)
    end
    trust_entities = {}
    player_id = nil
    log('Logged out. Data saved.')
end)

-------------------------------------------------------------------------------
-- Addon command handler
-------------------------------------------------------------------------------
windower.register_event('addon command', function(command, ...)
    command = command and command:lower() or 'help'
    local args = {...}

    if command == 'start' then
        tracking = true
        scan_party_for_trusts()
        log('Tracking started.')

    elseif command == 'stop' then
        tracking = false
        save_all()
        log('Tracking stopped. Data saved.')

    elseif command == 'status' then
        log('Tracking: ' .. (tracking and 'ON' or 'OFF'))
        local n = count_table(trust_entities)
        log('Active trusts: ' .. n)
        for id, info in pairs(trust_entities) do
            log('  ' .. info.name .. ' (Entity: ' .. id .. ', Model: ' .. tostring(info.model_id) .. ')')
        end
        log('Total trusts with data: ' .. count_table(trust_data))

    elseif command == 'report' or command == 'summary' then
        print_summary()

    elseif command == 'detail' or command == 'info' then
        local name = table.concat(args, ' ')
        if name and name ~= '' then
            print_detail(name)
        else
            log('Usage: //pp detail <trust name>')
        end

    elseif command == 'save' then
        save_all()

    elseif command == 'scan' then
        scan_party_for_trusts()
        log('Party scan complete.')

    elseif command == 'reset' then
        trust_data = {}
        trust_entities = {}
        log('All collected data cleared.')

    elseif command == 'help' then
        log('PacketParser v' .. _addon.version .. ' - FFXI Trust Data Collector')
        log('Commands:')
        log('  //pp start          Start tracking trust actions')
        log('  //pp stop           Stop tracking and save data')
        log('  //pp status         Show tracking status and active trusts')
        log('  //pp report         Summary of all collected trust data')
        log('  //pp detail <name>  Detailed breakdown for one trust')
        log('  //pp save           Force save all data to JSON files')
        log('  //pp scan           Manually re-scan party for trusts')
        log('  //pp reset          Clear all collected data')
        log('  //pp help           Show this help')
        log('')
        log('Data is saved to: ' .. config.output_dir)
        log('Auto-saves every ' .. config.auto_save_interval .. ' seconds.')

    else
        log('Unknown command: ' .. command .. '. Try //pp help')
    end
end)

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------
log('PacketParser v' .. _addon.version .. ' loaded. Tracking is ON.')
log('Use //pp help for commands. Data saves to: ' .. config.output_dir)
player_id = get_player_id()
pcall(scan_party_for_trusts)
