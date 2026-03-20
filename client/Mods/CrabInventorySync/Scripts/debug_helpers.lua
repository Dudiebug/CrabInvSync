-- CrabInventorySync - debug.lua
-- Drop this file in the same Scripts/ folder and add:
--   require("debug")
-- at the TOP of main.lua to enable it. Remove that line when done.
--
-- Keybinds (all fire in-game):
--   F6  — Dump ALL CrabPS property names + values to the UE4SS log
--   F7  — Try every plausible crystal/currency property name and print the ones that work
--   F8  — Print a full human-readable snapshot of your current inventory
--           (lets you verify the sync is reading data correctly before enabling it)
--
-- The UE4SS log is visible in the UE4SS GUI window OR in:
--   <GameRoot>\ue4ss\UE4SS.log

print("[CrabInventorySync DEBUG] Debug helpers loaded. F6/F7/F8/F10 active.\n")

-- ------------------------------------------------------------------ HOOKS --
-- Hook CrabPS and CrabPC functions so we can see what fires during pickup.
-- Pick up a perk/mod/relic and watch the log — whatever prints here is
-- what we can call ourselves to add items programmatically.
local function hookFn(path, label)
    local ok, err = pcall(function()
        RegisterHook(path, function(self)
            print("[HOOK] " .. label .. " fired\n")
        end)
    end)
    if ok then
        print("[DEBUG HOOK] Registered: " .. label .. "\n")
    else
        print("[DEBUG HOOK] Failed: " .. label .. " — " .. tostring(err) .. "\n")
    end
end

-- CrabPS server RPCs — these run on the authority and modify state
hookFn("/Script/CrabChampions.CrabPS:ServerIncrementNumInventorySlots", "CrabPS:ServerIncrementNumInventorySlots")
hookFn("/Script/CrabChampions.CrabPS:ServerEquipInventory",             "CrabPS:ServerEquipInventory")
hookFn("/Script/CrabChampions.CrabPS:ServerEquipCosmetics",             "CrabPS:ServerEquipCosmetics")
hookFn("/Script/CrabChampions.CrabPS:ServerSetWeaponDA",                "CrabPS:ServerSetWeaponDA")
hookFn("/Script/CrabChampions.CrabPS:ServerSetAbilityDA",               "CrabPS:ServerSetAbilityDA")
hookFn("/Script/CrabChampions.CrabPS:ServerSetMeleeDA",                 "CrabPS:ServerSetMeleeDA")
hookFn("/Script/CrabChampions.CrabPS:ServerRemovePerk",                 "CrabPS:ServerRemovePerk")
hookFn("/Script/CrabChampions.CrabPS:ServerRemoveRelic",                "CrabPS:ServerRemoveRelic")
hookFn("/Script/CrabChampions.CrabPS:ServerRemoveWeaponMod",            "CrabPS:ServerRemoveWeaponMod")
hookFn("/Script/CrabChampions.CrabPS:ServerRemoveAbilityMod",           "CrabPS:ServerRemoveAbilityMod")
hookFn("/Script/CrabChampions.CrabPS:ServerRemoveMeleeMod",             "CrabPS:ServerRemoveMeleeMod")
-- OnRep functions — these fire on the client when a replicated property changes
hookFn("/Script/CrabChampions.CrabPS:OnRep_Inventory",                  "CrabPS:OnRep_Inventory")
hookFn("/Script/CrabChampions.CrabPS:OnRep_WeaponDA",                   "CrabPS:OnRep_WeaponDA")
hookFn("/Script/CrabChampions.CrabPS:OnRep_AbilityDA",                  "CrabPS:OnRep_AbilityDA")
hookFn("/Script/CrabChampions.CrabPS:OnRep_MeleeDA",                    "CrabPS:OnRep_MeleeDA")
-- CrabPC server RPCs
hookFn("/Script/CrabChampions.CrabPC:ServerSpawnKeyTotemPickup",        "CrabPC:ServerSpawnKeyTotemPickup")

-- Diagnose whether Key constants and RegisterKeyBind are working
print("[DEBUG INIT] Key table type: " .. type(Key) .. "\n")
if type(Key) == "table" then
    print("[DEBUG INIT] Key.F6="  .. tostring(Key.F6)  .. "\n")
    print("[DEBUG INIT] Key.F7="  .. tostring(Key.F7)  .. "\n")
    print("[DEBUG INIT] Key.F8="  .. tostring(Key.F8)  .. "\n")
    print("[DEBUG INIT] Key.F10=" .. tostring(Key.F10) .. "\n")
