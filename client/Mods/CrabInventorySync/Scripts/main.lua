-- Uncomment the line below to enable debug keybinds (F6/F7/F8/F10). Remove when done.
-- require("debug_helpers")
-- require("debug_perks")

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
-- Internal property name for crystals on CrabPS (adjust if values read as 0)
local CRYSTALS_PROPERTY  = "Crystals"

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
            elseif key == "crystalsProperty" then CRYSTALS_PROPERTY    = value
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
    return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
end

local function jsonStrArray(arr)
    local parts = {}
    for _, v in ipairs(arr) do table.insert(parts, jsonStr(v)) end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function encodeInventory(inv)
    return string.format(
        '{"weapon":%s,"ability":%s,"melee":%s,"crystals":%d,"health":%.3f,"maxHealth":%.3f,' ..
        '"weaponMods":%s,"abilityMods":%s,"meleeMods":%s,"perks":%s,"relics":%s}',
        jsonStr(inv.weapon),
        jsonStr(inv.ability),
        jsonStr(inv.melee),
        math.floor(tonumber(inv.crystals) or 0),
        tonumber(inv.health) or 0.0,
        tonumber(inv.maxHealth) or 0.0,
        jsonStrArray(inv.weaponMods),
        jsonStrArray(inv.abilityMods),
        jsonStrArray(inv.meleeMods),
        jsonStrArray(inv.perks),
        jsonStrArray(inv.relics)
    )
end

-- Minimal JSON decoder for the specific inventory structure we produce.
-- Only handles flat string/number fields and arrays of strings.
local function decodeInventory(json)
    if not json or json == "" then return nil end
    -- Strip UTF-8 BOM (0xEF 0xBB 0xBF) if present — PowerShell 5 may write it.
    if json:sub(1,3) == "\xEF\xBB\xBF" then json = json:sub(4) end
    if json:sub(1,1) ~= "{" then return nil end
    local inv = {}
    inv.weapon   = json:match('"weapon"%s*:%s*"([^"]*)"')   or ""
    inv.ability  = json:match('"ability"%s*:%s*"([^"]*)"')  or ""
    inv.melee    = json:match('"melee"%s*:%s*"([^"]*)"')    or ""
    inv.crystals   = tonumber(json:match('"crystals"%s*:%s*(%d+)')) or 0
    inv.health     = tonumber(json:match('"health"%s*:%s*(%-?[%d%.]+)')) or 0.0
    inv.maxHealth  = tonumber(json:match('"maxHealth"%s*:%s*(%-?[%d%.]+)')) or 0.0

    local function strArray(j, key)
        local t = {}
        local s = j:match('"' .. key .. '"%s*:%s*(%[[^%]]*%])')
        if s then for item in s:gmatch('"([^"]*)"') do table.insert(t, item) end end
        return t
    end

    inv.weaponMods  = strArray(json, "weaponMods")
    inv.abilityMods = strArray(json, "abilityMods")
    inv.meleeMods   = strArray(json, "meleeMods")
    inv.perks       = strArray(json, "perks")
    inv.relics      = strArray(json, "relics")
    return inv
end

-- ============================================================
-- DA HELPERS
-- ============================================================
local function getDAName(da)
    if not da then return "" end
    local ok, v = pcall(function() return da:IsValid() end)
    if not ok or not v then return "" end
    local ok2, nameObj = pcall(function() return da:GetPropertyValue("Name") end)
    if not ok2 or not nameObj then return "" end
    local ok3, name = pcall(function() return nameObj:ToString() end)
    return (ok3 and name) and name or ""
end

local function findDA(daList, name)
    if not daList or name == "" then return nil end
    for _, da in ipairs(daList) do
        local ok, v = pcall(function() return da:IsValid() end)
        if ok and v then
            local ok2, nameObj = pcall(function() return da:GetPropertyValue("Name") end)
            if ok2 and nameObj then
                local ok3, n = pcall(function() return nameObj:ToString() end)
                if ok3 and n == name then return da end
            end
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
                local ok, da = pcall(function() return elem:get():GetPropertyValue(daField) end)
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

