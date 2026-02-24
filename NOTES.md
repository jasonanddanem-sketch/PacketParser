# PacketParser Project Notes

## What This Is

A Windower 4 addon that runs on **retail FFXI** to passively capture game data via packet parsing. It tracks **three categories** of data:

1. **Trusts** - WS, spells, JA, animation IDs (for fixing LSB trust scripts)
2. **Mobs/NMs** - TP moves, spells, animations, HP estimation (for fixing LSB mob data)
3. **Zone spawn tables** - every entity that loads in each zone with positions (for fixing LSB spawn tables)

The goal is to collect accurate retail data and use it to fix inaccurate implementations on a private server running **LandSandBoat (LSB)**.

## The Problem

LSB is inaccurate compared to retail in many areas:
- Trusts use wrong weapon skills, wrong spells, wrong animations
- Mob TP move lists are incomplete or wrong
- Mob spell lists don't match retail
- Some mobs/NMs that exist on retail are missing from LSB spawn tables entirely
- NM behavior (which TP moves they use, HP thresholds) is guessed
- LSB is a volunteer project matching a moving target (retail still gets updates)

## The Pipeline

```
1. Play retail FFXI with PacketParser addon loaded (just play normally)
2. Addon passively captures:
   - Action packets (0x028) from trusts AND mobs
   - Entity spawn packets (0x00E) for zone spawn tables
   - Player damage to mobs (for HP estimation)
3. Structured JSON files saved automatically:
   - data/trusts/  -> per-trust action data
   - data/mobs/    -> per-mob action data (organized by zone)
   - data/zones/   -> zone entity spawn tables
4. Compare JSON data against LSB scripts/DB
5. Update LSB to match retail
```

## How the Addon Works

### Entity Classification
Every entity that acts or spawns is classified:
- **Trust**: is_npc AND in player's party -> tracked for WS/spell/JA data
- **Mob**: is_npc AND NOT in party -> tracked for TP moves/spells
- **Player**: not is_npc -> only used to track damage dealt TO mobs

### Packets Captured
- **0x028 (Action)** - All combat actions: melee, WS, magic, JA, TP moves
- **0x00E (Entity Spawn/Update)** - Entity appearance in zone, used for spawn tables and position tracking

### Key Features
- Passive capture: records ALL action packets in the zone, not just from your fights
- Mob HP estimation: sums damage dealt by players to mobs during observed fights
- Zone spawn tables: every entity that loads is recorded with model ID and position
- Position dedup: only records new positions if >5 yalms from any previous position (for patrol routes)
- Auto-saves every 60 seconds + on zone change + on logout
- Data organized by zone for mobs, making it easy to compare against LSB zone-by-zone

### You Don't Have to Fight Everything
The addon captures packets from ALL fights in your zone. If someone else is fighting an NM across the zone, you get their action packets. Just being present is enough.

Also, the zone spawn table builds just by loading into a zone. Every mob that renders in your client generates a 0x00E packet — even if it's standing there doing nothing. This means you get a complete entity list just by walking through zones.

## Commands

### Tracking
- `//pp start` / `//pp stop` - toggle tracking
- `//pp status` - show zone, active trust/mob counts

### Reports
- `//pp report` - trust summary
- `//pp report mobs` - mob summary grouped by zone
- `//pp report zones` - zone spawn table summary
- `//pp detail <name>` - detailed view of any trust or mob (searches both)
- `//pp zone` - list all entities seen in current zone

### Data
- `//pp save` - force save
- `//pp scan` - re-scan party for trusts
- `//pp reset` / `//pp reset mobs` / `//pp reset all` - clear data

## Data Collection Guide

### Trusts
For each trust, summon and fight 5-10 mobs minimum to capture full rotation:
- **Melee DPS**: Let them TP and WS multiple times
- **Tanks**: Watch for Provoke, Flash, defensive abilities
- **WHM/Healers**: Get hurt so they heal; get debuffed so they remove status
- **BLM/Nukers**: Fight varied elements to see spell selection
- **BRD/Support**: Note song rotation
- **RDM/Hybrid**: Watch heal vs nuke vs enfeeble decisions

### Mobs/NMs
- **Just be present** in zones — passively captures all fights near you
- **Popular zones** generate data fast (other players fighting = free data)
- **Walk through zones** to build spawn tables even without fighting
- **NMs** are captured the same as regular mobs — no special handling needed
- **HP estimation** requires observing a mob from full HP to death

### Zone Spawn Tables
- **Zone into an area** — entities automatically register via 0x00E packets
- **Walk around** to load entities that are far from the zone entrance
- **Compare** the resulting zone JSON against your server's spawn tables to find missing mobs

## Where LSB Data Lives (on the private server)

