# CrabInventorySync

Real-time shared inventory sync for **Crab Champions** co-op — a three-tier Lua / PowerShell / Node.js architecture.


## How it works

1. All players install the `Mods/CrabInventorySync/` folder into their UE4SS `Mods/` directory and set the same `roomCode` in `Scripts/config.txt` (or let auto-detection handle it — the room is derived from the session host's player name automatically).
2. On mod load, `bridge.ps1` is auto-launched as a PowerShell window.
3. Every 500 ms the mod reads your inventory and writes `push.json` if anything changed.
4. The bridge detects the file change and POSTs it to the relay server.
5. The server merges all players' inventories (sum of crystals, health, mods, perks, relics; newest player wins for weapon/ability/melee; max wins for slot counts).
6. The bridge writes the merged result to `recv.json`.
7. Every player reads `recv.json` and applies it to their own character.

No "host" designation required — each client manages itself.

## Requirements

- **Crab Champions** (Steam)
- **UE4SS 3.x** — [UE4SS releases](https://github.com/UE4SS-RE/RE-UE4SS/releases)
- **Windows 10 or 11** (PowerShell is built in — no extra install needed)
- **Node.js** — only needed if you are self-hosting the server

## Installation

### Client (all players)

1. Copy `Mods/CrabInventorySync/` into your game's UE4SS `Mods/` folder:
   ```
   <GameRoot>\Crab Champions\Binaries\Win64\ue4ss\Mods\
   ```
2. Ensure `CrabInventorySync : 1` is present in `mods.txt`.
3. Launch the game — the bridge starts automatically.

### Server (optional — self-hosting)

The public relay at `https://crab.dudiebug.net` is used by default.
To self-host:

1. Install [Node.js](https://nodejs.org).
2. In the `server/` folder run:
   ```
   npm install
   node server.js
   ```
3. Update `serverUrl` in `Scripts/config.txt` to point to your server.

## Configuration

Edit `Mods/CrabInventorySync/Scripts/config.txt`:

| Key | Default | Description |
|-----|---------|-------------|
| `serverUrl` | `https://crab.dudiebug.net` | Relay server URL |
| `roomCode` | `default` | Fallback room code (auto-detected in multiplayer) |
| `syncWeapon` | `true` | Sync weapon slot |
| `syncAbility` | `true` | Sync ability slot |
| `syncMelee` | `true` | Sync melee slot |
| `syncCrystals` | `true` | Sync crystal pool |
| `syncHealth` | `true` | Sync health pool |
| `syncWeaponMods` | `true` | Sync weapon mods |
| `syncAbilityMods` | `true` | Sync ability mods |
| `syncMeleeMods` | `true` | Sync melee mods |
| `syncPerks` | `true` | Sync perk list |
| `syncRelics` | `true` | Sync relic list |
| `syncSlots` | `true` | Sync mod/perk slot counts (SetPropertyValue only — no UFunctions) |
| `crystalsProperty` | `Crystals` | Internal PlayerState property name for crystals |

## Server dashboard

The relay server hosts a live dashboard at the root URL (e.g. `https://crab.dudiebug.net`). It shows:

- All active rooms and their session members (connected vs. expected)
- The merged inventory for each room
- Per-player inventory contributions with freshness indicators

## Keybinds

| Key | Action |
|-----|--------|
| F9  | Force full re-sync immediately |

## Known issues

### ⚠️ Joining another player's session crashes the game

**Joining** a session hosted by another player while this mod is installed will crash your client. **Hosting** a session works correctly.

This is a known UE4SS limitation: when a client joins, the game's replication system initialises PlayerState objects in a specific order, and certain UE4SS hooks fire against partially-constructed objects before they are safe to access. The mod's main poll loop and all banned UFunction calls have been removed, but the crash on join is not yet resolved.

**Workaround:** only use this mod in sessions where you are the host.

### Other limitations

- Mod slot counts are increased via `SetPropertyValue` only — this is safe but may not persist across map transitions in all configurations.
- PowerShell 5+ is required (built into Windows 10/11).
- Room code auto-detection requires a live multiplayer session; solo play uses the fallback `roomCode` from config.

## License

This mod is released under the [MIT License](LICENSE).
UE4SS is included under its own [MIT License](UE4SS-LICENSE.txt) (Copyright 2022 Narknon).