-- ============================================================
-- SESSION ROOM DETECTION
-- ============================================================
-- All players in the same listen-server session share the same replicated
-- GameState.PlayerArray.  Index 0 is always the host (the player who started
-- the game / owns the listen server).  Using the host's name as the room code
-- means every client automatically derives the same room without any manual
-- configuration — joining the same Steam session is sufficient.
local function detectRoomCode()
    -- Try game-specific GameState class first, fall back to engine base class.
    local gs = FindFirstOf("CrabGS")
    if not gs then
        local ok, v = pcall(FindFirstOf, "GameStateBase")
        if ok and v then gs = v end
    end
    if not gs then return nil end
    local okv = pcall(function() return gs:IsValid() end)
    if not okv then return nil end

    local hostName = nil
    pcall(function()
        local arr = gs:GetPropertyValue("PlayerArray")
        if not arr then return end
        arr:ForEach(function(idx, elem)
            if idx == 0 and elem:get():IsValid() then
                hostName = getPlayerName(elem:get())
            end
        end)
    end)

    if not hostName or hostName == "" or hostName == "UnknownPlayer" then
        return nil
    end
    -- Sanitize: lowercase, collapse anything that isn't alphanumeric/dash to
    -- underscores, cap at 32 chars so room codes stay readable in server logs.
    return hostName:gsub("[^%w%-]", "_"):lower():sub(1, 32)
end

-- ============================================================
-- PLAYER STATE HELPERS
-- ============================================================

-- Returns true only if a string looks like a real readable name.
-- Garbled UTF-16LE leakage always contains null bytes (0x00 every other byte
-- for ASCII chars), so a null-byte check catches the exact failure mode here.
local function isReadable(s)
    if type(s) ~= "string" or #s == 0 or #s > 64 then return false end
    return not s:find('\0', 1, true)
end

-- Run a shell command and return its trimmed stdout, or nil on failure.
local function shellRead(cmd)
    local ok, handle = pcall(io.popen, cmd)
    if not ok or not handle then return nil end
    local out = handle:read("*a")
    handle:close()
    if out then out = out:gsub("[%s\r\n]+$", ""):gsub("^[%s\r\n]+", "") end
    return (out and out ~= "") and out or nil
end

-- Attempt to get a readable player name, working through four strategies.
-- See previous comments in git history for full rationale.
local function getPlayerName(ps)
    if ps then
        local ok1, v1 = pcall(function() return ps:GetPropertyValue("PlayerNamePrivate") end)
        if ok1 and isReadable(v1) then return v1 end

        local ok2, v2 = pcall(function()
            local fn = ps:GetPlayerName()
            return (type(fn) == "string") and fn or nil
        end)
        if ok2 and isReadable(v2) then return v2 end
    end

    local u = shellRead("echo %USERNAME%")
    if u and u ~= "%USERNAME%" and isReadable(u) then return u end

    local h = shellRead("hostname")
    if isReadable(h) then return h end

    return "UnknownPlayer"
end

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

-- Mod/perk/relic delta-tracking state — declared here so readInventory and
-- applyInventory (defined below) close over these locals correctly.
local ownModCounts      = { weaponMods=nil, abilityMods=nil, meleeMods=nil, perks=nil, relics=nil }
local lastGameModCounts = { weaponMods=nil, abilityMods=nil, meleeMods=nil, perks=nil, relics=nil }

-- Weapon/ability/melee debounce state.
-- The game briefly reports a stale ability during ability use (e.g. Black Hole → Grappling
-- Hook for one tick while the animation plays).  We only promote a new value to "stable"
-- after SLOT_STABLE_TICKS consecutive identical reads, so that flicker never reaches push.json.
-- After an apply the state is anchored so the applied value is not immediately treated as
-- a new change and pushed back (which would start the receive → push → receive loop).
local SLOT_STABLE_TICKS = 3   -- 3 × POLL_INTERVAL_MS = 1.5 s debounce window
local pendingWeapon  = nil;  local pendingWCount = 0;  local stableWeapon  = nil
local pendingAbility = nil;  local pendingACount = 0;  local stableAbility = nil
local pendingMelee   = nil;  local pendingMCount = 0;  local stableMelee   = nil