else
    print("[DEBUG INIT] Key is NOT a table — RegisterKeyBind will fail!\n")
end

local function safeRegister(keyVal, keyName, fn)
    local ok, err = pcall(RegisterKeyBind, keyVal, fn)
    if ok then
        print("[DEBUG INIT] Registered keybind for " .. keyName .. "\n")
    else
        print("[DEBUG INIT] FAILED to register " .. keyName .. ": " .. tostring(err) .. "\n")
    end
end

-- ------------------------------------------------------------------ F6 ----
-- Dump every readable property on CrabPS using class reflection.
-- This is the definitive way to find property names — no guessing needed.
local function onF6()
    print("[DEBUG F6] Callback fired!\n")
    print("[DEBUG F6] Dumping ALL CrabPS properties...\n")

    local ps = FindFirstOf("CrabPS")
    if not ps or not ps:IsValid() then
        print("[DEBUG F6] No CrabPS found. Are you in a game?\n")
        return
    end

    -- Method 1: iterate the UClass property chain (UE4SS 3.x reflection API)
    local dumpedAny = false
    pcall(function()
        local cls = ps:GetClass()
        if cls and cls:IsValid() then
            cls:ForEachPropertyInChain(function(prop)
                local propName = prop:GetName()
                local ok, val = pcall(function()
                    return ps:GetPropertyValue(propName)
                end)
                local display = ok and tostring(val) or "<unreadable>"
                print("  [PROP] " .. propName .. " = " .. display .. "\n")
                dumpedAny = true
            end)
        end
    end)

    -- Method 2: fallback using ForEachProperty (older UE4SS builds)
    if not dumpedAny then
        pcall(function()
            local cls = ps:GetClass()
            if cls and cls:IsValid() then
                cls:ForEachProperty(function(prop)
                    local propName = prop:GetName()
                    local ok, val = pcall(function()
                        return ps:GetPropertyValue(propName)
                    end)
                    local display = ok and tostring(val) or "<unreadable>"
                    print("  [PROP] " .. propName .. " = " .. display .. "\n")
                    dumpedAny = true
                end)
            end
        end)
    end

    if not dumpedAny then
        print("[DEBUG F6] Class reflection unavailable in this UE4SS build.\n")
        print("[DEBUG F6] Use the UE4SS GUI Live View instead, or try F7.\n")
    else
        print("[DEBUG F6] Done. Search the log for 'PROP' to find the crystal field.\n")
    end
end
safeRegister(Key.F6, "F6", onF6)

-- ------------------------------------------------------------------ F7 ----
-- Brute-force: try every plausible property name and print which ones
-- return a non-nil, non-zero value. Make sure you have some crystals first!
local function onF7()
    print("[DEBUG F7] Callback fired!\n")
    print("[DEBUG F7] Scanning for crystal/currency property name...\n")
    print("[DEBUG F7] Make sure you have some crystals before running this!\n")

    local ps = FindFirstOf("CrabPS")
    if not ps or not ps:IsValid() then
        print("[DEBUG F7] No CrabPS found.\n")
        return
    end

    local candidates = {
        -- Most likely names for Crab Champions
        "Crystals", "CrystalCount", "NumCrystals", "CrystalAmount",
        "TotalCrystals", "PlayerCrystals", "CrystalsCount",
        -- Generic currency names UE4 games often use
        "Currency", "Gold", "GoldCount", "Coins", "CoinsCount",
        "Money", "Cash", "Credits", "Points", "Gems",
        "Score", "Experience", "XP",
        -- Prefixed variants
        "CurrentCrystals", "CurrentGold", "CurrentCurrency",
        "RunCrystals", "RunCurrency", "RunGold",
        -- CrabChampions-specific guesses
        "CrabCrystals", "ShardCount", "Shards",
    }

    local found = {}
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return ps:GetPropertyValue(name) end)
        if ok and val ~= nil and val ~= false then
            print("  [HIT] " .. name .. " = " .. tostring(val) .. "\n")
            table.insert(found, name .. "=" .. tostring(val))
        end
    end

    if #found == 0 then
        print("[DEBUG F7] No matches found. Try F6 for a full property dump.\n")
    else
        print("[DEBUG F7] Hits: " .. table.concat(found, ", ") .. "\n")
        print("[DEBUG F7] Set the matching name as crystalsProperty in config.txt\n")
    end
end
safeRegister(Key.F7, "F7", onF7)

