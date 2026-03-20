-- CrabInventorySync v0.0.2 — main.lua
-- Ground-up rebuild.  Full inventory sync between multiplayer session members
-- via a PowerShell bridge and Node.js relay server.
--
-- Architecture:
--   Lua (this file) writes push.json  → bridge.ps1 POSTs to server
--   bridge.ps1 writes recv.json       ← server returns merged inventory
--   Lua reads recv.json and applies merged inventory to local PlayerState
--
-- Safety strategy:
--   A compound "probe" validates the entire PC → PS → canary chain before
--   every tick.  If the probe fails the tick is skipped entirely (no partial
--   reads, no partial writes).  Individual property reads still use pcall
--   but only as a secondary guard — the probe is the primary gate.
--
-- State machine:  INIT → READY → ACTIVE → SUSPENDED
--   INIT      : startup delay, zero game-object access
--   READY     : probe runs each tick, transitions to ACTIVE when it passes
--   ACTIVE    : full sync loop (read, push, apply)
--   SUSPENDED : objects unsafe (level transition / probe failure),
--               auto-recovers to READY after SUSPEND_MS

-- Uncomment to enable debug keybinds (F5-F8, F10):
-- require("debug")
-- require("debug_perks")

-- ============================================================
-- CONFIGURATION DEFAULTS  (overridden by config.txt)
-- ============================================================
local SERVER_URL        = "https://crab.dudiebug.net"
local SYNC_WEAPON       = true
local SYNC_ABILITY      = true
local SYNC_MELEE        = true
local SYNC_CRYSTALS     = true
local SYNC_HEALTH       = true
local SYNC_WEAPON_MODS  = true
local SYNC_ABILITY_MODS = true
local SYNC_MELEE_MODS   = true
local SYNC_PERKS        = true
local SYNC_RELICS       = true
local SYNC_SLOTS        = true
local CRYSTALS_PROPERTY = "Crystals"

local SCRIPT_DIR = "Mods/CrabInventorySync/Scripts/"
local PUSH_FILE  = SCRIPT_DIR .. "push.json"
local RECV_FILE  = SCRIPT_DIR .. "recv.json"

-- Timing
local POLL_MS       = 500    -- main loop interval
local STARTUP_MS    = 5000   -- wait before first game-object access
local SUSPEND_MS    = 5000   -- pause after level transition / probe failure
local STABLE_TICKS  = 3      -- debounce window for weapon/ability/melee

-- Pickup type enum for ServerIncrementNumInventorySlots
local PICKUP_WEAPON_MOD  = 4
local PICKUP_ABILITY_MOD = 5
local PICKUP_MELEE_MOD   = 6
local PICKUP_PERK        = 7

-- ============================================================
-- CONFIG LOADER
-- ============================================================
local function loadConfig()
    local paths = { SCRIPT_DIR .. "config.txt", "ue4ss/" .. SCRIPT_DIR .. "config.txt" }
    local configPath
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then f:close(); configPath = p; break end
    end
    if not configPath then
        print("[CrabSync] config.txt not found, using defaults.\n")
        return
    end
    for line in io.lines(configPath) do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v then
            if     k == "serverUrl"        then SERVER_URL        = v
            elseif k == "syncWeapon"       then SYNC_WEAPON       = v == "true"
            elseif k == "syncAbility"      then SYNC_ABILITY      = v == "true"
            elseif k == "syncMelee"        then SYNC_MELEE        = v == "true"
            elseif k == "syncCrystals"     then SYNC_CRYSTALS     = v == "true"
            elseif k == "syncHealth"       then SYNC_HEALTH       = v == "true"
            elseif k == "syncWeaponMods"   then SYNC_WEAPON_MODS  = v == "true"
            elseif k == "syncAbilityMods"  then SYNC_ABILITY_MODS = v == "true"
            elseif k == "syncMeleeMods"    then SYNC_MELEE_MODS   = v == "true"
            elseif k == "syncPerks"        then SYNC_PERKS        = v == "true"
            elseif k == "syncRelics"       then SYNC_RELICS       = v == "true"
            elseif k == "syncSlots"        then SYNC_SLOTS        = v == "true"
            elseif k == "crystalsProperty" then CRYSTALS_PROPERTY = v
            end
        end
    end
    print("[CrabSync] Config loaded.\n")
