-- Uncomment the line below to enable debug keybinds (F6/F7/F8). Remove when done.
-- require("debug")
-- require("debug_perks")
-- require("perk_tastyorange_mod")

-- CrabInventorySync - main.lua
-- Syncs inventory between all players in a multiplayer session via a PowerShell bridge.
--
-- HOW IT WORKS:
--   1. All players install this mod folder and set roomCode in config.txt.
--   2. On mod load the bridge (bridge.ps1) is auto-launched as a PowerShell window.
--   3. Every 500 ms the mod checks for inventory changes and writes push.json.
--   4. The bridge detects the file change and POSTs it to the server.
--   5. The server merges all inventories and returns the result to each bridge.
--   6. The bridge writes the merged inventory to recv.json.
--   7. Every player reads recv.json and applies the merged inventory to their own character.
--      No "host" designation is needed — each client handles itself.
--
-- LIMITATIONS:
--   - Mod slot counts are fixed by what each player already has; we can swap items
--     within existing slots but cannot add new slots (UE4 TArray limitation via UE4SS).
--   - Crystals property name is guessed; adjust crystalsProperty in config.txt if needed.
--   - PowerShell must be available (built into Windows 10/11 — no extra install needed).
--
-- REQUIRES: UE4SS 3.x, Windows 10 or 11

-- ============================================================
-- CONFIGURATION DEFAULTS (overridden by config.txt)
-- ============================================================
local SERVER_URL = "https://crab.dudiebug.net"
local ROOM_CODE  = "default"
-- Which items to sync (all true by default)
local SYNC_WEAPON        = true
local SYNC_ABILITY       = true
local SYNC_MELEE         = true
local SYNC_CRYSTALS      = true
local SYNC_WEAPON_MODS   = true
local SYNC_ABILITY_MODS  = true
local SYNC_MELEE_MODS    = true
local SYNC_PERKS         = true
local SYNC_RELICS        = true
local SYNC_HEALTH        = true
local SYNC_SLOTS         = true
-- Internal property name for crystals on CrabPS (adjust if values read as 0)
local CRYSTALS_PROPERTY  = "Crystals"
-- Shared secret sent with every push to keep the server endpoint private.
local ROOM_PASSWORD      = "4982904"

local SCRIPT_DIR_PRIMARY   = "Mods/CrabInventorySync/Scripts/"
local SCRIPT_DIR_SECONDARY = "ue4ss/Mods/CrabInventorySync/Scripts/"

-- File-based IPC with bridge.ps1.
-- Lua writes push.json  → bridge detects change and sends to server via WebSocket.
-- Bridge writes recv.json ← server broadcasts merged inventory back.
local PUSH_FILE = SCRIPT_DIR_PRIMARY .. "push.json"
local RECV_FILE = SCRIPT_DIR_PRIMARY .. "recv.json"

-- ============================================================
-- CONFIG LOADING
-- ============================================================
local function loadConfig()
    local configPath = nil
    for _, path in ipairs({ SCRIPT_DIR_PRIMARY .. "config.txt", SCRIPT_DIR_SECONDARY .. "config.txt" }) do
        local f = io.open(path, "r")
        if f then
            f:close()
            configPath = path
            break
        end
    end

    if not configPath then
        print("[CrabInventorySync] config.txt not found, using defaults.\n")
        return
    end

    for line in io.lines(configPath) do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and value then
            if     key == "serverUrl"        then SERVER_URL           = value
            elseif key == "roomCode"         then ROOM_CODE            = value
            elseif key == "syncWeapon"       then SYNC_WEAPON          = (value == "true")
            elseif key == "syncAbility"      then SYNC_ABILITY         = (value == "true")
            elseif key == "syncMelee"        then SYNC_MELEE           = (value == "true")
            elseif key == "syncCrystals"     then SYNC_CRYSTALS        = (value == "true")
            elseif key == "syncWeaponMods"   then SYNC_WEAPON_MODS     = (value == "true")
            elseif key == "syncAbilityMods"  then SYNC_ABILITY_MODS    = (value == "true")
            elseif key == "syncMeleeMods"    then SYNC_MELEE_MODS      = (value == "true")
            elseif key == "syncPerks"        then SYNC_PERKS           = (value == "true")
            elseif key == "syncRelics"       then SYNC_RELICS          = (value == "true")
            elseif key == "syncHealth"       then SYNC_HEALTH          = (value == "true")
            elseif key == "syncSlots"        then SYNC_SLOTS           = (value == "true")
            elseif key == "crystalsProperty" then CRYSTALS_PROPERTY    = value
            elseif key == "roomPassword"     then ROOM_PASSWORD        = value
            end
        end
    end

    print("[CrabInventorySync] Config loaded:\n")
    print("  roomCode  = " .. ROOM_CODE .. "\n")
end

-- ============================================================
-- JSON HELPERS
-- ============================================================
local function jsonStr(s)
    return '"' .. tostring(s)
        :gsub('\\', '\\\\')
        :gsub('"',  '\\"')
        :gsub('\n', '\\n')
        :gsub('\r', '\\r')
        :gsub('\t', '\\t')
        :gsub('\b', '\\b')
        :gsub('\f', '\\f')
        .. '"'
end

local function jsonStrArray(arr)
    local parts = {}
    for _, v in ipairs(arr) do table.insert(parts, jsonStr(v)) end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- Encode an array of inventory items as JSON objects {n,l,a}.
-- n = DA name, l = level (ByteProperty, 1-255), a = AccumulatedBuff (float).
-- This is the new payload format for weaponMods/abilityMods/meleeMods/perks/relics.
local function jsonItemArray(items)
    local parts = {}
    for _, item in ipairs(items) do
        table.insert(parts, string.format('{"n":%s,"l":%d,"a":%.4f}',
            jsonStr(item.name or ""),
            math.max(1, math.floor(tonumber(item.level) or 1)),
            tonumber(item.accum) or 0.0))
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- Decode an array of inventory items from the JSON produced by jsonItemArray.
-- Also accepts the legacy flat-string format ["name1","name2"] for backward compat.
local function parseItemArray(json, key)
    local t = {}
    -- Locate the array value for this key.
    local keyPat = '"' .. key .. '"%s*:%s*'
    local ks = json:find(keyPat)
    if not ks then return t end
    local arrayOpen = json:find('%[', ks)
    if not arrayOpen then return t end
    -- Peek at first non-whitespace character after '[' to detect format.
    local firstChar = json:match('^%s*(.)', arrayOpen + 1)
    if firstChar == '{' then
        -- New format: [{...},{...}]
        local pos = arrayOpen + 1
        while true do
            local closeBracket = json:find('%]', pos)
            local objS = json:find('{', pos)
            if not objS or (closeBracket and closeBracket < objS) then break end
            local objE = json:find('}', objS)
            if not objE then break end
            local obj = json:sub(objS, objE)
            local name  = obj:match('"n"%s*:%s*"([^"]*)"')
            local level = tonumber(obj:match('"l"%s*:%s*(%d+)'))   or 1
            local accum = tonumber(obj:match('"a"%s*:%s*(%-?[%d%.]+)')) or 0.0
            if name and name ~= "" then
                table.insert(t, { name=name, level=level, accum=accum })
            end
            pos = objE + 1
        end
    else
        -- Legacy format: ["name1","name2"]
        local raw = json:match('"' .. key .. '"%s*:%s*(%[[^%]]*%])')
        if raw then
            for name in raw:gmatch('"([^"]*)"') do
                table.insert(t, { name=name, level=1, accum=0.0 })
            end
        end
    end
    return t