-- ------------------------------------------------------------------ F8 ----
-- Print a full human-readable snapshot of what the sync mod currently reads
-- for your local player — useful for verifying data before running a real sync.
local function onF8()
    print("[DEBUG F8] Callback fired!\n")
    print("[DEBUG F8] Reading your current inventory snapshot...\n")

    local pc = FindFirstOf("CrabPC")
    if not pc or not pc:IsValid() then
        print("[DEBUG F8] No CrabPC found.\n")
        return
    end

    local ok, ps = pcall(function() return pc.PlayerState end)
    if not ok or not ps or not ps:IsValid() then
        print("[DEBUG F8] No PlayerState on CrabPC.\n")
        return
    end

    -- Player name
    local name = "?"
    pcall(function() name = ps:GetPlayerName():ToString() end)
    print("  Player   : " .. name .. "\n")

    -- Weapon / Ability / Melee
    local function dname(da)
        if not da then return "<nil>" end
        local okv = pcall(function() return da:IsValid() end)
        if not okv then return "<invalid>" end
        local ok2, n = pcall(function() return da.Name:ToString() end)
        return ok2 and n or "<error>"
    end
    pcall(function() print("  Weapon   : " .. dname(ps.WeaponDA)  .. "\n") end)
    pcall(function() print("  Ability  : " .. dname(ps.AbilityDA) .. "\n") end)
    pcall(function() print("  Melee    : " .. dname(ps.MeleeDA)   .. "\n") end)

    -- Crystals (try a few common names)
    for _, propName in ipairs({"Crystals","CrystalCount","Currency","Gold"}) do
        local okc, val = pcall(function() return ps:GetPropertyValue(propName) end)
        if okc and val ~= nil then
            print("  Crystals : " .. tostring(val) .. " (property: " .. propName .. ")\n")
            break
        end
    end

    -- Helper to print a mod/perk array
    local function printArray(label, propName, daField)
        pcall(function()
            local arr = ps:GetPropertyValue(propName)
            if not arr then
                print("  " .. label .. ": <property not found>\n")
                return
            end
            local items = {}
            arr:ForEach(function(_, elem)
                if elem:get():IsValid() then
                    local okd, da = pcall(function() return elem:get()[daField] end)
                    if okd and da then
                        local okn, n = pcall(function() return da.Name:ToString() end)
                        table.insert(items, okn and n or "?")
                    end
                end
            end)
            if #items == 0 then
                print("  " .. label .. ": (none)\n")
            else
                print("  " .. label .. ": " .. table.concat(items, ", ") .. "\n")
            end
        end)
    end

    printArray("WeaponMods ", "WeaponMods",  "WeaponModDA")
    printArray("AbilityMods", "AbilityMods", "AbilityModDA")
    printArray("MeleeMods  ", "MeleeMods",   "MeleeModDA")
    printArray("Perks      ", "Perks",       "PerkDA")
    printArray("Relics     ", "Relics",      "RelicDA")

    print("[DEBUG F8] Done. If everything shows above, the sync mod can read your inventory correctly.\n")
end
safeRegister(Key.F8, "F8", onF8)

-- ------------------------------------------------------------------ F10 ---
-- Probe CrabPS and CrabPC for functions that might add items (perks, mods,
-- relics, weapons, etc.).  If we find the right one we can call it to add
-- synced items instead of only overwriting existing slots.
local function onF10()
    print("[DEBUG F10] Callback fired!\n")
    print("[DEBUG F10] Scanning CrabPS and CrabPC for add-item functions...\n")

    local targets = {}
    local ps = FindFirstOf("CrabPS")
    if ps and pcall(function() return ps:IsValid() end) then
        table.insert(targets, { name = "CrabPS", obj = ps })
    end
    local pc = FindFirstOf("CrabPC")
    if pc and pcall(function() return pc:IsValid() end) then
        table.insert(targets, { name = "CrabPC", obj = pc })
    end

    if #targets == 0 then
        print("[DEBUG F10] No CrabPS or CrabPC found. Are you in a game?\n")
        return
    end

    -- Keywords that hint at item-management functions
    local keywords = {
        "add", "give", "grant", "pickup", "spawn", "create",
        "equip", "remove", "clear", "set",
        "perk", "mod", "relic", "weapon", "ability", "melee",
        "item", "inventory", "loadout", "slot",
    }

    for _, target in ipairs(targets) do
        print("[DEBUG F10] === " .. target.name .. " functions ===\n")
        local count = 0
        pcall(function()
            local cls = target.obj:GetClass()
            if not cls or not cls:IsValid() then return end
            cls:ForEachFunction(function(func)
                local funcName = func:GetName()
                local lower = funcName:lower()
                for _, kw in ipairs(keywords) do
                    if lower:find(kw, 1, true) then
                        -- Try to get parameter count (num params varies by UE4SS version)
                        local paramInfo = ""
                        pcall(function()
                            local params = {}
                            func:ForEachProperty(function(prop)
                                table.insert(params, prop:GetName())
                            end)
                            if #params > 0 then
                                paramInfo = "(" .. table.concat(params, ", ") .. ")"
                            else
                                paramInfo = "()"
                            end
                        end)
                        print("  [FUNC] " .. target.name .. ":" .. funcName .. paramInfo .. "\n")
                        count = count + 1
                        break
                    end
                end
            end)
        end)
        print("[DEBUG F10] " .. count .. " matching functions on " .. target.name .. "\n")
    end

    print("[DEBUG F10] Done. Look for functions like ServerAddPerk, GivePerk, AddWeaponMod, etc.\n")
