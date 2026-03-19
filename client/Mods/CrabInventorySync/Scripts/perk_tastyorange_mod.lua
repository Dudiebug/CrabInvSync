-- perk_tastyorange_mod.lua
-- Gives TastyOrange a custom "+3% damage per weapon mod owned" behavior.
--
-- HOW IT WORKS:
--   No native PerkType exists for "counts weapon mods", so we use
--   PerkType=72 (Collector) as a C++ host and trick it with math:
--
--     Collector formula:  damage_bonus = BaseBuff × perkCount
--     We want:            damage_bonus = modCount  × DAMAGE_PER_MOD
--     Therefore:          BaseBuff     = modCount  × DAMAGE_PER_MOD / perkCount
--
--   Updated every TICK_MS so it stays accurate as you pick up / lose items.
--   This change is local only — DataAssets are per-process, no sync needed.

local DAMAGE_PER_MOD    = 3.0   -- % per weapon mod (change this to adjust scaling)
local PERK_TYPE_HOST    = 72    -- Collector: game computes BaseBuff × perkCount
local TICK_MS           = 500   -- how often to recalculate (ms)

-- ──────────────────────────────────────────────────────────────────────────────
-- Helpers (self-contained so this file doesn't depend on main.lua load order)
-- ──────────────────────────────────────────────────────────────────────────────

local tastyDA   = nil   -- cached DA_Perk_TastyOrange reference
local ptSet     = false -- true once PerkType has been written

local function findTastyDA()
    -- Return cached if still valid
    if tastyDA then
        local ok, v = pcall(function() return tastyDA:IsValid() end)
        if ok and v then return tastyDA end
        tastyDA = nil
        ptSet   = false
    end
    local all = FindAllOf("CrabPerkDA")
    if not all then return nil end
    for _, da in ipairs(all) do
        local ok, n = pcall(function() return da:GetFullName() end)
        if ok and n and tostring(n):lower():find("tastyorange") then
            tastyDA = da
            return da
        end
    end
    return nil
end

-- Count elements in a TArray on a UObject without crashing on struct arrays.
-- ForEach callback signature: (index, element) — we just count.
local function countArr(obj, propName)
    local n = 0
    pcall(function()
        local arr = obj:GetPropertyValue(propName)
        if arr then arr:ForEach(function() n = n + 1 end) end
    end)
    return n
end

local function getLocalPS()
    local pc = FindFirstOf("CrabPC")
    if not pc then return nil end
    local okv = pcall(function() return pc:IsValid() end)
    if not okv then return nil end
    local ok, ps = pcall(function() return pc:GetPropertyValue("PlayerState") end)
    if not ok or not ps then return nil end
    local okps = pcall(function() return ps:IsValid() end)
    return okps and ps or nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Main tick
-- ──────────────────────────────────────────────────────────────────────────────

local function tick()
    local da = findTastyDA()
    if not da then
        -- DA not loaded yet — keep trying
        ExecuteWithDelay(TICK_MS, tick)
        return
    end

    -- Step 1: Set PerkType = Collector once (C++ host behavior).
    if not ptSet then
        local ok, err = pcall(function()
            da:SetPropertyValue("PerkType", PERK_TYPE_HOST)
        end)
        if ok then
            ptSet = true
            print("[TastyMod] PerkType → 72 (Collector host). Now computing BaseBuff dynamically.\n")
        else
            print("[TastyMod] Could not set PerkType: " .. tostring(err) .. "\n")
        end
    end

    -- Step 2: Recalculate BaseBuff = modCount × DAMAGE_PER_MOD / perkCount.
    local ps = getLocalPS()
    if ps then
        local modCount  = countArr(ps, "WeaponMods")
        local perkCount = countArr(ps, "Perks")

        -- TastyOrange only matters if actually equipped (perkCount ≥ 1).
        -- Dividing by zero is also bad, so guard both.
        if perkCount > 0 then
            local newBuff = (modCount * DAMAGE_PER_MOD) / perkCount
            pcall(function() da:SetPropertyValue("BaseBuff", newBuff) end)
        end
    end

    ExecuteWithDelay(TICK_MS, tick)
end

-- Short initial delay so DataAssets finish streaming before the first scan.
ExecuteWithDelay(500, tick)

print("[TastyMod] Loaded — TastyOrange: +" .. DAMAGE_PER_MOD .. "% damage per weapon mod owned.\n")
