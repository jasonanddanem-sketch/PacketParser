# PacketParser Project Notes

## What This Is

A Windower 4 addon that runs on **retail FFXI** to capture trust behavior data via packet parsing. The goal is to collect accurate trust data (weapon skills, spells, animations, job abilities) from retail and use it to fix inaccurate trust implementations on a private server running **LandSandBoat (LSB)**.

## The Problem

LSB's trust implementations are often inaccurate compared to retail FFXI:
- Trusts use wrong weapon skills
- Trusts have wrong or missing spells in their spell lists
- Animation IDs are incorrect causing visual glitches
- AI behavior (when to WS, when to heal, spell priority) doesn't match retail
- LSB is a volunteer project matching a moving target (retail still gets updates)

## The Pipeline

```
1. Play retail FFXI with PacketParser addon running
2. Addon captures action packets (0x028) from trust entities
3. Structured JSON files are saved per trust (data/ directory)
4. Compare JSON data against LSB trust scripts
5. Update LSB Lua scripts to match retail behavior
```

## How the Addon Works

- Registers for incoming packet event on packet ID 0x028 (action packet)
- Identifies trusts by scanning party members that are NPCs (is_npc flag)
- Parses the bit-packed action packet structure to extract:
  - Actor ID (which trust performed the action)
  - Category (melee=1, ranged=2, weapon_skill=3, magic=4, job_ability=6, dance=14, rune=15)
  - Param (the WS ID, spell ID, or ability ID depending on category)
  - Animation ID (the exact animation the server tells the client to play)
  - Damage/healing values
  - Additional effects (enspells, procs)
- Resolves IDs to human-readable names using Windower's resource tables
- Saves JSON per trust + a _summary.json index file
- Auto-saves every 60 seconds, also saves on logout and //pp stop

## Commands

- `//pp start` / `//pp stop` - toggle tracking
- `//pp status` - show active trusts being tracked
- `//pp report` - summary of all collected data
- `//pp detail <name>` - detailed view of one trust
- `//pp save` - force save
- `//pp scan` - manually re-scan party for trusts
- `//pp reset` - clear all data

## Data Collection Checklist

For each trust, the player should:
1. Summon the trust (ideally solo or small group for clean data)
2. Fight mobs that survive long enough for the trust to use WS and spells (5-10 fights minimum)
3. Vary conditions:
   - Let HP drop to trigger healer behavior
   - Pull multiple mobs for AoE behavior
   - Fight different mob types (undead, birds, etc.) for element-specific casters
4. Check `//pp detail <name>` to see if enough data has been captured
5. Move to the next trust

### Per-Role Focus
- **Melee DPS**: Let them build TP and WS multiple times, note self-buffs
- **Tanks**: Watch for Provoke, Flash, defensive abilities
- **WHM/Healers**: Get hurt so they heal, get debuffed so they remove status
- **BLM/Nukers**: Fight varied elements to see spell selection
- **BRD/Support**: Note song rotation and which songs they pick
- **RDM/Hybrid**: Observe when they heal vs nuke vs enfeeble

## Where LSB Trust Scripts Live (on the private server)

- Individual trust scripts: `server/scripts/actions/spells/trust/`
- Gambit AI framework: `server/scripts/globals/gambits.lua`
- Trust globals: `server/scripts/globals/trust.lua`
- Database tables: weapon_skills, spell_list, trust-related tables in MariaDB

## What to Do With the Captured Data

### Comparing Against LSB

For each trust JSON file, compare:

1. **Weapon Skills**: Does the LSB trust script use the same WS IDs? Check the gambit definitions.
2. **Spell List**: Does the trust have the correct spells in its spell list (DB and Lua)?
3. **Animation IDs**: Do the animation values in the DB/Lua match what retail sends?
4. **Ability Usage**: Are job abilities correct and used in the right situations?

### Updating LSB Scripts

Most fixes are Lua-side:
- Edit the trust's spell script in `server/scripts/actions/spells/trust/<trust_name>.lua`
- Update gambit entries to use correct WS IDs
- Update spell lists in the trust's initialization
- Some fixes require DB changes (animation values in weapon_skills or spell tables)

### What Can't Be Fixed Without C++ Source

- If the binary hardcodes or overrides animation IDs in packet construction
- Low-level AI timing or packet-level behavior
- The private server uses pre-compiled binaries (xi_map, xi_world, xi_connect, xi_search)

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
      animation:   12 bits  <-- this is the animation ID we want
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
| 11 | Monster TP move | Ability ID |
| 13 | Pet ability | Ability ID |
| 14 | Dance | Step/Waltz/Flourish ID |
| 15 | Rune | Ward/Effusion ID |

## Known Limitations

- First version; the bit-packed parsing may not be 100% accurate for all edge cases
- All parsing is wrapped in pcall so bad packets are silently skipped
- Does not capture trust model/appearance data from spawn packets (uses get_mob_by_id instead)
- Does not track targeting behavior (who the trust targets with heals/nukes)
- Does not capture interrupted/cancelled actions (only completed ones)
- Data does not persist across addon reloads (JSON files persist but aren't reloaded)

## Future Improvements

- Parse 0x00E entity spawn packets for detailed model/appearance data
- Track targeting behavior (heals party member X, nukes mob Y)
- Record TP thresholds (what TP% does the trust WS at)
- Capture interrupted actions from readying/casting packets
- Reload previously saved JSON data on addon load
- Auto-diff tool that compares captured data against LSB Lua scripts
- Web dashboard for viewing captured data