end

local function encodeInventory(inv)
    local sl = inv.slots or { weaponMods=0, abilityMods=0, meleeMods=0, perks=0 }
    return string.format(
        '{"weapon":%s,"ability":%s,"melee":%s,"crystals":%d,' ..
        '"health":%.3f,"maxHealth":%.3f,' ..
        '"weaponMods":%s,"abilityMods":%s,"meleeMods":%s,"perks":%s,"relics":%s,' ..
        '"slots":{"weaponMods":%d,"abilityMods":%d,"meleeMods":%d,"perks":%d}}',
        jsonStr(inv.weapon),
        jsonStr(inv.ability),
        jsonStr(inv.melee),
        math.floor(tonumber(inv.crystals) or 0),
        tonumber(inv.health)    or 0.0,
        tonumber(inv.maxHealth) or 0.0,
        jsonItemArray(inv.weaponMods),
        jsonItemArray(inv.abilityMods),
        jsonItemArray(inv.meleeMods),
        jsonItemArray(inv.perks),
        jsonItemArray(inv.relics),
        math.floor(tonumber(sl.weaponMods) or 0),
        math.floor(tonumber(sl.abilityMods) or 0),
        math.floor(tonumber(sl.meleeMods)  or 0),
        math.floor(tonumber(sl.perks)      or 0)
    )
end

-- Minimal JSON decoder for the specific inventory structure we produce.
-- Handles both the new item-object format and the legacy flat-string format.
local function decodeInventory(json)
    if not json or json == "" then return nil end
    -- Strip UTF-8 BOM (0xEF 0xBB 0xBF) if present — PowerShell 5 may write it.
    if json:sub(1,3) == "\xEF\xBB\xBF" then json = json:sub(4) end
    if json:sub(1,1) ~= "{" then return nil end
    local inv = {}
    inv.weapon    = json:match('"weapon"%s*:%s*"([^"]*)"')  or ""
    inv.ability   = json:match('"ability"%s*:%s*"([^"]*)"') or ""
    inv.melee     = json:match('"melee"%s*:%s*"([^"]*)"')   or ""
    inv.crystals  = tonumber(json:match('"crystals"%s*:%s*(%d+)'))          or 0
    inv.health    = tonumber(json:match('"health"%s*:%s*(%-?[%d%.]+)'))     or 0.0
    inv.maxHealth = tonumber(json:match('"maxHealth"%s*:%s*(%-?[%d%.]+)'))  or 0.0

    inv.weaponMods  = parseItemArray(json, "weaponMods")
    inv.abilityMods = parseItemArray(json, "abilityMods")
    inv.meleeMods   = parseItemArray(json, "meleeMods")
    inv.perks       = parseItemArray(json, "perks")
    inv.relics      = parseItemArray(json, "relics")

    -- Parse slots sub-object.
    local slotsBlock = json:match('"slots"%s*:%s*(%b{})')
    inv.slots = {
        weaponMods  = tonumber(slotsBlock and slotsBlock:match('"weaponMods"%s*:%s*(%d+)'))  or 0,
        abilityMods = tonumber(slotsBlock and slotsBlock:match('"abilityMods"%s*:%s*(%d+)')) or 0,
        meleeMods   = tonumber(slotsBlock and slotsBlock:match('"meleeMods"%s*:%s*(%d+)'))   or 0,
        perks       = tonumber(slotsBlock and slotsBlock:match('"perks"%s*:%s*(%d+)'))       or 0,
    }
    return inv
end

-- ============================================================
-- DA HELPERS
-- ============================================================
local function getDAName(da)
    if not da then return "" end
    local ok, v = pcall(function() return da:IsValid() end)
    if not ok or not v then return "" end
    local ok2, name = pcall(function() return da.Name:ToString() end)
    return (ok2 and name) and name or ""
end

local function findDA(daList, name)
    if not daList or name == "" then return nil end
    for _, da in ipairs(daList) do
        local ok, v = pcall(function() return da:IsValid() end)
        if ok and v then
            local ok2, n = pcall(function() return da.Name:ToString() end)
            if ok2 and n == name then return da end
        end
    end
    return nil
end

-- Read all mod/perk/relic slots on ps and return a name→count table.
-- Called by readInventory (delta computation) and applyInventory (anchoring).
local function computeSlotCounts(ps, propName, daField)
    local counts = {}
    pcall(function()
        local arr = ps:GetPropertyValue(propName)
        if not arr then return end
        arr:ForEach(function(_, elem)
            if elem:get():IsValid() then
                local ok, da = pcall(function() return elem:get()[daField] end)
                if ok and da then
                    local name = getDAName(da)
                    if name ~= "" then
                        counts[name] = (counts[name] or 0) + 1
                    end
                end
            end
        end)
    end)
    return counts
end

-- Read all mod/perk/relic slots on ps and return a sorted array of item objects
-- { name=string, level=int, accum=float }.
-- Reads InventoryInfo.Level and InventoryInfo.AccumulatedBuff directly from each
-- TArray struct element so the push payload includes per-item level data.
local function readItemArray(ps, propName, daField)
    local items = {}
    pcall(function()
        local arr = ps:GetPropertyValue(propName)
        if not arr then return end
        arr:ForEach(function(_, elem)
            if not elem:get():IsValid() then return end
            local okda, da = pcall(function() return elem:get()[daField] end)
            if not okda or not da then return end
            local name = getDAName(da)
            if name == "" then return end
            local level, accum = 1, 0.0
            pcall(function()
                local info = elem:get().InventoryInfo
                if info then
                    level = math.max(1, math.floor(tonumber(info.Level) or 1))
                    accum = tonumber(info.AccumulatedBuff) or 0.0
                end
            end)
            table.insert(items, { name=name, level=level, accum=accum })
        end)
    end)
    -- Sort by name so the encoded JSON is deterministic regardless of TArray order.
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

-- Returns an empty array — the server merges all active players in the room.
-- (Previously returned display names via getPlayerName/shellRead, which spawned
-- a cmd.exe process for every player every 500 ms and crashed the bridge.)
local function getSessionPlayers()
    return {}
end

-- ============================================================
-- PLAYER STATE HELPERS
-- ============================================================

local function getLocalPS()
    local pc = FindFirstOf("CrabPC")
    if not pc then return nil end
    local ok, v = pcall(function() return pc:IsValid() end)
    if not ok or not v then return nil end
    -- Use GetPropertyValue rather than direct property access (pc.PlayerState).
    -- Direct access hands UE4SS a raw pointer that may be mid-destruction during
    -- a level transition; GetPropertyValue goes through UE4SS's own validity layer
    -- and avoids the native C++ exception that pcall cannot catch.
    local ok2, ps = pcall(function() return pc:GetPropertyValue("PlayerState") end)
    if not ok2 or not ps then return nil end
    local ok3, v3 = pcall(function() return ps:IsValid() end)
    return (ok3 and v3) and ps or nil
