# PacketParser - FFXI Retail Data Collector

A Windower 4 addon that passively captures game data from retail FFXI. Tracks **trusts**, **mobs/NMs**, and **zone spawn tables** by parsing packets in real-time. Outputs structured JSON files for fixing private server (LSB) implementations.

## Installation

Copy the `PacketParser` folder into your `Windower4/addons/` directory.

Load in-game:
```
//lua load PacketParser
```

## What It Captures

The addon runs passively — just play normally and it records everything happening around you.

### Trusts (party NPCs)
- Weapon skills (ID, name, animation, damage samples)
- Spells (ID, name, animation, usage count)
- Job abilities, dances, runes
- Melee/ranged animation IDs
- Additional effects (enspells, procs)

### Mobs & NMs (any NPC in the zone)
- TP moves (ID, name, animation, damage)
- Spells cast
- Melee/ranged animations
- Damage taken from players (for HP estimation)
- First/last seen timestamps

### Zone Spawn Tables
- Every NPC/mob entity that loads in each zone
- Model IDs
- Position data (for patrol route mapping)
- Entity counts

**You don't have to fight anything** — the addon captures packets from all fights happening around you. Other players fighting NMs nearby generate data you can use.

## Commands

### Tracking
| Command | Description |
|---|---|
| `//pp start` | Start tracking (on by default) |
| `//pp stop` | Stop tracking and save |
| `//pp status` | Show active tracking status |

### Reports
| Command | Description |
|---|---|
| `//pp report` | Trust data summary |
| `//pp report mobs` | Mob data summary (grouped by zone) |
| `//pp report zones` | Zone spawn table summary |
| `//pp detail <name>` | Detailed view of any trust or mob |
| `//pp zone` | List all entities in current zone |

### Data Management
| Command | Description |
|---|---|
| `//pp save` | Force save all data now |
| `//pp scan` | Re-scan party for trusts |
| `//pp reset` | Clear trust data |
| `//pp reset mobs` | Clear mob data |
| `//pp reset all` | Clear everything |

## Output Structure

```
PacketParser/data/
  _summary.json          Master summary of all captured data
  trusts/
    Zeid_II.json         Per-trust action data
    Apururu.json
  mobs/
    Jugner_Forest/
      Jaggedy-Eared_Jack.json    Per-mob action data (organized by zone)
      Forest_Hare.json
    La_Theine_Plateau/
      Battering_Ram.json
  zones/
    Jugner_Forest.json   Complete entity spawn table for the zone
    La_Theine_Plateau.json
```

## Example Mob Output

```json
{
  "name": "Jaggedy-Eared Jack",
  "zone": "Jugner Forest",
  "zone_id": 104,
  "total_samples": 45,
  "times_seen": 3,
  "tp_moves": [
    {
      "id": 320,
      "name": "Foot Kick",
      "animation_id": 41,
      "count": 8,
      "damage_samples": [120, 95, 140, 110]
    }
  ],
  "spells": [],
  "damage_taken": [250, 300, 180, 420, 500],
  "total_damage_recorded": 1650
}
```

## Tips

- **Just play normally** with the addon loaded — it captures everything passively
- **Zone spawn tables** build automatically as you zone in — every entity that loads is recorded
- **NM data** is captured even if someone else is fighting it — you just need to be in the zone
- **Mob HP estimation** works by summing all damage dealt to a mob during observed fights
- Data auto-saves every 60 seconds and on zone change/logout
- Run `//pp report mobs` to see which mobs/NMs you've captured data for
- Run `//pp zone` to see what entities are in your current zone (compare against your server's spawn tables)
