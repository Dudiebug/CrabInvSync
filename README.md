# CrabInventorySync

Real-time shared inventory sync for **Crab Champions** co-op — a three-tier Lua / PowerShell / Node.js architecture.

> **Beta safety note:** Joined clients run read-only/no-apply by default behind a lifecycle gate. Host/solo testing remains the primary supported path while multiplayer contribution safety is still being built.

## How it works

1. All players install the `Mods/CrabInventorySync/` folder into their UE4SS `Mods/` directory and set the same `roomCode` in `Scripts/config.txt` (or let auto-detection handle it — the room is derived from the session host's player name automatically).
2. On mod load, `bridge.ps1` is auto-launched as a PowerShell window.
3. Every 500 ms the mod reads your inventory and writes `push_<instance>.json` if anything changed.
4. The bridge detects the file change and POSTs it to the relay server.
5. The server merges all players' inventories (sum of crystals, health, and slot contributions; merged mods, perks, and relics; newest changed weapon/ability/melee wins).
6. The bridge writes the merged result to `recv_<instance>.json`.
7. Every player reads `recv_<instance>.json` and applies it to their own character.

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
| `syncHealth` | `false` | Experimental health pool sync; keep disabled until readiness is verified in-game |
| `syncWeaponMods` | `true` | Sync weapon mods |
| `syncAbilityMods` | `true` | Sync ability mods |
| `syncMeleeMods` | `true` | Sync melee mods |
| `syncPerks` | `true` | Sync perk list |
| `syncRelics` | `true` | Sync relic list |
| `syncSlots` | `true` | Sync mod/perk slot counts (SetPropertyValue only — no UFunctions) |
| `allowScalarMetadataApply` | `false` | Safety gate for item `InventoryInfo` scalar writes; keep disabled |
| `allowJoinedClientApply` | `false` | Joined clients are read-only/no-apply by default |
| `allowMultiplayerApply` | `false` | Multiplayer live-state applies are disabled by default |
| `hostOnlyApply` | `true` | If multiplayer apply is enabled later, only host/solo roles may apply by default |
| `lifecycleStableTicksRequired` | `5` | Consecutive stable shallow lifecycle probes required before sync reads/pushes/applies |
| `crystalsProperty` | `Crystals` | Internal PlayerState property name for crystals |

Runtime IPC files are per game launch: `push_<instance>.json` and
`recv_<instance>.json`. Running `bridge.ps1` manually without an instance ID
still uses legacy `push.json` and `recv.json` paths for debugging.

There is no `healthProperty` config key. Current HP is read from
`CrabHC.HealthInfo.CurrentHealth`; max HP is read from
`CrabHC.HealthInfo.CurrentMaxHealth`. When `syncHealth=false`, the client does
not read, send, or apply health. Armor plates are currently local-only.

Keys are not synced. Item payloads preserve `InventoryInfo.Level`,
`InventoryInfo.AccumulatedBuff`, and `InventoryInfo.Enhancements` as `{n,l,a,e}`.
The client still reads, encodes, decodes, merges, and compares that metadata:
reorder-only changes are ignored while level, buff, and enhancement differences
are detected and logged. Scalar metadata apply is quarantined by default with
`allowScalarMetadataApply=false`, so the client does not write `Level`,
`AccumulatedBuff`, or nested `Enhancements` back into live item structs until
stable slot identity and duplicate-free pairing are proven.

The client has a global lifecycle safety gate. On startup, join, travel, and
manual reset it enters `suspended`, then `probing`, and only acts after several
consecutive stable shallow probes. While unstable it does not read full
inventory, push, apply recv, traverse item arrays deeply, or write equipment,
crystals, slots, health, or item metadata. Joined clients are read-only/no-apply
by default with `allowJoinedClientApply=false`; unknown roles are treated as
unsafe. The contribution ledger for safe multiplayer apply is still pending.

## Server dashboard

The relay server hosts a live dashboard at the root URL (e.g. `https://crab.dudiebug.net`). It shows:

- All active rooms and their session members (connected vs. expected)
- The merged inventory for each room
- Per-player inventory contributions with freshness indicators

## Server deploy

The production VPS currently runs a flat service layout:

- `WorkingDirectory=/opt/crab-sync`
- `ExecStart=/usr/bin/node server.js 3000`
- service name: `crab-sync`

The repo stores the Node app in `server/`, so `server/deploy-flat.sh` updates
`server/`, copies it into the flat service root, installs dependencies, checks
`server.js`, and restarts the service.

First install on the VPS:

```bash
cd /opt/crab-sync
git init
git remote add origin https://github.com/Dudiebug/CrabInvSync.git 2>/dev/null || true
git fetch origin master
git checkout -f origin/master -- server
cp -a server/. .
bash deploy-flat.sh
```

Future deploys:

```bash
cd /opt/crab-sync
bash deploy-flat.sh
```

## Keybinds

| Key | Action |
|-----|--------|
| F9  | Force full re-sync immediately |

## Known issues

### Joined-client apply is disabled by default

Joined clients are kept in read-only/no-apply safe mode by default. They may read
and push only after the lifecycle probe is stable, but they do not apply recv to
live game state unless `allowJoinedClientApply=true` is explicitly set for
testing.

This protects the known risky join/travel window where Unreal replication can
expose partially constructed or stale objects. The contribution ledger and
fully safe joined-client apply path are still pending.

**Workaround for live shared applies:** only use live-state applying sync in solo
or host-controlled test sessions for now.

### Other limitations

- Mod slot counts are increased via `SetPropertyValue` only — this is safe but may not persist across map transitions in all configurations.
- PowerShell 5+ is required (built into Windows 10/11).
- Room code auto-detection requires a live multiplayer session; solo play uses the fallback `roomCode` from config.

## Install helpers

For a stable test copy from this repo, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-client-to-game.ps1 "C:\Path\To\Crab Champions\Binaries\Win64"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-installed-client.ps1 "C:\Path\To\Crab Champions\Binaries\Win64"
```

The install helper accepts the game `Win64` folder, the UE4SS `Mods` folder, or
the final `Mods\CrabInventorySync` folder. It copies only the required
`CrabInventorySync` files and does not mirror or delete unrelated game files.

## License

This mod is released under the [MIT License](LICENSE).
UE4SS is included under its own [MIT License](UE4SS-LICENSE.txt) (Copyright 2022 Narknon).