end

-- Returns the local player's CrabHC (health component), or nil.
-- Health lives on CrabHC.HealthInfo.CurrentHealth — NOT on CrabPS.
-- We must match by pawn ownership; FindAllOf("CrabHC") returns enemies too.
local function getLocalHC()
    local ps = getLocalPS()
    if not ps then return nil end

    -- Get pawn from player state (more direct than going through PC).
    local ok, pawn = pcall(function() return ps:GetPropertyValue("PawnPrivate") end)
    if not ok or not pawn then return nil end
    local okv, v = pcall(function() return pawn:IsValid() end)
    if not okv or not v then return nil end

    -- The health component is stored as property "HC" on the pawn (confirmed from
    -- UE4 object dump: CrabHC .../BP_Destructible_HealthRock...:HC).
    local ok2, hc = pcall(function() return pawn:GetPropertyValue("HC") end)
    if ok2 and hc then
        local ok3, iv = pcall(function() return hc:IsValid() end)
        if ok3 and iv then return hc end
    end

    -- Fall back: scan all CrabHC instances and match via outer == pawn.
    -- UE4SS compares UObject userdata by address so == works correctly here.
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

-- No per-mod delta state needed — mod arrays use MAX merge on the server,
-- so pushing the full current slot contents is safe (no feedback loop).

-- ============================================================
-- SET-COMPARISON HELPERS
-- ============================================================
-- Compare two sorted string arrays element-by-element.
-- Used to detect whether a recv payload would actually change the set of mods
-- in a given slot array, vs. merely reflecting UE4 TArray internal reordering.
-- IMPORTANT: both arrays must already be sorted before calling this.
local function arraysEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Return the sorted list of DA names currently stored in a TArray on ps.
-- Used by applyInventory to compare the live game state against the recv payload
-- without being fooled by TArray reordering (which is not a real inventory change).
local function getSortedNamesFromPS(ps, propName, daField)
    local names = {}
    pcall(function()
        local arr = ps:GetPropertyValue(propName)
        if not arr then return end
        arr:ForEach(function(_, elem)
            if elem:get():IsValid() then
                local ok, da = pcall(function() return elem:get()[daField] end)
                if ok and da then
                    local name = getDAName(da)
                    if name ~= "" then table.insert(names, name) end
                end
            end
        end)
    end)
    table.sort(names)
    return names
end

-- Weapon/ability/melee debounce state.
-- The game briefly reports a stale ability during ability use (e.g. Black Hole → Grappling
-- Hook for one tick while the animation plays).  We only promote a new value to "stable"
-- after SLOT_STABLE_TICKS consecutive identical reads, so that flicker never reaches push.json.
-- After an apply the state is anchored so the applied value is not immediately treated as
-- a new change and pushed back (which would start the receive → push → receive loop).
local SLOT_STABLE_TICKS = 4   -- 4 × POLL_INTERVAL_MS = 2.0 s debounce window
                              -- (3 was enough for ability flicker; 4 covers the
                              --  1-2 tick stale-weapon-DA read during chest interaction)
local pendingWeapon  = nil;  local pendingWCount = 0;  local stableWeapon  = nil
local pendingAbility = nil;  local pendingACount = 0;  local stableAbility = nil
local pendingMelee   = nil;  local pendingMCount = 0;  local stableMelee   = nil

-- Lobby equip path can briefly report CurrentHealth/CurrentMaxHealth as 0 for
-- 1-2 polls.  Only suppress zero-health reads for a short, equip-triggered window.
-- This does NOT delay real death outside the equip path.
local EQUIP_HEALTH_ZERO_GRACE_TICKS = 2   -- ticks (recalculated from POLL_INTERVAL_MS below)
local equipHealthZeroReadsRemaining = 0

