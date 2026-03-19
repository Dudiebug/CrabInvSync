-- debug_perks.lua
-- F6 = scan ALL CrabPerkDA objects → print name + PerkType + BaseBuff
-- F7 = dump CrabPS scalar properties (looking for kill counter)
-- Output goes to UE4SS.log.

local function safeName(obj)
    local ok, n = pcall(function() return obj:GetFullName() end)
    return (ok and n ~= nil) and tostring(n) or "(no name)"
end

-- ─── F6: Scan every CrabPerkDA for PerkType + BaseBuff ───────────────────────
RegisterKeyBind(Key.F6, function()
    print("[PerkDump] === Scanning ALL CrabPerkDA objects ===\n")

    local allPerks = FindAllOf("CrabPerkDA")
    if not allPerks then
        print("[PerkDump] No CrabPerkDA objects found!\n")
        return
    end

    print("[PerkDump] Found " .. #allPerks .. " DataAssets\n")

    for _, da in ipairs(allPerks) do
        local name = safeName(da)

        local okT, perkType = pcall(function() return da:GetPropertyValue("PerkType") end)
        local pt = (okT and perkType ~= nil) and tostring(perkType) or "?"

        local okB, baseBuff = pcall(function() return da:GetPropertyValue("BaseBuff") end)
        local bb = (okB and type(baseBuff) == "number") and tostring(baseBuff) or "?"

        print("[PerkDump]  PerkType=" .. pt .. "  BaseBuff=" .. bb .. "  " .. name .. "\n")
    end

    print("[PerkDump] Done.\n")
end)

-- ─── F7: Dump CrabPS properties looking for kill / stack counters ─────────────
RegisterKeyBind(Key.F7, function()
    print("[PerkDump] === CrabPS property scan ===\n")

    local pc = FindFirstOf("CrabPC")
    if not pc then print("[PerkDump] No CrabPC\n"); return end
    local ok, ps = pcall(function() return pc:GetPropertyValue("PlayerState") end)
    if not ok or not ps then print("[PerkDump] No PlayerState\n"); return end

    -- Candidate property names for kill/stack tracking on the player state
    local props = {
        -- Kill / elimination counters
        "KillCount", "KillCountThisIsland", "IslandKillCount",
        "EnemiesKilled", "EliminationCount", "TotalKills", "Eliminations",
        "EnemiesKilledThisIsland", "KillsThisIsland", "IslandEliminations",
        "TastyOrangeCount", "TastyOrangeKills", "PerkKillCount",
        -- Weapon mod count
        "WeaponModCount", "NumWeaponMods", "WeaponModLevel",
        "TotalWeaponModLevels", "WeaponModTotal",
        -- Perk count
        "PerkCount", "NumPerks", "TotalPerkLevels", "PerkLevel",
        -- Generic stack / buff counters
        "StackCount", "BuffStacks", "PerkStacks",
        -- Crystal / misc
        "Crystals", "TotalCrystals",
    }

    for _, p in ipairs(props) do
        local okv, v = pcall(function() return ps:GetPropertyValue(p) end)
        if okv and v ~= nil then
            local tv = type(v)
            if tv == "number" or tv == "boolean" or tv == "string" then
                print("[PerkDump]   " .. p .. " = " .. tostring(v) .. "\n")
            else
                -- userdata: try GetFullName
                local ok2, n = pcall(function() return v:GetFullName() end)
                if ok2 and n ~= nil then
                    -- it's an object/enum — still print it
                    print("[PerkDump]   " .. p .. " = OBJECT: " .. tostring(n) .. "\n")
                end
                -- silent skip for null-proxy USERDATA (missing props)
            end
        end
    end

    print("[PerkDump] Done.\n")

    -- ── Also scan CrabHC / HealthInfo struct for the MaxHealth field name ──
    print("[PerkDump] === CrabHC / HealthInfo property scan ===\n")

    local pawn
    pcall(function() pawn = ps:GetPropertyValue("PawnPrivate") end)
    if not pawn then print("[PerkDump] No pawn found\n"); return end

    local hc
    pcall(function() hc = pawn:GetPropertyValue("HC") end)
    if not hc then print("[PerkDump] No HC component found\n"); return end

    -- Try HealthInfo struct field names for max health.
    local hi
    pcall(function() hi = hc:GetPropertyValue("HealthInfo") end)
    if hi then
        local hiFields = {
            "MaxHealth", "BaseMaxHealth", "MaxHP", "MaxHitPoints",
            "CurrentHealth", "Health", "HP", "HitPoints",
            "MaximumHealth", "HealthMax", "MaxHealthPoints",
        }
        print("[PerkDump] HealthInfo struct fields:\n")
        for _, f in ipairs(hiFields) do
            local okv, v = pcall(function() return hi[f] end)
            if okv and v ~= nil and type(v) == "number" then
                print("[PerkDump]   hi." .. f .. " = " .. tostring(v) .. "\n")
            end
        end
    else
        print("[PerkDump] Could not get HealthInfo from HC\n")
    end

    -- Try direct HC component properties for max health.
    local hcProps = {
        "MaxHealth", "BaseMaxHealth", "MaxHP", "CurrentHealth",
        "MaximumHealth", "HealthMax", "DefaultMaxHealth",
    }
    print("[PerkDump] CrabHC direct properties:\n")
    for _, p in ipairs(hcProps) do
        local okv, v = pcall(function() return hc:GetPropertyValue(p) end)
        if okv and v ~= nil then
            local tv = type(v)
            if tv == "number" or tv == "boolean" or tv == "string" then
                print("[PerkDump]   hc." .. p .. " = " .. tostring(v) .. "\n")
            end
        end
    end

    print("[PerkDump] HC scan done.\n")
end)

print("[PerkDump] Loaded — F6 = scan all perk DAs | F7 = scan PS + HC counters.\n")