-- ============================================================
-- INVENTORY READ
-- ============================================================
local function readInventory(ps)
    local inv = {
        weapon = "", ability = "", melee = "", crystals = 0, health = 0, maxHealth = 0,
        weaponMods = {}, abilityMods = {}, meleeMods = {}, perks = {}, relics = {}
    }
    if not ps then return inv end
    local okv = pcall(function() return ps:IsValid() end)
    if not okv then return inv end

    -- Debounced reads for weapon/ability/melee.  A value must be identical for
    -- SLOT_STABLE_TICKS consecutive polls before it is reported in the push payload.
    -- This filters out the 1-tick ability flicker that occurs during ability use.
    -- On first read the initial value is accepted immediately (no delay).
    if SYNC_WEAPON then
        local cur = ""
        pcall(function() cur = getDAName(ps:GetPropertyValue("WeaponDA")) end)
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
        pcall(function() cur = getDAName(ps:GetPropertyValue("AbilityDA")) end)
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
        pcall(function() cur = getDAName(ps:GetPropertyValue("MeleeDA")) end)
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
            -- HealthInfo is a struct — direct field access only (no GetPropertyValue).
            local raw = hi.CurrentHealth
            if not raw or raw <= 0 or raw >= 9999 then return end
            if lastGameHealth == nil then
                ownHealth      = raw
                lastGameHealth = raw
            else
                local delta = raw - lastGameHealth
                ownHealth      = math.max(0, (ownHealth or 0) + delta)
                lastGameHealth = raw
            end
            inv.health = ownHealth
        end)
    end

    -- Delta-track each mod/perk/relic category so we only push items we personally
    -- earned — same pattern as crystals/health to prevent sync feedback loops.
    -- ownModCounts[key] holds our personal name→count contribution; synced items
    -- are anchored into lastGameModCounts after apply so their delta = 0 next tick.
    for _, cat in ipairs({
        { inv="weaponMods",  prop="WeaponMods",  da="WeaponModDA"  },
        { inv="abilityMods", prop="AbilityMods", da="AbilityModDA" },
        { inv="meleeMods",   prop="MeleeMods",   da="MeleeModDA"   },
        { inv="perks",       prop="Perks",       da="PerkDA"       },
        { inv="relics",      prop="Relics",      da="RelicDA"      },
    }) do
        local current = computeSlotCounts(ps, cat.prop, cat.da)
        local own  = ownModCounts[cat.inv]
        local last = lastGameModCounts[cat.inv]

        if own == nil then
            -- First read after init/reset: everything currently in our slots is ours.
            own = {}
            for name, count in pairs(current) do own[name] = count end
        else
            -- Only the delta since the last tick changes our contribution.
            -- Positive delta = earned something; negative = lost/spent something.
            local allNames = {}
            for name in pairs(current) do allNames[name] = true end
            for name in pairs(last)    do allNames[name] = true end
            for name in pairs(allNames) do
                local delta = (current[name] or 0) - (last[name] or 0)
                if delta ~= 0 then
                    own[name] = math.max(0, (own[name] or 0) + delta)
                end
            end
        end

        ownModCounts[cat.inv]      = own
        lastGameModCounts[cat.inv] = current  -- anchor to this tick's game state

        -- Expand name→count into the flat string array the JSON encoder expects.
        -- Duplicate names represent stacked items and are preserved intentionally.
        for name, count in pairs(own) do
            for _ = 1, count do table.insert(inv[cat.inv], name) end
        end
    end

    return inv
end

