# CrabInventorySync

> **Beta v0.0.1** — ground-up rebuild. Expect rough edges. Report issues on GitHub.

Real-time shared inventory mod for **Crab Champions** co-op. When any player in your session picks up a weapon, ability, melee, mod, perk, or relic — or earns crystals, takes damage, or unlocks a new slot — every other player's game updates to match within ~500 ms.

No host required. No room codes. Each client manages itself.

---

## How It Works

```
Game (UE4SS Lua)
    ↕  push.json / recv.json  (file IPC)
bridge.ps1  (PowerShell HTTP client)
    ↕  REST HTTP
server.js  (Node.js — crab.dudiebug.net)
```

1. The mod reads your inventory and writes `push.json` whenever something changes (or every ~3 s as a fallback).
2. The bridge detects the file change and POSTs it to the relay server.
3. The server groups players into sessions automatically using the player list visible in GameState — no manual room code needed.
4. The server merges all inventories in your session and returns the result.
5. The bridge writes the merged inventory to `recv.json`.
6. Every client reads `recv.json` and applies it to their own character.

The bridge launches automatically when you start the game. You don't need to run anything manually.

---

## What Gets Synced

| Category | Merge rule |
|----------|-----------|
| Weapon / Ability / Melee | Most recently updated player wins |
| Crystals | Summed across all players |
| Health | Summed across all players |
| Weapon Mods / Ability Mods / Melee Mods | Item counts summed per item name |
| Perks | Item counts summed per item name |
| Relics | Item counts summed per item name |
| Mod / Perk slot counts | Highest unlock count across players applied to all |

> **Slot limit:** Mod and perk slots are unlocked up to the highest count in your session using the game's own `ServerIncrementNumInventorySlots` RPC. You can't fill slots that don't exist yet — pick up at least one item of that type first to initialize the slot.

---

## Requirements

- **Crab Champions** (Steam)
- **Windows 10 or 11** — PowerShell is built-in, no extra install needed
- **Node.js** — only if you are self-hosting the server

---

## Installation

1. Download `CrabInventorySync-v0.0.1-beta.zip` from the [Releases](../../releases) page.
2. Extract the contents directly into your game's `Win64` folder:
   ```
   <SteamLibrary>\steamapps\common\Crab Champions\CrabChampions\Binaries\Win64\
   ```
3. Launch Crab Champions. UE4SS loads the mod automatically, and the bridge window opens alongside the game.
4. Join or host a multiplayer session. Session grouping is automatic.

> If you already have UE4SS installed, you can skip the DLL files and only extract the `Mods\CrabInventorySync\` folder and update `Mods\mods.txt`.

---

## Configuration

Edit `Mods\CrabInventorySync\Scripts\config.txt` inside the `Win64` folder:

| Key | Default | Description |
|-----|---------|-------------|
| `serverUrl` | `https://crab.dudiebug.net` | Relay server URL (only change if self-hosting) |
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
| `syncSlots` | `true` | Unlock mod/perk slots to match the highest count in the session |
| `crystalsProperty` | `Crystals` | Internal PlayerState property name for crystals — change if crystals always read as 0 |

---

## Keybinds

| Key | Action |
|-----|--------|
| **F9** | Force an immediate full re-sync |

---

## Troubleshooting

**Crystals always read as 0**
Change `crystalsProperty` in `config.txt`. Press F7 (with debug enabled) to scan for the correct property name.

**Bridge window doesn't open**
Launch `bridge.ps1` manually from `Mods\CrabInventorySync\` in a PowerShell window.

**Mod not loading**
Check that `CrabInventorySync : 1` is present in `Mods\mods.txt` and that `enabled.txt` exists in `Mods\CrabInventorySync\`.

**Items not syncing**
Press F9 to force a fresh sync. Check the bridge window for HTTP errors — the relay server may be down.

---

## Debug Tools

The mod ships with optional debug scripts. Uncomment the relevant line at the top of `main.lua` to enable:

```lua
-- require("debug_helpers")  -- F5/F6/F7/F8/F10 keybinds
-- require("debug_perks")    -- F6/F7 perk scanner
```

| Key | Action |
|-----|--------|
| F5 | Test `ServerIncrementNumInventorySlots` for all slot types |
| F6 | Dump all CrabPS properties to UE4SS.log |
| F7 | Scan for the correct crystals property name |
| F8 | Print a full inventory snapshot as the mod reads it |
| F10 | Scan CrabPS/CrabPC for item-management functions |

UE4SS log output is in the UE4SS GUI window or at `Win64\ue4ss\UE4SS.log`.

---

## Self-Hosting the Server

The public relay at `https://crab.dudiebug.net` is used by default. To run your own:

1. Install [Node.js](https://nodejs.org)
2. In the `server/` folder run:
   ```
   npm install
   node server.js [port]
   ```
3. Set `serverUrl` in `config.txt` to your server's address.

---

## License

This mod is released under the [MIT License](LICENSE).
UE4SS is bundled under its own [MIT License](UE4SS-LICENSE.txt).
