Here's a fresh README written entirely from the code:

---

# CrabInventorySync

A real-time co-op inventory sharing mod for **Crab Champions**. When any player picks up a weapon, ability, melee weapon, mod, perk, or relic — or earns crystals or takes damage — every other player's game updates to match within ~500ms. The inventory pool is fully shared.

No host designation required. Each client manages itself.

---

## How It Works

```
Game (UE4SS Lua mod)
    ↕  push.json / recv.json
bridge.ps1 (PowerShell HTTP client)
    ↕  REST HTTP
server.js (Node.js Express — crab.dudiebug.net)
```

Every 500ms, the mod reads your local inventory and writes `push.json` if anything changed. The bridge detects the file change and POSTs it to the server. The server merges all active players' inventories and returns the result. The bridge writes the merged result to `recv.json`. Every client reads `recv.json` and applies it to their own character.

The bridge is auto-launched by the mod on game start. You don't need to run anything manually.

---

## Requirements

- **Crab Champions** (Steam)
- **Windows 10 or 11** — PowerShell is built in, no extra install needed
- **Node.js** — only needed if you are self-hosting the server

---

## Installation

1. Extract the contents of `CrabInventorySyncClient.zip` into your game's `Win64` folder:
   ```
   <SteamLibrary>\steamapps\common\Crab Champions\Binaries\Win64\
   ```
2. Launch Crab Champions. The mod loads automatically via UE4SS, and the bridge window opens alongside the game.
3. Start a multiplayer session. The room is detected automatically from the session host's name — no manual room code setup needed.

> If UE4SS is already installed, make sure this release's version is compatible with your existing installation, or let this one overwrite it.

---

## Configuration

Edit `ue4ss\Mods\CrabInventorySync\Scripts\config.txt`:

| Key | Default | Description |
|-----|---------|-------------|
| `serverUrl` | `https://crab.dudiebug.net` | Relay server URL |
| `roomCode` | `default` | Fallback room code (only used if auto-detection fails, e.g. solo or main menu) |
| `syncWeapon` | `true` | Sync weapon slot |
| `syncAbility` | `true` | Sync ability slot |
| `syncMelee` | `true` | Sync melee slot |
| `syncCrystals` | `true` | Sync crystal pool |
| `syncHealth` | `true` | Sync health pool |
| `syncWeaponMods` | `true` | Sync weapon mods |
| `syncAbilityMods` | `true` | Sync ability mods |
| `syncMeleeMods` | `true` | Sync melee mods |
| `syncPerks` | `true` | Sync perks |
| `syncRelics` | `true` | Sync relics |
| `crystalsProperty` | `Crystals` | Internal PlayerState property name for crystals — change if crystals always read as 0 |

---

## Keybinds

| Key | Action |
|-----|--------|
| F9 | Force a full re-sync immediately |

---

## Self-Hosting the Server

The public relay at `https://crab.dudiebug.net` is used by default. To run your own:

1. Install [Node.js](https://nodejs.org)
2. In the `server/` folder:
   ```
   npm install
   node server.js
   ```
3. Set `serverUrl` in `config.txt` to your server address.

The server exposes a live dashboard at `http://localhost:3000/` showing all active rooms, per-player inventories, and the merged result, updating every 500ms.

---

## Debug Tools

The mod ships with optional debug scripts. To enable them, uncomment the relevant `require` line at the top of `main.lua`:

```lua
-- require("debug")        -- F6/F7/F8: property dumper, crystal scanner, inventory snapshot
-- require("debug_perks")  -- F6/F7: perk DA scanner, kill counter and health struct finder
```

| Key | Script | Action |
|-----|--------|--------|
| F6 | debug.lua | Dump all CrabPS property names and values to UE4SS.log |
| F7 | debug.lua | Scan for the correct crystals property name |
| F8 | debug.lua | Print a full snapshot of your current inventory as the mod reads it |
| F6 | debug_perks.lua | Scan all perk DataAssets for PerkType and BaseBuff |
| F7 | debug_perks.lua | Scan PlayerState and health component properties |

UE4SS log output is visible in the UE4SS GUI window or at `<GameRoot>\ue4ss\UE4SS.log`.

---

## License

This mod is released under the [MIT License](LICENSE).  
UE4SS is included under its own [MIT License](UE4SS-LICENSE.txt) (Copyright 2022 Narknon).
