# Codex Notes

- Startup item arrays are readiness-gated in `client/Mods/CrabInventorySync/Scripts/main.lua`: do not push mod/perk/relic arrays until CrabPS is valid and the arrays have been readable/stable for 3 consecutive ticks.
- During startup/readiness, less-complete item reads reuse the previous stable local item state instead of pushing transient empty or partial arrays.
- Solo self-echo protection uses `clientInstanceId` and `pushSeq`; the bridge forwards them and the server echoes them for single-client merged inventories.
- Structural item applies are skipped when recv is older self-echo or less complete than local stable/readiness state. Scalar metadata writes remain limited to safely paired same-name items.
- Keep health disabled by default and preserve `healthValid=false` output, `{n,l,a,e}` item payloads, reorder-only no-ops, no nested enhancement writes, and no TastyMod/TastyOrange.