end
safeRegister(Key.F10, "F10", onF10)

-- ------------------------------------------------------------------ F5 ----
-- Test ServerIncrementNumInventorySlots.
-- Calls it once for each pickup type (Perk=7, Relic=8, WeaponMod=4,
-- AbilityMod=5, MeleeMod=6), then dumps the array lengths so we can see
-- if any slots were added.
--
-- ECrabPickupType enum (from Live View):
--   None=0, Weapon=1, Ability=2, Melee=3,
--   WeaponMod=4, AbilityMod=5, MeleeMod=6,
--   Perk=7, Relic=8, Consumable=9, Random=10
-- ECrabPickupType: WeaponMod=4, AbilityMod=5, MeleeMod=6, Perk=7, Relic=8
local SLOT_TYPES = {
    { name="WeaponMod", type=4 },
    { name="AbilityMod", type=5 },
    { name="MeleeMod",  type=6 },
    { name="Perk",      type=7 },
    { name="Relic",     type=8 },
}

local function onF5()
    print("[DEBUG F5] Testing ServerIncrementNumInventorySlots for all types — finding readable slot properties...\n")

    local ps = FindFirstOf("CrabPS")
    if not ps or not ps:IsValid() then
        print("[DEBUG F5] No CrabPS found. Are you in a game?\n")
        return
    end

    -- Only track candidates that currently return a plain number
    local candidates = {
        "NumWeaponModSlots", "NumAbilityModSlots", "NumMeleeModSlots",
        "NumPerkSlots", "NumRelicSlots",
        "WeaponModSlots", "AbilityModSlots", "MeleeModSlots", "PerkSlots", "RelicSlots",
        "MaxWeaponMods", "MaxAbilityMods", "MaxMeleeMods", "MaxPerks", "MaxRelics",
        "NumWeaponMods", "NumAbilityMods", "NumMeleeMods", "NumPerks", "NumRelics",
        "NumInventorySlots", "MaxInventorySlots", "TotalSlots", "NumSlots",
    }

    local function snapshot(obj)
        local s = {}
        for _, name in ipairs(candidates) do
            local ok, val = pcall(function() return obj:GetPropertyValue(name) end)
            if ok and type(val) == "number" then
                s[name] = val
            end
        end
        return s
    end

    local function testType(entry, cb)
        local before = snapshot(ps)
        local ok, err = pcall(function() ps:ServerIncrementNumInventorySlots(entry.type, 0) end)
        if not ok then
            print("[DEBUG F5] " .. entry.name .. " FAILED: " .. tostring(err) .. "\n")
            cb()
            return
        end
        ExecuteWithDelay(400, function()
            local ps2 = FindFirstOf("CrabPS")
            if not ps2 or not ps2:IsValid() then cb(); return end
            local after = snapshot(ps2)
            local found = false
            for _, name in ipairs(candidates) do
                local b, a = before[name], after[name]
                if b and a and a ~= b then
                    print("  [" .. entry.name .. "] " .. name .. ": " .. b .. " → " .. a .. "\n")
                    found = true
                end
            end
            if not found then
                print("  [" .. entry.name .. "] no numeric property changed\n")
            end
            cb()
        end)
    end

    -- Chain tests sequentially so results don't interleave
    local i = 0
    local function next()
        i = i + 1
        if i <= #SLOT_TYPES then
            testType(SLOT_TYPES[i], next)
        else
            print("[DEBUG F5] Done.\n")
        end
    end
    next()
end
safeRegister(Key.F5, "F5", onF5)