-- ============================================================
-- INVENTORY READ
-- ============================================================
local function readInventory(ps)
    local inv = {
        weapon = "", ability = "", melee = "",
        crystals = 0, keys = 0, health = 0, maxHealth = 0,
        weaponMods = {}, abilityMods = {}, meleeMods = {}, perks = {}, relics = {},
        slots = { weaponMods=0, abilityMods=0, meleeMods=0, perks=0 }
    }
    if not ps then return inv end
    local okv, valid = pcall(function() return ps:IsValid() end)
    if not okv or not valid then return inv end

    -- Debounced reads for weapon/ability/melee.  A value must be identical for
    -- SLOT_STABLE_TICKS consecutive polls before it is reported in the push payload.
    -- This filters out the 1-tick ability flicker that occurs during ability use.
    -- On first read the initial value is accepted immediately (no delay).
    if SYNC_WEAPON then
        local cur = ""
        pcall(function() cur = getDAName(ps.WeaponDA) end)
        if cur ~= pendingWeapon then
            pendingWeapon = cur;  pendingWCount = 1
            if stableWeapon == nil then stableWeapon = cur end   -- accept initial value immediately
        else
            pendingWCount = pendingWCount + 1
            if pendingWCount >= SLOT_STABLE_TICKS then stableWeapon = cur end
        end
        inv.weapon = stableWeapon or ""
    end
    if SYNC_ABILITY then
        local cur = ""
        pcall(function() cur = getDAName(ps.AbilityDA) end)
        if cur ~= pendingAbility then
            pendingAbility = cur;  pendingACount = 1
            if stableAbility == nil then stableAbility = cur end
        else
            pendingACount = pendingACount + 1
            if pendingACount >= SLOT_STABLE_TICKS then stableAbility = cur end
        end
        inv.ability = stableAbility or ""
    end
    if SYNC_MELEE then
        local cur = ""
        pcall(function() cur = getDAName(ps.MeleeDA) end)
        if cur ~= pendingMelee then
            pendingMelee = cur;  pendingMCount = 1
            if stableMelee == nil then stableMelee = cur end
        else
            pendingMCount = pendingMCount + 1
            if pendingMCount >= SLOT_STABLE_TICKS then stableMelee = cur end
        end
        inv.melee = stableMelee or ""
    end

    pcall(function()
        local raw = math.floor(tonumber(ps:GetPropertyValue(CRYSTALS_PROPERTY)) or 0)
        if lastGameCrystals == nil then
            -- First ever read: everything is ours (no sync has happened yet).
            ownCrystals      = raw
            lastGameCrystals = raw
        else
            -- Only the delta since the last tick (earned / spent) changes our contribution.
            -- Positive delta  = crystals earned in-game → add to ownCrystals.
            -- Negative delta  = crystals spent in-game  → subtract from ownCrystals.
            -- The applied sync total was already baked into lastGameCrystals by
            -- applyInventory, so the next tick's delta for an uneventful tick is 0.
            local delta = raw - lastGameCrystals
            ownCrystals      = math.max(0, (ownCrystals or 0) + delta)
            lastGameCrystals = raw
        end
        inv.crystals = ownCrystals
    end)

    if SYNC_HEALTH then
        pcall(function()
            local hc = getLocalHC()
            if not hc then return end
            local hi = hc:GetPropertyValue("HealthInfo")
            if not hi then return end
            local ignoreHealthZeroThisRead = (equipHealthZeroReadsRemaining > 0)
            -- HealthInfo is a struct: direct field access only (no GetPropertyValue).
            -- Field names from object dump section 5 (CrabHealthInfo):
            --   0x0C  CurrentHealth     - the real live HP value
            --   0x10  CurrentMaxHealth  - effective max HP (BaseMaxHealth * MaxHealthMultiplier)
            -- NOTE: there is NO field named "MaxHealth" on CrabHealthInfo.
            -- Delta-track current HP.
            local raw = hi.CurrentHealth
            if raw and raw > 0 then
                if lastGameHealth == nil then
                    ownHealth      = raw
                    lastGameHealth = raw
                else
                    local delta  = raw - lastGameHealth
                    local newOwn = (ownHealth or 0) + delta
                    if newOwn <= 0 then
                        -- Hard reset while alive (weapon select / round reset), not gradual damage.
                        ownHealth      = raw
                        lastGameHealth = raw
                    else
                        ownHealth      = newOwn
                        lastGameHealth = raw
                    end
                end
            elseif raw == 0 then
                if ignoreHealthZeroThisRead then
                    print("[CrabSync:health] Ignoring transient CurrentHealth=0 during lobby-equip grace.\n")
                else
                    -- Player is dead. Anchor to 0 so respawn delta is counted correctly.
                    ownHealth      = 0
                    lastGameHealth = 0
                end
            end
            -- Always report the last known contribution (never the 0 default).
            if ownHealth then inv.health = ownHealth end

            -- Delta-track max HP with the same re-init guard.
            local maxRaw = hi.CurrentMaxHealth
            if maxRaw and maxRaw > 0 then
                if lastGameMaxHealth == nil then
                    ownMaxHealth      = maxRaw
                    lastGameMaxHealth = maxRaw
                else
                    local maxDelta  = maxRaw - lastGameMaxHealth
                    local newMaxOwn = (ownMaxHealth or 0) + maxDelta
                    if newMaxOwn <= 0 then
                        ownMaxHealth      = maxRaw
                        lastGameMaxHealth = maxRaw
                    else
                        ownMaxHealth      = newMaxOwn
                        lastGameMaxHealth = maxRaw
                    end
                end
            elseif maxRaw == 0 then
                if ignoreHealthZeroThisRead then
                    print("[CrabSync:health] Ignoring transient CurrentMaxHealth=0 during lobby-equip grace.\n")
                else
                    ownMaxHealth      = 0
                    lastGameMaxHealth = 0
                end
            end
            if ownMaxHealth then inv.maxHealth = ownMaxHealth end
            if equipHealthZeroReadsRemaining > 0 then
                equipHealthZeroReadsRemaining = equipHealthZeroReadsRemaining - 1
            end
        end)
    end

    -- Read full item data (name + Level + AccumulatedBuff) from each TArray slot.
    -- readItemArray reads InventoryInfo directly from the struct so Level and
    -- AccumulatedBuff are captured in the push payload.  Results are sorted by name
    -- so the JSON is deterministic regardless of UE4 TArray internal ordering —
    -- this eliminates the false-positive change detection that caused the shuffle bug.
    for _, cat in ipairs({
        { inv="weaponMods",  prop="WeaponMods",  da="WeaponModDA"  },
        { inv="abilityMods", prop="AbilityMods", da="AbilityModDA" },
        { inv="meleeMods",   prop="MeleeMods",   da="MeleeModDA"   },
        { inv="perks",       prop="Perks",       da="PerkDA"       },
        { inv="relics",      prop="Relics",      da="RelicDA"      },
    }) do
        inv[cat.inv] = readItemArray(ps, cat.prop, cat.da)
    end


    if SYNC_SLOTS then
        -- Delta-tracking for slot counts, identical to the crystals / health pattern.
        -- We report only the slots we personally unlocked so the server can SUM
        -- contributions from all players without causing a doubling feedback loop.
        local slotProps = {
            { key="weaponMods",  prop="NumWeaponModSlots"  },
            { key="abilityMods", prop="NumAbilityModSlots" },
            { key="meleeMods",   prop="NumMeleeModSlots"   },
            { key="perks",       prop="NumPerkSlots"       },
        }
        for _, sp in ipairs(slotProps) do
            pcall(function()
                local raw = math.floor(tonumber(ps:GetPropertyValue(sp.prop)) or 0)
                if lastGameSlots[sp.key] == nil then
                    -- First read: treat everything we see as our own contribution.
                    ownSlots[sp.key]      = raw
                    lastGameSlots[sp.key] = raw
                else
                    -- Only positive deltas count as earning new slots in-game.
                    -- Negative deltas (e.g. after a sync write raised the total)
                    -- are ignored so applied totals don't shrink our contribution.
                    local delta = raw - lastGameSlots[sp.key]
                    if delta > 0 then
                        ownSlots[sp.key] = (ownSlots[sp.key] or 0) + delta
                    end
                    lastGameSlots[sp.key] = raw
                end
                inv.slots[sp.key] = ownSlots[sp.key]
            end)
        end
    end

    return inv
end

