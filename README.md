# CrabInventorySync

Real-time shared inventory sync for **Crab Champions** co-op — a three-tier Lua / PowerShell / Node.js architecture.

## How it works

Once installed, the mod runs entirely in the background. When you join a co-op session, all players' inventories — crystals, health, weapons, abilities, mods, perks, and relics — are automatically merged and kept in sync in real time. No setup or configuration is needed; the mod detects your session automatically.

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
| `crystalsProperty` | `Crystals` | Internal PlayerState property name for crystals |

## Keybinds

| Key | Action |
|-----|--------|
| F9  | Force full re-sync immediately |

## Limitations

- Mod slot counts are fixed by what each player already owns — items can be swapped within existing slots but new slots cannot be added (UE4SS TArray limitation).
- PowerShell 5+ is required (built into Windows 10/11).
- Room code auto-detection requires a live multiplayer session; solo play uses the fallback `roomCode` from config.

## License

This mod is released under the [MIT License](LICENSE).
UE4SS is included under its own [MIT License](UE4SS-LICENSE.txt) (Copyright 2022 Narknon).
