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

print("[CrabInventorySync DEBUG] Debug helpers loaded. F6/F7/F8 active.\n")

-- ------------------------------------------------------------------ F6 ----
-- Dump every readable property on CrabPS using class reflection.
-- This is the definitive way to find property names — no guessing needed.
RegisterKeyBind(Key.F6, function()
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
end)

-- ------------------------------------------------------------------ F7 ----
-- Brute-force: try every plausible property name and print which ones
-- return a non-nil, non-zero value. Make sure you have some crystals first!
RegisterKeyBind(Key.F7, function()
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
end)

-- ------------------------------------------------------------------ F8 ----
-- Print a full human-readable snapshot of what the sync mod currently reads
-- for your local player — useful for verifying data before running a real sync.
RegisterKeyBind(Key.F8, function()
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
end)