-- ============================================================
-- INVENTORY APPLY
-- ============================================================
local function applyInventory(ps, inv)
    if not ps or not inv then return end
    local ok, valid = pcall(function() return ps:IsValid() end)
    if not ok or not valid then return end

    local weaponDAs     = SYNC_WEAPON        and FindAllOf("CrabWeaponDA")     or {}
    local abilityDAs    = SYNC_ABILITY       and FindAllOf("CrabAbilityDA")    or {}
    local meleeDAs      = SYNC_MELEE         and FindAllOf("CrabMeleeDA")      or {}
    local weaponModDAs  = SYNC_WEAPON_MODS   and FindAllOf("CrabWeaponModDA")  or {}
    local abilityModDAs = SYNC_ABILITY_MODS  and FindAllOf("CrabAbilityModDA") or {}
    local meleeModDAs   = SYNC_MELEE_MODS    and FindAllOf("CrabMeleeModDA")   or {}
    local perkDAs       = SYNC_PERKS         and FindAllOf("CrabPerkDA")       or {}
    local relicDAs      = SYNC_RELICS        and FindAllOf("CrabRelicDA")      or {}

    if SYNC_WEAPON or SYNC_ABILITY or SYNC_MELEE then
        local appliedWeapon, appliedAbility, appliedMelee
        pcall(function()
            -- Only call ServerEquipInventory if a name actually changed — calling
            -- it unnecessarily resets ammo, fire rate, and other weapon state.
            local curWeapon  = getDAName(ps.WeaponDA)
            local curAbility = getDAName(ps.AbilityDA)
            local curMelee   = getDAName(ps.MeleeDA)
            local newWeapon  = (SYNC_WEAPON  and inv.weapon  ~= "") and inv.weapon  or curWeapon
            local newAbility = (SYNC_ABILITY and inv.ability ~= "") and inv.ability or curAbility
            local newMelee   = (SYNC_MELEE   and inv.melee   ~= "") and inv.melee   or curMelee
            -- Log recv vs game vs debounce-stable on every apply evaluation.
            print(string.format(
                "[CrabSync:apply] recv=(%s|%s|%s)  game=(%s|%s|%s)  stable=(%s|%s|%s)\n",
                inv.weapon or "", inv.ability or "", inv.melee or "",
                curWeapon, curAbility, curMelee,
                stableWeapon or "?", stableAbility or "?", stableMelee or "?"))
            -- If the game's current value differs from the debounce-stable value the
            -- player is mid-pick (debounce window active).  Applying recv here would
            -- revert the just-picked item back to the old server value — block it.
            local blockedW = SYNC_WEAPON  and stableWeapon  ~= nil and curWeapon  ~= stableWeapon
            local blockedA = SYNC_ABILITY and stableAbility ~= nil and curAbility ~= stableAbility
            local blockedM = SYNC_MELEE   and stableMelee   ~= nil and curMelee   ~= stableMelee
            if blockedW then newWeapon  = curWeapon  end
            if blockedA then newAbility = curAbility end
            if blockedM then newMelee   = curMelee   end
            if blockedW or blockedA or blockedM then
                print(string.format(
                    "[CrabSync:apply] BLOCKED debounce: W=%s A=%s M=%s\n",
                    tostring(blockedW), tostring(blockedA), tostring(blockedM)))
            end
            if newWeapon == curWeapon and newAbility == curAbility and newMelee == curMelee then return end
            local weapon  = findDA(weaponDAs,  newWeapon)  or ps.WeaponDA
            local ability = findDA(abilityDAs, newAbility) or ps.AbilityDA
            local melee   = findDA(meleeDAs,   newMelee)   or ps.MeleeDA
            if weapon and ability and melee then
                print(string.format(
                    "[CrabSync:apply] ServerEquipInventory → %s / %s / %s\n",
                    newWeapon, newAbility, newMelee))
                ps:ServerEquipInventory(weapon, ability, melee)
                equipHealthZeroReadsRemaining = EQUIP_HEALTH_ZERO_GRACE_TICKS
                print(string.format("[CrabSync:health] Equip apply detected - suppressing zero-health reads for %d tick(s).\n", EQUIP_HEALTH_ZERO_GRACE_TICKS))
                appliedWeapon  = newWeapon
                appliedAbility = newAbility
                appliedMelee   = newMelee
            end
        end)
        -- Anchor the debounce state to what we just applied.  Without this the next
        -- readInventory sees the applied value as a brand-new arrival, pushes it, and
        -- receives it back — triggering the receive → push → receive loop.
        if appliedWeapon  then pendingWeapon  = appliedWeapon;  pendingWCount = SLOT_STABLE_TICKS; stableWeapon  = appliedWeapon  end
        if appliedAbility then pendingAbility = appliedAbility; pendingACount = SLOT_STABLE_TICKS; stableAbility = appliedAbility end
        if appliedMelee   then pendingMelee   = appliedMelee;   pendingMCount = SLOT_STABLE_TICKS; stableMelee   = appliedMelee   end
    end

    -- Apply the pooled crystal total.  The feedback loop is prevented by the
    -- delta-tracking in readInventory: after this write, lastGameCrystals is set
    -- to the applied value so the very next readInventory sees delta = 0 and does
    -- NOT add the synced total to ownCrystals again.
    --
    -- Guard: only write if the merged total EXCEEDS the current game value.
    -- Writing a stale lower total silently deletes crystals the player earned
    -- mid-combat (example: game=200, stale server=150 → apply reduces to 150).
    -- Exception: current == 0 means fresh load / new run, always apply.
    if SYNC_CRYSTALS and inv.crystals and inv.crystals > 0 then
        pcall(function()
            -- CrabPS.Crystals is UInt32Property (dump §2.1 offset 0x470) — unsigned,
            -- range 0–4,294,967,295.  A pooled server total from many players could exceed
            -- that; clamping prevents a wrap-to-near-zero write that would wipe all crystals.
            local UINT32_MAX = 4294967295
            local total   = math.min(math.floor(inv.crystals), UINT32_MAX)
            local current = math.min(math.floor(tonumber(ps:GetPropertyValue(CRYSTALS_PROPERTY)) or 0), UINT32_MAX)
            -- Always write the merged total, even if it is lower than the current value.
            -- The delta-tracker in readInventory already anchors lastGameCrystals to
            -- whatever we write here, so the very next tick sees delta = 0 and does NOT
            -- re-add the synced total to ownCrystals.  Without this, crystals spent by
            -- another player (or crystals that drop after a player disconnects) would
            -- never propagate — the "only increase" guard silently blocks the write.
            if total ~= current then
                ps:SetPropertyValue(CRYSTALS_PROPERTY, total)
                lastGameCrystals = total   -- anchor: next read delta = 0
                pcall(function() ps:OnRep_Crystals() end)
            end
        end)
    end


    if SYNC_HEALTH and ((inv.health and inv.health > 0) or (inv.maxHealth and inv.maxHealth > 0)) then
        pcall(function()
            local hc = getLocalHC()
            if not hc then return end
            local hi = hc:GetPropertyValue("HealthInfo")
            if not hi then return end

            local didWrite = false

            -- Apply pooled max HP first so the ceiling is raised before current HP.
            -- Server SUMs maxHealth across players (same as current HP), so two players
            -- at 250 maxHP each → everyone gets 500 maxHP applied.
            -- SetPropertyValue on struct fields bypasses engine clamping, so the game
            -- stores exactly what we write — the delta tracker sees 0 next tick.
            local mergedMax = math.floor(tonumber(inv.maxHealth) or 0)
            if mergedMax > 0 then
                local currentMax = 0
                pcall(function() currentMax = math.floor(tonumber(hi.CurrentMaxHealth) or 0) end)
                -- Always write the merged total (not just when increasing).
                -- If a player leaves or dies their maxHealth contribution drops, and that
                -- reduction must propagate to all remaining players.  The anchor below
                -- prevents the read → delta → push → recv → apply feedback loop.
                if mergedMax ~= currentMax then
                    hi.CurrentMaxHealth = mergedMax
                    lastGameMaxHealth   = mergedMax  -- anchor: next read delta = 0
                    didWrite = true
                end
            end

            -- Apply pooled current HP.
            -- We do NOT clamp to maxHP — the design is to pool both totals together,
            -- so 2 × 250 HP players should each see 500/500, not 250/500.
            -- Always write the merged total so damage taken by any player reduces
            -- everyone's displayed HP — "4 as 1, one takes damage all feel it".
            local mergedHP = math.floor(tonumber(inv.health) or 0)
            if mergedHP > 0 then
                local currentHP = 0
                pcall(function() currentHP = math.floor(tonumber(hi.CurrentHealth) or 0) end)
                if mergedHP ~= currentHP then
                    hi.CurrentHealth = mergedHP
                    lastGameHealth   = mergedHP  -- anchor: next read delta = 0
                    didWrite = true
                end
            end

            if didWrite then
                pcall(function() hc:OnRep_HealthInfo() end)
            end
        end)
    end

    -- Smart slot writer: two-pass algorithm that PRESERVES slots already holding
    -- a wanted mod, and only rewrites slots whose current DA is not in the wanted set.
    --
    -- Why this matters:
    --   The old approach wrote sorted-recv sequentially into slots 0,1,2…
    --   If the server had [ModA,ModB,ModC] and the player had 2 slots [ModA,ModC],
    --   it would write slot0=ModA, slot1=ModB — silently overwriting ModC with ModB.
    --   InventoryInfo (Level, Enhancements) lives in the slot struct, so the Level
    --   for ModC would now be labelled as ModB, destroying the player's earned progress.
    --
    --   The two-pass approach:
    --     Pass 1 — walk slots; if slot's DA is in the wanted set, mark it satisfied
    --              (leave it entirely untouched — DA, Level, Enhancements, AccumulatedBuff
    --              all preserved).  Collect slots that hold unwanted DAs.
    --     Pass 2 — fill the collected "dirty" slots with the mods still unsatisfied
    --              from the wanted set.  Only dirty slots are ever written.
    local function applySlotArray(propName, daField, daList, sourceNames)
        if #sourceNames == 0 or not daList or #daList == 0 then return end
        pcall(function()
            local arr = ps:GetPropertyValue(propName)
            if not arr then return end

            -- Build a mutable wanted-count map from the recv names.
            local wanted = {}
            for _, n in ipairs(sourceNames) do
                wanted[n] = (wanted[n] or 0) + 1
            end

            -- Pass 1: identify slots that already satisfy a wanted entry vs. slots
            -- that hold a DA not in the wanted set (need overwriting).
            local dirtySlots = {}
            arr:ForEach(function(_, elem)
                if not elem:get():IsValid() then return end
                local ok, da = pcall(function() return elem:get()[daField] end)
                local curName = (ok and da) and getDAName(da) or ""
                if wanted[curName] and wanted[curName] > 0 then
                    -- Slot already has a wanted mod.  Mark it satisfied and leave it alone.
                    wanted[curName] = wanted[curName] - 1
                else
                    -- Slot holds a mod not wanted (or unreadable).  Queue for overwrite.
                    table.insert(dirtySlots, elem:get())
                end
            end)

            -- Collect the mods still needed (unsatisfied entries in wanted).
            local modsToPlace = {}
            for name, count in pairs(wanted) do
                for _ = 1, count do table.insert(modsToPlace, name) end
            end

            -- Pass 2: write unsatisfied mods into dirty slots only.
            -- Slots with correct mods are never touched — their Level and Enhancements
            -- remain exactly as the game set them.
            for i, slotElem in ipairs(dirtySlots) do
                if not modsToPlace[i] then break end  -- no more mods to assign
                local da = findDA(daList, modsToPlace[i])
                if da then pcall(function() slotElem[daField] = da end) end
            end
        end)
    end

    -- Apply each category then immediately anchor the delta-tracker so the next
    -- readInventory sees delta = 0 for synced items (same technique as crystals/health).
    -- We re-read the actual TArray after writing rather than assuming all items landed,
    -- since applySlotArray silently skips items beyond the player's slot count.
    --
    -- SET-BASED GUARD: before each slot write, compare the sorted set of names in
    -- recv against the sorted set currently in the TArray.  If they are identical
    -- (i.e. same mods, just a different UE4 TArray order) we skip the write entirely.
    --
    -- Why this matters:
    --   applySlotArray writes recv[1] → slot 0, recv[2] → slot 1, etc.  If TArray
    --   reordering has shuffled the game's internal order, the write swaps the DA
    --   pointer in each slot WITHOUT moving the InventoryInfo struct (Level, Enhancements
    --   live with the slot, not the DA).  Result: mod names rotate between slots while
    --   their Levels stay behind — the "shuffle" bug.  Skipping the write when the SET
    --   is unchanged prevents this entirely.
    for _, entry in ipairs({
        { flag=SYNC_WEAPON_MODS,  prop="WeaponMods",  da="WeaponModDA",  list=weaponModDAs,  src=inv.weaponMods,  key="weaponMods"  },
        { flag=SYNC_ABILITY_MODS, prop="AbilityMods", da="AbilityModDA", list=abilityModDAs, src=inv.abilityMods, key="abilityMods" },
        { flag=SYNC_MELEE_MODS,   prop="MeleeMods",   da="MeleeModDA",   list=meleeModDAs,   src=inv.meleeMods,   key="meleeMods"   },
        { flag=SYNC_PERKS,        prop="Perks",       da="PerkDA",       list=perkDAs,       src=inv.perks,       key="perks"       },
        { flag=SYNC_RELICS,       prop="Relics",      da="RelicDA",      list=relicDAs,      src=inv.relics,      key="relics"      },
    }) do
        if entry.flag then
            -- entry.src is now an array of {name,level,accum} objects.
            -- Extract sorted names for the set-comparison (we don't want TArray
            -- reordering to trigger a slot write — only real add/remove changes do).
            local sortedSrc = {}
            for _, item in ipairs(entry.src) do table.insert(sortedSrc, item.name) end
            table.sort(sortedSrc)
            local gameSorted = getSortedNamesFromPS(ps, entry.prop, entry.da)
            -- Membership check: only write if a mod currently in-game is missing from
            -- recv. If recv merely has MORE mods than slots can hold (e.g. 2-player pool
            -- has 2 mods but this player only has 1 slot), that is expected — do NOT
            -- rewrite, otherwise the guard fires every tick and never settles.
            local recvSet = {}
            for _, name in ipairs(sortedSrc) do recvSet[name] = true end
            local missingInRecv = false
            for _, name in ipairs(gameSorted) do
                if not recvSet[name] then
                    missingInRecv = true
                    break
                end
            end
            -- Also write if recv has something new AND the game slot is empty/short
            -- (i.e. game has fewer unique mods than recv, meaning there's room to add).
            local gameSet = {}
            for _, name in ipairs(gameSorted) do gameSet[name] = true end
            local newInRecv = false
            for _, name in ipairs(sortedSrc) do
                if not gameSet[name] then
                    newInRecv = true
                    break
                end
            end
            if missingInRecv or newInRecv then
                print(string.format("[CrabSync:apply] %s set changed (%d game / %d recv) — writing slots\n",
                    entry.prop, #gameSorted, #sortedSrc))
                -- applySlotArray expects a flat name list for its wanted-set logic.
                local srcNames = sortedSrc  -- already extracted above
                applySlotArray(entry.prop, entry.da, entry.list, srcNames)
            end
        end
    end

    -- Level + AccumulatedBuff upgrade pass.
    -- Runs over every slot regardless of whether applySlotArray wrote to it.
    -- If the server has a higher Level for a mod the player already owns
    -- (earned by another player picking up duplicates), we write it here.
    -- We NEVER downgrade — only take the max.
    --
    -- Note: Enhancements (Anvil upgrades, nested TArray<enum>) are not written
    -- here because growing a nested TArray inside a struct inside a TArray is
    -- not safely supported by UE4SS. They are pushed/pulled in the payload for
    -- future use once a safe write path is confirmed.
    local function applyInventoryInfo(propName, daField, srcItems)
        -- Build a lookup: name → {level, accum}
        local recvInfo = {}
        for _, item in ipairs(srcItems) do
            recvInfo[item.name] = item
        end
        pcall(function()
            local arr = ps:GetPropertyValue(propName)
            if not arr then return end
            arr:ForEach(function(_, elem)
                if not elem:get():IsValid() then return end
                local okda, da = pcall(function() return elem:get()[daField] end)
                if not okda or not da then return end
                local name = getDAName(da)
                local wanted = recvInfo[name]
                if not wanted then return end
                pcall(function()
                    local info = elem:get().InventoryInfo
                    if not info then return end
                    -- Level: only upgrade, never downgrade.
                    -- CrabInventoryInfo.Level is ByteProperty (0-255); clamp to
                    -- prevent wrap-around that would reset progress to 0.
                    local curLevel    = math.floor(tonumber(info.Level) or 1)
                    local wantedLevel = math.min(255, math.floor(tonumber(wanted.level) or 1))
                    if wantedLevel > curLevel then
                        info.Level = wantedLevel
                    end
                    -- AccumulatedBuff: take the max (relics accumulate over time).
                    local curAccum    = tonumber(info.AccumulatedBuff) or 0.0
                    local wantedAccum = tonumber(wanted.accum)         or 0.0
                    if wantedAccum > curAccum then
                        info.AccumulatedBuff = wantedAccum
                    end
                end)
            end)
        end)
    end

    for _, entry in ipairs({
        { flag=SYNC_WEAPON_MODS,  prop="WeaponMods",  da="WeaponModDA",  src=inv.weaponMods  },
        { flag=SYNC_ABILITY_MODS, prop="AbilityMods", da="AbilityModDA", src=inv.abilityMods },
        { flag=SYNC_MELEE_MODS,   prop="MeleeMods",   da="MeleeModDA",   src=inv.meleeMods   },
        { flag=SYNC_PERKS,        prop="Perks",       da="PerkDA",       src=inv.perks       },
        { flag=SYNC_RELICS,       prop="Relics",      da="RelicDA",      src=inv.relics      },
    }) do
        if entry.flag then applyInventoryInfo(entry.prop, entry.da, entry.src) end
    end

    -- Notify the game that inventory changed so UI slots and mod-effect systems
    -- recalculate immediately rather than waiting for the next replication cycle.
    pcall(function() ps:OnRep_Inventory() end)

    -- Apply slot counts from the merged payload.  Only increase — never decrease.
    -- Uses SetPropertyValue (reflection write) only; no UFunction calls.
    -- All NumXxxSlots properties are ByteProperty (0-255); clamp to prevent
    -- wrap-around that would reset slot count to 0.
    if SYNC_SLOTS and inv.slots then
        for _, entry in ipairs({
            { prop="NumWeaponModSlots",  key="weaponMods"  },
            { prop="NumAbilityModSlots", key="abilityMods" },
            { prop="NumMeleeModSlots",   key="meleeMods"   },
            { prop="NumPerkSlots",       key="perks"       },
        }) do
            local incoming = math.min(255, math.floor(tonumber(inv.slots[entry.key]) or 0))
            if incoming > 0 then
                pcall(function()
                    local current = math.floor(tonumber(ps:GetPropertyValue(entry.prop)) or 0)
                    if incoming > current then
                        ps:SetPropertyValue(entry.prop, incoming)
                        -- Anchor the delta tracker to what we just wrote so the very next
                        -- readInventory tick sees delta = 0 and does NOT add the synced
                        -- total to ownSlots again (same pattern as crystals / health).
                        lastGameSlots[entry.key] = incoming
                    end
                end)
            end
        end
    end
end

-- ============================================================
-- AUTO-LAUNCH BRIDGE
-- ============================================================
-- Writes a tiny VBScript to Scripts/ and executes it via wscript (a GUI app,
-- so there is no CMD flash from wscript itself). The VBScript:
--   1. Checks via WMI whether a powershell.exe with "bridge.ps1" is already
--      running and skips launch if found (prevents double-launch on mod reload).
--   2. Starts bridge.ps1 via PowerShell — no Node.js required. PowerShell is
--      built into Windows 10/11 and always in the system PATH.
--   3. windowStyle=1 = normal visible window so you can see connection status.
local function autoLaunchBridge()
    local vbsPath = SCRIPT_DIR_PRIMARY .. "autolaunch.vbs"

    local lines = {
        'Dim fso : Set fso = CreateObject("Scripting.FileSystemObject")',
        'Dim scriptDir : scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)',
        'Dim bridgeDir : bridgeDir = fso.GetParentFolderName(scriptDir)',
        'Dim bridgePath : bridgePath = bridgeDir & "\\bridge.ps1"',
        'Dim sh : Set sh = CreateObject("WScript.Shell")',
        -- Check for already-running bridge.
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
        -- Launch PowerShell bridge. windowStyle=1 = normal visible so errors are readable.
        'Dim playerName : playerName = sh.ExpandEnvironmentStrings("%USERNAME%")',
        'Dim q : q = Chr(34)',
        'sh.CurrentDirectory = bridgeDir',
        'sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File " & q & bridgePath & q & " " & q & "' .. SERVER_URL .. '" & q & " " & q & playerName & q, 1, False',
    }

    local f = io.open(vbsPath, "w")
    if not f then
        print("[CrabInventorySync] Could not write autolaunch.vbs — launch bridge.ps1 manually.\n")
        return
    end
    f:write(table.concat(lines, "\r\n") .. "\r\n")
    f:close()

    local vbsWin = vbsPath:gsub("/", "\\")
    os.execute('wscript //nologo "' .. vbsWin .. '"')
    print("[CrabInventorySync] Bridge launched (check PowerShell window for status).\n")
end

-- ============================================================
-- CONTINUOUS SYNC
-- ============================================================
-- How it works:
--   pollTick() runs every POLL_INTERVAL_MS milliseconds via a self-rescheduling
--   ExecuteWithDelay chain.  Each tick does two things:
--
--   1. pushIfChanged  — reads the local player's inventory and compares it
--      (as a JSON string) to the last thing we pushed.  If anything changed
--      (new perk, weapon swap, crystals gained, etc.) push.json is updated
--      immediately so the bridge forwards it to the server.
--
--   2. applyIfChanged — reads recv.json and compares it to the last merged
--      inventory we applied.  Every player does this independently; no host
--      designation needed.  Each client applies the merged result to their
--      own PlayerState only (the one this client actually owns/controls).
--
-- Level transitions:  isTransitioning is set to true for 4 s when
-- ClientOnClearedIsland fires, pausing both halves of the poll to avoid
-- accessing game objects that are mid-destruction (the previous crash source).
-- After the pause both lastPushedJson and lastRecvJson are cleared so the
-- first tick after the new level loads performs a full fresh sync.

local POLL_INTERVAL_MS = 500   -- how often to check for changes (ms)
EQUIP_HEALTH_ZERO_GRACE_TICKS = math.max(1, math.ceil(1000 / POLL_INTERVAL_MS))

local lastPushedJson  = ""     -- inventory JSON last written to push.json (change detection)
local lastRecvJson    = ""     -- raw recv.json text we last read
local lastRecvInvJson = ""     -- canonical inventory JSON last applied (format-insensitive)
local isTransitioning = false  -- pauses polling during level transitions
local skipNextApply   = false  -- true for one tick after a push, so bridge can update recv.json
                               -- before we apply (prevents stale recv from reverting a fresh pickup)

-- Crystal delta-tracking — prevents the feedback loop caused by applying the server's
-- summed total back into the game, which would inflate our contribution on the next push.
--
-- ownCrystals      : what we report to the server as our contribution.
--                    Starts at nil (uninitialised) and is set on the first readInventory.
--                    Updated by the delta between consecutive raw game reads so that only
--                    crystals we actually earned (or spent) change our contribution.
-- lastGameCrystals : the raw game value we saw on the last readInventory call, OR the
--                    value we wrote with SetPropertyValue inside applyInventory.
--                    Keeping it in sync with the game state makes the next delta = 0
--                    immediately after an apply, preventing double-counting.
local ownCrystals      = nil   -- our contribution to the shared pool (nil = not yet set)
local lastGameCrystals = nil   -- raw game crystal count at the last read or apply

-- Same delta-tracking pattern for health.
-- ownHealth reports our HP contribution; lastGameHealth anchors the delta so that
-- applying the summed pool doesn't inflate our contribution on the next push.
local ownHealth      = nil   -- our HP contribution (nil = not yet set)
local lastGameHealth = nil   -- raw game HP at the last read or apply

-- Same delta-tracking pattern for max HP.
-- ownMaxHealth      : our personal CurrentMaxHealth contribution.
-- lastGameMaxHealth : raw game CurrentMaxHealth at last read or apply.
-- Server SUMs maxHealth across players just like current HP, so two players
-- each at 250 maxHP → merged 500 maxHP applied to everyone.
local ownMaxHealth      = nil
local lastGameMaxHealth = nil

-- Same delta-tracking pattern for slot counts.
-- Each slot key (weaponMods, abilityMods, meleeMods, perks) is tracked independently.
-- ownSlots[k]      = how many slots of type k we personally contributed.
-- lastGameSlots[k] = raw game slot count at last read or apply (nil = not yet initialised).
-- The server SUMs contributions from all players, so we must send only our delta,
-- not the already-synced total (which would cause doubling on every subsequent push).
local ownSlots      = { weaponMods=0, abilityMods=0, meleeMods=0, perks=0 }
local lastGameSlots = { weaponMods=nil, abilityMods=nil, meleeMods=nil, perks=nil }



-- Write push.json only when the inventory has actually changed.
-- The file is written as {"room":"...","inventory":{...}} so the bridge can
-- use the correct room for both push POSTs and sync GETs.
-- Room code comes from config.txt (ROOM_CODE).
local function pushIfChanged()
    if isTransitioning then return end
    local ps = getLocalPS()
    if not ps then return end

    local invJson = encodeInventory(readInventory(ps))
    -- Always log the push evaluation so we can see debounce-stable vs last-pushed.
    print(string.format(
        "[CrabSync:push] eval stable=(%s|%s|%s) changed=%s\n",
        stableWeapon or "?", stableAbility or "?", stableMelee or "?",
        tostring(invJson ~= lastPushedJson)))
    if invJson == lastPushedJson then return end

    -- Wrap inventory with room, session player list, and password.
    local sessionPlayers = getSessionPlayers()
    local playersJson    = jsonStrArray(sessionPlayers)
    local payload = '{"room":' .. jsonStr(ROOM_CODE) .. ',"players":' .. playersJson .. ',"password":' .. jsonStr(ROOM_PASSWORD) .. ',"inventory":' .. invJson .. '}'
    local f = io.open(PUSH_FILE, "w")
    if f then
        f:write(payload)
        f:close()
        lastPushedJson = invJson   -- store only the inv portion for change detection
        skipNextApply  = true      -- give bridge one tick to process push before we apply
        print("[CrabInventorySync] Change detected — pushed to bridge.\n")
    end
end

-- Apply recv.json to the local player's own PlayerState whenever the bridge
-- writes a new merged inventory.  Every client does this for themselves.
local function applyIfChanged()
    if isTransitioning then return end
    -- Skip apply for one tick after we pushed: lets the bridge process push.json
    -- and update recv.json so we do not immediately apply stale data.
    if skipNextApply then
        skipNextApply = false
        print("[CrabSync] apply SKIPPED (post-push tick - letting bridge update recv)\n")
        return
    end
    local f = io.open(RECV_FILE, "r")
    if not f then return end
    local json = f:read("*a")
    f:close()
    if json == "" or json == lastRecvJson then return end

    local inv = decodeInventory(json)
    if not inv then return end
    local invJson = encodeInventory(inv)
    if invJson == lastRecvInvJson then
        -- Same logical inventory; only raw JSON formatting/order changed.
        lastRecvJson = json
        return
    end

    local ps = getLocalPS()
    if not ps then return end
    applyInventory(ps, inv)
    lastRecvJson = json
    lastRecvInvJson = invJson
    print("[CrabInventorySync] Applied merged inventory to local player.\n")
end

local function pollTick()
    pushIfChanged()
    applyIfChanged()
    ExecuteWithDelay(POLL_INTERVAL_MS, pollTick)
end

-- ============================================================
-- HOOKS & KEYBINDS
-- ============================================================
loadConfig()
autoLaunchBridge()

-- Pause polling for 4 s during level transitions to avoid the 0xe06d7363 crash
-- (PlayerState is mid-destruction when this hook fires; defer until safe).
RegisterHook("/Script/CrabChampions.CrabPC:ClientOnClearedIsland", function()
    isTransitioning = true
    print("[CrabInventorySync] Level transition — pausing sync for 4 s.\n")
    ExecuteWithDelay(4000, function()
        isTransitioning = false
        lastPushedJson  = ""   -- force fresh push in the new level
        lastRecvJson    = ""   -- force fresh apply if recv.json has data
        lastRecvInvJson = ""
        -- NOTE: do NOT reset delta-tracking state (ownCrystals, ownHealth,
        -- ownMaxHealth, ownSlots, lastGame* counters).  The game preserves
        -- these values across island clears, so resetting them re-initialises
        -- each player's contribution to the FULL pooled total — doubling the
        -- pool on every transition.  The existing guards (max(0,...) clamp,
        -- newOwn<=0 re-init, apply anchoring) already handle genuine game
        -- resets (lobby, new run) correctly without a nil reset here.
        pendingWeapon  = nil;  pendingWCount = 0;  stableWeapon  = nil
        pendingAbility = nil;  pendingACount = 0;  stableAbility = nil
        pendingMelee   = nil;  pendingMCount = 0;  stableMelee   = nil
        print("[CrabInventorySync] Resuming continuous sync.\n")
    end)
end)

-- F9: force an immediate re-push and re-apply on the very next tick.
RegisterKeyBind(Key.F9, function()
    lastPushedJson   = ""
    lastRecvJson     = ""
    lastRecvInvJson  = ""
    -- NOTE: do NOT reset delta-tracking state (ownCrystals, ownHealth,
    -- ownMaxHealth, ownSlots).  Resetting them re-initialises each player's
    -- contribution to the full pooled total, doubling the pool.
    pendingWeapon  = nil;  pendingWCount = 0;  stableWeapon  = nil
    pendingAbility = nil;  pendingACount = 0;  stableAbility = nil
    pendingMelee   = nil;  pendingMCount = 0;  stableMelee   = nil
    print("[CrabInventorySync] Manual sync forced (F9).\n")
end)

-- Kick off the poll loop.  First tick fires after one interval so the game
-- has a moment to finish initialising before we start reading PlayerState.
ExecuteWithDelay(POLL_INTERVAL_MS, pollTick)

print("[CrabInventorySync] Loaded. Syncing every " .. POLL_INTERVAL_MS .. " ms. Press F9 to force.\n")
