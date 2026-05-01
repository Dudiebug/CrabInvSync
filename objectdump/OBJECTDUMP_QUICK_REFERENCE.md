# CrabInvSync Object Dump Quick Reference

This is a focused map for CrabInvSync work. It is derived from targeted
searches in `objectdump/UE4SS_ObjectDump.txt.part*`, not a replacement for the
full dump.

## CrabPS

- `WeaponDA`: ObjectProperty -> `CrabWeaponDA`
- `AbilityDA`: ObjectProperty -> `CrabAbilityDA`
- `MeleeDA`: ObjectProperty -> `CrabMeleeDA`
- `NumWeaponModSlots`: ByteProperty
- `WeaponMods`: ArrayProperty -> `CrabWeaponMod`
- `NumAbilityModSlots`: ByteProperty
- `AbilityMods`: ArrayProperty -> `CrabAbilityMod`
- `NumMeleeModSlots`: ByteProperty
- `MeleeMods`: ArrayProperty -> `CrabMeleeMod`
- `NumPerkSlots`: ByteProperty
- `Perks`: ArrayProperty -> `CrabPerk`
- `Relics`: ArrayProperty -> `CrabRelic`
- `InventoryCooldowns`: ArrayProperty -> `CrabInventoryCooldown`
- `Crystals`: UInt32Property
- `Keys`: IntProperty
- `HealthInfo`: StructProperty -> `CrabHealthInfo`
- `BaseMaxHealth`: FloatProperty
- `MaxHealthMultiplier`: FloatProperty

## Item Structs

- `CrabWeaponMod`: `WeaponModDA`, `InventoryInfo`
- `CrabAbilityMod`: `AbilityModDA`, `InventoryInfo`
- `CrabMeleeMod`: `MeleeModDA`, `InventoryInfo`
- `CrabPerk`: `PerkDA`, `InventoryInfo`
- `CrabRelic`: `RelicDA`, `InventoryInfo`

## CrabInventoryInfo

- `Level`: ByteProperty. CrabInvSync treats item level payload values as `1..255`.
- `Enhancements`: ArrayProperty -> `ECrabEnhancementType`
- `AccumulatedBuff`: FloatProperty. Keep signed finite values unless testing proves otherwise.

Synced item payloads should carry this as `{n,l,a,e}`:

- `n`: DA name
- `l`: `InventoryInfo.Level`
- `a`: `InventoryInfo.AccumulatedBuff`
- `e`: `InventoryInfo.Enhancements` as numeric `ECrabEnhancementType` values

Apply gating should compare deterministic item signatures:

`name|level|accumRounded|enhancement1,enhancement2,...`

Sort signatures before comparing arrays so UE TArray reorder-only changes are
no-ops. DA-name counts are only safe for deciding whether item pointers need to
move; they are not a complete item-state comparison.

Scalar metadata writes are limited to safely paired live slots with matching
DA-name counts:

- write `InventoryInfo.Level` with `1..255` clamping
- write signed finite `InventoryInfo.AccumulatedBuff`
- do not write `InventoryInfo.Enhancements` until a safe nested TArray path is proven

`ECrabEnhancementType` values:

- `None`: 0
- `Bouncing`: 1
- `Accelerating`: 2
- `Zigging`: 3
- `Spiraling`: 4
- `Snaking`: 5
- `Returning`: 6
- `Orbiting`: 7
- `Chipping`: 8
- `Sticky`: 9
- `Growing`: 10
- `Freezing`: 11
- `Flaming`: 12
- `Electrifying`: 13
- `Toxifying`: 14
- `Arcanifying`: 15
- `Persisting`: 16
- `Doubling`: 17
- `Targeting`: 18
- `Damaging`: 19
- `Booming`: 20
- `Tripling`: 21
- `Splitting`: 22
- `Scattering`: 23
- `Expanding`: 24
- `Homing`: 25
- `Endangering`: 26
- `Random`: 27
- `ECrabEnhancementType_MAX`: 28

## CrabAutoSave

`CrabAutoSave` persists the same run-state shape used by `CrabPS`, including:

- `HealthInfo`, `BaseMaxHealth`, `MaxHealthMultiplier`
- `WeaponDA`, `AbilityDA`, `MeleeDA`
- `NumWeaponModSlots`, `WeaponMods`
- `NumAbilityModSlots`, `AbilityMods`
- `NumMeleeModSlots`, `MeleeMods`
- `NumPerkSlots`, `Perks`
- `Relics`
- `Crystals`

The saved mod, perk, and relic arrays point at the same item structs that carry
`InventoryInfo`, so metadata-destructive writes can become persistent.

## Health

`CrabHealthInfo` fields:

- `CurrentArmorPlates`
- `CurrentArmorPlateHealth`
- `PreviousArmorPlateHealth`
- `CurrentHealth`
- `CurrentMaxHealth`
- `PreviousHealth`
- `PreviousMaxHealth`

`CrabHC` also exposes:

- `OwningC`
- `BaseArmorPlates`
- `BaseMaxHealth`
- `bShouldRegenerateHealth`
- `HealthRegenerationAmount`
- `bCanBeEliminated`
- `bHasOneShotProtection`
- `bHasDeathProtection`
- `HealthInfo`

CrabInvSync currently reads current HP from `CrabHC.HealthInfo.CurrentHealth`
and max HP from `CrabHC.HealthInfo.CurrentMaxHealth`. Armor plates need a
separate in-game policy/test pass.

## Pickup Metadata

- `CrabInteractPickup.PickupInfo`: StructProperty -> `CrabPickupInfo`
- `CrabPickupInfo.PickupDA`: ObjectProperty
- `CrabPickupInfo.InventoryInfo`: StructProperty -> `CrabInventoryInfo`
- `CrabPC.ClientOnPickedUpPickup(PickupDA, Level)` exposes pickup DA and level,
  but not the full enhancement list.

## RPCs and OnRep Callbacks

`CrabPS`:

- `ServerEquipInventory(NewWeaponDA, NewAbilityDA, NewMeleeDA)`
- `ServerSetWeaponDA(NewWeaponDA)`
- `ServerSetAbilityDA(NewAbilityDA)`
- `ServerSetMeleeDA(NewMeleeDA)`
- `ServerIncrementNumInventorySlots(PickupType, Cost)`
- `ServerRemoveWeaponMod(WeaponModType)`
- `ServerRemoveAbilityMod(AbilityModType)`
- `ServerRemoveMeleeMod(MeleeModType)`
- `ServerRemovePerk(PerkType)`
- `ServerRemoveRelic(RelicType)`
- `OnRep_Inventory`
- `OnRep_Crystals`
- `OnRep_WeaponDA`
- `OnRep_AbilityDA`
- `OnRep_MeleeDA`

`CrabPC`:

- `ClientRefreshPSUI`
- `ClientOnPickedUpPickup(PickupDA, Level)`
- `ServerRestoreAutoSave(AutoSave)`

## ECrabPickupType

- `None`: 0
- `Weapon`: 1
- `Ability`: 2
- `Melee`: 3
- `WeaponMod`: 4
- `AbilityMod`: 5
- `MeleeMod`: 6
- `Perk`: 7
- `Relic`: 8
- `Consumable`: 9
- `Random`: 10

## ECrabPerkType

`ECrabPerkType` is the generic perk enum. CrabInvSync should sync perks by
generic item payload data and should not add special-case behavior for individual
perk enum values.

## Ranges

- ByteProperty: `0..255`
- `CrabInventoryInfo.Level`: payload clamp `1..255`
- `CrabPS.Crystals` UInt32Property: `0..4294967295`
- FloatProperty inventory buffs: signed finite numbers

## Code Traps

- Do not compare item arrays by DA name only once metadata is part of the payload.
- Same DA names with different `Level`, `AccumulatedBuff`, or `Enhancements`
  must be treated as metadata-different, not identical.
- Do not rebuild item arrays unless full `CrabInventoryInfo` metadata is preserved.
- Do not drop `InventoryInfo.Enhancements`; payloads preserve it as `e`, but
  the current client does not yet write nested enhancement TArrays back to UE.
- Do not write slot counts above `255`.
- Do not write crystals above `4294967295`.
- Do not use direct `pc.PlayerState` access during transition-prone code paths.
- Keep CrabInvSync perk handling generic.