end

-- ============================================================
-- JSON HELPERS
-- ============================================================
local function jstr(s)
    return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
end

local function jstrArr(arr)
    local parts = {}
    for _, v in ipairs(arr) do parts[#parts + 1] = jstr(v) end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function encodeInventory(inv)
    return string.format(
        '{"weapon":%s,"ability":%s,"melee":%s,' ..
        '"crystals":%d,"health":%.3f,"maxHealth":%.3f,' ..
        '"weaponMods":%s,"abilityMods":%s,"meleeMods":%s,' ..
        '"perks":%s,"relics":%s,' ..
        '"slots":{"weaponMods":%d,"abilityMods":%d,"meleeMods":%d,"perks":%d}}',
        jstr(inv.weapon), jstr(inv.ability), jstr(inv.melee),
        math.floor(tonumber(inv.crystals) or 0),
        tonumber(inv.health) or 0, tonumber(inv.maxHealth) or 0,
        jstrArr(inv.weaponMods), jstrArr(inv.abilityMods), jstrArr(inv.meleeMods),
        jstrArr(inv.perks), jstrArr(inv.relics),
        inv.slots.weaponMods, inv.slots.abilityMods,
        inv.slots.meleeMods, inv.slots.perks
    )
end

local function decodeInventory(raw)
    if not raw or raw == "" then return nil end
    -- Strip UTF-8 BOM (PowerShell 5 may write it)
    if raw:sub(1, 3) == "\xEF\xBB\xBF" then raw = raw:sub(4) end
    if raw:sub(1, 1) ~= "{" then return nil end

    local inv = {}
    inv.weapon   = raw:match('"weapon"%s*:%s*"([^"]*)"')   or ""
    inv.ability  = raw:match('"ability"%s*:%s*"([^"]*)"')  or ""
    inv.melee    = raw:match('"melee"%s*:%s*"([^"]*)"')    or ""
    inv.crystals   = tonumber(raw:match('"crystals"%s*:%s*(%d+)'))           or 0
    inv.health     = tonumber(raw:match('"health"%s*:%s*(%-?[%d%.]+)'))      or 0
    inv.maxHealth  = tonumber(raw:match('"maxHealth"%s*:%s*(%-?[%d%.]+)'))   or 0

    local function strArr(key)
        local t = {}
        local s = raw:match('"' .. key .. '"%s*:%s*(%[[^%]]*%])')
        if s then for item in s:gmatch('"([^"]*)"') do t[#t + 1] = item end end
        return t
    end
    inv.weaponMods  = strArr("weaponMods")
    inv.abilityMods = strArr("abilityMods")
    inv.meleeMods   = strArr("meleeMods")
    inv.perks       = strArr("perks")
    inv.relics      = strArr("relics")

    inv.slots = {
        weaponMods  = tonumber(raw:match('"slots"%s*:%s*{[^}]-"weaponMods"%s*:%s*(%d+)'))  or 0,
        abilityMods = tonumber(raw:match('"slots"%s*:%s*{[^}]-"abilityMods"%s*:%s*(%d+)')) or 0,
        meleeMods   = tonumber(raw:match('"slots"%s*:%s*{[^}]-"meleeMods"%s*:%s*(%d+)'))   or 0,
        perks       = tonumber(raw:match('"slots"%s*:%s*{[^}]-"perks"%s*:%s*(%d+)'))       or 0,
    }
    return inv
end

-- ============================================================
-- SAFETY HELPERS
-- ============================================================

--- Returns true if s looks like a valid player name (no null bytes, sane length).
local function isReadable(s)
    return type(s) == "string" and #s > 0 and #s < 64 and not s:find('\0', 1, true)
end

--- Run a shell command and return its trimmed stdout, or nil.
local function shellRead(cmd)
    local ok, h = pcall(io.popen, cmd)
    if not ok or not h then return nil end
    local out = h:read("*a"); h:close()
    if out then out = out:gsub("[%s\r\n]+$", ""):gsub("^[%s\r\n]+", "") end
    return (out and out ~= "") and out or nil
end

--- Safely read a DataAsset's internal name.  Returns "" on any failure.
--- Checks type(da) == "userdata" BEFORE calling :IsValid() or .Name:ToString()
--- because calling methods on a non-userdata (e.g. nil) in UE4SS can trigger
--- native SEH exceptions that pcall cannot catch.
local function daName(da)
    if type(da) ~= "userdata" then return "" end
    local ok1, valid = pcall(function() return da:IsValid() end)
    if not ok1 or not valid then return "" end
    local ok2, name = pcall(function() return da.Name:ToString() end)
    return (ok2 and type(name) == "string") and name or ""
end

--- Locate a DataAsset by internal name in a list returned by FindAllOf.
local function findDA(list, name)
    if not list or name == "" then return nil end
    for _, da in ipairs(list) do
        if daName(da) == name then return da end
    end
    return nil
end

--- Compound safety probe.  Validates the full PC → PS → canary chain.
--- Returns the local player's CrabPS, or nil if anything is suspect.
local function probe()
    local ok1, pc = pcall(FindFirstOf, "CrabPC")
    if not ok1 or type(pc) ~= "userdata" then return nil end

    local ok2, ps = pcall(function() return pc:GetPropertyValue("PlayerState") end)
    if not ok2 or type(ps) ~= "userdata" then return nil end

    -- IsValid() null-checks the underlying C++ pointer before dereferencing.
    -- This catches the multiplayer join race where PS exists as a Lua wrapper
    -- but the C++ object hasn't been replicated yet (null pointer inside).
    local ok3, valid = pcall(function() return ps:IsValid() end)
    if not ok3 or not valid then return nil end

    -- Canary: Crystals is always present on CrabPS and always a number.
    local ok4, canary = pcall(function() return ps:GetPropertyValue(CRYSTALS_PROPERTY) end)
    if not ok4 or type(canary) ~= "number" then return nil end

    return ps
end

--- Read a name→count table from a TArray of structs on ps.
--- propName = "WeaponMods", daField = "WeaponModDA", etc.
local function readSlotCounts(ps, propName, daField)
    local counts = {}
    pcall(function()
        local arr = ps:GetPropertyValue(propName)
        if not arr then return end
        arr:ForEach(function(_, elem)
            local ok, da = pcall(function() return elem:get():GetPropertyValue(daField) end)
            if ok and da then
                local n = daName(da)
                if n ~= "" then counts[n] = (counts[n] or 0) + 1 end
            end
        end)
    end)
    return counts
end

-- ============================================================
-- PEER DETECTION
-- ============================================================
local function getPeers()
    local peers = {}
    local ok1, gs = pcall(FindFirstOf, "CrabGS")
    if not ok1 or type(gs) ~= "userdata" then return peers end
    local ok2, valid = pcall(function() return gs:IsValid() end)
    if not ok2 or not valid then return peers end
    pcall(function()
        local arr = gs:GetPropertyValue("PlayerArray")
        if not arr then return end
        arr:ForEach(function(_, elem)
            pcall(function()
                local ps = elem:get()
                if type(ps) ~= "userdata" then return end
                local okv, v = pcall(function() return ps:IsValid() end)
                if not okv or not v then return end
                local okn, name = pcall(function() return ps:GetPropertyValue("PlayerNamePrivate") end)
                if okn and isReadable(name) then peers[#peers + 1] = name; return end
                local okn2, name2 = pcall(function()
                    local fn = ps:GetPlayerName()
                    return type(fn) == "string" and fn or nil
                end)
                if okn2 and isReadable(name2) then peers[#peers + 1] = name2 end
            end)
        end)
    end)
    return peers
end

-- ============================================================
-- PLAYER NAME
-- ============================================================
local function getPlayerName(ps)
    if ps then
        local ok1, v1 = pcall(function() return ps:GetPropertyValue("PlayerNamePrivate") end)
        if ok1 and isReadable(v1) then return v1 end
        local ok2, v2 = pcall(function()
            local fn = ps:GetPlayerName()
            return type(fn) == "string" and fn or nil
        end)
        if ok2 and isReadable(v2) then return v2 end
    end
    local u = shellRead("echo %USERNAME%")
    if u and u ~= "%USERNAME%" and isReadable(u) then return u end
    local h = shellRead("hostname")
    if isReadable(h) then return h end
    return "UnknownPlayer"
end

-- ============================================================
-- HEALTH COMPONENT ACCESS
-- ============================================================
--- Returns the local player's CrabHC (health component), or nil.
local function getLocalHC(ps)
    if not ps then return nil end
    local ok, pawn = pcall(function() return ps:GetPropertyValue("PawnPrivate") end)
    if not ok or type(pawn) ~= "userdata" then return nil end
    local okv, v = pcall(function() return pawn:IsValid() end)
    if not okv or not v then return nil end

    -- Try direct property access first
    local ok2, hc = pcall(function() return pawn:GetPropertyValue("HC") end)
    if ok2 and type(hc) == "userdata" then
        local ok3, iv = pcall(function() return hc:IsValid() end)
        if ok3 and iv then return hc end
    end

    -- Fallback: scan all CrabHC instances and match by outer == pawn
    local allHCs = FindAllOf("CrabHC")
    if not allHCs then return nil end
    for _, hc in ipairs(allHCs) do
        local okh, vh = pcall(function() return hc:IsValid() end)
        if okh and vh then
            local oko, outer = pcall(function() return hc:GetOuter() end)
            if oko and outer then
                local okeq, eq = pcall(function() return outer == pawn end)
                if okeq and eq then return hc end
            end
        end
    end
    return nil
end

-- ============================================================
-- STATE
-- ============================================================
local STATE_INIT      = "INIT"
local STATE_READY     = "READY"
local STATE_ACTIVE    = "ACTIVE"
local STATE_SUSPENDED = "SUSPENDED"

local state = STATE_INIT

-- Push / recv change detection
local lastPushedJson = ""
local lastRecvJson   = ""

-- Apply pause: skip one apply cycle after a push so bridge can update recv.json
local applyBlocked = false

-- Debounce state for weapon/ability/melee
local pendingW = nil;  local countW = 0;  local stableW = nil
local pendingA = nil;  local countA = 0;  local stableA = nil
local pendingM = nil;  local countM = 0;  local stableM = nil

-- Delta tracking: crystals
local ownCrystals    = nil
local anchorCrystals = nil

-- Delta tracking: health
local ownHealth    = nil
local anchorHealth = nil

-- Delta tracking: mod/perk/relic name→count tables
local ownCounts    = { weaponMods = nil, abilityMods = nil, meleeMods = nil, perks = nil, relics = nil }
local anchorCounts = { weaponMods = nil, abilityMods = nil, meleeMods = nil, perks = nil, relics = nil }

-- Slot count tracking
local lastAppliedSlots = { weaponMods = 0, abilityMods = 0, meleeMods = 0, perks = 0 }

--- Reset all mutable sync state (called on level transition and F9).
local function resetTrackers()
    lastPushedJson = ""
    lastRecvJson   = ""
    applyBlocked   = false
    pendingW = nil;  countW = 0;  stableW = nil
    pendingA = nil;  countA = 0;  stableA = nil
    pendingM = nil;  countM = 0;  stableM = nil
    ownCrystals    = nil;  anchorCrystals = nil
    ownHealth      = nil;  anchorHealth   = nil
    for _, k in ipairs({"weaponMods","abilityMods","meleeMods","perks","relics"}) do
        ownCounts[k]    = nil
        anchorCounts[k] = nil
    end
    lastAppliedSlots = { weaponMods = 0, abilityMods = 0, meleeMods = 0, perks = 0 }
end

local function suspend(reason)
    state = STATE_SUSPENDED
    print("[CrabSync] SUSPENDED: " .. reason .. "\n")
    resetTrackers()
    ExecuteWithDelay(SUSPEND_MS, function()
        if state == STATE_SUSPENDED then
            state = STATE_READY
            print("[CrabSync] → READY (auto-recover)\n")
        end
    end)
end

-- ============================================================
-- INVENTORY READ
-- ============================================================
local function readInventory(ps)
    local inv = {
        weapon = "", ability = "", melee = "",
        crystals = 0, health = 0, maxHealth = 0,
        weaponMods = {}, abilityMods = {}, meleeMods = {},
        perks = {}, relics = {},
        slots = { weaponMods = 0, abilityMods = 0, meleeMods = 0, perks = 0 },
    }

    -- Debounced weapon/ability/melee reads
    if SYNC_WEAPON then
        local cur = ""
        pcall(function() cur = daName(ps:GetPropertyValue("WeaponDA")) end)
        if cur ~= pendingW then
            pendingW = cur; countW = 1
            if stableW == nil then stableW = cur end
        else
            countW = countW + 1
            if countW >= STABLE_TICKS then stableW = cur end
        end
        inv.weapon = stableW or ""
    end

    if SYNC_ABILITY then
        local cur = ""
        pcall(function() cur = daName(ps:GetPropertyValue("AbilityDA")) end)
        if cur ~= pendingA then
            pendingA = cur; countA = 1
            if stableA == nil then stableA = cur end
        else
            countA = countA + 1
            if countA >= STABLE_TICKS then stableA = cur end
        end
        inv.ability = stableA or ""
    end

    if SYNC_MELEE then
        local cur = ""
        pcall(function() cur = daName(ps:GetPropertyValue("MeleeDA")) end)
        if cur ~= pendingM then
            pendingM = cur; countM = 1
            if stableM == nil then stableM = cur end
        else
            countM = countM + 1
            if countM >= STABLE_TICKS then stableM = cur end
        end
        inv.melee = stableM or ""
    end

    -- Crystals (delta-tracked)
    if SYNC_CRYSTALS then
        pcall(function()
            local raw = math.floor(tonumber(ps:GetPropertyValue(CRYSTALS_PROPERTY)) or 0)
            if anchorCrystals == nil then
                ownCrystals    = raw
                anchorCrystals = raw
            else
                local delta = raw - anchorCrystals
                ownCrystals    = math.max(0, (ownCrystals or 0) + delta)
                anchorCrystals = raw
            end
            inv.crystals = ownCrystals
        end)
    end

    -- Health (delta-tracked, via CrabHC)
    if SYNC_HEALTH then
        pcall(function()
            local hc = getLocalHC(ps)
            if not hc then return end
            local hi = hc:GetPropertyValue("HealthInfo")
            if not hi then return end
            local raw = hi.CurrentHealth
            if not raw or raw <= 0 or raw >= 9999 then return end
            if anchorHealth == nil then
                ownHealth    = raw
                anchorHealth = raw
            else
                local delta = raw - anchorHealth
                ownHealth    = math.max(0, (ownHealth or 0) + delta)
                anchorHealth = raw
            end
            inv.health = ownHealth
            local maxHp = nil
            pcall(function() maxHp = hi.CurrentMaxHealth end)
            if maxHp and maxHp > 0 then inv.maxHealth = maxHp end
        end)
    end

    -- Mod/perk/relic arrays (delta-tracked name→count)
    local categories = {
        { key = "weaponMods",  prop = "WeaponMods",  da = "WeaponModDA"  },
        { key = "abilityMods", prop = "AbilityMods", da = "AbilityModDA" },
        { key = "meleeMods",   prop = "MeleeMods",   da = "MeleeModDA"   },
        { key = "perks",       prop = "Perks",       da = "PerkDA"       },
        { key = "relics",      prop = "Relics",      da = "RelicDA"      },
    }
    for _, cat in ipairs(categories) do
        local current = readSlotCounts(ps, cat.prop, cat.da)
        local own    = ownCounts[cat.key]
        local anchor = anchorCounts[cat.key]

        if own == nil then
            -- First read: everything is ours
            own = {}
            for name, count in pairs(current) do own[name] = count end
        else
            -- Delta: only changes since last tick adjust our contribution
            local allNames = {}
            for name in pairs(current) do allNames[name] = true end
            for name in pairs(anchor)  do allNames[name] = true end
            for name in pairs(allNames) do
                local delta = (current[name] or 0) - (anchor[name] or 0)
                if delta ~= 0 then
                    own[name] = math.max(0, (own[name] or 0) + delta)
                end
            end
        end

        ownCounts[cat.key]    = own
        anchorCounts[cat.key] = current

        -- Expand name→count into flat string array
        for name, count in pairs(own) do
            for _ = 1, count do inv[cat.key][#inv[cat.key] + 1] = name end
        end
    end

    -- Slot counts
    if SYNC_SLOTS then
        pcall(function()
            inv.slots.weaponMods  = tonumber(ps:GetPropertyValue("NumWeaponModSlots"))  or 0
            inv.slots.abilityMods = tonumber(ps:GetPropertyValue("NumAbilityModSlots")) or 0
            inv.slots.meleeMods   = tonumber(ps:GetPropertyValue("NumMeleeModSlots"))   or 0
            inv.slots.perks       = tonumber(ps:GetPropertyValue("NumPerkSlots"))        or 0
        end)
    end

    return inv
end

-- ============================================================
-- INVENTORY APPLY
-- ============================================================
local function applyInventory(ps, inv)
    if not ps or not inv then return end

    local weaponDAs     = SYNC_WEAPON       and FindAllOf("CrabWeaponDA")     or {}
    local abilityDAs    = SYNC_ABILITY      and FindAllOf("CrabAbilityDA")    or {}
    local meleeDAs      = SYNC_MELEE        and FindAllOf("CrabMeleeDA")      or {}
    local weaponModDAs  = SYNC_WEAPON_MODS  and FindAllOf("CrabWeaponModDA")  or {}
    local abilityModDAs = SYNC_ABILITY_MODS and FindAllOf("CrabAbilityModDA") or {}
    local meleeModDAs   = SYNC_MELEE_MODS   and FindAllOf("CrabMeleeModDA")   or {}
    local perkDAs       = SYNC_PERKS        and FindAllOf("CrabPerkDA")       or {}
    local relicDAs      = SYNC_RELICS       and FindAllOf("CrabRelicDA")      or {}

    -- Weapon / Ability / Melee via ServerEquipInventory
    if SYNC_WEAPON or SYNC_ABILITY or SYNC_MELEE then
        local appliedW, appliedA, appliedM
        pcall(function()
            local curW = daName(ps:GetPropertyValue("WeaponDA"))
            local curA = daName(ps:GetPropertyValue("AbilityDA"))
            local curM = daName(ps:GetPropertyValue("MeleeDA"))

            local newW = (SYNC_WEAPON  and inv.weapon  ~= "") and inv.weapon  or curW
            local newA = (SYNC_ABILITY and inv.ability ~= "") and inv.ability or curA
            local newM = (SYNC_MELEE   and inv.melee   ~= "") and inv.melee   or curM

            -- Block apply if debounce detects mid-pick (game value ≠ stable value)
            if SYNC_WEAPON  and stableW and curW ~= stableW then newW = curW end
            if SYNC_ABILITY and stableA and curA ~= stableA then newA = curA end
            if SYNC_MELEE   and stableM and curM ~= stableM then newM = curM end

            -- In the lobby the player has no loadout yet; calling ServerEquipInventory
            -- before the inventory system is initialized crashes the game (SEH).
            -- Only apply if the player already has at least one item equipped.
            if curW == "" and curA == "" and curM == "" then return end

            if newW == curW and newA == curA and newM == curM then return end

            local w = findDA(weaponDAs,  newW) or ps:GetPropertyValue("WeaponDA")
            local a = findDA(abilityDAs, newA) or ps:GetPropertyValue("AbilityDA")
            local m = findDA(meleeDAs,   newM) or ps:GetPropertyValue("MeleeDA")
            if w and a and m then
                ps:ServerEquipInventory(w, a, m)
                appliedW = newW; appliedA = newA; appliedM = newM
                print(string.format("[CrabSync] Equip → %s / %s / %s\n", newW, newA, newM))
            end
        end)
        -- Anchor debounce state to what we applied
        if appliedW then pendingW = appliedW; countW = STABLE_TICKS; stableW = appliedW end
        if appliedA then pendingA = appliedA; countA = STABLE_TICKS; stableA = appliedA end
        if appliedM then pendingM = appliedM; countM = STABLE_TICKS; stableM = appliedM end
    end

    -- Crystals
    if SYNC_CRYSTALS and inv.crystals and inv.crystals > 0 then
        pcall(function()
            local total = math.floor(inv.crystals)
            ps:SetPropertyValue(CRYSTALS_PROPERTY, total)
            anchorCrystals = total
        end)
    end

    -- Health
    if SYNC_HEALTH and inv.health and inv.health > 0 and inv.health < 9999 then
        pcall(function()
            local hc = getLocalHC(ps)
            if not hc then return end
            local hi = hc:GetPropertyValue("HealthInfo")
            if not hi then return end
            hi.CurrentHealth = inv.health
            local maxHp = nil
            pcall(function() maxHp = hi.CurrentMaxHealth end)
            anchorHealth = (maxHp and maxHp > 0) and math.min(inv.health, maxHp) or inv.health
            -- NOTE: hc:OnRep_HealthInfo() intentionally omitted.
            -- Calling OnRep functions directly outside the replication context
            -- causes a null-pointer dereference (SEH 0xC0000005) inside the game's
            -- health system when called during or shortly after a multiplayer join.
            -- The property write above is sufficient for sync purposes.
        end)
    end

    -- NOTE: ServerIncrementNumInventorySlots is intentionally NOT called here.
    -- This RPC crashes (ACCESS_VIOLATION) when called before the island inventory
    -- system initializes — which includes the lobby and the early join phase.
    -- Slot counts are still READ and PUSHED to the server so peers see your slot
    -- totals, and fillSlots below will fill whatever slots already exist.
    -- Unlocking new slots is left to the game's normal pickup flow.

    -- Mod/perk/relic arrays: fill existing slots with merged items
    local function fillSlots(propName, daField, daList, sourceNames)
        if #sourceNames == 0 or not daList or #daList == 0 then return end
        pcall(function()
            local arr = ps:GetPropertyValue(propName)
            if not arr then return end
            local idx = 1
            arr:ForEach(function(_, elem)
                if sourceNames[idx] then
                    local okv, valid = pcall(function() return elem:get():IsValid() end)
                    if okv and valid then
                        local da = findDA(daList, sourceNames[idx])
                        if da then
                            pcall(function() elem:get():SetPropertyValue(daField, da) end)
                        end
                    end
                    idx = idx + 1
                end
            end)
        end)
    end

    -- Apply each category and anchor delta trackers to written values
    local applyList = {
        { flag = SYNC_WEAPON_MODS,  prop = "WeaponMods",  da = "WeaponModDA",  list = weaponModDAs,  src = inv.weaponMods,  key = "weaponMods"  },
        { flag = SYNC_ABILITY_MODS, prop = "AbilityMods", da = "AbilityModDA", list = abilityModDAs, src = inv.abilityMods, key = "abilityMods" },
        { flag = SYNC_MELEE_MODS,   prop = "MeleeMods",   da = "MeleeModDA",   list = meleeModDAs,   src = inv.meleeMods,   key = "meleeMods"   },
        { flag = SYNC_PERKS,        prop = "Perks",       da = "PerkDA",       list = perkDAs,       src = inv.perks,       key = "perks"       },
        { flag = SYNC_RELICS,       prop = "Relics",      da = "RelicDA",      list = relicDAs,      src = inv.relics,      key = "relics"      },
    }
    for _, entry in ipairs(applyList) do
        if entry.flag then
            fillSlots(entry.prop, entry.da, entry.list, entry.src)
            -- Anchor to what we intended to write (not a re-read, which may lag by 1 tick)
            local written = {}
            for _, name in ipairs(entry.src) do
                written[name] = (written[name] or 0) + 1
            end
            anchorCounts[entry.key] = written
        end
    end
end

-- ============================================================
-- PUSH / APPLY IPC
-- ============================================================
local function pushIfChanged(ps)
    local invJson = encodeInventory(readInventory(ps))
    if invJson == lastPushedJson then return end

    local peers = getPeers()
    local payload = '{"peers":' .. jstrArr(peers) .. ',"inventory":' .. invJson .. '}'
    local f = io.open(PUSH_FILE, "w")
    if f then
        f:write(payload)
        f:close()
        lastPushedJson = invJson
        applyBlocked   = true   -- pause apply for 1 tick so bridge can update recv.json
        print("[CrabSync] Pushed.\n")
    end
end

local function applyIfChanged(ps)
    -- Apply pause: skip this tick if we just pushed
    if applyBlocked then
        applyBlocked = false
        return
    end

    local f = io.open(RECV_FILE, "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if raw == "" or raw == lastRecvJson then return end

    lastRecvJson = raw
    local inv = decodeInventory(raw)
    if not inv then return end

    applyInventory(ps, inv)
    print("[CrabSync] Applied merged inventory.\n")
end

-- ============================================================
-- AUTO-LAUNCH BRIDGE
-- ============================================================
local function autoLaunchBridge()
    local vbsPath = SCRIPT_DIR .. "autolaunch.vbs"
    local lines = {
        'Dim fso : Set fso = CreateObject("Scripting.FileSystemObject")',
        'Dim scriptDir : scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)',
        'Dim bridgeDir : bridgeDir = fso.GetParentFolderName(scriptDir)',
        'Dim bridgePath : bridgePath = bridgeDir & "\\bridge.ps1"',
        'Dim sh : Set sh = CreateObject("WScript.Shell")',
        'Dim wmi, procs, proc, running',
        'running = False',
        'On Error Resume Next',
        'Set wmi = GetObject("winmgmts:")',
        'Set procs = wmi.ExecQuery("SELECT * FROM Win32_Process WHERE Name = \'powershell.exe\'")',
        'If Not IsNull(procs) And Not IsEmpty(procs) Then',
        '    For Each proc In procs',
        '        If InStr(proc.CommandLine, "bridge.ps1") > 0 Then running = True',
        '    Next',
        'End If',
        'On Error GoTo 0',
        'If running Then WScript.Quit',
        'Dim playerName : playerName = sh.ExpandEnvironmentStrings("%USERNAME%")',
        'sh.CurrentDirectory = bridgeDir',
        'sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File """ & bridgePath & """ ' .. SERVER_URL .. ' " & playerName & "", 1, False',
    }
    local f = io.open(vbsPath, "w")
    if not f then
        print("[CrabSync] Could not write autolaunch.vbs — launch bridge.ps1 manually.\n")
        return
    end
    f:write(table.concat(lines, "\r\n") .. "\r\n")
    f:close()
    local vbsWin = vbsPath:gsub("/", "\\")
    os.execute('wscript //nologo "' .. vbsWin .. '"')
    print("[CrabSync] Bridge launched.\n")
end

-- ============================================================
-- MAIN TICK LOOP
-- ============================================================
local function tick()
    if state == STATE_INIT then
        -- waiting for startup delay; do nothing
        goto reschedule
    end

    if state == STATE_READY then
        local ps = probe()
        if ps then
            state = STATE_ACTIVE
            print("[CrabSync] → ACTIVE\n")
        end
        goto reschedule
    end

    if state == STATE_ACTIVE then
        local ps = probe()
        if not ps then
            suspend("probe failed")
            goto reschedule
        end

        -- Read + push every tick (500ms polling — near-real-time, no hooks needed)
        pushIfChanged(ps)

        -- Apply recv.json only when the pawn is spawned and valid.
        -- RPCs (ServerEquipInventory, ServerIncrementNumInventorySlots) and direct
        -- OnRep calls crash with ACCESS_VIOLATION if the game's inventory/health
        -- systems haven't finished initializing post-join (pawn not yet spawned).
        local pawnOk, pawn = pcall(function() return ps:GetPropertyValue("PawnPrivate") end)
        if pawnOk and type(pawn) == "userdata" then
            local pvOk, pawnValid = pcall(function() return pawn:IsValid() end)
            if pvOk and pawnValid then
                applyIfChanged(ps)
            end
        end
    end

    -- STATE_SUSPENDED: do nothing, auto-recover timer handles transition

    ::reschedule::
    ExecuteWithDelay(POLL_MS, tick)
end

-- ============================================================
-- HOOKS
-- ============================================================
loadConfig()
autoLaunchBridge()

-- NOTE: No RegisterHook calls are used intentionally.
-- OnRep hooks on CrabPS fire for ALL players' PlayerStates during multiplayer join
-- (replication storm), not just the local player's. UE4SS crashes (SEH 0xe06d7363)
-- marshaling partially-initialized PS objects from other players into Lua userdata.
-- pcall() cannot catch native SEH exceptions — they kill the GameThread.
-- Solution: pure 500ms polling via the tick loop. pushIfChanged() only writes
-- push.json when inventory actually changes, so bandwidth is unchanged.
-- Level transitions are handled by probe() failure → suspend() → auto-recover.

-- F9: force immediate full resync
RegisterKeyBind(Key.F9, function()
    resetTrackers()
    if state == STATE_SUSPENDED then
        state = STATE_READY
    end
    print("[CrabSync] Manual resync forced (F9).\n")
end)

-- Start the tick loop after startup delay
ExecuteWithDelay(STARTUP_MS, function()
    state = STATE_READY
    print("[CrabSync] → READY (startup delay complete)\n")
    tick()
end)

print(string.format(
    "[CrabSync] v0.0.2 loaded. First sync in %.1f s, then every %d ms. Press F9 to force.\n",
    STARTUP_MS / 1000, POLL_MS
))
