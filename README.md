# PacketParser - FFXI Trust Data Collector

A Windower 4 addon that captures trust behavior data from retail FFXI by parsing action packets in real-time. Outputs structured JSON files that can be used to fix trust implementations on private servers (LSB).

## Installation

Copy the `PacketParser` folder into your `Windower4/addons/` directory.

Load in-game:
```
//lua load PacketParser
```

## Usage

The addon starts tracking automatically when loaded. Just play normally with trusts in your party.

### Commands

| Command | Description |
|---|---|
| `//pp start` | Start tracking (on by default) |
| `//pp stop` | Stop tracking and save data |
| `//pp status` | Show active trusts being tracked |
| `//pp report` | Summary of all collected data |
| `//pp detail <name>` | Detailed breakdown for one trust |
| `//pp save` | Force save all data now |
| `//pp scan` | Re-scan party for trusts |
| `//pp reset` | Clear all collected data |
| `//pp help` | Show help |

### What It Captures

For each trust in your party, the addon records:

- **Weapon Skills** - ID, name, animation ID, usage count, damage samples
- **Spells** - ID, name, animation ID, usage count
- **Job Abilities** - ID, name, animation ID, usage count
- **Melee/Ranged Animations** - Animation IDs for auto-attacks
- **Dances** - Steps, waltzes, flourishes (for DNC trusts)
- **Runes** - Wards and effusions (for RUN trusts)
- **Additional Effects** - Enspell procs, defense down, etc.

### Output

Data is saved as JSON files in `PacketParser/data/`:

- One file per trust (e.g., `Zeid_II.json`)
- `_summary.json` - overview of all captured trusts
- Auto-saves every 60 seconds

### Example Output

```json
{
  "name": "Zeid II",
  "model_id": 927,
  "total_samples": 142,
  "weapon_skills": [
    {
      "id": 30,
      "name": "Ground Strike",
      "animation_id": 63,
      "count": 12,
      "damage_samples": [450, 380, 520, 410]
    }
  ],
  "spells": [
    {
      "id": 260,
      "name": "Stun",
      "animation_id": 27,
      "count": 8
    }
  ]
}
```

## Tips for Data Collection

1. **Summon trusts one at a time** for cleanest data attribution
2. **Fight mobs that last a while** so trusts cycle through their full ability sets
3. **5-10 fights minimum** per trust to capture their full rotation
4. **Vary conditions** - let HP drop for healer behavior, fight groups for AoE, fight undead for element-specific casters
5. **Leave it running** during normal play sessions to accumulate data passively

## How the Data Gets Used

After collecting data, the JSON files can be compared against private server (LSB) trust scripts to identify:

- Wrong weapon skills (trust uses WS X on retail but WS Y on the server)
- Missing spells in the trust's spell list
- Wrong animation IDs causing visual glitches
- Incorrect ability priorities/frequencies