-- ============================================================
-- INVENTORY APPLY
-- ============================================================
local function applyInventory(ps, inv)
    if not ps or not inv then return end
    local ok = pcall(function() return ps:IsValid() end)
    if not ok then return end

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
            local curWeapon  = getDAName(ps:GetPropertyValue("WeaponDA"))
            local curAbility = getDAName(ps:GetPropertyValue("AbilityDA"))
            local curMelee   = getDAName(ps:GetPropertyValue("MeleeDA"))
            local newWeapon  = (SYNC_WEAPON  and inv.weapon  ~= "") and inv.weapon  or curWeapon
            local newAbility = (SYNC_ABILITY and inv.ability ~= "") and inv.ability or curAbility
            local newMelee   = (SYNC_MELEE   and inv.melee   ~= "") and inv.melee   or curMelee
            -- Log recv vs game vs debounce-stable on every apply evaluation.
            --print(string.format(
            --    "[CrabSync:apply] recv=(%s|%s|%s)  game=(%s|%s|%s)  stable=(%s|%s|%s)\n",
            --    inv.weapon or "", inv.ability or "", inv.melee or "",
            --    curWeapon, curAbility, curMelee,
            --    stableWeapon or "?", stableAbility or "?", stableMelee or "?"))
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
                --print(string.format(
                --    "[CrabSync:apply] BLOCKED debounce: W=%s A=%s M=%s\n",
                --    tostring(blockedW), tostring(blockedA), tostring(blockedM)))
            end
            if newWeapon == curWeapon and newAbility == curAbility and newMelee == curMelee then return end
            local weapon  = findDA(weaponDAs,  newWeapon)  or ps:GetPropertyValue("WeaponDA")
            local ability = findDA(abilityDAs, newAbility) or ps:GetPropertyValue("AbilityDA")
            local melee   = findDA(meleeDAs,   newMelee)   or ps:GetPropertyValue("MeleeDA")
            if weapon and ability and melee then
                --print(string.format(
                --    "[CrabSync:apply] ServerEquipInventory → %s / %s / %s\n",
                --    newWeapon, newAbility, newMelee))
                ps:ServerEquipInventory(weapon, ability, melee)
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
    if SYNC_CRYSTALS and inv.crystals and inv.crystals > 0 then
        pcall(function()
            local total = math.floor(inv.crystals)
            ps:SetPropertyValue(CRYSTALS_PROPERTY, total)
            lastGameCrystals = total   -- keep delta-tracker in sync with what we wrote
        end)
    end

    if SYNC_HEALTH and inv.health and inv.health > 0 and inv.health < 9999 then
        pcall(function()
            local hc = getLocalHC()
            if not hc then return end
            local hi = hc:GetPropertyValue("HealthInfo")
            if not hi then return end
            hi.CurrentHealth = inv.health
            -- Cap the anchor to actual MaxHealth so that if the game clamps the applied
            -- value (merged > our max), the next delta read is 0, not a large negative
            -- that zeros out ownHealth and causes health: 0 in future pushes.
            local maxHp = nil
            pcall(function() maxHp = hi.MaxHealth end)
            lastGameHealth = (maxHp and maxHp > 0) and math.min(inv.health, maxHp) or inv.health
            pcall(function() hc:OnRep_HealthInfo() end)
        end)
    end

    local function applySlotArray(propName, daField, daList, sourceNames, ownItems)
        if not daList or #daList == 0 then return end

        -- Compute items that need writing: sourceNames minus what we already own in-slot.
        -- This prevents overwriting a slot that already has one of our own items with
        -- someone else's item (e.g. merged list = [RemotePerk, YourPerk] → slot 0 written
        -- with RemotePerk, clobbering YourPerk).
        local toWrite = {}
        local ownRemaining = {}
        for name, count in pairs(ownItems or {}) do ownRemaining[name] = count end
        for _, name in ipairs(sourceNames) do
            if ownRemaining[name] and ownRemaining[name] > 0 then
                ownRemaining[name] = ownRemaining[name] - 1   -- already in a slot, skip
            else
                table.insert(toWrite, name)
            end
        end
        if #toWrite == 0 then return end

        -- Write toWrite items only to slots that don't contain one of our own items.
        local ownSkip = {}
        for name, count in pairs(ownItems or {}) do ownSkip[name] = count end
        local writeIdx = 1
        pcall(function()
            local arr = ps:GetPropertyValue(propName)
            if not arr then return end
            arr:ForEach(function(_, elem)
                if writeIdx > #toWrite then return end
                if elem:get():IsValid() then
                    local ok, curDA = pcall(function() return elem:get():GetPropertyValue(daField) end)
                    local curName = (ok and curDA) and getDAName(curDA) or ""
                    if ownSkip[curName] and ownSkip[curName] > 0 then
                        ownSkip[curName] = ownSkip[curName] - 1
                        return   -- preserve our own item in this slot
                    end
                    local da = findDA(daList, toWrite[writeIdx])
                    if da then
                        pcall(function() elem:get():SetPropertyValue(daField, da) end)
                        writeIdx = writeIdx + 1
                    end
                end
            end)
        end)
    end

    -- Apply each category then immediately anchor the delta-tracker so the next
    -- readInventory sees delta = 0 for synced items (same technique as crystals/health).
    -- We re-read the actual TArray after writing rather than assuming all items landed,
    -- since applySlotArray silently skips items beyond the player's slot count.
    for _, entry in ipairs({
        { flag=SYNC_WEAPON_MODS,  prop="WeaponMods",  da="WeaponModDA",  list=weaponModDAs,  src=inv.weaponMods,  key="weaponMods"  },
        { flag=SYNC_ABILITY_MODS, prop="AbilityMods", da="AbilityModDA", list=abilityModDAs, src=inv.abilityMods, key="abilityMods" },
        { flag=SYNC_MELEE_MODS,   prop="MeleeMods",   da="MeleeModDA",   list=meleeModDAs,   src=inv.meleeMods,   key="meleeMods"   },
        { flag=SYNC_PERKS,        prop="Perks",       da="PerkDA",       list=perkDAs,       src=inv.perks,       key="perks"       },
        { flag=SYNC_RELICS,       prop="Relics",      da="RelicDA",      list=relicDAs,      src=inv.relics,      key="relics"      },
    }) do
        if entry.flag then
            applySlotArray(entry.prop, entry.da, entry.list, entry.src, ownModCounts[entry.key])
            -- Anchor to what we INTENDED to write, not computeSlotCounts.
            -- Reading the slot immediately after writing via UE4SS reflection returns
            -- the pre-write value for that tick (the game hasn't processed it yet).
            -- Using the stale read as the anchor causes a spurious +delta on the next
            -- readInventory, which pushes the old mod, triggers another apply, and
            -- creates the 500 ms Arcane Shot ↔ Ice Shot oscillation seen in the logs.
            local writtenCounts = {}
            for _, name in ipairs(entry.src) do
                writtenCounts[name] = (writtenCounts[name] or 0) + 1
            end
            lastGameModCounts[entry.key] = writtenCounts
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
        'sh.CurrentDirectory = bridgeDir',
        'sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File """ & bridgePath & """ ' .. SERVER_URL .. ' " & playerName & "", 1, False',
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

local lastPushedJson  = ""     -- inventory JSON last written to push.json (change detection)
local lastRecvJson    = ""     -- JSON we last applied from recv.json
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


-- Write push.json only when the inventory has actually changed.
-- The file is written as {"room":"...","inventory":{...}} so the bridge can
-- automatically use the correct room for both push POSTs and sync GETs without
-- any manual config — set roomCode in config.txt to match all players in the session.
local function pushIfChanged()
    if isTransitioning then return end
    local ps = getLocalPS()
    if not ps then return end

    local roomForPush = ROOM_CODE

    local invJson = encodeInventory(readInventory(ps))
    -- Always log the push evaluation so we can see debounce-stable vs last-pushed.
    --print(string.format(
    --    "[CrabSync:push] eval stable=(%s|%s|%s) changed=%s\n",
    --    stableWeapon or "?", stableAbility or "?", stableMelee or "?",
    --    tostring(invJson ~= lastPushedJson)))
    if invJson == lastPushedJson then return end

    -- Wrap inventory with room so the bridge doesn't need it hardcoded.
    local payload = '{"room":' .. jsonStr(roomForPush) .. ',"inventory":' .. invJson .. '}'
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
    -- Skip apply for one tick after we pushed — lets the bridge process push.json
    -- and update recv.json so we don't immediately apply a stale recv that reverts
    -- whatever the player just picked up (weapon, mod, ability, melee).
    if skipNextApply then skipNextApply = false; --[[print("[CrabSync] apply SKIPPED (post-push tick — letting bridge update recv)\n")]] return end
    local f = io.open(RECV_FILE, "r")
    if not f then return end
    local json = f:read("*a")
    f:close()
    if json == "" or json == lastRecvJson then return end
    lastRecvJson = json
    local inv = decodeInventory(json)
    if not inv then return end
    local ps = getLocalPS()
    if not ps then return end
    applyInventory(ps, inv)
    --print("[CrabInventorySync] Applied merged inventory to local player.\n")
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
-- One-time player name detection for fallback room code.
-- shellRead (io.popen) is only safe to call here at startup — not inside the 500 ms
-- poll loop, where it would spawn a new cmd.exe process every half-second and flood
-- the system, which was causing the bridge to crash after a single push.
if ROOM_CODE == "default" then
    local name = getPlayerName(nil)
    if name and name ~= "UnknownPlayer" then
        ROOM_CODE = name:gsub("[^%w%-]", "_"):lower():sub(1, 32)
        print("[CrabInventorySync] Fallback room: " .. ROOM_CODE .. "\n")
    end
end
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
        -- Reset delta-trackers so the first read in the new level re-initialises
        -- cleanly (avoids a large negative delta from the old applied total vs.
        -- the new level's starting values).
        ownCrystals      = nil
        lastGameCrystals = nil
        ownHealth        = nil
        lastGameHealth   = nil
        for _, key in ipairs({"weaponMods","abilityMods","meleeMods","perks","relics"}) do
            ownModCounts[key]      = nil
            lastGameModCounts[key] = nil
        end
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

    ownCrystals      = nil   -- re-initialise delta-trackers on next read
    lastGameCrystals = nil
    ownHealth        = nil
    lastGameHealth   = nil
    for _, key in ipairs({"weaponMods","abilityMods","meleeMods","perks","relics"}) do
        ownModCounts[key]      = nil
        lastGameModCounts[key] = nil
    end
    pendingWeapon  = nil;  pendingWCount = 0;  stableWeapon  = nil
    pendingAbility = nil;  pendingACount = 0;  stableAbility = nil
    pendingMelee   = nil;  pendingMCount = 0;  stableMelee   = nil
    print("[CrabInventorySync] Manual sync forced (F9).\n")
end)

-- Kick off the poll loop.  First tick fires after one interval so the game
-- has a moment to finish initialising before we start reading PlayerState.
ExecuteWithDelay(POLL_INTERVAL_MS, pollTick)

print("[CrabInventorySync] Loaded. Syncing every " .. POLL_INTERVAL_MS .. " ms. Press F9 to force.\n")
