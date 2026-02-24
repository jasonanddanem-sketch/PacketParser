--[[
    PacketParser - FFXI Retail Data Collector for Windower 4

    Captures action data from ALL entities in the zone:
      - Trusts (party NPCs) - WS, spells, JA, animations
      - Mobs/NMs (non-party NPCs) - TP moves, spells, behavior
      - Zone spawn tables - every entity that loads in each zone

    Outputs structured JSON files for comparison against LSB server data.

    Usage:
        //pp start              Start tracking
        //pp stop               Stop tracking and save
        //pp status             Show tracking status
        //pp report [mobs]      Summary of trusts or mobs
        //pp detail <name>      Detailed data for a trust or mob
        //pp zone               Show zone spawn data
        //pp save               Force save current data
        //pp scan               Manually scan party for trusts
        //pp reset [all]        Clear data (trusts, or all)
        //pp help               Show help
]]

_addon.name = 'PacketParser'
_addon.author = 'Claude'
_addon.version = '2.0.0'
_addon.commands = {'pp', 'packetparser'}

require('logger')

local res = require('resources')

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------
local config = {
    auto_save_interval = 60,
    trust_dir   = windower.addon_path .. 'data/trusts/',
    mob_dir     = windower.addon_path .. 'data/mobs/',
    zone_dir    = windower.addon_path .. 'data/zones/',
    party_scan_interval = 5,
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local tracking = true
local player_id = nil
local last_save = os.clock()
local last_party_scan = 0
local current_zone_id = 0
local current_zone_name = 'Unknown'

-- Trust tracking
local trust_entities = {}   -- entity_id -> {name, model_id}
local trust_data = {}       -- trust_name -> action data

-- Mob tracking
local mob_entities = {}     -- entity_id -> {name, model_id, zone}
local mob_data = {}         -- "zone/mob_name" -> action data

-- Zone spawn tracking
local zone_spawns = {}      -- zone_name -> { entities = {name -> {model_id, count, positions}} }

-- Player entity cache (to exclude from mob tracking)
local player_entities = {}  -- entity_id -> true

-------------------------------------------------------------------------------
-- Action categories
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
-- Utility
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

local function read_uint16_le(data, pos)
    local b1, b2 = data:byte(pos, pos + 1)
    return b1 + b2 * 0x100
end

local function read_float_le(data, pos)
    -- Read IEEE 754 single-precision float (little-endian)
    local b1, b2, b3, b4 = data:byte(pos, pos + 3)
    if not b1 then return 0 end
    local sign = (b4 >= 128) and -1 or 1
    local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
    local mantissa = ((b3 % 128) * 256 + b2) * 256 + b1
    if exp == 0 and mantissa == 0 then return 0 end
    if exp == 255 then return 0 end -- inf/nan
    return sign * math.ldexp(1 + mantissa / 0x800000, exp - 127)
end

local function sanitize_filename(name)
    return name:gsub('[^%w%s%-]', ''):gsub('%s+', '_')
end

local function ensure_dir(path)
    os.execute('mkdir "' .. path:gsub('/', '\\') .. '" 2>nul')
end

local function get_zone_name(zone_id)
    local z = res.zones[zone_id]
    return z and z.en or ('Zone_' .. tostring(zone_id))
end

-------------------------------------------------------------------------------
-- BitReader
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
-- JSON encoder
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
        if val ~= val then return 'null' end
        if val == math.huge or val == -math.huge then return 'null' end
        return tostring(val)
    elseif type(val) == 'string' then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif type(val) == 'table' then
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
-------------------------------------------------------------------------------
local function parse_action_packet(data)
    if #data < 10 then return nil end

    local act = {}
    act.actor_id = read_uint32_le(data, 5)

    local reader = BitReader.new(data, 9)

    act.target_count = reader:read(10)
    act.category     = reader:read(4)
    act.param        = reader:read(16)
    reader:skip(16)

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
            action.param     = reader:read(17)
            action.message   = reader:read(10)
            reader:skip(31)

            if effect ~= 0 then
                action.add_effect = {
                    animation = reader:read(10),
                    effect    = reader:read(4),
                    param     = reader:read(17),
                    message   = reader:read(10),
                }
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
-- Entity classification
-------------------------------------------------------------------------------
local function get_player_id()
    local player = windower.ffxi.get_player()
    return player and player.id or nil
end

local function get_party_ids()
    local ids = {}
    local party = windower.ffxi.get_party()
    if not party then return ids end
    local slots = {'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}
    for _, slot in ipairs(slots) do
        local member = party[slot]
        if member and member.mob then
            ids[member.mob.id] = true
        end
    end
    return ids
end

local function is_in_party(entity_id)
    local party = windower.ffxi.get_party()
    if not party then return false end
    local slots = {'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}
    for _, slot in ipairs(slots) do
        local member = party[slot]
        if member and member.mob and member.mob.id == entity_id then
            return true
        end
    end
    return false
end

-- Returns: 'trust', 'mob', 'player', 'pet', or 'unknown'
local function classify_entity(entity_id)
    if not entity_id or entity_id == 0 then return 'unknown' end

    -- Already classified
    if trust_entities[entity_id] then return 'trust' end
    if mob_entities[entity_id] then return 'mob' end
    if player_entities[entity_id] then return 'player' end
    if player_id and entity_id == player_id then return 'player' end

    local mob = windower.ffxi.get_mob_by_id(entity_id)
    if not mob then return 'unknown' end

    -- Players
    if not mob.is_npc then
        player_entities[entity_id] = true
        return 'player'
    end

    -- NPC in party = trust
    if is_in_party(entity_id) then
        local name = mob.name or 'Unknown'
        trust_entities[entity_id] = {
            name     = name,
            model_id = mob.model_id or 0,
            index    = mob.index or 0,
        }
        init_trust_entry(name, mob.model_id)
        log('Tracking trust: ' .. name)
        return 'trust'
    end

    -- NPC not in party = mob/NM
    local name = mob.name or 'Unknown'
    mob_entities[entity_id] = {
        name     = name,
        model_id = mob.model_id or 0,
        zone     = current_zone_name,
    }
    init_mob_entry(name)
    return 'mob'
end

-------------------------------------------------------------------------------
-- Data initialization
-------------------------------------------------------------------------------
function init_trust_entry(name, model_id)
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

function init_mob_entry(name)
    local key = current_zone_name .. '/' .. name
    if not mob_data[key] then
        mob_data[key] = {
            name          = name,
            zone          = current_zone_name,
            zone_id       = current_zone_id,
            tp_moves      = {},  -- monster TP abilities
            spells        = {},
            melee_anims   = {},
            ranged_anims  = {},
            add_effects   = {},
            damage_taken  = {}, -- damage samples taken from players (for HP estimation)
            samples       = 0,
            first_seen    = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            last_seen     = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            times_seen    = 1,
        }
    else
        mob_data[key].last_seen = os.date('!%Y-%m-%dT%H:%M:%SZ')
        mob_data[key].times_seen = mob_data[key].times_seen + 1
    end
end

local function init_zone_spawn(zone_name)
    if not zone_spawns[zone_name] then
        zone_spawns[zone_name] = {
            zone_name = zone_name,
            zone_id   = current_zone_id,
            entities  = {},
            last_visit = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        }
    else
        zone_spawns[zone_name].last_visit = os.date('!%Y-%m-%dT%H:%M:%SZ')
    end
end

-------------------------------------------------------------------------------
-- Trust party scan
-------------------------------------------------------------------------------
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
                    init_trust_entry(name, mob.model_id)
                    log('Tracking trust: ' .. name .. ' (Model: ' .. tostring(mob.model_id or '?') .. ')')
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Name resolution
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
    elseif category == 11 then
        -- Monster abilities use a different resource
        local r = res.monster_abilities[param]
        return r and r.en or ('Unknown_MobAbility_' .. param)
    elseif category == 13 then
        local r = res.monster_abilities[param]
        if not r then r = res.job_abilities[param] end
        return r and r.en or ('Unknown_PetAbility_' .. param)
    end
    return 'Unknown_' .. param
end

-------------------------------------------------------------------------------
-- Action recording (shared by trust + mob)
-------------------------------------------------------------------------------
local function record_entity_action(data_table, category, param, animation, damage, add_effect)
    data_table.samples = data_table.samples + 1
    local key = tostring(param)

    if category == 1 then -- Melee
        local akey = tostring(animation)
        if not data_table.melee_anims[akey] then
            data_table.melee_anims[akey] = { animation_id = animation, count = 0 }
        end
        data_table.melee_anims[akey].count = data_table.melee_anims[akey].count + 1

    elseif category == 2 then -- Ranged
        local akey = tostring(animation)
        if not data_table.ranged_anims[akey] then
            data_table.ranged_anims[akey] = { animation_id = animation, count = 0 }
        end
        data_table.ranged_anims[akey].count = data_table.ranged_anims[akey].count + 1

    elseif category == 3 then -- Weapon Skill
        if not data_table.weapon_skills then data_table.weapon_skills = {} end
        if not data_table.weapon_skills[key] then
            data_table.weapon_skills[key] = {
                id             = param,
                name           = resolve_name(3, param),
                animation_id   = animation,
                count          = 0,
                damage_samples = {},
            }
        end
        local ws = data_table.weapon_skills[key]
        ws.count = ws.count + 1
        ws.animation_id = animation
        if damage and damage > 0 and #ws.damage_samples < 100 then
            ws.damage_samples[#ws.damage_samples + 1] = damage
        end

    elseif category == 4 then -- Magic
        if not data_table.spells[key] then
            data_table.spells[key] = {
                id           = param,
                name         = resolve_name(4, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data_table.spells[key].count = data_table.spells[key].count + 1
        data_table.spells[key].animation_id = animation

    elseif category == 6 then -- Job Ability
        if not data_table.job_abilities then data_table.job_abilities = {} end
        if not data_table.job_abilities[key] then
            data_table.job_abilities[key] = {
                id           = param,
                name         = resolve_name(6, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data_table.job_abilities[key].count = data_table.job_abilities[key].count + 1
        data_table.job_abilities[key].animation_id = animation

    elseif category == 11 then -- Monster TP Move
        if not data_table.tp_moves then data_table.tp_moves = {} end
        if not data_table.tp_moves[key] then
            data_table.tp_moves[key] = {
                id           = param,
                name         = resolve_name(11, param),
                animation_id = animation,
                count        = 0,
                damage_samples = {},
            }
        end
        local tp = data_table.tp_moves[key]
        tp.count = tp.count + 1
        tp.animation_id = animation
        if damage and damage > 0 and #tp.damage_samples < 100 then
            tp.damage_samples[#tp.damage_samples + 1] = damage
        end

    elseif category == 13 then -- Pet Ability
        if not data_table.tp_moves then data_table.tp_moves = {} end
        if not data_table.tp_moves[key] then
            data_table.tp_moves[key] = {
                id           = param,
                name         = resolve_name(13, param),
                animation_id = animation,
                count        = 0,
                damage_samples = {},
            }
        end
        data_table.tp_moves[key].count = data_table.tp_moves[key].count + 1

    elseif category == 14 then -- Dance
        if not data_table.dances then data_table.dances = {} end
        if not data_table.dances[key] then
            data_table.dances[key] = {
                id           = param,
                name         = resolve_name(14, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data_table.dances[key].count = data_table.dances[key].count + 1

    elseif category == 15 then -- Rune
        if not data_table.runes then data_table.runes = {} end
        if not data_table.runes[key] then
            data_table.runes[key] = {
                id           = param,
                name         = resolve_name(15, param),
                animation_id = animation,
                count        = 0,
            }
        end
        data_table.runes[key].count = data_table.runes[key].count + 1
    end

    -- Additional effects
    if add_effect then
        if not data_table.add_effects then data_table.add_effects = {} end
        local ae_key = tostring(add_effect.animation) .. '_' .. tostring(add_effect.param)
        if not data_table.add_effects[ae_key] then
            data_table.add_effects[ae_key] = {
                animation = add_effect.animation,
                effect    = add_effect.effect,
                param     = add_effect.param,
                message   = add_effect.message,
                count     = 0,
                source_category = CATEGORY_NAMES[category] or tostring(category),
            }
        end
        data_table.add_effects[ae_key].count = data_table.add_effects[ae_key].count + 1
    end
end

-------------------------------------------------------------------------------
-- Record damage dealt TO a mob (for HP estimation)
-------------------------------------------------------------------------------
local function record_damage_to_mob(target_id, damage)
    if not damage or damage <= 0 then return end

    local mob_info = mob_entities[target_id]
    if not mob_info then
        -- Try to classify
        local mob = windower.ffxi.get_mob_by_id(target_id)
        if mob and mob.is_npc and not is_in_party(target_id) then
            local name = mob.name or 'Unknown'
            mob_entities[target_id] = {
                name     = name,
                model_id = mob.model_id or 0,
                zone     = current_zone_name,
            }
            init_mob_entry(name)
            mob_info = mob_entities[target_id]
        end
    end

    if not mob_info then return end

    local key = current_zone_name .. '/' .. mob_info.name
    local data = mob_data[key]
    if not data then return end

    if not data.damage_taken then data.damage_taken = {} end
    if #data.damage_taken < 500 then
        data.damage_taken[#data.damage_taken + 1] = damage
    end
end

-------------------------------------------------------------------------------
-- Zone spawn recording
-------------------------------------------------------------------------------
local function record_zone_entity(entity_id, name, model_id, pos_x, pos_y, pos_z)
    if not name or name == '' then return end

    init_zone_spawn(current_zone_name)
    local zone = zone_spawns[current_zone_name]

    if not zone.entities[name] then
        zone.entities[name] = {
            name       = name,
            model_id   = model_id or 0,
            count      = 0,
            positions  = {},
            is_npc     = true,
        }
    end

    local ent = zone.entities[name]
    ent.count = ent.count + 1

    -- Record position samples (up to 20 per entity for patrol routes)
    if pos_x and pos_z and #ent.positions < 20 then
        -- Avoid duplicate positions
        local dominated = false
        for _, p in ipairs(ent.positions) do
            local dx = (p.x or 0) - pos_x
            local dz = (p.z or 0) - pos_z
            if dx * dx + dz * dz < 25 then -- within 5 yalms
                dominated = true
                break
            end
        end
        if not dominated then
            ent.positions[#ent.positions + 1] = {
                x = math.floor(pos_x * 100) / 100,
                y = math.floor((pos_y or 0) * 100) / 100,
                z = math.floor(pos_z * 100) / 100,
            }
        end
    end
end

-------------------------------------------------------------------------------
-- File I/O
-------------------------------------------------------------------------------
local function table_to_array(t, sort_field)
    if not t then return {} end
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
    ensure_dir(config.trust_dir)
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
    local filename = config.trust_dir .. sanitize_filename(name) .. '.json'
    local f = io.open(filename, 'w')
    if f then f:write(json_encode(output)); f:close() end
end

local function save_mob(key, data)
    ensure_dir(config.mob_dir)
    -- Create zone subdirectory
    local zone_subdir = config.mob_dir .. sanitize_filename(data.zone) .. '/'
    ensure_dir(zone_subdir)

    local output = {
        name           = data.name,
        zone           = data.zone,
        zone_id        = data.zone_id,
        total_samples  = data.samples,
        times_seen     = data.times_seen,
        first_seen     = data.first_seen,
        last_seen      = data.last_seen,
        tp_moves       = table_to_array(data.tp_moves, 'count'),
        spells         = table_to_array(data.spells, 'count'),
        melee_anims    = table_to_array(data.melee_anims, 'count'),
        ranged_anims   = table_to_array(data.ranged_anims, 'count'),
        add_effects    = table_to_array(data.add_effects, 'count'),
        damage_taken   = data.damage_taken or {},
        estimated_hp   = nil,
    }

    -- Rough HP estimate: sum of all damage taken samples
    -- (only useful if mob was killed during capture)
    if data.damage_taken and #data.damage_taken > 0 then
        local total = 0
        for _, d in ipairs(data.damage_taken) do total = total + d end
        output.total_damage_recorded = total
    end

    local filename = zone_subdir .. sanitize_filename(data.name) .. '.json'
    local f = io.open(filename, 'w')
    if f then f:write(json_encode(output)); f:close() end
end

local function save_zone(zone_name, data)
    ensure_dir(config.zone_dir)

    local output = {
        zone_name  = data.zone_name,
        zone_id    = data.zone_id,
        last_visit = data.last_visit,
        entity_count = count_table(data.entities),
        entities   = {},
    }

    -- Convert to sorted array
    for name, ent in pairs(data.entities) do
        output.entities[#output.entities + 1] = {
            name      = ent.name,
            model_id  = ent.model_id,
            count     = ent.count,
            positions = ent.positions,
        }
    end
    table.sort(output.entities, function(a, b) return a.name < b.name end)

    local filename = config.zone_dir .. sanitize_filename(zone_name) .. '.json'
    local f = io.open(filename, 'w')
    if f then f:write(json_encode(output)); f:close() end
end

local function save_all()
    -- Save trusts
    local trust_count = 0
    for name, data in pairs(trust_data) do
        if data.samples > 0 then
            save_trust(name, data)
            trust_count = trust_count + 1
        end
    end

    -- Save mobs
    local mob_count = 0
    for key, data in pairs(mob_data) do
        if data.samples > 0 then
            save_mob(key, data)
            mob_count = mob_count + 1
        end
    end

    -- Save zone spawns
    local zone_count = 0
    for zone_name, data in pairs(zone_spawns) do
        if count_table(data.entities) > 0 then
            save_zone(zone_name, data)
            zone_count = zone_count + 1
        end
    end

    -- Write master summary
    ensure_dir(windower.addon_path .. 'data/')
    local summary = {
        saved_at    = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        trust_count = trust_count,
        mob_count   = mob_count,
        zone_count  = zone_count,
        trusts      = {},
        mobs        = {},
        zones       = {},
    }

    for name, data in pairs(trust_data) do
        summary.trusts[#summary.trusts + 1] = {
            name = name, samples = data.samples,
            ws = count_table(data.weapon_skills or {}),
            spells = count_table(data.spells or {}),
        }
    end
    table.sort(summary.trusts, function(a, b) return a.name < b.name end)

    for key, data in pairs(mob_data) do
        if data.samples > 0 then
            summary.mobs[#summary.mobs + 1] = {
                name = data.name, zone = data.zone, samples = data.samples,
                tp_moves = count_table(data.tp_moves or {}),
                spells = count_table(data.spells or {}),
            }
        end
    end
    table.sort(summary.mobs, function(a, b)
        if a.zone ~= b.zone then return a.zone < b.zone end
        return a.name < b.name
    end)

    for zone_name, data in pairs(zone_spawns) do
        summary.zones[#summary.zones + 1] = {
            zone = zone_name, entities = count_table(data.entities),
        }
    end
    table.sort(summary.zones, function(a, b) return a.zone < b.zone end)

    local sf = io.open(windower.addon_path .. 'data/_summary.json', 'w')
    if sf then sf:write(json_encode(summary)); sf:close() end

    local total = trust_count + mob_count
    if total > 0 then
        log('Saved: ' .. trust_count .. ' trusts, ' .. mob_count .. ' mobs, ' .. zone_count .. ' zones')
    end
    last_save = os.clock()
end

-------------------------------------------------------------------------------
-- Reporting
-------------------------------------------------------------------------------
local function print_trust_summary()
    local n = count_table(trust_data)
    if n == 0 then
        log('No trust data. Summon trusts and fight!')
        return
    end
    log('=== Trust Summary (' .. n .. ') ===')
    local names = {}
    for name in pairs(trust_data) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local d = trust_data[name]
        local parts = {}
        if count_table(d.weapon_skills or {}) > 0 then parts[#parts + 1] = count_table(d.weapon_skills) .. ' WS' end
        if count_table(d.spells or {}) > 0 then parts[#parts + 1] = count_table(d.spells) .. ' spells' end
        if count_table(d.job_abilities or {}) > 0 then parts[#parts + 1] = count_table(d.job_abilities) .. ' JA' end
        local detail = #parts > 0 and (' [' .. table.concat(parts, ', ') .. ']') or ''
        log('  ' .. name .. ': ' .. d.samples .. ' actions' .. detail)
    end
end

local function print_mob_summary()
    local n = 0
    for _, data in pairs(mob_data) do
        if data.samples > 0 then n = n + 1 end
    end
    if n == 0 then
        log('No mob data yet. Walk near some fights!')
        return
    end
    log('=== Mob Summary (' .. n .. ') ===')

    -- Group by zone
    local by_zone = {}
    for key, data in pairs(mob_data) do
        if data.samples > 0 then
            if not by_zone[data.zone] then by_zone[data.zone] = {} end
            by_zone[data.zone][#by_zone[data.zone] + 1] = data
        end
    end

    local zone_names = {}
    for z in pairs(by_zone) do zone_names[#zone_names + 1] = z end
    table.sort(zone_names)

    for _, zone in ipairs(zone_names) do
        log('  [' .. zone .. ']')
        table.sort(by_zone[zone], function(a, b) return a.name < b.name end)
        for _, d in ipairs(by_zone[zone]) do
            local parts = {}
            if count_table(d.tp_moves or {}) > 0 then parts[#parts + 1] = count_table(d.tp_moves) .. ' TP' end
            if count_table(d.spells or {}) > 0 then parts[#parts + 1] = count_table(d.spells) .. ' spells' end
            local detail = #parts > 0 and (' [' .. table.concat(parts, ', ') .. ']') or ''
            log('    ' .. d.name .. ': ' .. d.samples .. ' actions' .. detail)
        end
    end
end

local function print_zone_summary()
    local n = count_table(zone_spawns)
    if n == 0 then
        log('No zone data yet.')
        return
    end
    log('=== Zone Spawn Summary ===')
    local zones = {}
    for z in pairs(zone_spawns) do zones[#zones + 1] = z end
    table.sort(zones)
    for _, z in ipairs(zones) do
        local data = zone_spawns[z]
        log('  ' .. z .. ': ' .. count_table(data.entities) .. ' unique entities')
    end
end

local function print_detail(search_name)
    -- Search trusts first, then mobs
    local data = nil
    local matched_name = nil
    local entity_type = nil

    -- Trust exact match
    for name, d in pairs(trust_data) do
        if name == search_name then
            data = d; matched_name = name; entity_type = 'Trust'; break
        end
    end
    -- Trust fuzzy match
    if not data then
        local lower = search_name:lower()
        for name, d in pairs(trust_data) do
            if name:lower() == lower or name:lower():find(lower, 1, true) then
                data = d; matched_name = name; entity_type = 'Trust'; break
            end
        end
    end
    -- Mob exact match
    if not data then
        for key, d in pairs(mob_data) do
            if d.name == search_name then
                data = d; matched_name = d.name .. ' (' .. d.zone .. ')'; entity_type = 'Mob'; break
            end
        end
    end
    -- Mob fuzzy match
    if not data then
        local lower = search_name:lower()
        for key, d in pairs(mob_data) do
            if d.name:lower() == lower or d.name:lower():find(lower, 1, true) then
                data = d; matched_name = d.name .. ' (' .. d.zone .. ')'; entity_type = 'Mob'; break
            end
        end
    end

    if not data then
        log('No data for: ' .. search_name)
        return
    end

    log('=== ' .. entity_type .. ': ' .. matched_name .. ' ===')
    if data.model_id then log('Model ID: ' .. tostring(data.model_id)) end
    if data.zone then log('Zone: ' .. data.zone) end
    log('Total actions: ' .. data.samples)
    if data.times_seen then log('Times seen: ' .. data.times_seen) end
    log('')

    -- Weapon Skills (trusts)
    if data.weapon_skills and count_table(data.weapon_skills) > 0 then
        log('Weapon Skills:')
        for _, ws in pairs(data.weapon_skills) do
            log('  ' .. ws.name .. ' [ID:' .. ws.id ..
                ' Anim:0x' .. string.format('%03X', ws.animation_id) ..
                ' x' .. ws.count .. ']')
        end
    end

    -- TP Moves (mobs)
    if data.tp_moves and count_table(data.tp_moves) > 0 then
        log('TP Moves:')
        for _, tp in pairs(data.tp_moves) do
            local dmg = ''
            if tp.damage_samples and #tp.damage_samples > 0 then
                local total = 0
                for _, d in ipairs(tp.damage_samples) do total = total + d end
                dmg = ' AvgDmg:' .. math.floor(total / #tp.damage_samples)
            end
            log('  ' .. tp.name .. ' [ID:' .. tp.id ..
                ' Anim:0x' .. string.format('%03X', tp.animation_id) ..
                ' x' .. tp.count .. dmg .. ']')
        end
    end

    if data.spells and count_table(data.spells) > 0 then
        log('Spells:')
        for _, sp in pairs(data.spells) do
            log('  ' .. sp.name .. ' [ID:' .. sp.id ..
                ' Anim:0x' .. string.format('%03X', sp.animation_id) ..
                ' x' .. sp.count .. ']')
        end
    end

    if data.job_abilities and count_table(data.job_abilities) > 0 then
        log('Job Abilities:')
        for _, ja in pairs(data.job_abilities) do
            log('  ' .. ja.name .. ' [ID:' .. ja.id ..
                ' Anim:0x' .. string.format('%03X', ja.animation_id) ..
                ' x' .. ja.count .. ']')
        end
    end

    if data.melee_anims and count_table(data.melee_anims) > 0 then
        log('Melee Animations:')
        for _, a in pairs(data.melee_anims) do
            log('  Anim:0x' .. string.format('%03X', a.animation_id) .. ' x' .. a.count)
        end
    end

    -- Damage taken summary (mobs)
    if data.damage_taken and #data.damage_taken > 0 then
        local total = 0
        for _, d in ipairs(data.damage_taken) do total = total + d end
        log('Damage Taken: ' .. #data.damage_taken .. ' hits, total: ' .. total .. ', avg: ' .. math.floor(total / #data.damage_taken))
    end

    log('==========================')
end

-------------------------------------------------------------------------------
-- Packet handlers
-------------------------------------------------------------------------------
windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if not tracking then return end
    if injected then return end

    -- Action packet
    if id == 0x028 then
        local ok, act = pcall(parse_action_packet, data)
        if not ok or not act then return end

        local cat = act.category

        -- Skip readying/casting start packets
        if cat == 7 or cat == 8 or cat == 9 or cat == 12 then return end

        local entity_type = classify_entity(act.actor_id)

        if entity_type == 'trust' then
            local info = trust_entities[act.actor_id]
            if info then
                local tdata = trust_data[info.name]
                if tdata then
                    for _, target in ipairs(act.targets) do
                        for _, action in ipairs(target.actions) do
                            record_entity_action(tdata, cat, act.param, action.animation, action.param, action.add_effect)
                        end
                    end
                end
            end

        elseif entity_type == 'mob' then
            local info = mob_entities[act.actor_id]
            if info then
                local key = current_zone_name .. '/' .. info.name
                local mdata = mob_data[key]
                if mdata then
                    for _, target in ipairs(act.targets) do
                        for _, action in ipairs(target.actions) do
                            record_entity_action(mdata, cat, act.param, action.animation, action.param, action.add_effect)
                        end
                    end
                end
            end

        elseif entity_type == 'player' then
            -- Record damage dealt TO mobs by players (for HP estimation)
            if cat == 1 or cat == 2 or cat == 3 or cat == 4 or cat == 6 then
                for _, target in ipairs(act.targets) do
                    for _, action in ipairs(target.actions) do
                        if action.param and action.param > 0 then
                            pcall(record_damage_to_mob, target.id, action.param)
                        end
                    end
                end
            end
        end
    end

    -- NPC/Entity spawn/update packet (0x00E)
    -- Used to build zone spawn tables
    if id == 0x00E then
        if #data < 48 then return end

        local entity_id = read_uint32_le(data, 5)
        local index     = read_uint16_le(data, 9)
        local update_mask = data:byte(11)

        -- Only process if this has position or name data
        local mob = windower.ffxi.get_mob_by_id(entity_id)
        if mob and mob.is_npc and mob.name and mob.name ~= '' then
            -- Try to get position
            local pos_x, pos_y, pos_z
            if mob.x and mob.z then
                pos_x = mob.x
                pos_y = mob.y
                pos_z = mob.z
            end

            pcall(record_zone_entity, entity_id, mob.name, mob.model_id, pos_x, pos_y, pos_z)

            -- Also register as mob entity if not already known and not in party
            if not trust_entities[entity_id] and not mob_entities[entity_id] and not player_entities[entity_id] then
                if not is_in_party(entity_id) then
                    mob_entities[entity_id] = {
                        name     = mob.name,
                        model_id = mob.model_id or 0,
                        zone     = current_zone_name,
                    }
                    init_mob_entry(mob.name)
                end
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
        pcall(save_all)
    end
end)

-------------------------------------------------------------------------------
-- Zone change
-------------------------------------------------------------------------------
windower.register_event('zone change', function(new_zone_id)
    -- Save before clearing
    if count_table(trust_data) > 0 or count_table(mob_data) > 0 then
        pcall(save_all)
    end

    trust_entities = {}
    mob_entities = {}
    player_entities = {}

    current_zone_id = new_zone_id
    current_zone_name = get_zone_name(new_zone_id)
    init_zone_spawn(current_zone_name)

    log('Zoned into: ' .. current_zone_name .. ' (ID: ' .. new_zone_id .. ')')
end)

-------------------------------------------------------------------------------
-- Login / logout
-------------------------------------------------------------------------------
windower.register_event('login', function()
    player_id = get_player_id()
    log('Logged in. Tracking is ' .. (tracking and 'ON' or 'OFF'))
end)

windower.register_event('logout', function()
    pcall(save_all)
    trust_entities = {}
    mob_entities = {}
    player_entities = {}
    player_id = nil
    log('Logged out. Data saved.')
end)

-------------------------------------------------------------------------------
-- Commands
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
        log('Zone: ' .. current_zone_name)
        log('Trusts: ' .. count_table(trust_entities) .. ' active, ' .. count_table(trust_data) .. ' total')
        log('Mobs: ' .. count_table(mob_entities) .. ' active, ' .. count_table(mob_data) .. ' with data')
        log('Zone entities: ' .. (zone_spawns[current_zone_name] and count_table(zone_spawns[current_zone_name].entities) or 0))

    elseif command == 'report' or command == 'summary' then
        local sub = args[1] and args[1]:lower() or 'trusts'
        if sub == 'mobs' or sub == 'mob' then
            print_mob_summary()
        elseif sub == 'zones' or sub == 'zone' then
            print_zone_summary()
        else
            print_trust_summary()
        end

    elseif command == 'detail' or command == 'info' then
        local name = table.concat(args, ' ')
        if name and name ~= '' then
            print_detail(name)
        else
            log('Usage: //pp detail <trust or mob name>')
        end

    elseif command == 'zone' then
        print_zone_summary()
        if zone_spawns[current_zone_name] then
            local data = zone_spawns[current_zone_name]
            log('')
            log('Current zone: ' .. current_zone_name)
            log('Unique entities: ' .. count_table(data.entities))
            local names = {}
            for n in pairs(data.entities) do names[#names + 1] = n end
            table.sort(names)
            for _, n in ipairs(names) do
                local e = data.entities[n]
                log('  ' .. n .. ' (Model:' .. tostring(e.model_id) .. ', Seen:' .. e.count .. 'x)')
            end
        end

    elseif command == 'save' then
        save_all()

    elseif command == 'scan' then
        scan_party_for_trusts()
        log('Party scan complete.')

    elseif command == 'reset' then
        local sub = args[1] and args[1]:lower() or ''
        if sub == 'all' then
            trust_data = {}
            trust_entities = {}
            mob_data = {}
            mob_entities = {}
            zone_spawns = {}
            player_entities = {}
            log('All data cleared (trusts, mobs, zones).')
        elseif sub == 'mobs' then
            mob_data = {}
            mob_entities = {}
            log('Mob data cleared.')
        elseif sub == 'zones' then
            zone_spawns = {}
            log('Zone spawn data cleared.')
        else
            trust_data = {}
            trust_entities = {}
            log('Trust data cleared. Use "//pp reset all" to clear everything.')
        end

    elseif command == 'help' then
        log('PacketParser v' .. _addon.version .. ' - FFXI Retail Data Collector')
        log('')
        log('Tracking:')
        log('  //pp start              Start tracking')
        log('  //pp stop               Stop tracking and save')
        log('  //pp status             Show tracking status')
        log('')
        log('Reports:')
        log('  //pp report             Trust summary')
        log('  //pp report mobs        Mob summary (grouped by zone)')
        log('  //pp report zones       Zone spawn summary')
        log('  //pp detail <name>      Detailed view of trust or mob')
        log('  //pp zone               List all entities in current zone')
        log('')
        log('Data:')
        log('  //pp save               Force save all data')
        log('  //pp scan               Re-scan party for trusts')
        log('  //pp reset              Clear trust data')
        log('  //pp reset mobs         Clear mob data')
        log('  //pp reset all          Clear everything')
        log('')
        log('Output: ' .. windower.addon_path .. 'data/')
        log('  trusts/    Trust JSON files')
        log('  mobs/      Mob JSON files (by zone)')
        log('  zones/     Zone spawn tables')

    else
        log('Unknown command: ' .. command .. '. Try //pp help')
    end
end)

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------
player_id = get_player_id()

-- Try to get current zone
local info = windower.ffxi.get_info()
if info and info.zone then
    current_zone_id = info.zone
    current_zone_name = get_zone_name(info.zone)
    init_zone_spawn(current_zone_name)
end

log('PacketParser v' .. _addon.version .. ' loaded.')
log('Tracking trusts, mobs, and zone spawns. Use //pp help for commands.')
pcall(scan_party_for_trusts)
