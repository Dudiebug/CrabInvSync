# Codex Notes

- Startup item arrays are readiness-gated in `client/Mods/CrabInventorySync/Scripts/main.lua`: do not traverse or push mod/perk/relic arrays until role is eligible, shallow local read succeeds, item-array warmup completes, and the arrays have been readable/stable for 3 consecutive ticks.
- During startup/readiness, less-complete item reads reuse the previous stable local item state instead of pushing transient empty or partial arrays.
- Solo self-echo protection uses `clientInstanceId` and `pushSeq`; the bridge forwards them and the server echoes them for single-client merged inventories.
- Structural item applies are skipped when recv is older self-echo or less complete than local stable/readiness state.
- Scalar metadata writes are quarantined by default with `allowScalarMetadataApply=false`; `{n,l,a,e}` is still read/merged/compared/logged, but `InventoryInfo.Level`, `InventoryInfo.AccumulatedBuff`, and `InventoryInfo.Enhancements` are not written to live item structs while disabled.
- If scalar metadata apply is ever enabled for testing, it still requires readiness, non-stale/non-less-complete recv, slot-index pairing, exact DA full-name match at that slot, and no duplicate DA identity in the category. Nested `Enhancements` writes remain disabled.
- Global lifecycle gate defaults to `suspended -> probing -> stable`; the tick that reaches shallow stable returns immediately, then full sync waits for `lifecycleStableWarmupTicks`, role eligibility, a shallow same-generation local read, `itemArrayWarmupTicksRequired`, and one clean full-ready loop before recv apply can run.
- Existing recv text is snapshotted on startup/reset/full-ready and ignored until a newer recv write arrives; joined clients are read-only/no-read/no-apply by default with `allowJoinedClientRead=false` and `allowJoinedClientApply=false`, unknown roles cannot read or apply by default, and multiplayer apply remains disabled with `allowMultiplayerApply=false` until contribution ledger work is done.
- Keep health disabled by default and preserve `healthValid=false` output, `{n,l,a,e}` item payloads, reorder-only no-ops, and no nested enhancement writes.