### Trust Scripts
- Individual trust scripts: `server/scripts/actions/spells/trust/`
- Gambit AI framework: `server/scripts/globals/gambits.lua`
- Trust globals: `server/scripts/globals/trust.lua`
- DB tables: weapon_skills, spell_list, trust tables in MariaDB

### Mob Data
- Mob scripts: `server/scripts/zones/<zone_name>/mobs/`
- Mob spawn tables: DB `mob_spawn_points`, `mob_groups`, `mob_pools`
- Mob skills: DB `mob_skills`, `mob_skill_lists`
- NM-specific scripts: same mob scripts directory, with special logic

### Zone Data
- Zone scripts: `server/scripts/zones/<zone_name>/`
- Spawn points: DB `mob_spawn_points` table
- NPC spawns: DB `npc_list` table

## How to Use Captured Data

### Trusts: Comparing Against LSB
1. Open `data/trusts/<TrustName>.json`
2. Compare weapon_skills list against the trust's gambit definitions in LSB
3. Compare spells list against the trust's spell list in LSB
4. Check animation IDs match what the DB/Lua has
5. Update LSB Lua scripts and/or DB entries to match

### Mobs: Comparing Against LSB
1. Open `data/mobs/<ZoneName>/<MobName>.json`
2. Compare tp_moves list against LSB's `mob_skill_lists` DB entries
3. Compare spells against mob script's spell list
4. Check if the mob even exists in LSB's spawn tables
5. Use damage_taken data to estimate HP and verify against LSB

### Zones: Finding Missing Spawns
1. Open `data/zones/<ZoneName>.json`
2. Get list of entities on retail
3. Compare against LSB's `mob_spawn_points` + `npc_list` for that zone
4. Any entity on retail but not in LSB = missing spawn
5. Position data can be used to set correct spawn coordinates

## Technical Details

### Action Packet (0x028) Structure

```
Bytes 0-3:  Standard FFXI packet header
Bytes 4-7:  Actor ID (uint32 LE)
Byte 8+:    Bit-packed data (LSB-first within bytes)

Bit fields:
  target_count: 10 bits
  category:      4 bits
  param:        16 bits (WS/spell/ability ID)
  unknown:      16 bits

  Per target:
    target_id:    32 bits
    action_count:  4 bits

    Per action:
      reaction:     5 bits
      animation:   12 bits  <-- animation ID
      effect:       4 bits  (additional effect flag)
      stagger:      7 bits
      knockback:    3 bits
      param:       17 bits  (damage value)
      message:     10 bits
      unknown:     31 bits

      If effect != 0 (additional effect):
        add_anim:    10 bits
        add_effect:   4 bits (spike flag)
        add_param:   17 bits
        add_message: 10 bits

      If add_effect != 0 (spike effect):
        spike_anim:  10 bits
        spike_effect: 4 bits
        spike_param: 14 bits
        spike_msg:   10 bits
```

### Category Reference

| ID | Type | Param Contains |
|----|------|----------------|
| 1  | Melee auto-attack | - |
| 2  | Ranged auto-attack | - |
| 3  | Weapon Skill | WS ID |
| 4  | Magic | Spell ID |
| 5  | Item use | Item ID |
| 6  | Job Ability | Ability ID |
| 7  | WS readying (ignored) | WS ID |
| 8  | Casting start (ignored) | Spell ID |
| 11 | Monster TP move | Monster Ability ID |
| 13 | Pet ability | Ability ID |
| 14 | Dance | Step/Waltz/Flourish ID |
| 15 | Rune | Ward/Effusion ID |

### Monster Abilities
- Category 11 uses `res.monster_abilities` for name resolution (NOT `res.weapon_skills`)
- These are the mob-specific TP moves like "Fireball", "Tail Smash", etc.
- LSB stores these in `mob_skills` and `mob_skill_lists` DB tables

## What Can't Be Fixed Without C++ Source

- Animation IDs hardcoded in binary packet construction
- Low-level AI timing or packet-level behavior
- The private server uses pre-compiled binaries (xi_map, xi_world, xi_connect, xi_search)

## Known Limitations

- Bit-packed parsing may not be 100% accurate for all edge cases (wrapped in pcall for safety)
- Does not track targeting behavior (who the trust heals, which mob the BLM nukes)
- Does not capture interrupted/cancelled actions
- Data does not persist across addon reloads (JSON files persist but aren't reloaded into memory)
- HP estimation only works if you observe a mob from spawn/full HP to death
- Zone spawn tables may be incomplete if you don't walk through the entire zone

## Future Improvements

- Track targeting behavior (heals party member X, nukes mob Y)
- Record TP thresholds (what TP% do trusts WS at)
- Capture interrupted actions from readying/casting packets
- Reload previously saved JSON data on addon load
- Auto-diff tool comparing captured data against LSB scripts
- Drop table capture (treasure pool packets)
- NPC dialog capture
- Crafting result capture
