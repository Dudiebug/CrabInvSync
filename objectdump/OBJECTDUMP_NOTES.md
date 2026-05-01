# CrabChampions — UE4SS Object Dump Complete Reference
> Source: UE4SS_ObjectDump.txt (parts 01–53, 83,081 lines total)
> Session dump taken: 2026-03-25
> Cross-referenced with bridge/UE4SS logs from the "shuffle" incident.
> Scope: ALL CrabChampions-namespace classes, structs, enums, DAs, and properties.

---

## TABLE OF CONTENTS
1. [Statistics](#1-statistics)
2. [Core Player State — CrabPS](#2-core-player-state--crabps)
3. [Inventory Item Structs](#3-inventory-item-structs)
4. [CrabInventoryInfo — The Critical Sub-Struct](#4-crabinventoryinfo--the-critical-sub-struct)
5. [CrabHealthInfo](#5-crabHealthInfo)
6. [CrabAutoSave — Save Game Struct](#6-crabautoSave--save-game-struct)
7. [All Other Structs (35 total)](#7-all-other-structs)
8. [CrabPlayerC — Player Pawn](#8-crabplayerc--player-pawn)
9. [CrabPC — Player Controller](#9-crabpc--player-controller)
10. [CrabGM — Game Mode](#10-crabgm--game-mode)
11. [CrabGS — Game State](#11-crabgs--game-state)
12. [CrabHC — Health Component](#12-crabhc--health-component)
13. [CrabProjectile](#13-crabprojectile)
14. [CrabWeaponDA & Related DAs](#14-crabweaponda--related-das)
15. [All 56 Enums](#15-all-56-enums)
16. [All 125 Classes](#16-all-125-classes)
17. [Data Assets Found](#17-data-assets-found)
18. [Known Bugs & Root Causes](#18-known-bugs--root-causes)
19. [Fix Recommendations & Pseudocode](#19-fix-recommendations--pseudocode)
20. [Priority Fix Checklist](#20-priority-fix-checklist)

---

## 1. Statistics

| Category      | Count |
|---------------|-------|
| Enums         | 56    |
| Classes       | 125   |
| ScriptStructs | 35    |
| Dump parts    | 53    |
| Total lines   | 83,081 |

---

## 2. Core Player State — `CrabPS`

**Full path:** `/Script/CrabChampions.CrabPS`
**Class pointer:** `000001BA78A2A840`

This is the authoritative in-run player state. All inventory, stats, and progression
data for a live session lives here and is replicated from server to clients.

### 2.1 Complete Field Layout

| Offset  | UE4 Type        | Field Name                    | Notes |
|---------|-----------------|-------------------------------|-------|
| `0x328` | ArrayProperty   | `InventoryCooldowns`          | Per-slot pickup cooldown timers. Array of `CrabInventoryCooldown`. |
| `0x338` | EnumProperty    | `PlayerTintType`              | `ECrabTintType` — cosmetic tint color |
| `0x340` | ArrayProperty   | `PSPickups`                   | Active pickup actor references |
| `0x350` | IntProperty     | `ComboCounter`                | Integer combo tick counter |
| `0x354` | FloatProperty   | `Combo`                       | Combo multiplier value |
| `0x358` | IntProperty     | `Eliminations`                | Kill count this run |
| `0x368` | UInt32Property  | `DamageDealt`                 | Cumulative damage dealt |
| `0x36C` | UInt32Property  | `HighestDamageDealt`          | Single-hit damage record |
| `0x370` | IntProperty     | `DamageTaken`                 | Cumulative damage taken |
| `0x374` | IntProperty     | `DamageTakenOnThisIsland`     | Resets each island |
| `0x378` | IntProperty     | `NumFlawlessIslands`          | Islands completed without taking damage |
| `0x37C` | StructProperty  | `HealthInfo`                  | → `CrabHealthInfo` (armor plates, current HP, max HP) |
| `0x398` | FloatProperty   | `BaseMaxHealth`               | Base HP pool before multipliers |
| `0x39C` | FloatProperty   | `MaxHealthMultiplier`         | HP scaling multiplier from perks |
| `0x3A0` | FloatProperty   | `DamageMultiplier`            | Outgoing damage scaling |
| `0x3A4` | FloatProperty   | `ScaleMultiplier`             | Player size scaling |
| `0x3A8` | EnumProperty    | `AccountRank`                 | `ECrabAccountRank` |
| `0x3AC` | IntProperty     | `AccountLevel`                | Account progression level |
| `0x3B0` | IntProperty     | `Keys`                        | Key currency (chest unlocks) |
| `0x3B8` | ObjectProperty  | `CrabSkin`                    | → `CrabCosmeticsDA` (current skin) |
| `0x3C0` | ObjectProperty  | `WeaponDA`                    | → `CrabWeaponDA` (current weapon) |
| `0x3C8` | ObjectProperty  | `AbilityDA`                   | → `CrabAbilityDA` (current ability) |
| `0x3D0` | ObjectProperty  | `MeleeDA`                     | → `CrabMeleeDA` (current melee) |
| `0x3D8` | ByteProperty    | `NumWeaponModSlots`           | Max weapon mod slots (caps `WeaponMods` length) |
| `0x3E0` | ArrayProperty   | `WeaponMods`                  | → `[]CrabWeaponMod` |
| `0x3F0` | ByteProperty    | `NumAbilityModSlots`          | Max ability mod slots |
| `0x3F8` | ArrayProperty   | `AbilityMods`                 | → `[]CrabAbilityMod` |
| `0x408` | ByteProperty    | `NumMeleeModSlots`            | Max melee mod slots |
| `0x410` | ArrayProperty   | `MeleeMods`                   | → `[]CrabMeleeMod` |
| `0x420` | ByteProperty    | `NumPerkSlots`                | Max perk slots |
| `0x428` | ArrayProperty   | `Perks`                       | → `[]CrabPerk` |
| `0x438` | ArrayProperty   | `Relics`                      | → `[]CrabRelic` |
| `0x460` | IntProperty     | `NumTimesSalvaged`            | Times player salvaged an item |
| `0x464` | IntProperty     | `NumShopPurchases`            | Shop purchases this run |
| `0x468` | IntProperty     | `NumShopRerolls`              | Shop reroll count |
| `0x46C` | IntProperty     | `NumTotemsDestroyed`          | Totem destruction count |
| `0x470` | **UInt32Property** | **`Crystals`**             | ⚠️ **UNSIGNED 32-bit.** Range 0–4,294,967,295. Do NOT write negative values — they wrap. |
| `0x478` | EnumProperty    | `IslandRewardRarity`          | `ECrabRarityType` — rarity of current island reward |
| `0x480` | ObjectProperty  | `ParkourCheckpoint`           | Last activated parkour checkpoint |
| `0x488` | ArrayProperty   | `ChosenAnvils`                | Anvil upgrades applied this run |
| `0x498` | ObjectProperty  | `ChosenPortal`                | Selected portal DA for next island |
| `0x4A0` | IntProperty     | `TotalTimeTaken`              | Run duration in seconds |

### 2.2 Server RPC Functions

These are server-authoritative RPCs. They are the official game API for inventory changes.
The sync mod currently bypasses them (writing directly to the TArray), which is why
Level and Enhancement data is lost.

```
ServerSetWeaponDA(NewWeaponDA: UObject)
ServerSetMeleeDA(NewMeleeDA: UObject)
ServerSetAbilityDA(NewAbilityDA: UObject)
ServerRemoveWeaponMod(WeaponModType: ECrabWeaponModType)
ServerRemoveAbilityMod(AbilityModType: ECrabAbilityModType)
ServerRemoveMeleeMod(MeleeModType: ECrabMeleeModType)
ServerRemovePerk(PerkType: ECrabPerkType)
ServerRemoveRelic(RelicType: ECrabRelicType)
ServerEquipInventory(NewWeaponDA, NewAbilityDA, NewMeleeDA)
ServerEquipCosmetics(NewCrabSkin)
ServerRefreshAccount(NewAccountLevel: int, NewKeys: int, NewAccountRank: ECrabAccountRank)
ServerIncrementNumInventorySlots(PickupType: ECrabPickupType, Cost: int)
```

### 2.3 Replication Callbacks (OnRep)

These fire automatically when the server replicates the corresponding field to a client.
Useful for hooking into state changes without polling.

```
OnRep_Inventory          — fires when any mod/perk/relic array changes
OnRep_Crystals           — fires on crystal count change
OnRep_Combo              — fires on combo change
OnRep_Eliminations       — fires on kill count change
OnRep_DamageTakenOnThisIsland
OnRep_AccountLevel
OnRep_AccountRank
OnRep_WeaponDA           — fires when weapon changes
OnRep_AbilityDA          — fires when ability changes
OnRep_MeleeDA            — fires when melee changes
OnRep_ScaleMultiplier
OnRep_IslandRewardRarity
```

---

## 3. Inventory Item Structs

All five item types follow an identical two-field pattern:
1. A **DA (Data Asset) ObjectProperty** at offset `0x0` — the item's type identity
2. An **`InventoryInfo` StructProperty** at offset `0x8` — per-instance metadata (Level, Enhancements, AccumulatedBuff)

### 3.1 `CrabWeaponMod`
**Path:** `/Script/CrabChampions.CrabWeaponMod`
**Struct pointer:** `000001BA26728BC0`
**Also used on:** `CrabProjectile`, `CrabWeaponDA.StartingWeaponMod`, `CrabAutoSave`

| Offset | Type            | Field          | Notes |
|--------|-----------------|----------------|-------|
| `0x0`  | ObjectProperty  | `WeaponModDA`  | → `CrabWeaponModDA`. This is the mod identity used for DA lookup by name. |
| `0x8`  | StructProperty  | `InventoryInfo`| → `CrabInventoryInfo` (Level, Enhancements, AccumulatedBuff) |

### 3.2 `CrabAbilityMod`
**Path:** `/Script/CrabChampions.CrabAbilityMod`
**Struct pointer:** `000001BA26728C80`
**Also used on:** `CrabProjectile`, `CrabAutoSave`

| Offset | Type            | Field           |
|--------|-----------------|-----------------|
| `0x0`  | ObjectProperty  | `AbilityModDA`  |
| `0x8`  | StructProperty  | `InventoryInfo` |

### 3.3 `CrabMeleeMod`
**Path:** `/Script/CrabChampions.CrabMeleeMod`
**Struct pointer:** `000001BA26728D40`
**Also used on:** `CrabAutoSave`

| Offset | Type            | Field           |
|--------|-----------------|-----------------|
| `0x0`  | ObjectProperty  | `MeleeModDA`    |
| `0x8`  | StructProperty  | `InventoryInfo` |

### 3.4 `CrabPerk`
**Path:** `/Script/CrabChampions.CrabPerk`
**Struct pointer:** `000001BA26728E00`
**Also used on:** `CrabProjectile`, `CrabAutoSave`

| Offset | Type            | Field           |
|--------|-----------------|-----------------|
| `0x0`  | ObjectProperty  | `PerkDA`        |
| `0x8`  | StructProperty  | `InventoryInfo` |

### 3.5 `CrabRelic`
**Path:** `/Script/CrabChampions.CrabRelic`
**Struct pointer:** `000001BA26728F80`
**Also used on:** `CrabAutoSave`

| Offset | Type            | Field           |
|--------|-----------------|-----------------|
| `0x0`  | ObjectProperty  | `RelicDA`       |
| `0x8`  | StructProperty  | `InventoryInfo` |

---

## 4. `CrabInventoryInfo` — The Critical Sub-Struct

**Path:** `/Script/CrabChampions.CrabInventoryInfo`
**Struct pointer:** `000001BA26728EC0`
**Embedded at offset `0x8`** inside every `CrabWeaponMod`, `CrabAbilityMod`,
`CrabMeleeMod`, `CrabPerk`, and `CrabRelic` entry.

| Offset | Type           | Field             | Notes |
|--------|----------------|-------------------|-------|
| `0x0`  | **ByteProperty** | **`Level`**     | ⚠️ **THE LEVEL FIELD.** `1` = base item. `2+` = one or more duplicates picked up and stacked. This is what shows as the star/level indicator in the UI. |
| `0x8`  | ArrayProperty  | `Enhancements`    | `[]ECrabEnhancementType` — all Anvil upgrades applied to this specific item instance. |
| `0x18` | FloatProperty  | `AccumulatedBuff` | Running accumulated buff value. Used by relics and other items with ongoing effects. |

### Why This Struct Destroys Levels When APPLY Runs

The current APPLY logic adds mods back to the TArray by DA reference only — it calls
something equivalent to `add(DA_WeaponMod_EscalatingShot)`. The game constructs a new
`CrabWeaponMod` entry with `InventoryInfo` at its default value: **`Level = 1`,
`Enhancements = []`, `AccumulatedBuff = 0.0`**. Any earned levels or Anvil upgrades on
that mod are permanently lost for that APPLY cycle.

Since the shuffle bug causes APPLY to fire every 1–2 seconds, this means every leveled
or Anvil-upgraded mod is continuously being reset. The user then experiences:
- Mods visually appear at Level 1 even though they were higher
- Anvil upgrades disappear from the UI
- The game's `CrabAutoSave` may persist the reset Level=1 on save, making the loss permanent

### `CrabInventoryInfo` is also used on:
- `CrabPickupInfo.InventoryInfo` — pedestal/chest pickup context
- `CrabPlayerC:ServerDropPickup:InventoryInfo` — the info passed when dropping an item
- `CrabInventorySlotUI.InventoryInfo` — what the UI slot widget reads to display Level/Enhancements

---

## 5. `CrabHealthInfo`

**Path:** `/Script/CrabChampions.CrabHealthInfo`
**Struct pointer:** `000001BA26728B00`
**Embedded in:**
- `CrabPS.HealthInfo` at offset `0x37C`
- `CrabHC.HealthInfo` at offset `0xFC`
- `CrabAutoSave.HealthInfo` at offset `0x88`

| Offset | Type          | Field                      | Notes |
|--------|---------------|----------------------------|-------|
| `0x0`  | IntProperty   | `CurrentArmorPlates`       | Number of active armor plate charges |
| `0x4`  | FloatProperty | `CurrentArmorPlateHealth`  | HP of the currently active armor plate |
| `0x8`  | FloatProperty | `PreviousArmorPlateHealth` | Previous armor plate HP (for delta/animation) |
| `0xC`  | FloatProperty | `CurrentHealth`            | ⚠️ **The real current HP value** |
| `0x10` | FloatProperty | `CurrentMaxHealth`         | Effective max HP = `BaseMaxHealth * MaxHealthMultiplier` |
| `0x14` | FloatProperty | `PreviousHealth`           | Previous HP tick (for delta calculation) |
| `0x18` | FloatProperty | `PreviousMaxHealth`        | Previous max HP tick |

### Notes for Sync Mod

The mod currently syncs a single `health` float against `CrabPS.BaseMaxHealth` or
a similar field. The actual authoritative HP is `HealthInfo.CurrentHealth`. The true
max HP is `HealthInfo.CurrentMaxHealth`, which is the product of `BaseMaxHealth *
MaxHealthMultiplier` and is NOT the same as `BaseMaxHealth` alone.

Armor plates are a completely separate HP layer on top. If a player has armor plates
active, syncing only `CurrentHealth` will visually show wrong HP and may break armor
plate mechanics.

---

## 6. `CrabAutoSave` — Save Game Struct

**Path:** `/Script/CrabChampions.CrabAutoSave`
**Struct pointer:** `000001BA267291C0`

This is the save game struct. It **mirrors CrabPS exactly** for persistence across runs.
Critically, it uses the **same** `CrabWeaponMod`, `CrabPerk`, etc. structs — meaning
`InventoryInfo.Level` and `InventoryInfo.Enhancements` ARE written to disk. If the sync
mod writes Level=1 into CrabPS and the game auto-saves, the Level=1 is now permanent.

| Offset  | Type           | Field                      | Notes |
|---------|----------------|----------------------------|-------|
| `0x4`   | EnumProperty   | `Difficulty`               | Run difficulty setting |
| `0x8`   | IntProperty    | `CountdownDifficultyModifier` | |
| `0x18`  | IntProperty    | `CountdownDifficultyModifier` | (second reference) |
| `0x20`  | StructProperty | `NextIslandInfo`           | → `CrabNextIslandInfo` |
| `0x88`  | StructProperty | `HealthInfo`               | → `CrabHealthInfo` |
| `0xC0`  | ObjectProperty | `AbilityDA`                | Saved current ability |
| `0xC8`  | ObjectProperty | `MeleeDA`                  | Saved current melee |
| `0xD0`  | ByteProperty   | `NumWeaponModSlots`        | Saved slot count |
| `0xD8`  | ArrayProperty  | `WeaponMods`               | → `[]CrabWeaponMod` **with Level and Enhancements** |
| `0xE8`  | ByteProperty   | `NumAbilityModSlots`       | |
| `0xF0`  | ArrayProperty  | `AbilityMods`              | → `[]CrabAbilityMod` |
| `0x100` | ByteProperty   | `NumMeleeModSlots`         | |
| `0x108` | ArrayProperty  | `MeleeMods`                | → `[]CrabMeleeMod` |
| `0x118` | ByteProperty   | `NumPerkSlots`             | |
| `0x120` | ArrayProperty  | `Perks`                    | → `[]CrabPerk` |
| `0x130` | ArrayProperty  | `Relics`                   | → `[]CrabRelic` |
| `0x140` | IntProperty    | `NumTimesSalvaged`         | |
| `0x144` | IntProperty    | `NumShopPurchases`         | |
| `0x148` | IntProperty    | `NumShopRerolls`           | |
| `0x14C` | IntProperty    | `NumTotemsDestroyed`       | |
| `0x150` | UInt32Property | `Crystals`                 | ⚠️ Unsigned — same as CrabPS |
| `0x154` | IntProperty    | `TotalTimeTaken`           | Run duration |
| `0x158` | ArrayProperty  | `CompletedChallenges`      | → `[]CrabChallenge` |
| `0x8`   | EnumProperty   | `DifficultyModifiers` (inner) | `[]ECrabDifficultyModifier` |

---

## 7. All Other Structs

### `CrabWeaponInfo`
**Path:** `/Script/CrabChampions.CrabWeaponInfo`
**Pointer:** `000001BA26727C00`
Weapon runtime state (e.g. current ammo, fire mode state). Fields not fully resolved.

### `CrabInventoryCooldown`
**Path:** `/Script/CrabChampions.CrabInventoryCooldown`
**Pointer:** `000001BA26728440`
Per-slot cooldown tracking. Used in `CrabPS.InventoryCooldowns`.

### `CrabDamageInfo`
**Path:** `/Script/CrabChampions.CrabDamageInfo`
**Pointer:** `000001BA26727FC0`
Damage event payload. Contains hit type, area type, debuff data, etc.

### `CrabDebuff`
**Path:** `/Script/CrabChampions.CrabDebuff`
**Pointer:** `000001BA26727F00`
A single debuff instance. Type + value + duration.

### `CrabDebuffState`
**Path:** `/Script/CrabChampions.CrabDebuffState`
**Pointer:** `000001BA26728080`
Active debuff state on an actor (accumulated debuffs).

### `CrabProjectileInfo`
**Path:** `/Script/CrabChampions.CrabProjectileInfo`
**Pointer:** `000001BA26728200`
Metadata for a fired projectile (speed, size, bounce count, etc.).

### `CrabProjectileModInfo`
**Path:** `/Script/CrabChampions.CrabProjectileModInfo`
**Pointer:** `000001BA26729400`
Per-projectile mod application tracking.

### `CrabStrikeInfo`
**Path:** `/Script/CrabChampions.CrabStrikeInfo`
**Pointer:** `000001BA26729340`
Melee strike data.

### `CrabPickupInfo`
**Path:** `/Script/CrabChampions.CrabPickupInfo`
**Pointer:** `000001BA267282C0`
Pickup actor metadata. Contains `InventoryInfo` at offset `0x8`, same as inventory items.

| Offset | Type            | Field           |
|--------|-----------------|-----------------|
| `0x0`  | (type ref)      | Pickup type     |
| `0x8`  | StructProperty  | `InventoryInfo` | → `CrabInventoryInfo` |

### `CrabPedestalInfo`
**Path:** `/Script/CrabChampions.CrabPedestalInfo`
**Pointer:** `000001BA26728380`
Shop/chest pedestal item display state.

### `CrabPortalInfo`
**Path:** `/Script/CrabChampions.CrabPortalInfo`
**Pointer:** `000001BA26728740`
Portal destination and rarity data.

### `CrabIsland`
**Path:** `/Script/CrabChampions.CrabIsland`
**Pointer:** `000001BA267285C0`
Island instance state.

### `CrabNextIslandInfo`
**Path:** `/Script/CrabChampions.CrabNextIslandInfo`
**Pointer:** `000001BA26728A40`
Next island selection (biome, type, rarity).

### `CrabChallenge`
**Path:** `/Script/CrabChampions.CrabChallenge`
**Pointer:** `000001BA26729100`
Challenge completion record.

### `CrabContract`
**Path:** `/Script/CrabChampions.CrabContract`
**Pointer:** `000001BA26728680`
Contract state.

### `CrabGauntletInfo`
**Path:** `/Script/CrabChampions.CrabGauntletInfo`
**Pointer:** `000001BA26728800`
Gauntlet run metadata.

### `CrabRankedWeapon`
**Path:** `/Script/CrabChampions.CrabRankedWeapon`
**Pointer:** `000001BA26728500`
Ranked mode weapon selection.

### `CrabEnemySpawnSettings`
**Path:** `/Script/CrabChampions.CrabEnemySpawnSettings`
**Pointer:** `000001BA26726400`

### `CrabEnemyStats`
**Path:** `/Script/CrabChampions.CrabEnemyStats`
**Pointer:** `000001BA26728980`

### `CrabAISettings`
**Path:** `/Script/CrabChampions.CrabAISettings`
**Pointer:** `000001BA267288C0`

### `CrabLightingPreset`
**Path:** `/Script/CrabChampions.CrabLightingPreset`
**Pointer:** `000001BA26726340`

### `CrabExplosionFX`
**Path:** `/Script/CrabChampions.CrabExplosionFX`
**Pointer:** `000001BA26727E40`

### `CrabVideoSettings`
**Path:** `/Script/CrabChampions.CrabVideoSettings`
**Pointer:** `000001BA26727D80`

### `CrabKeyBind`
**Path:** `/Script/CrabChampions.CrabKeyBind`
**Pointer:** `000001BA26727CC0`

### `CrabCosmetic`
**Path:** `/Script/CrabChampions.CrabCosmetic`
**Pointer:** `000001BA26729040`

### `CrabLobbyStats`
**Path:** `/Script/CrabChampions.CrabLobbyStats`
**Pointer:** `000001BA26729280`

### `CrabAutoSave`
(Documented in §6)

### `ClientAuthoritativeMoveData`
**Path:** `/Script/CrabChampions.ClientAuthoritativeMoveData`
**Pointer:** `000001BA26726580`
Client-side movement replication payload.

---

## 8. `CrabPlayerC` — Player Pawn

**Path:** `/Script/CrabChampions.CrabPlayerC`
**Class pointer:** `000001BA78A2BEC0`
**Default object:** `000001BA242AB380`

The player character pawn. Holds runtime references and contains the server RPCs for
player actions.

### Key Properties

| Offset  | Type          | Field                   | Notes |
|---------|---------------|-------------------------|-------|
| `0x7F0` | ArrayProperty | `PendingDamageInfoArray`| Queued damage events |
| `0x810` | FloatProperty | `PendingHealthToHeal`   | Queued heal amount |
| `0x820` | ArrayProperty | `NearbyActors`          | Nearby actor references |
| `0x848` | ClassProperty | `PlayerNameUIToSpawn`   | UI class for name display |
| `0x850` | ClassProperty | `PingUIToSpawn`         | UI class for ping display |
| `0xA98` | ArrayProperty | `ChestsToAutoLoot`      | Auto-loot chest queue |

### Server RPC Functions

```
ServerInteract()
ServerFlip(FlipDir: EFlipDir)
ServerDropPickup(InventoryInfo: CrabInventoryInfo)
ServerDealFallDamage()
ServerDealDamage(DamageInfoArray: []CrabDamageInfo)
ServerDash(DashDir: EFlipDir)
ServerAutoLoot()
MulticastFlip(FlipDir: EFlipDir)
MulticastDash(DashDir: EFlipDir)
```

### Components

```
CharacterMesh0     — SkeletalMeshComponent
CharMoveComp       — CrabCMC (movement)
HC                 — CrabHC (health component)
CameraSpringArm    — SpringArmComponent
```

---

## 9. `CrabPC` — Player Controller

**Path:** `/Script/CrabChampions.CrabPC`
Handles input and client-side control logic. Not heavily documented in the dump.

---

## 10. `CrabGM` — Game Mode

**Path:** `/Script/CrabChampions.CrabGM`
**Class pointer:** `000001BA78A27240`

### Key Properties

| Offset  | Type          | Field                    |
|---------|---------------|--------------------------|
| `0x2D8` | ArrayProperty | `DebugChallengeModifiers`|

---

## 11. `CrabGS` — Game State

**Path:** `/Script/CrabChampions.CrabGS`
**Class pointer:** `000001BA78A26B80`

### Key Properties

| Offset  | Type          | Field                     | Notes |
|---------|---------------|---------------------------|-------|
| `0x2A8` | ArrayProperty | `DifficultyModifiers`     | `[]ECrabDifficultyModifier` |
| `0x2B8` | IntProperty   | `CountdownDifficultyModifier` | |
| `0x2E8` | IntProperty   | `XLLevel`                 | Extra-large difficulty level |
| `0x2F0` | ArrayProperty | `ChallengeModifiers`      | Active challenge modifiers |

Also has: `PlayerStateUIToSpawn` (ClassProperty → `CrabPlayerStateUI`),
`PlayerStateUIVerticalBox` (ObjectProperty → `UVerticalBox`).

---

## 12. `CrabHC` — Health Component

**Path:** `/Script/CrabChampions.CrabHC`
**Class pointer:** `000001BA78A264C0`
**Default object component on:** `CrabPlayerC` (as `HC` component)

| Offset  | Type           | Field                      | Notes |
|---------|----------------|----------------------------|-------|
| `0xC0`  | FloatProperty  | `BaseMaxHealth`            | Base HP pool |
| `0xD4`  | FloatProperty  | `HealthRegenerationAmount` | HP regen per tick |
| `0xFC`  | StructProperty | `HealthInfo`               | → `CrabHealthInfo` (authoritative HP) |

---

## 13. `CrabProjectile`

**Path:** `/Script/CrabChampions.CrabProjectile`
**Class pointer:** `000001BA78A2B140`

Projectiles carry their own **snapshot** of the player's mods at fire time. This means
mods continue to apply mid-flight even if CrabPS is being rewritten by the sync mod.

### Inventory Snapshot Fields

| Offset  | Type          | Field          | Notes |
|---------|---------------|----------------|-------|
| `0x2B8` | ArrayProperty | `WeaponMods`   | → `[]CrabWeaponMod` (snapshot at fire) |
| `0x2C8` | ArrayProperty | `AbilityMods`  | → `[]CrabAbilityMod` |
| `0x2D8` | ArrayProperty | `Perks`        | → `[]CrabPerk` |
| —       | ArrayProperty | `Enhancements` | → `[]ECrabEnhancementType` |

---

## 14. `CrabWeaponDA` & Related DAs

**Path:** `/Script/CrabChampions.CrabWeaponDA`
**Class pointer:** `000001BA78A33C40`

| Offset  | Type           | Field                | Notes |
|---------|----------------|----------------------|-------|
| `0xC8`  | StructProperty | `StartingWeaponMod`  | → `CrabWeaponMod` — the default mod baked into each weapon. Do NOT double-add when applying. |

### `CrabWeaponModDA`
**Path:** `/Script/CrabChampions.CrabWeaponModDA`
**Class pointer:** `000001BA78A33A00`
Referenced by `CrabWeaponMod.WeaponModDA`. One DA instance per mod type.

### `CrabInventoryDA`
**Path:** `/Script/CrabChampions.CrabInventoryDA`

| Offset  | Type        | Field              | Notes |
|---------|-------------|--------------------|-------|
| `0xB8`  | StrProperty | `LevelDescription` | Tooltip text that changes per Level value. Confirms Level is a meaningful game mechanic, not cosmetic. |

### `CrabAbilityDA`
**Path:** `/Script/CrabChampions.CrabAbilityDA`
**Class pointer:** `000001BA78A1A600`

### `CrabMeleeDA`
**Path:** `/Script/CrabChampions.CrabMeleeDA`
**Class pointer:** `000001BA78A2D9C0`

| Offset  | Type          | Field                    |
|---------|---------------|--------------------------|
| `0xC0`  | FloatProperty | `MeleeModDebuffMultiplier` |

### `CrabPerkDA`
**Class pointer:** `000001BA78A2C7C0`

### `CrabRelicDA`
**Class pointer:** `000001BA78A29F40`

### `CrabAnvil`
**Path:** `/Script/CrabChampions.CrabAnvil`

| Offset  | Type         | Field            | Notes |
|---------|--------------|------------------|-------|
| `0x2A0` | EnumProperty | `EnhancementType`| `ECrabEnhancementType` — the type of upgrade this anvil provides |

---

## 15. All 56 Enums

### Inventory & Item Type Enums
| Enum | Pointer | Used By |
|------|---------|---------|
| `ECrabWeaponModType` | `000001BA24C452C0` | `ServerRemoveWeaponMod`, DA lookup |
| `ECrabAbilityModType` | `000001BA24C45380` | `ServerRemoveAbilityMod` |
| `ECrabMeleeModType` | `000001BA24C45440` | `ServerRemoveMeleeMod` |
| `ECrabPerkType` | `000001BA24C453E0` | `ServerRemovePerk` |
| `ECrabRelicType` | `000001BA24C454A0` | `ServerRemoveRelic` |
| `ECrabEnhancementType` | `000001BA24C451A0` | `CrabInventoryInfo.Enhancements`, `CrabAnvil.EnhancementType` |
| `ECrabEnhanceableType` | — | Items that can receive enhancements |
| `ECrabPickupType` | `000001BA24C45020` | `ServerIncrementNumInventorySlots` |
| `ECrabPickupTag` | — | Tag classification for pickups |

### Game State & Progression Enums
| Enum | Notes |
|------|-------|
| `ECrabMatchState` | Lobby, InGame, GameOver, etc. |
| `ECrabIslandType` | Combat, Parkour, Shop, Boss, etc. |
| `ECrabBiome` | Island biome/environment |
| `ECrabBlessing` | Blessing modifiers |
| `ECrabChallengeModifier` | Active challenge types |
| `ECrabDifficultyModifier` | `000001BA24C455C0` — Difficulty modifier types |
| `ECrabRank` / `ECrabAccountRank` | `000001BA24C45620` |
| `ECrabRarityType` / `ECrabRarity` | `000001BA24C45080` — Common/Rare/Epic/Legendary |
| `ECrabLootPool` | Which loot pool to pull from |

### Damage & Combat Enums
| Enum | Notes |
|------|-------|
| `ECrabDamageType` | Physical, Fire, Ice, etc. |
| `ECrabDamageHitType` | Direct, Splash, DoT, etc. |
| `ECrabDamageTagType` | Metadata tags on damage events |
| `ECrabDamageAreaType` | Sphere, Cone, Line, etc. |
| `ECrabDebuffType` | Fire, Ice, Poison, Lightning, etc. |
| `ECrabHitmarkerType` | UI hitmarker variants |
| `ECrabCrosshairType` | Crosshair display variants |
| `ECrabFireMode` | `000001BA78A288C0` context — Auto, Semi, Burst |
| `ECrabTriggerChanceType` | Chance trigger categories |

### Ability & Action Enums
| Enum | Notes |
|------|-------|
| `ECrabAbilitySpawnType` | How ability projectiles are spawned |
| `ECrabProjectileState` | Active, Homing, Detonating, etc. |
| `ECrabLesserProjectileType` | Sub-projectile variant |
| `ECrabShotSpawnType` | Shot pattern type |
| `ECrabShotDirType` | Shot direction type |
| `ECrabInputDir` | Player input direction encoding |

### Enemy & AI Enums
| Enum | Notes |
|------|-------|
| `ECrabEnemyCategory` | Basic, Elite, Boss, etc. |
| `ECrabEnemyMovementType` | Ground, Flying, Stationary |
| `ECrabEnemyBuff` | Active buffs on enemies |
| `ECrabTurretType` | Turret variant |
| `ECrabFormationType` | Enemy formation patterns |
| `ECrabTargetType` | Target priority types |

### World & Environment Enums
| Enum | Notes |
|------|-------|
| `ECrabBossPhase` | Boss fight phase |
| `ECrabHarvestAreaType` | Resource area type |
| `ECrabEQCType` | Environment Query Context type |
| `ECrabSpawnPointType` | Enemy spawn point variant |
| `ECrabOutOfBoundsState` | Out-of-bounds penalty states |
| `ECrabBlockingHitState` | Collision hit states |
| `EFlipDir` | `000001BA72381540` — Direction enum for flip/dash |

### Misc & UI Enums
| Enum | Notes |
|------|-------|
| `ECrabCrystalDropType` | Crystal drop pattern |
| `ECrabConfirmationPromptType` | Dialog prompt variants |
| `ECrabConsumableType` | Consumable item types |
| `ECrabContractType` | Contract variants |
| `ECrabGauntletType` | Gauntlet mode types |
| `ECrabGauntletReward` | Gauntlet reward types |
| `ECrabTotemType` | Totem variant |
| `ECrabCosmeticType` | Cosmetic category |
| `ECrabTintType` | `000001BA24C44AE0` — Player tint variants |
| `ECrabMiscPickupType` | Misc pickup categories |
| `ECrabCurrencyType` | Crystal, Key, etc. |

---

## 16. All 125 Classes

### Core Game Framework
```
CrabC                   — Base character class
CrabPC                  — Player controller
CrabPS                  — Player state (inventory authority)
CrabGM                  — Game mode
CrabGS                  — Game state
CrabGI                  — Game instance
CrabLM                  — Level manager
CrabSG                  — Save game
CrabSettingsSG          — Settings save game
CrabRandomizer          — RNG system
CrabStatics             — Static utility functions
```

### Player Character
```
CrabPlayerC             — Player pawn
CrabPlayerAnimInstance  — Player animation blueprint
CrabPlayerNameUI        — Player name widget
CrabPlayerStateUI       — Player state HUD widget
CrabCMC                 — Crab character movement component
CrabHC                  — Crab health component
CrabSpectatorC          — Spectator pawn
CrabTargetDummyC        — Practice dummy
CrabCosmeticC           — Cosmetic attachment actor
```

### Combat & Projectiles
```
CrabProjectile          — Base projectile (carries mod snapshot at fire time)
CrabWeapon              — Weapon actor
CrabBeam                — Beam-type projectile
CrabStrike              — Melee/strike actor
CrabDamageArea          — AOE damage zone actor
```

### Enemy
```
CrabEnemyC              — Base enemy character
CrabEnemyAIC            — Enemy AI controller
CrabEnemyAnimInstance   — Enemy animation blueprint
CrabEnemyEQC            — Enemy environment query context
CrabBossC               — Boss character
CrabTurret              — Stationary turret enemy
```

### Item Data Assets (DA classes)
```
CrabPickupDA            — Base pickup DA
CrabInventoryDA         — Base inventory item DA (has LevelDescription)
CrabWeaponDA            — Weapon DA (has StartingWeaponMod)
CrabAbilityDA           — Ability DA
CrabMeleeDA             — Melee DA
CrabWeaponModDA         — Weapon mod DA
CrabAbilityModDA        — Ability mod DA
CrabMeleeModDA          — Melee mod DA
CrabPerkDA              — Perk DA
CrabRelicDA             — Relic DA
CrabConsumableDA        — Consumable DA
CrabCosmeticsDA         — Cosmetic skin DA
CrabBiomeDA             — Biome DA
CrabSpawnablesDA        — Enemy spawn pool DA
```

### Action DAs (weapon fire behavior)
```
CrabActionDA            — Base action DA
CrabFireWeaponActionDA  — Fire weapon action
CrabProjectileActionDA  — Spawn projectile action
CrabSpawnActionDA       — Spawn actor action
CrabLaunchActionDA      — Launch physics action
CrabRamActionDA         — Ram/charge action
CrabProximityExplodeActionDA — Proximity explosion action
CrabAOEActionDA         — AOE action
CrabStrikeActionDA      — Melee strike action
CrabAOEDA               — AOE zone DA
```

### World Actors & Interactables
```
CrabInteractable        — Base interactable
CrabInteractUI          — Interact prompt widget
CrabChest               — Chest actor
CrabShopPedestal        — Shop item pedestal
CrabShopPedestalUI      — Shop pedestal UI
CrabStatsPedestal       — Stats display pedestal
CrabStatsUI             — Stats UI widget
CrabPortal              — Portal actor
CrabPortalInteractUI    — Portal interaction UI
CrabGauntlet            — Gauntlet actor
CrabGauntletInteractUI  — Gauntlet UI
CrabTotem               — Totem actor
CrabAnvil               — Anvil upgrade actor
CrabHarvestArea         — Resource/crystal harvest zone
CrabCheckpoint          — Run checkpoint
CrabLaunchPad           — Launch pad actor
CrabBounds              — Level boundary actor
CrabCrown               — Crown pickup actor
CrabPhysicsActor        — Physics prop
CrabDestructible        — Destructible environment object
```

### Pickup Actors
```
CrabOverlapPickup       — Walk-over pickup
CrabInteractPickup      — Press-to-pickup actor
CrabHealthPickup        — HP orb
CrabCrystalPickup       — Crystal orb
CrabBananaPickup        — Banana consumable pickup
```

### UI — Gameplay HUD
```
CrabUI                  — Base widget
CrabGameplayUI          — Main in-game HUD
CrabGameStateUI         — Game state overlay
CrabInventoryUI         — Inventory screen
CrabInventorySlotUI     — Individual inventory slot (reads InventoryInfo for Level display)
CrabInventoryEventUI    — Inventory change notification
CrabEnhancementUI       — Anvil enhancement display
CrabCosmeticSlotUI      — Cosmetic slot widget
CrabHealthBarUI         — HP bar
CrabArrowSelectionUI    — Arrow/selection UI
CrabCrosshairUI         — Crosshair widget
CrabDamageTextUI        — Floating damage numbers
CrabPingUI              — Ping display
CrabChatEntryRowUI      — Chat message row
CrabInviteFriendRowUI   — Friend invite row
CrabJoinedPlayerRowUI   — Joined player row
```

### UI — Menus & End Screens
```
CrabInGameMenuUI        — Pause menu
CrabGameOverUI          — Game over screen
CrabGameOverRowUI       — Per-player row on game over
CrabMinigameGameOverUI  — Minigame game over
CrabMinigameGameOverRowUI
CrabRevivalUI           — Revival prompt
CrabBlessingUI          — Blessing selection
CrabChallengeModifierUI — Challenge modifier display
CrabDifficultyModifierUI — Difficulty modifier display
CrabConfirmationPromptUI — Confirm/cancel dialog
CrabSliderUI            — Slider widget
CrabUnlockedCosmeticUI  — Cosmetic unlock notification
CrabKeyBindRowUI        — Key binding row
```

### UI — Settings Menus
```
CrabSettingsMenuUI
CrabControlsMenuUI
CrabVideoMenuUI
CrabSoundMenuUI
CrabDifficultyMenuUI
CrabFocusMenuUI
CrabCosmeticsMenuUI
CrabMultiplayerMenuUI
```

---

## 17. Data Assets Found

### Weapon DAs (20+ in dump)
```
DA_Weapon_DualPistols
DA_Weapon_AutoRifle
DA_Weapon_DualShotguns
DA_Weapon_AutoShotgun
DA_Weapon_BurstPistol
DA_Weapon_Sniper
DA_Weapon_Crossbow
DA_Weapon_OrbLauncher
DA_Weapon_RocketLauncher
DA_Weapon_Minigun
DA_Weapon_BladeLauncher
DA_Weapon_ClusterLauncher
DA_Weapon_Flamethrower
DA_Weapon_ArcaneWand
DA_Weapon_LaserCannons
DA_Weapon_Seagle
DA_Weapon_MarksmanRifle
DA_Weapon_IceStaff
DA_Weapon_LightningScepter
[+ additional variants]
```

### Weapon Mod DAs (100+ in dump)
```
DA_WeaponMod_EscalatingShot
DA_WeaponMod_SharpShot
DA_WeaponMod_TrickShot
DA_WeaponMod_RapidFire
DA_WeaponMod_DoubleShot
DA_WeaponMod_WindUp
DA_WeaponMod_UltraShot
DA_WeaponMod_HealthShot
DA_WeaponMod_GripTape
DA_WeaponMod_MagShot
DA_WeaponMod_FireShot
DA_WeaponMod_ArcaneShot
DA_WeaponMod_IceShot
DA_WeaponMod_LightningShot
DA_WeaponMod_PoisonShot
DA_WeaponMod_BouncingShot
DA_WeaponMod_AcceleratingShot
DA_WeaponMod_ZigZagShot
DA_WeaponMod_SpiralShot
DA_WeaponMod_SnakeShot
DA_WeaponMod_ChaoticShot
DA_WeaponMod_BoomerangShot
DA_WeaponMod_OrbitingShot
DA_WeaponMod_RecoilShot
DA_WeaponMod_FastShot
DA_WeaponMod_KnockbackShot
DA_WeaponMod_BigMag
[+ 70+ more variants]

Legendary weapon mods found specifically:
DA_WeaponMod_LightningStorm
DA_WeaponMod_HomingShot
DA_WeaponMod_PoisonStrike
DA_WeaponMod_SpikeStrike
DA_WeaponMod_DiceShot
DA_WeaponMod_IceStorm
DA_WeaponMod_FireStorm
DA_WeaponMod_PoisonStorm
DA_WeaponMod_IceStrike
DA_WeaponMod_FireStrike
DA_WeaponMod_LightningStrike
```

### Ability DAs
```
DA_Ability_Grenade
DA_Ability_GrapplingHook
DA_Ability_BlackHole
DA_Ability_LaserBeam
DA_Ability_IceBlast
DA_Ability_ElectroGlobe
DA_Ability_AirStrike
[+ additional]
```

### Perk DAs (107 in dump — sample)
```
DA_Perk_Mango
DA_Perk_Fortitude
DA_Perk_HardTarget
DA_Perk_HotShot
DA_Perk_Sharpshooter
DA_Perk_Regenerator
DA_Perk_Collector
DA_Perk_SilverLining
DA_Perk_ValuedCustomer
DA_Perk_PersonalSpace
DA_Perk_Bullseye
[+ 96 more]
```

### Melee DAs
Multiple instances in `/Game/Blueprint/Melee/`, including at least:
```
DA_Melee_Hammer
[+ additional]
```

### Relic DAs
```
DA_Relic_RingOfPower
DA_Relic_RingOfArmor
[+ additional]
```

---

## 18. Known Bugs & Root Causes

### BUG 1 — CRITICAL: The Shuffle / Infinite APPLY Loop
**Session confirmed:** 20260325-131730
**UE4SS log evidence:** Parts 5–9 show APPLY firing every 1–2 seconds with alternating
mod orderings. Parts 10–12 show the same push rate but APPLY being blocked by
"skipped (post-push tick)" on every single tick.

**Root cause:**
The game's `TArray` for `WeaponMods`, `Perks`, and other inventory arrays does NOT
preserve insertion order. When the Lua mod writes mods in order `[Double Shot, Wind Up]`,
the game stores and returns them as `[Wind Up, Double Shot]`. The change detection
compares arrays index-by-index, so it always detects a diff → `changed=true` → PUSH →
server returns new order → APPLY rewrites TArray → game re-shuffles → detect diff again.
Loop runs indefinitely.

**Confirmed ordering pairs from logs:**
```
{Sharp Shot, Trick Shot, Rapid Fire, Double Shot, Ultra Shot, Health Shot, Escalating Shot, Wind Up}
{Sharp Shot, Trick Shot, Rapid Fire, Wind Up,   Ultra Shot, Health Shot, Escalating Shot, Double Shot}
```
The only difference is positions 3 and 7 (Double Shot ↔ Wind Up). The game consistently
swaps these two regardless of insertion order. This is a deterministic reordering by the
game engine, likely alphabetical or by internal DA hash.

**Perks also affected:**
```
{Sharpshooter, Silver Lining, Hot Shot, Hard Target, Mango, Collector, Regenerator, Fortitude}
{Fortitude,    Silver Lining, Hot Shot, Hard Target, Mango, Regenerator, Sharpshooter, Collector}
{Collector,    Fortitude,     Hot Shot, Hard Target, Mango, Sharpshooter, Regenerator, Silver Lining}
{Silver Lining,Fortitude,     Hot Shot, Hard Target, Mango, Regenerator,  Collector,   Sharpshooter}
```
Same 8 perks, rotating through multiple orderings every ~2 seconds.

**Impact cascade:**
1. APPLY fires every 1–2 seconds all run long
2. Every APPLY clears TArray and adds fresh entries → `InventoryInfo.Level = 1`,
   `InventoryInfo.Enhancements = []`, `InventoryInfo.AccumulatedBuff = 0.0`
3. Earned mod levels are wiped on every cycle
4. Anvil upgrades are wiped on every cycle
5. `CrabAutoSave` may persist Level=1 if the game auto-saves after an APPLY
6. Server receives one push per ~1–2 seconds even when nothing actually changed
7. "Ghost mods" appear: a mod the game removed via normal gameplay gets re-added by
   the next APPLY from the server's stale state

**Object dump confirmation:**
`CrabInventoryInfo.Level` is `ByteProperty` at offset `0x0`. `CrabInventoryInfo.Enhancements`
is `ArrayProperty` at offset `0x8`. Both are part of every mod/perk/relic struct in
`CrabPS.WeaponMods`, `CrabPS.Perks`, etc. The current APPLY code never touches these fields.

---

### BUG 2 — SECONDARY: Crystal Overwrite by Stale Server State
**Session confirmed:** 20260325-131730

**Root cause:**
The APPLY writes `CrabPS.Crystals` to the server's last-known value unconditionally.
During active play, crystals accumulate in-game faster than pushes update the server.
When APPLY fires with a stale server value, it REDUCES the player's crystals.

**Confirmed from UE4SS logs:**
```
crystals | applied=6034; before=6070; lastGameCrystals=6034   (-36)
crystals | applied=3180; before=3226; lastGameCrystals=3180   (-46)
crystals | applied=58;   before=4063; lastGameCrystals=58     (-4005, post-level-change)
```

**Additional:** `CrabPS.Crystals` is `UInt32Property` — UNSIGNED. If a negative number
is ever written (e.g. from a Lua arithmetic error), it will wrap to ~4.29 billion.
The bridge currently formats crystals as a regular number, which should be safe, but
any subtraction-based logic in the apply path is dangerous.

**The 13,000 crystal discrepancy** the user saw (game UI showed one value, inventory
showed 58) was most likely caused by:
- The game had accumulated ~13,000 crystals from combat
- The server still had `crystals=58` from before the last level transition
- After the bridge was closed, the APPLY stopped firing
- The game's local crystal count remained at 13,000 but the server showed 58
- When the inventory UI was checked, it displayed the server's value (58) rather than
  the live game value

---

### BUG 3 — TRANSIENT: Rocket Launcher Weapon Blip
**Session confirmed:** 20260325-131730 at 20:20:51 (UE4SS time)

**Root cause:**
For 1–2 ticks, `CrabPS.WeaponDA` (or the field the mod reads for weapon name) returned
a reference to `DA_Weapon_RocketLauncher` instead of `DA_Weapon_Minigun`. This is likely
the game temporarily swapping the active weapon reference during a chest interaction or
pickup animation frame — the game briefly points WeaponDA at the item being offered before
reverting to the player's equipped weapon.

**Impact:**
- Bridge pushed `weapon=Rocket Launcher, weaponMods=[]` to server
- Server state briefly set to Rocket Launcher with no mods
- An APPLY fired with merged `weapon=Minigun, weaponMods={}` (empty — from the tick
  before Escalating Shot was registered) while in-game weapon was Rocket Launcher
- Resolved naturally on the next tick

**Risk:** If APPLY fires during the blip with a full merged loadout and the game's
current weapon is different, the mod code may try to apply Minigun mods while the game
thinks the weapon is Rocket Launcher, potentially applying mods to the wrong weapon object.

---

## 19. Fix Recommendations & Pseudocode

### Fix 1: Set-Based Change Detection (fixes Bug 1 / the shuffle)

Replace index-by-index array comparison with an unordered set comparison for all
inventory arrays (weaponMods, abilityMods, meleeMods, perks, relics).

```lua
-- Utility: compare two flat name-lists as sets (handles duplicates via count)
local function setsEqual(a, b)
    if #a ~= #b then return false end
    local counts = {}
    for _, v in ipairs(a) do counts[v] = (counts[v] or 0) + 1 end
    for _, v in ipairs(b) do
        if not counts[v] or counts[v] == 0 then return false end
        counts[v] = counts[v] - 1
    end
    return true
end

-- In change detection:
if not setsEqual(localWeaponMods, serverWeaponMods) then changed = true end
if not setsEqual(localPerks,      serverPerks)      then changed = true end
-- etc.
```

This alone eliminates the infinite loop. APPLY will only fire when the actual SET of
mods differs, not just the order.

---

### Fix 2: Preserve Level and Enhancements Across APPLY (fixes Level reset)

Before clearing the TArray, read every entry's Level and Enhancements. Cache them by
mod name. After re-adding, write them back.

```lua
-- Step 1: snapshot current Level and Enhancements from game TArray
local function snapshotInventoryInfo(tarray, getDAName)
    local snapshot = {}
    for i = 0, tarray:GetArrayNum() - 1 do
        local entry = tarray:Get(i)
        local name = getDAName(entry)
        snapshot[name] = {
            level        = entry.InventoryInfo.Level,
            enhancements = {},  -- copy enhancement array entries
            accum        = entry.InventoryInfo.AccumulatedBuff,
        }
        local enh = entry.InventoryInfo.Enhancements
        for j = 0, enh:GetArrayNum() - 1 do
            table.insert(snapshot[name].enhancements, enh:Get(j))
        end
    end
    return snapshot
end

-- Step 2: after re-adding mods, restore Level and Enhancements
local function restoreInventoryInfo(tarray, getDAName, snapshot)
    for i = 0, tarray:GetArrayNum() - 1 do
        local entry = tarray:Get(i)
        local name = getDAName(entry)
        if snapshot[name] then
            entry.InventoryInfo.Level = snapshot[name].level
            entry.InventoryInfo.AccumulatedBuff = snapshot[name].accum
            -- restore enhancements array
            local enh = entry.InventoryInfo.Enhancements
            for _, v in ipairs(snapshot[name].enhancements) do
                enh:Add(v)
            end
        end
    end
end

-- Usage in APPLY:
local snap = snapshotInventoryInfo(ps.WeaponMods, getWeaponModName)
-- ... clear and re-add mods ...
restoreInventoryInfo(ps.WeaponMods, getWeaponModName, snap)
```

---

### Fix 3: Crystal Apply Guard (fixes Bug 2)

Only write crystals to the game if the server value is higher than the current game value,
except on initial session load (where game value is 0).

```lua
local gameCrystals   = ps.Crystals          -- UInt32, current in-game value
local serverCrystals = merged.crystals       -- value from server

local isInitialLoad  = (gameCrystals == 0)

if isInitialLoad or serverCrystals > gameCrystals then
    ps.Crystals = serverCrystals
end
-- If serverCrystals < gameCrystals, do nothing. The player earned more crystals
-- than the server knows about; the next PUSH will update the server.
```

For pooled multi-player crystal sync (where the server accumulates all players'
crystals), only apply at TRANSITION events and session start, never on mid-combat ticks.

---

### Fix 4: Weapon Stability Window (fixes Bug 3)

Require 3–4 consecutive identical weapon reads before accepting a weapon change. Also
add a heuristic: if the new weapon name has 0 mods but the previous weapon had mods,
require an extra stability tick.

```lua
local WEAPON_STABILITY_TICKS = 4   -- was 2

-- If new weapon has 0 mods but previous had mods, add 2 more ticks
local function weaponChangeIsSuspicious(newWeapon, newMods, prevWeapon, prevMods)
    return newWeapon ~= prevWeapon and #newMods == 0 and #prevMods > 0
end
```

---

### Fix 5: Track Level and Enhancements in Server Payload

To properly sync leveled mods across players, the server payload needs to include Level
and Enhancements for each item. Schema addition:

```json
{
  "weaponMods": [
    { "name": "Escalating Shot", "level": 2, "enhancements": ["ECrabEnhancementType::Damage"] }
  ],
  "perks": [
    { "name": "Hard Target", "level": 1, "enhancements": [] }
  ]
}
```

The Lua mod would need to:
1. Read `InventoryInfo.Level` and `InventoryInfo.Enhancements` when building the PUSH payload
2. Write them back during APPLY

---

## 20. Priority Fix Checklist

| Pri | Fix | Where | Impact |
|-----|-----|-------|--------|
| 🔴 P0 | Set-based comparison for all 5 inventory arrays (weaponMods, abilityMods, meleeMods, perks, relics) | Lua — change detection | Eliminates infinite APPLY loop, stops the shuffle entirely |
| 🔴 P0 | Preserve `InventoryInfo.Level` before clear, restore after re-add | Lua — APPLY logic | Stops level resets every 1–2 seconds |
| 🔴 P0 | Preserve `InventoryInfo.Enhancements` before clear, restore after re-add | Lua — APPLY logic | Stops Anvil upgrade wipes |
| 🟡 P1 | Crystal apply guard: only set if server > game, or on initial load | Lua — crystal APPLY | Stops crystal drain during combat |
| 🟡 P1 | Increase weapon stability window to 3–4 ticks; add 0-mod suspicion heuristic | Lua — weapon read | Stops Rocket Launcher blip from corrupting state |
| 🟢 P2 | Add Level + Enhancements fields to server JSON payload | Server + Lua | Enables true cross-player level sync |
| 🟢 P2 | Sync `HealthInfo.CurrentArmorPlates` and `CurrentArmorPlateHealth` | Server + Lua | Accurate armor plate sync |
| 🟢 P2 | Use `HealthInfo.CurrentMaxHealth` instead of `BaseMaxHealth` alone | Lua — health read | Accurate max HP when HP-scaling perks are active |
| 🟢 P2 | Guard against writing negative values to `Crystals` (unsigned 32-bit) | Lua — crystal write | Prevents wrap-to-4-billion bug |
| 🟢 P3 | Preserve `InventoryInfo.AccumulatedBuff` (relic running buff) | Lua — APPLY logic | Stops relic buff resets |

---

## Appendix A — Object Pointer Quick Reference

| Object | Pointer |
|--------|---------|
| `CrabPS` class | `000001BA78A2A840` |
| `CrabPlayerC` class | `000001BA78A2BEC0` |
| `CrabWeaponMod` struct | `000001BA26728BC0` |
| `CrabAbilityMod` struct | `000001BA26728C80` |
| `CrabMeleeMod` struct | `000001BA26728D40` |
| `CrabPerk` struct | `000001BA26728E00` |
| `CrabRelic` struct | `000001BA26728F80` |
| `CrabInventoryInfo` struct | `000001BA26728EC0` |
| `CrabHealthInfo` struct | `000001BA26728B00` |
| `CrabAutoSave` struct | `000001BA267291C0` |
| `CrabWeaponDA` class | `000001BA78A33C40` |
| `CrabWeaponModDA` class | `000001BA78A33A00` |
| `CrabAbilityDA` class | `000001BA78A1A600` |
| `CrabMeleeDA` class | `000001BA78A2D9C0` |
| `CrabPerkDA` class | `000001BA78A2C7C0` |
| `CrabRelicDA` class | `000001BA78A29F40` |
| `CrabHC` class | `000001BA78A264C0` |
| `ECrabWeaponModType` enum | `000001BA24C452C0` |
| `ECrabAbilityModType` enum | `000001BA24C45380` |
| `ECrabMeleeModType` enum | `000001BA24C45440` |
| `ECrabPerkType` enum | `000001BA24C453E0` |
| `ECrabRelicType` enum | `000001BA24C454A0` |
| `ECrabEnhancementType` enum | `000001BA24C451A0` |
| `ECrabPickupType` enum | `000001BA24C45020` |
| `ECrabRarityType` enum | `000001BA24C45080` |
| `ECrabTintType` enum | `000001BA24C44AE0` |
| `ECrabDifficultyModifier` enum | `000001BA24C455C0` |
| `ECrabAccountRank` enum | `000001BA24C45620` |
| `EFlipDir` enum | `000001BA72381540` |

---

*Last updated: 2026-03-25 — Dudiebug / CrabChampionsInventorySync*
*Source: UE4SS_ObjectDump.txt parts 01–53 (83,081 lines), fully read and catalogued.*
