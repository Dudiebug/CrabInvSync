-- Uncomment the line below to enable debug keybinds (F6/F7/F8). Remove when done.
-- require("debug")
-- require("debug_perks")

-- CrabInventorySync - main.lua
-- Syncs inventory between all players in a multiplayer session via a PowerShell bridge.
--
-- HOW IT WORKS:
--   1. All players install this mod folder and set roomCode in config.txt.
--   2. On mod load the bridge (bridge.ps1) is auto-launched as a PowerShell window.
--   3. Every 500 ms the mod checks for inventory changes and writes push_<instance>.json.
--   4. The bridge detects the file change and POSTs it to the server.
--   5. The server merges all inventories and returns the result to each bridge.
--   6. The bridge writes the merged inventory to recv_<instance>.json.
--   7. Every player reads recv_<instance>.json and applies it to their own character.
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
local SYNC_HEALTH        = false
local SYNC_SLOTS         = true
local ALLOW_SCALAR_METADATA_APPLY = false
-- Internal property name for crystals on CrabPS (adjust if values read as 0)
local CRYSTALS_PROPERTY  = "Crystals"
-- Shared secret sent with every push to keep the server endpoint private.
local ROOM_PASSWORD      = "4982904"

-- Object-dump-derived property ranges.
local BYTE_MAX       = 255
local UINT32_MAX     = 4294967295
local ITEM_LEVEL_MIN = 1

-- Objectdump: ECrabEnhancementType values are enum-backed byte-sized values.
-- Keep the numeric payload stable, but accept enum-name strings from UE4SS if a
-- build exposes TArray elements that way.
local ECRAB_ENHANCEMENT_VALUES = {
    None = 0,
    Bouncing = 1,
    Accelerating = 2,
    Zigging = 3,
    Spiraling = 4,
    Snaking = 5,
    Returning = 6,
    Orbiting = 7,
    Chipping = 8,
    Sticky = 9,
    Growing = 10,
    Freezing = 11,
    Flaming = 12,
    Electrifying = 13,
    Toxifying = 14,
    Arcanifying = 15,
    Persisting = 16,
    Doubling = 17,
    Targeting = 18,
    Damaging = 19,
    Booming = 20,
    Tripling = 21,
    Splitting = 22,
    Scattering = 23,
    Expanding = 24,
    Homing = 25,
    Endangering = 26,
    Random = 27,
    ECrabEnhancementType_MAX = 28,
}

local SCRIPT_DIR_PRIMARY   = "Mods/CrabInventorySync/Scripts/"
local SCRIPT_DIR_SECONDARY = "ue4ss/Mods/CrabInventorySync/Scripts/"

-- File-based IPC with bridge.ps1.
-- Lua writes push_<INSTANCE_ID>.json; bridge detects change and sends it via HTTP.
-- Bridge writes recv_<INSTANCE_ID>.json with the merged inventory from the server.
--
-- Per-launch INSTANCE_ID suffix prevents two game instances on the same machine
-- (split-screen, local co-op testing, multi-account box) from overwriting each
-- other's push/recv files.  Bridge receives the ID via the autolaunch VBS
-- and uses matching paths on its side.
--
-- os.time() alone isn't enough: two game processes launched in the same second
-- would produce identical IDs.  We fold in the hex address of a freshly-allocated
-- table, which differs per Lua VM (and therefore per game process), giving us
-- effectively-unique IDs without needing OS-level PID access.
local function makeInstanceId()
    local addr = tostring({}):match("0x(%x+)") or "0"
    return string.format("%d_%s", os.time(), addr)
end
local INSTANCE_ID = makeInstanceId()
local CLIENT_INSTANCE_ID = INSTANCE_ID
local PUSH_FILE = SCRIPT_DIR_PRIMARY .. "push_" .. INSTANCE_ID .. ".json"
local RECV_FILE = SCRIPT_DIR_PRIMARY .. "recv_" .. INSTANCE_ID .. ".json"

-- ============================================================
-- CONFIG LOADING
-- ============================================================
-- Whitespace trim used to clean config values before assignment.
local function configTrim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Set to false (with an error log) if the loaded config is missing required
-- fields or malformed.  pollTick / autoLaunchBridge check this before doing
-- anything that would fail silently downstream.
CONFIG_VALID = true

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

    -- Known keys → setter.  Keeping this as a table (rather than a chained
    -- elseif) lets us cheaply detect unknown keys so typos like `syncCristals`
    -- don't silently turn into "oh that setting just never worked".
    local setters = {
        serverUrl        = function(v) SERVER_URL       = v end,
        roomCode         = function(v) ROOM_CODE        = v end,
        crystalsProperty = function(v) CRYSTALS_PROPERTY = v end,
        roomPassword     = function(v) ROOM_PASSWORD    = v end,
        syncWeapon       = function(v) SYNC_WEAPON       = (v == "true") end,
        syncAbility      = function(v) SYNC_ABILITY      = (v == "true") end,
        syncMelee        = function(v) SYNC_MELEE        = (v == "true") end,
        syncCrystals     = function(v) SYNC_CRYSTALS     = (v == "true") end,
        syncWeaponMods   = function(v) SYNC_WEAPON_MODS  = (v == "true") end,
        syncAbilityMods  = function(v) SYNC_ABILITY_MODS = (v == "true") end,
        syncMeleeMods    = function(v) SYNC_MELEE_MODS   = (v == "true") end,
        syncPerks        = function(v) SYNC_PERKS        = (v == "true") end,
        syncRelics       = function(v) SYNC_RELICS       = (v == "true") end,
        syncHealth       = function(v) SYNC_HEALTH       = (v == "true") end,
        syncSlots        = function(v) SYNC_SLOTS        = (v == "true") end,
        allowScalarMetadataApply = function(v) ALLOW_SCALAR_METADATA_APPLY = (v == "true") end,
    }

    local lineNo = 0
    for line in io.lines(configPath) do
        lineNo = lineNo + 1
        -- Skip blanks and comments (# or ; prefix) without warning noise.
        local stripped = configTrim(line)
        if stripped ~= "" and not stripped:match("^[#;]") then
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key and value then
                local setter = setters[key]
                if setter then
                    setter(value)
                else
                    print(string.format(
                        "[CrabInventorySync] config.txt line %d: unknown key %q — ignoring.\n",
                        lineNo, key))
                end
            else
                print(string.format(
                    "[CrabInventorySync] config.txt line %d: malformed (expected `key = value`): %s\n",
                    lineNo, stripped))
            end
        end
    end

    -- Trim whitespace the user might have left in values.
    SERVER_URL    = configTrim(SERVER_URL)
    ROOM_CODE     = configTrim(ROOM_CODE)
    ROOM_PASSWORD = configTrim(ROOM_PASSWORD)

    -- Hard validation — silent failure here used to mean the bridge launched
    -- against an unreachable URL and the mod appeared to do nothing.
    if SERVER_URL == "" then
        print("[CrabInventorySync] ERROR: serverUrl is empty in config.txt — sync disabled.\n")
        CONFIG_VALID = false
    end
    if ROOM_CODE == "" then
        print("[CrabInventorySync] ERROR: roomCode is empty in config.txt — sync disabled.\n")
        CONFIG_VALID = false
    end

    print("[CrabInventorySync] Config loaded:\n")
    print("  roomCode  = " .. ROOM_CODE .. "\n")
    print("  serverUrl = " .. SERVER_URL .. "\n")
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

local function jsonNumber(n, decimals)
    local num = tonumber(n) or 0
    if num ~= num or num == math.huge or num == -math.huge then num = 0 end
    local s
    if decimals ~= nil then
        s = string.format("%." .. tostring(decimals) .. "f", num)
    else
        s = tostring(num)
    end
    -- Lua can honour OS locale for decimal separators; JSON always requires '.'
    return s:gsub(",", ".")
end

local function isFiniteNumber(n)
    local num = tonumber(n)
    return num ~= nil and num == num and num ~= math.huge and num ~= -math.huge
end

local function clampInt(n, minValue, maxValue)
    local value = math.floor(tonumber(n) or minValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function normalizeEnhancementValue(value)
    if value == nil then return nil end
    if type(value) == "number" then
        return clampInt(value, 0, BYTE_MAX)
    end

    local okNumeric, numeric = pcall(function() return tonumber(value) end)
    if not okNumeric then numeric = nil end
    if numeric then
        return clampInt(numeric, 0, BYTE_MAX)
    end

    local text = tostring(value)
    local enumName = text:match("ECrabEnhancementType::([%w_]+)") or text:match("([%w_]+)$")
    local mapped = enumName and ECRAB_ENHANCEMENT_VALUES[enumName]
    if mapped ~= nil then
        return clampInt(mapped, 0, BYTE_MAX)
    end

    return nil
end

local function jsonIntArray(arr)
    local parts = {}
    for _, value in ipairs(arr or {}) do
        local normalized = normalizeEnhancementValue(value)
        if normalized ~= nil then table.insert(parts, tostring(normalized)) end
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function parseEnhancementArray(raw)
    local out = {}
    if not raw then return out end
    for value in raw:gmatch("%-?%d+") do
        table.insert(out, clampInt(value, 0, BYTE_MAX))
    end
    return out
end

local function readEnhancementArray(enhancements)
    local out = {}
    if not enhancements then return out end

    pcall(function()
        enhancements:ForEach(function(_, elem)
            local raw = elem
            if type(elem) == "table" or type(elem) == "userdata" then
                local okGet, value = pcall(function() return elem:get() end)
                if okGet then raw = value end
            end
            local normalized = normalizeEnhancementValue(raw)
            if normalized ~= nil then table.insert(out, normalized) end
        end)
    end)

    return out
end

-- Encode an array of inventory items as JSON objects {n,l,a,e}, plus optional
-- slot/identity hints used only for future safe-pairing checks.
-- n = DA name, l = level (ByteProperty, 1-255), a = AccumulatedBuff (float),
-- e = InventoryInfo.Enhancements enum array.
-- This is the new payload format for weaponMods/abilityMods/meleeMods/perks/relics.
local function jsonItemArray(items)
    local parts = {}
    for _, item in ipairs(items) do
        local fields = {
            '"n":' .. jsonStr(item.name or item.n or ""),
            '"l":' .. tostring(clampInt(item.level or item.l, ITEM_LEVEL_MIN, BYTE_MAX)),
            '"a":' .. jsonNumber(item.accum or item.a, 4),
            '"e":' .. jsonIntArray(item.enhancements or item.e),
        }
        local slotIndex = item.slotIndex or item.index or item.i
        if slotIndex ~= nil then
            table.insert(fields, '"i":' .. tostring(clampInt(slotIndex, 0, UINT32_MAX)))
        end
        local fullDA = item.fullDA or item.daFullName or item.d
        if fullDA and fullDA ~= "" then
            table.insert(fields, '"d":' .. jsonStr(fullDA))
        end
        table.insert(parts, "{" .. table.concat(fields, ",") .. "}")
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function jsonUnescape(s)
    if type(s) ~= "string" then return "" end
    return s
        :gsub('\\"', '"')
        :gsub('\\\\', '\\')
        :gsub('\\n', '\n')
        :gsub('\\r', '\r')
        :gsub('\\t', '\t')
        :gsub('\\b', '\b')
        :gsub('\\f', '\f')
end

local function parseOptionalSlotIndex(obj)
    local raw = obj and obj:match('"i"%s*:%s*(%d+)')
    if raw == nil then return nil end
    return clampInt(raw, 0, UINT32_MAX)
end

local function parseOptionalFullDA(obj)
    local raw = obj and obj:match('"d"%s*:%s*"([^"]*)"')
    if not raw or raw == "" then return "" end
    return jsonUnescape(raw)
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
            local level = clampInt(obj:match('"l"%s*:%s*(%d+)'), ITEM_LEVEL_MIN, BYTE_MAX)
            local accum = tonumber(obj:match('"a"%s*:%s*(%-?[%d%.]+)')) or 0.0
            local enhancements = parseEnhancementArray(obj:match('"e"%s*:%s*(%[[^%]]*%])'))
            local slotIndex = parseOptionalSlotIndex(obj)
            local fullDA = parseOptionalFullDA(obj)
            if name and name ~= "" then
                table.insert(t, { name=name, level=level, accum=accum, enhancements=enhancements, slotIndex=slotIndex, fullDA=fullDA })
            end
            pos = objE + 1
        end
    else
        -- Legacy format: ["name1","name2"]
        local raw = json:match('"' .. key .. '"%s*:%s*(%[[^%]]*%])')
        if raw then
            for name in raw:gmatch('"([^"]*)"') do
                table.insert(t, { name=name, level=ITEM_LEVEL_MIN, accum=0.0, enhancements={} })
            end
        end
    end
    return t
end

local function encodeInventory(inv)
    local sl = inv.slots or { weaponMods=0, abilityMods=0, meleeMods=0, perks=0 }
    local parts = {
        '"weapon":' .. jsonStr(inv.weapon),
        '"ability":' .. jsonStr(inv.ability),
        '"melee":' .. jsonStr(inv.melee),
        '"crystals":' .. tostring(clampInt(inv.crystals, 0, UINT32_MAX)),
    }

    if inv.healthValid == true and inv.health ~= nil and inv.maxHealth ~= nil then
        table.insert(parts, '"healthValid":true')
        table.insert(parts, '"health":' .. jsonNumber(inv.health, 3))
        table.insert(parts, '"maxHealth":' .. jsonNumber(inv.maxHealth, 3))
    elseif inv.healthValid == false then
        table.insert(parts, '"healthValid":false')
    end

    table.insert(parts, '"weaponMods":' .. jsonItemArray(inv.weaponMods))
    table.insert(parts, '"abilityMods":' .. jsonItemArray(inv.abilityMods))
    table.insert(parts, '"meleeMods":' .. jsonItemArray(inv.meleeMods))
    table.insert(parts, '"perks":' .. jsonItemArray(inv.perks))
    table.insert(parts, '"relics":' .. jsonItemArray(inv.relics))
    table.insert(parts, string.format(
        '"slots":{"weaponMods":%d,"abilityMods":%d,"meleeMods":%d,"perks":%d}',
        clampInt(sl.weaponMods, 0, BYTE_MAX),
        clampInt(sl.abilityMods, 0, BYTE_MAX),
        clampInt(sl.meleeMods, 0, BYTE_MAX),
        clampInt(sl.perks, 0, BYTE_MAX)
    ))
    if inv.clientInstanceId and inv.clientInstanceId ~= "" then
        table.insert(parts, '"clientInstanceId":' .. jsonStr(inv.clientInstanceId))
    end
    if inv.pushSeq then
        table.insert(parts, '"pushSeq":' .. tostring(clampInt(inv.pushSeq, 0, UINT32_MAX)))
    end
    return "{" .. table.concat(parts, ",") .. "}"
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
    inv.crystals  = clampInt(json:match('"crystals"%s*:%s*(%d+)'), 0, UINT32_MAX)

    local healthFlag = json:match('"healthValid"%s*:%s*(%a+)')
    local healthRaw = tonumber(json:match('"health"%s*:%s*(%-?[%d%.]+)'))
    local maxHealthRaw = tonumber(json:match('"maxHealth"%s*:%s*(%-?[%d%.]+)'))
    if healthFlag == "false" then
        inv.healthValid = false
    elseif healthRaw ~= nil or maxHealthRaw ~= nil then
        inv.health = healthRaw
        inv.maxHealth = maxHealthRaw
        inv.healthValid = true
    else
        inv.healthValid = false
    end

    inv.weaponMods  = parseItemArray(json, "weaponMods")
    inv.abilityMods = parseItemArray(json, "abilityMods")
    inv.meleeMods   = parseItemArray(json, "meleeMods")
    inv.perks       = parseItemArray(json, "perks")
    inv.relics      = parseItemArray(json, "relics")

    -- Parse slots sub-object.
    local slotsBlock = json:match('"slots"%s*:%s*(%b{})')
    inv.slots = {
        weaponMods  = clampInt(slotsBlock and slotsBlock:match('"weaponMods"%s*:%s*(%d+)'), 0, BYTE_MAX),
        abilityMods = clampInt(slotsBlock and slotsBlock:match('"abilityMods"%s*:%s*(%d+)'), 0, BYTE_MAX),
        meleeMods   = clampInt(slotsBlock and slotsBlock:match('"meleeMods"%s*:%s*(%d+)'), 0, BYTE_MAX),
        perks       = clampInt(slotsBlock and slotsBlock:match('"perks"%s*:%s*(%d+)'), 0, BYTE_MAX),
    }
    inv.clientInstanceId = json:match('"clientInstanceId"%s*:%s*"([^"]*)"') or ""
    inv.pushSeq = clampInt(json:match('"pushSeq"%s*:%s*(%d+)'), 0, UINT32_MAX)
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

local function getDAFullName(da)
    if not da then return "" end
    local ok, v = pcall(function() return da:IsValid() end)
    if not ok or not v then return "" end
    local okFull, fullName = pcall(function() return da:GetFullName() end)
    if okFull and fullName then return tostring(fullName) end
    return getDAName(da)
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
-- { name=string, level=int, accum=float, enhancements=int[] }.
-- Reads InventoryInfo directly from each TArray struct element so the push
-- payload includes per-item Level, AccumulatedBuff, and Enhancements data.
local function readItemArray(ps, propName, daField)
    local items = {}
    local readable = false
    local okRead = pcall(function()
        local arr = ps:GetPropertyValue(propName)
        if not arr then return end
        readable = true
        arr:ForEach(function(index, elem)
            local okSlot, slot = pcall(function() return elem:get() end)
            if not okSlot or not slot:IsValid() then return end
            local okda, da = pcall(function() return slot[daField] end)
            if not okda or not da then return end
            local name = getDAName(da)
            if name == "" then return end
            local fullDA = getDAFullName(da)
            local level, accum, enhancements = 1, 0.0, {}
            pcall(function()
                local info = slot.InventoryInfo
                if info then
                    level = clampInt(info.Level, ITEM_LEVEL_MIN, BYTE_MAX)
                    accum = tonumber(info.AccumulatedBuff) or 0.0
                    enhancements = readEnhancementArray(info.Enhancements)
                end
            end)
            table.insert(items, {
                name=name,
                level=level,
                accum=accum,
                enhancements=enhancements,
                slotIndex=index,
                fullDA=fullDA,
                valid=true,
            })
        end)
    end)
    -- Preserve live slot traversal order in the payload. Sorting is reserved for
    -- comparison/signature helpers and is never used for mutation pairing.
    return items, (readable and okRead)
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
-- Compare two string arrays element-by-element.
local function arraysEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function normalizedAccum(value)
    local n = tonumber(value) or 0.0
    if n ~= n or n == math.huge or n == -math.huge then return 0.0 end
    return n
end

local function normalizeEnhancementList(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        local normalized = normalizeEnhancementValue(value)
        if normalized ~= nil then table.insert(out, normalized) end
    end
    return out
end

local function normalizeItem(item)
    item = item or {}
    return {
        name = tostring(item.name or item.n or ""),
        level = clampInt(item.level or item.l, ITEM_LEVEL_MIN, BYTE_MAX),
        accum = normalizedAccum(item.accum or item.a),
        enhancements = normalizeEnhancementList(item.enhancements or item.e),
        slotIndex = item.slotIndex or item.index or item.i,
        fullDA = tostring(item.fullDA or item.daFullName or item.d or ""),
    }
end

local function enhancementSignature(enhancements)
    local parts = {}
    for _, value in ipairs(normalizeEnhancementList(enhancements)) do
        table.insert(parts, tostring(value))
    end
    return table.concat(parts, ",")
end

local function itemSignature(item)
    local normalized = normalizeItem(item)
    return table.concat({
        normalized.name,
        tostring(normalized.level),
        jsonNumber(normalized.accum, 4),
        enhancementSignature(normalized.enhancements),
    }, "|")
end

local function sortedItemSignatures(items)
    local signatures = {}
    for _, item in ipairs(items or {}) do
        local normalized = normalizeItem(item)
        if normalized.name ~= "" then table.insert(signatures, itemSignature(normalized)) end
    end
    table.sort(signatures)
    return signatures
end

local function itemSignaturesInOrder(items)
    local signatures = {}
    for _, item in ipairs(items or {}) do
        local normalized = normalizeItem(item)
        if normalized.name ~= "" then table.insert(signatures, itemSignature(normalized)) end
    end
    return signatures
end

local function sortedItemNames(items)
    local names = {}
    for _, item in ipairs(items or {}) do
        local normalized = normalizeItem(item)
        if normalized.name ~= "" then table.insert(names, normalized.name) end
    end
    table.sort(names)
    return names
end

local function sortedNormalizedItems(items)
    local normalized = {}
    for _, item in ipairs(items or {}) do
        local n = normalizeItem(item)
        if n.name ~= "" then table.insert(normalized, n) end
    end
    table.sort(normalized, function(a, b)
        return itemSignature(a) < itemSignature(b)
    end)
    return normalized
end

local function groupItemsByName(items)
    local groups = {}
    for _, item in ipairs(items or {}) do
        local normalized = normalizeItem(item)
        if normalized.name ~= "" then
            if not groups[normalized.name] then groups[normalized.name] = {} end
            table.insert(groups[normalized.name], item)
        end
    end
    return groups
end

local function getItemsFromPS(ps, propName, daField)
    local items = {}
    pcall(function()
        local arr = ps:GetPropertyValue(propName)
        if not arr then return end
        arr:ForEach(function(index, elem)
            local okSlot, slot = pcall(function() return elem:get() end)
            local slotValid = false
            if okSlot and slot then
                local okValid, valid = pcall(function() return slot:IsValid() end)
                slotValid = okValid and valid
            end
            if slotValid then
                local okDa, da = pcall(function() return slot[daField] end)
                if okDa and da then
                    local name = getDAName(da)
                    if name ~= "" then
                        local fullDA = getDAFullName(da)
                        local level, accum, enhancements, info = ITEM_LEVEL_MIN, 0.0, {}, nil
                        pcall(function()
                            info = slot.InventoryInfo
                            if info then
                                level = clampInt(info.Level, ITEM_LEVEL_MIN, BYTE_MAX)
                                accum = normalizedAccum(info.AccumulatedBuff)
                                enhancements = readEnhancementArray(info.Enhancements)
                            end
                        end)
                        table.insert(items, {
                            name=name,
                            level=level,
                            accum=accum,
                            enhancements=enhancements,
                            slot=slot,
                            info=info,
                            index=index,
                            slotIndex=index,
                            fullDA=fullDA,
                            valid=true,
                        })
                    end
                end
            end
        end)
    end)
    return items
end

local function itemIdentityKey(item)
    local normalized = normalizeItem(item)
    if normalized.fullDA ~= "" then return normalized.fullDA end
    return normalized.name
end

local function hasDuplicateIdentity(items)
    local counts = {}
    for _, item in ipairs(items or {}) do
        local key = itemIdentityKey(item)
        if key ~= "" then
            counts[key] = (counts[key] or 0) + 1
            if counts[key] > 1 then return true, key end
        end
    end
    return false, nil
end

local function pairItemsBySlotIdentity(gameItems, recvItems)
    local liveBySlot = {}
    local recvBySlot = {}

    for _, live in ipairs(gameItems or {}) do
        if live.slotIndex == nil and live.index ~= nil then live.slotIndex = live.index end
        if live.slotIndex == nil then
            return nil, "unsafe pairing"
        end
        if liveBySlot[live.slotIndex] then
            return nil, "unsafe pairing"
        end
        liveBySlot[live.slotIndex] = live
    end

    for _, item in ipairs(recvItems or {}) do
        local incoming = normalizeItem(item)
        if incoming.slotIndex == nil then
            return nil, "unsafe pairing"
        end
        if recvBySlot[incoming.slotIndex] then
            return nil, "unsafe pairing"
        end
        recvBySlot[incoming.slotIndex] = incoming
    end

    local pairsOut = {}
    for slotIndex, incoming in pairs(recvBySlot) do
        local live = liveBySlot[slotIndex]
        if not live then
            return nil, "unsafe pairing"
        end
        if live.fullDA == nil or live.fullDA == "" or incoming.fullDA == nil or incoming.fullDA == "" then
            return nil, "unsafe pairing"
        end
        if live.fullDA ~= incoming.fullDA then
            return nil, "DA mismatch"
        end
        table.insert(pairsOut, { live=live, incoming=incoming })
    end

    return pairsOut, nil
end

local function logMetadataSkip(label, reason)
    print(string.format("[CrabSync:apply] %s metadata write skipped: %s\n", label, reason))
end

local function applyScalarMetadataForPairs(label, gameItems, recvItems, guard)
    guard = guard or {}

    if not ALLOW_SCALAR_METADATA_APPLY then
        print(string.format("[CrabSync:apply] %s metadata compared but not written: scalar apply disabled\n", label))
        logMetadataSkip(label, "scalar apply disabled")
        return false
    end
    if guard.staleRecv then
        logMetadataSkip(label, "stale recv")
        return false
    end
    if guard.lessCompleteRecv or itemReadinessReady ~= true then
        logMetadataSkip(label, "unsafe pairing")
        return false
    end

    local liveDup, liveDupKey = hasDuplicateIdentity(gameItems)
    local recvDup, recvDupKey = hasDuplicateIdentity(recvItems)
    if liveDup or recvDup then
        logMetadataSkip(label, "duplicate ambiguity")
        print(string.format(
            "[CrabSync:apply] %s duplicate ambiguity detail: %s\n",
            label, tostring(liveDupKey or recvDupKey or "?")))
        return false
    end

    local pairsOut, err = pairItemsBySlotIdentity(gameItems, recvItems)
    if not pairsOut then
        if err == "DA mismatch" then
            logMetadataSkip(label, "DA mismatch")
        else
            logMetadataSkip(label, "unsafe pairing")
        end
        return false
    end

    local updated, alreadyMatched, enhancementSkipped = 0, 0, 0
    for _, pair in ipairs(pairsOut) do
        local live, incoming = pair.live, pair.incoming
        if not live.info then
            print(string.format("[CrabSync:apply] %s scalar metadata skipped for %s: InventoryInfo unavailable\n", label, live.name))
        else
            local wantedLevel = clampInt(incoming.level, ITEM_LEVEL_MIN, BYTE_MAX)
            local wantedAccum = normalizedAccum(incoming.accum)
            local curLevel = clampInt(live.info.Level, ITEM_LEVEL_MIN, BYTE_MAX)
            local curAccum = normalizedAccum(live.info.AccumulatedBuff)
            local changed = false

            if curLevel ~= wantedLevel then
                pcall(function() live.info.Level = wantedLevel end)
                changed = true
            end
            if jsonNumber(curAccum, 4) ~= jsonNumber(wantedAccum, 4) then
                pcall(function() live.info.AccumulatedBuff = wantedAccum end)
                changed = true
            end

            if changed then
                updated = updated + 1
                print(string.format(
                    "[CrabSync:apply] %s scalar metadata updated for %s: level %d->%d, accum %s->%s\n",
                    label, live.name, curLevel, wantedLevel, jsonNumber(curAccum, 4), jsonNumber(wantedAccum, 4)))
            else
                alreadyMatched = alreadyMatched + 1
            end

            if enhancementSignature(live.enhancements) ~= enhancementSignature(incoming.enhancements) then
                enhancementSkipped = enhancementSkipped + 1
                print(string.format(
                    "[CrabSync:apply] %s enhancement mismatch compared but not written for %s: game=[%s] recv=[%s]\n",
                    label, live.name, enhancementSignature(live.enhancements), enhancementSignature(incoming.enhancements)))
            end
        end
    end

    if updated == 0 and enhancementSkipped == 0 then
        print(string.format("[CrabSync:apply] %s scalar metadata already matched (%d paired items)\n", label, alreadyMatched))
    end
    return updated > 0
end

local function compareItemMetadata(gameItems, recvItems)
    local gameNames = sortedItemNames(gameItems)
    local recvNames = sortedItemNames(recvItems)
    if not arraysEqual(gameNames, recvNames) then
        return { kind="name mismatch", slotWriteCandidate=true }
    end

    local gameSorted = sortedItemSignatures(gameItems)
    local recvSorted = sortedItemSignatures(recvItems)
    if arraysEqual(gameSorted, recvSorted) then
        if arraysEqual(itemSignaturesInOrder(gameItems), itemSignaturesInOrder(recvItems)) then
            return { kind="same" }
        end
        return { kind="reorder-only no-op" }
    end

    local gameNorm = sortedNormalizedItems(gameItems)
    local recvNorm = sortedNormalizedItems(recvItems)
    local flags = { level=false, accum=false, enhancements=false }
    local maxLen = math.max(#gameNorm, #recvNorm)
    for i = 1, maxLen do
        local g, r = gameNorm[i], recvNorm[i]
        if g and r and g.name == r.name then
            if g.level ~= r.level then flags.level = true end
            if jsonNumber(g.accum, 4) ~= jsonNumber(r.accum, 4) then flags.accum = true end
            if enhancementSignature(g.enhancements) ~= enhancementSignature(r.enhancements) then
                flags.enhancements = true
            end
        end
    end

    local reasons = {}
    if flags.level then table.insert(reasons, "level mismatch") end
    if flags.accum then table.insert(reasons, "accumulated buff mismatch") end
    if flags.enhancements then table.insert(reasons, "enhancement mismatch") end
    if #reasons == 0 then table.insert(reasons, "metadata mismatch") end
    return {
        kind = table.concat(reasons, ", "),
        metadataMismatch = true,
        enhancementMismatch = flags.enhancements,
    }
end

-- Return (filledSlots, totalSlots) for a TArray inventory property.
-- A slot is "filled" when it has a readable DA name; empty/unreadable slots still
-- count toward totalSlots capacity.
local function getArrayOccupancy(ps, propName, daField)
    local filled, total = 0, 0
    pcall(function()
        local arr = ps:GetPropertyValue(propName)
        if not arr then return end
        arr:ForEach(function(_, elem)
            if not elem:get():IsValid() then return end
            total = total + 1
            local ok, da = pcall(function() return elem:get()[daField] end)
            if not ok or not da then return end
            local name = getDAName(da)
            if name ~= "" then filled = filled + 1 end
        end)
    end)
    return filled, total
end

-- Weapon/ability/melee debounce state.
-- The game briefly reports a stale ability during ability use (e.g. Black Hole → Grappling
-- Hook for one tick while the animation plays).  We only promote a new value to "stable"
-- after SLOT_STABLE_TICKS consecutive identical reads, so that flicker never reaches PUSH_FILE.
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
local EQUIP_HEALTH_ZERO_GRACE_MS    = 1000
local EQUIP_HEALTH_ZERO_GRACE_TICKS = 2   -- recalculated from POLL_INTERVAL_MS below
local equipHealthZeroReadsRemaining = 0

-- Forward declarations for delta-tracking state so read/apply helpers below
-- and the poll-loop code later share the same upvalues.
local ownCrystals, lastGameCrystals
local ownHealth, lastGameHealth
local ownMaxHealth, lastGameMaxHealth
local hasConfirmedValidHealthSample = false
local ownSlots      = { weaponMods=0, abilityMods=0, meleeMods=0, perks=0 }
local lastGameSlots = { weaponMods=nil, abilityMods=nil, meleeMods=nil, perks=nil }
local lastSentPushSeq = 0

-- Transient-empty-read debounce for readItemArray.  TArrays occasionally read as
-- empty for a single tick while the engine is mid-update (e.g. swapping a mod);
-- that briefly "unequipped" state would otherwise get pushed to the server and
-- broadcast to every other player until the next tick corrected it.  We reuse
-- the previous non-empty read for up to EMPTY_READ_CONFIRM_TICKS consecutive
-- empty reads; a real unequip is accepted on the tick after that.
local EMPTY_READ_CONFIRM_TICKS = 2
local lastNonEmptyItems = {}   -- cat.inv -> previous items[] (only when non-empty)
local emptyReadStreak   = {}   -- cat.inv -> consecutive empty-read count

-- Startup item-array readiness gate.  The first few PlayerState reads can expose
-- valid equipment DAs while mod/perk/relic TArrays are still empty or only partly
-- populated.  We require several consecutive whole-inventory item reads before any
-- item arrays are allowed into PUSH_FILE, and keep the last stable local item state
-- when startup/readiness reads briefly go less complete.
local ITEM_ARRAY_STABLE_TICKS = 3
local ITEM_ARRAY_CATEGORIES = {
    { key="weaponMods",  prop="WeaponMods",  da="WeaponModDA",  flag=function() return SYNC_WEAPON_MODS end },
    { key="abilityMods", prop="AbilityMods", da="AbilityModDA", flag=function() return SYNC_ABILITY_MODS end },
    { key="meleeMods",   prop="MeleeMods",   da="MeleeModDA",   flag=function() return SYNC_MELEE_MODS end },
    { key="perks",       prop="Perks",       da="PerkDA",       flag=function() return SYNC_PERKS end },
    { key="relics",      prop="Relics",      da="RelicDA",      flag=function() return SYNC_RELICS end },
}
local itemReadinessCandidateSig = nil
local itemReadinessCandidateTicks = 0
local itemReadinessReady = false
local itemReadinessStableState = nil

local function cloneItem(item)
    local src = normalizeItem(item)
    local enhancements = {}
    for _, value in ipairs(src.enhancements or {}) do table.insert(enhancements, value) end
    return {
        name=src.name,
        level=src.level,
        accum=src.accum,
        enhancements=enhancements,
        slotIndex=src.slotIndex,
        fullDA=src.fullDA,
    }
end

local function cloneItemArraysFrom(inv)
    local out = {}
    for _, cat in ipairs(ITEM_ARRAY_CATEGORIES) do
        out[cat.key] = {}
        for _, item in ipairs((inv and inv[cat.key]) or {}) do
            table.insert(out[cat.key], cloneItem(item))
        end
    end
    return out
end

local function copyItemArraysInto(inv, source)
    if not inv or not source then return end
    for _, cat in ipairs(ITEM_ARRAY_CATEGORIES) do
        inv[cat.key] = {}
        for _, item in ipairs(source[cat.key] or {}) do
            table.insert(inv[cat.key], cloneItem(item))
        end
    end
end

local function itemArraySummary(inv)
    local parts = {}
    for _, cat in ipairs(ITEM_ARRAY_CATEGORIES) do
        table.insert(parts, cat.key .. "=" .. tostring(#((inv and inv[cat.key]) or {})))
    end
    return table.concat(parts, " ")
end

local function itemReadinessSignature(inv)
    local parts = {}
    for _, cat in ipairs(ITEM_ARRAY_CATEGORIES) do
        table.insert(parts, cat.key .. ":" .. table.concat(sortedItemSignatures((inv and inv[cat.key]) or {}), ";"))
    end
    return table.concat(parts, "|")
end

local function itemStateLessComplete(candidate, stable)
    if not candidate or not stable then return false end
    for _, cat in ipairs(ITEM_ARRAY_CATEGORIES) do
        if #((candidate[cat.key]) or {}) < #((stable[cat.key]) or {}) then
            return true, cat.key
        end
    end
    return false, nil
end

local function hasStableItemCategory(key)
    return itemReadinessStableState ~= nil and itemReadinessStableState[key] ~= nil
end

local function itemCountsByName(items)
    local counts = {}
    for _, item in ipairs(items or {}) do
        local name = normalizeItem(item).name
        if name ~= "" then counts[name] = (counts[name] or 0) + 1 end
    end
    return counts
end

local function itemCountsEqualByName(left, right)
    local leftCounts = itemCountsByName(left)
    local rightCounts = itemCountsByName(right)
    for name, count in pairs(leftCounts) do
        if (rightCounts[name] or 0) ~= count then return false end
    end
    for name, count in pairs(rightCounts) do
        if (leftCounts[name] or 0) ~= count then return false end
    end
    return true
end

local function itemListLessCompleteThanReference(candidate, reference)
    if not candidate or not reference then return false end
    if #candidate < #reference then return true end

    local candidateCounts = itemCountsByName(candidate)
    local referenceCounts = itemCountsByName(reference)
    for name, count in pairs(referenceCounts) do
        if (candidateCounts[name] or 0) < count then return true end
    end
    return false
end

local function resetItemReadiness()
    itemReadinessCandidateSig = nil
    itemReadinessCandidateTicks = 0
    itemReadinessReady = false
    itemReadinessStableState = nil
    lastNonEmptyItems = {}
    emptyReadStreak = {}
end

local function updateItemReadiness(inv, readable)
    local allReadable = true
    for _, cat in ipairs(ITEM_ARRAY_CATEGORIES) do
        if cat.flag() and readable[cat.key] ~= true then
            allReadable = false
            break
        end
    end

    local lessComplete, lessKey = itemStateLessComplete(inv, itemReadinessStableState)
    if lessComplete then
        copyItemArraysInto(inv, itemReadinessStableState)
        inv._itemReadinessReusedStable = true
        print(string.format(
            "[CrabSync:read] item push skipped transient startup read - %s less complete; reusing stable %s\n",
            lessKey or "items", itemArraySummary(inv)))
    end

    if not allReadable then
        inv._itemsReady = false
        print(string.format(
            "[CrabSync:read] item push skipped transient startup read - arrays not readable (%s)\n",
            itemArraySummary(inv)))
        return
    end

    local sig = itemReadinessSignature(inv)
    if sig ~= itemReadinessCandidateSig then
        itemReadinessCandidateSig = sig
        itemReadinessCandidateTicks = 1
        print(string.format(
            "[CrabSync:read] item readiness candidate: %s ticks=1/%d\n",
            itemArraySummary(inv), ITEM_ARRAY_STABLE_TICKS))
    else
        itemReadinessCandidateTicks = itemReadinessCandidateTicks + 1
        if not itemReadinessReady then
            print(string.format(
                "[CrabSync:read] item readiness candidate: %s ticks=%d/%d\n",
                itemArraySummary(inv), itemReadinessCandidateTicks, ITEM_ARRAY_STABLE_TICKS))
        end
    end

    if itemReadinessCandidateTicks >= ITEM_ARRAY_STABLE_TICKS then
        itemReadinessStableState = cloneItemArraysFrom(inv)
        if not itemReadinessReady then
            print(string.format("[CrabSync:read] item readiness stable: %s\n", itemArraySummary(inv)))
        end
        itemReadinessReady = true
    end
    inv._itemsReady = itemReadinessReady
end

-- ============================================================
-- INVENTORY READ
-- ============================================================
local function readInventory(ps)
    local inv = {
        weapon = "", ability = "", melee = "",
        crystals = 0, keys = 0,
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

    if SYNC_CRYSTALS then
        pcall(function()
            local raw = clampInt(ps:GetPropertyValue(CRYSTALS_PROPERTY), 0, UINT32_MAX)
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
                ownCrystals      = clampInt((ownCrystals or 0) + delta, 0, UINT32_MAX)
                lastGameCrystals = raw
            end
            inv.crystals = ownCrystals
        end)
    end

    if SYNC_HEALTH then
        inv.healthValid = false
        pcall(function()
            local hc = getLocalHC()
            if not hc then
                print("[CrabSync:health] health read skipped: HC not ready\n")
                return
            end
            local hi = hc:GetPropertyValue("HealthInfo")
            if not hi then
                print("[CrabSync:health] health read skipped: HealthInfo not ready\n")
                return
            end
            local ignoreHealthZeroThisRead = (equipHealthZeroReadsRemaining > 0)
            -- HealthInfo is a struct: direct field access only (no GetPropertyValue).
            -- Field names from object dump section 5 (CrabHealthInfo):
            --   0x0C  CurrentHealth     - the real live HP value
            --   0x10  CurrentMaxHealth  - effective max HP (BaseMaxHealth * MaxHealthMultiplier)
            -- NOTE: there is NO field named "MaxHealth" on CrabHealthInfo.
            local raw = hi.CurrentHealth
            local maxRaw = hi.CurrentMaxHealth

            if not isFiniteNumber(maxRaw) or tonumber(maxRaw) <= 0 then
                print("[CrabSync:health] health read skipped: HealthInfo not ready\n")
                return
            end
            if not isFiniteNumber(raw) then
                print("[CrabSync:health] health read skipped: HealthInfo not ready\n")
                return
            end

            raw = tonumber(raw)
            maxRaw = tonumber(maxRaw)
            if raw == 0 and ignoreHealthZeroThisRead then
                print("[CrabSync:health] health read skipped: startup zero\n")
                equipHealthZeroReadsRemaining = math.max(0, equipHealthZeroReadsRemaining - 1)
                return
            end
            if raw == 0 and not hasConfirmedValidHealthSample then
                print("[CrabSync:health] health read skipped: startup zero\n")
                return
            end

            if raw > 0 then
                hasConfirmedValidHealthSample = true
            end

            if raw > 0 then
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
            else
                -- Player is dead. Anchor to 0 so respawn delta is counted correctly.
                ownHealth      = 0
                lastGameHealth = 0
            end

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

            inv.health = ownHealth
            inv.maxHealth = ownMaxHealth
            inv.healthValid = (ownHealth ~= nil and ownMaxHealth ~= nil)
            print(string.format(
                "[CrabSync:health] health read valid: health=%s maxHealth=%s\n",
                jsonNumber(inv.health, 3), jsonNumber(inv.maxHealth, 3)))
            if equipHealthZeroReadsRemaining > 0 then
                equipHealthZeroReadsRemaining = equipHealthZeroReadsRemaining - 1
            end
        end)
    end

    -- Read full item data (name + Level + AccumulatedBuff) from each TArray slot.
    -- readItemArray reads InventoryInfo directly from the struct so Level and
    -- AccumulatedBuff are captured in the push payload. Slot traversal order is
    -- preserved; sorted signatures are only used for comparison/no-op detection.
    local itemReadable = {}
    for _, cat in ipairs(ITEM_ARRAY_CATEGORIES) do
        if cat.flag() then
            local items, readable = readItemArray(ps, cat.prop, cat.da)
            local key = cat.key
            itemReadable[key] = readable
            if #items == 0
               and lastNonEmptyItems[key]
               and (emptyReadStreak[key] or 0) < EMPTY_READ_CONFIRM_TICKS
            then
                -- Suspected transient empty read — reuse last non-empty value
                -- until we've seen EMPTY_READ_CONFIRM_TICKS consecutive empties.
                emptyReadStreak[key] = (emptyReadStreak[key] or 0) + 1
                inv[key] = lastNonEmptyItems[key]
            else
                if #items > 0 then
                    lastNonEmptyItems[key] = items
                    emptyReadStreak[key]   = 0
                else
                    emptyReadStreak[key] = (emptyReadStreak[key] or 0) + 1
                end
                inv[key] = items
            end
        else
            inv[cat.key] = {}
            itemReadable[cat.key] = true
        end
    end

    updateItemReadiness(inv, itemReadable)

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
                local raw = clampInt(ps:GetPropertyValue(sp.prop), 0, BYTE_MAX)
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
                        ownSlots[sp.key] = clampInt((ownSlots[sp.key] or 0) + delta, 0, BYTE_MAX)
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
    local applyReport = { applied=false, partialSkipped=false }
    if not ps or not inv then return applyReport end
    local ok, valid = pcall(function() return ps:IsValid() end)
    if not ok or not valid then return applyReport end

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
            local emptyRecvW = SYNC_WEAPON  and (inv.weapon  or "") == "" and curWeapon  ~= ""
            local emptyRecvA = SYNC_ABILITY and (inv.ability or "") == "" and curAbility ~= ""
            local emptyRecvM = SYNC_MELEE   and (inv.melee   or "") == "" and curMelee   ~= ""
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
            if emptyRecvW or emptyRecvA or emptyRecvM then
                applyReport.partialSkipped = true
                print(string.format(
                    "[CrabSync:apply] partial skip: empty recv equipment ignored over local W=%s A=%s M=%s\n",
                    tostring(emptyRecvW), tostring(emptyRecvA), tostring(emptyRecvM)))
            end
            if blockedW then newWeapon  = curWeapon  end
            if blockedA then newAbility = curAbility end
            if blockedM then newMelee   = curMelee   end
            if blockedW or blockedA or blockedM then
                applyReport.partialSkipped = true
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
                applyReport.applied = true
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
    if SYNC_CRYSTALS and inv.crystals ~= nil then
        pcall(function()
            -- CrabPS.Crystals is UInt32Property (dump §2.1 offset 0x470) — unsigned,
            -- range 0–4,294,967,295.  A pooled server total from many players could exceed
            -- that; clamping prevents a wrap-to-near-zero write that would wipe all crystals.
            local total   = clampInt(inv.crystals, 0, UINT32_MAX)
            local current = clampInt(ps:GetPropertyValue(CRYSTALS_PROPERTY), 0, UINT32_MAX)
            -- Always write the merged total, even if it is lower than the current value.
            -- The delta-tracker in readInventory already anchors lastGameCrystals to
            -- whatever we write here, so the very next tick sees delta = 0 and does NOT
            -- re-add the synced total to ownCrystals.  Without this, crystals spent by
            -- another player (or crystals that drop after a player disconnects) would
            -- never propagate — the "only increase" guard silently blocks the write.
            if total ~= current then
                ps:SetPropertyValue(CRYSTALS_PROPERTY, total)
                lastGameCrystals = total   -- anchor: next read delta = 0
                applyReport.applied = true
                pcall(function() ps:OnRep_Crystals() end)
            end
        end)
    end


    if SYNC_HEALTH then
        pcall(function()
            if inv.healthValid ~= true or inv.health == nil or inv.maxHealth == nil then
                print("[CrabSync:health] server/recv health invalid\n")
                print("[CrabSync:health] health apply skipped\n")
                applyReport.partialSkipped = true
                return
            end

            local mergedHP = math.max(0, math.floor(tonumber(inv.health) or 0))
            mergedMax = math.max(0, math.floor(tonumber(inv.maxHealth) or 0))
            if mergedMax <= 0 then
                print("[CrabSync:health] server/recv health invalid\n")
                print("[CrabSync:health] health apply skipped\n")
                applyReport.partialSkipped = true
                return
            end
            if mergedHP == 0 and not hasConfirmedValidHealthSample then
                print("[CrabSync:health] server/recv health invalid\n")
                print("[CrabSync:health] health apply skipped\n")
                applyReport.partialSkipped = true
                return
            end

            local hc = getLocalHC()
            if not hc then
                print("[CrabSync:health] health apply skipped\n")
                applyReport.partialSkipped = true
                return
            end
            local hi = hc:GetPropertyValue("HealthInfo")
            if not hi then
                print("[CrabSync:health] health apply skipped\n")
                applyReport.partialSkipped = true
                return
            end

            local localMax = nil
            pcall(function() localMax = tonumber(hi.CurrentMaxHealth) end)
            if (not hasConfirmedValidHealthSample) and (not isFiniteNumber(localMax) or localMax <= 0) then
                print("[CrabSync:health] health apply skipped\n")
                applyReport.partialSkipped = true
                return
            end

            local didWrite = false

            -- Apply pooled max HP first so the ceiling is raised before current HP.
            -- Server SUMs maxHealth across players (same as current HP), so two players
            -- at 250 maxHP each → everyone gets 500 maxHP applied.
            -- SetPropertyValue on struct fields bypasses engine clamping, so the game
            -- stores exactly what we write — the delta tracker sees 0 next tick.
            local mergedMax = math.max(0, math.floor(tonumber(inv.maxHealth) or 0))
            if mergedMax >= 0 then
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
            mergedHP = math.max(0, math.floor(tonumber(inv.health) or 0))
            if mergedHP >= 0 then
                local currentHP = 0
                pcall(function() currentHP = math.floor(tonumber(hi.CurrentHealth) or 0) end)
                if mergedHP ~= currentHP then
                    hi.CurrentHealth = mergedHP
                    lastGameHealth   = mergedHP  -- anchor: next read delta = 0
                    didWrite = true
                end
            end

            if didWrite then
                applyReport.applied = true
                pcall(function() hc:OnRep_HealthInfo() end)
            end
            print(string.format(
                "[CrabSync:health] health apply accepted: health=%d maxHealth=%d wrote=%s\n",
                math.max(0, math.floor(tonumber(inv.health) or 0)),
                math.max(0, math.floor(tonumber(inv.maxHealth) or 0)),
                tostring(didWrite)))
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

            -- Collect the mods still needed in incoming payload order. Sorted
            -- signatures are comparison-only; they are not used for mutation.
            local modsToPlace = {}
            for _, name in ipairs(sourceNames) do
                if wanted[name] and wanted[name] > 0 then
                    table.insert(modsToPlace, name)
                    wanted[name] = wanted[name] - 1
                end
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
    -- METADATA-AWARE GUARD: before each slot write, compare sorted item
    -- signatures from recv against the live TArray. A signature includes DA
    -- name, Level, AccumulatedBuff, and Enhancements, so same-name metadata
    -- differences are detected while reorder-only changes remain no-ops.
    --
    -- Why this matters:
    --   applySlotArray writes recv[1] → slot 0, recv[2] → slot 1, etc.  If TArray
    --   reordering has shuffled the game's internal order, the write swaps the DA
    --   pointer in each slot WITHOUT moving the InventoryInfo struct (Level, Enhancements
    --   live with the slot, not the DA).  Result: mod names rotate between slots while
    --   their Levels stay behind — the "shuffle" bug.  Skipping the write when
    --   metadata signatures match prevents this entirely.
    if itemReadinessReady ~= true then
        applyReport.partialSkipped = true
        print("[CrabSync:apply] item apply skipped: local item readiness not stable\n")
        print("[CrabSync:apply] item apply skipped: readiness false\n")
    else
        for _, entry in ipairs({
            { flag=SYNC_WEAPON_MODS,  prop="WeaponMods",  da="WeaponModDA",  list=weaponModDAs,  src=inv.weaponMods,  key="weaponMods"  },
            { flag=SYNC_ABILITY_MODS, prop="AbilityMods", da="AbilityModDA", list=abilityModDAs, src=inv.abilityMods, key="abilityMods" },
            { flag=SYNC_MELEE_MODS,   prop="MeleeMods",   da="MeleeModDA",   list=meleeModDAs,   src=inv.meleeMods,   key="meleeMods"   },
            { flag=SYNC_PERKS,        prop="Perks",       da="PerkDA",       list=perkDAs,       src=inv.perks,       key="perks"       },
            { flag=SYNC_RELICS,       prop="Relics",      da="RelicDA",      list=relicDAs,      src=inv.relics,      key="relics"      },
        }) do
            if entry.flag then
            -- entry.src is an array of {name,level,accum,enhancements} objects.
            -- Compare full metadata signatures first; only DA-name mismatches can
            -- trigger slot writes.
            local recvItems = {}
            for _, item in ipairs(entry.src) do table.insert(recvItems, normalizeItem(item)) end
            local gameItems = getItemsFromPS(ps, entry.prop, entry.da)
            local recvIsSelfEcho = (inv.clientInstanceId ~= nil and inv.clientInstanceId ~= "" and inv.clientInstanceId == CLIENT_INSTANCE_ID)
            local recvPushSeq = clampInt(inv.pushSeq, 0, UINT32_MAX)
            local oldSelfEcho = recvIsSelfEcho and recvPushSeq < lastSentPushSeq
            local stableItems = (itemReadinessStableState and itemReadinessStableState[entry.key]) or nil
            local lessCompleteRecv = (#recvItems < #gameItems) or itemListLessCompleteThanReference(recvItems, stableItems)
            local recvNames = {}
            for _, item in ipairs(recvItems) do table.insert(recvNames, item.name) end
            local metadataGuard = {
                staleRecv = oldSelfEcho,
                lessCompleteRecv = lessCompleteRecv,
            }
            local structuralApplyBlocked = false

            if oldSelfEcho then
                structuralApplyBlocked = true
                applyReport.partialSkipped = true
                print(string.format(
                    "[CrabSync:apply] structural apply skipped: self echo - %s recvSeq=%d localSeq=%d\n",
                    entry.prop, recvPushSeq, lastSentPushSeq))
                print(string.format(
                    "[CrabSync:apply] %s metadata write skipped: stale recv\n",
                    entry.prop))
            end
            if lessCompleteRecv then
                structuralApplyBlocked = true
                applyReport.partialSkipped = true
                print(string.format(
                    "[CrabSync:apply] structural apply skipped: less-complete recv - startup/self-echo less-complete recv skipped. %s game=%d recv=%d stable=%s\n",
                    entry.prop, #gameItems, #recvItems, tostring(hasStableItemCategory(entry.key))))
                print(string.format(
                    "[CrabSync:apply] %s metadata write skipped: unsafe pairing\n",
                    entry.prop))
            end

            local diff = compareItemMetadata(gameItems, recvItems)

            if diff.kind == "reorder-only no-op" then
                print(string.format(
                    "[CrabSync:apply] %s reorder-only no-op - item metadata signatures match\n",
                    entry.prop))
            elseif diff.kind == "same" then
                if applyScalarMetadataForPairs(entry.prop, gameItems, recvItems, metadataGuard) then
                    applyReport.applied = true
                end
            elseif diff.metadataMismatch then
                print(string.format(
                    "[CrabSync:apply] %s metadata differs (%s) - no slot rebuild\n",
                    entry.prop, diff.kind))
                if applyScalarMetadataForPairs(entry.prop, gameItems, recvItems, metadataGuard) then
                    applyReport.applied = true
                end
            elseif diff.slotWriteCandidate then
                local gameSorted = sortedItemNames(gameItems)
                local sortedSrc = sortedItemNames(recvItems)
                local gameCounts = {}
                for _, name in ipairs(gameSorted) do
                    gameCounts[name] = (gameCounts[name] or 0) + 1
                end
                local recvCounts = {}
                for _, name in ipairs(sortedSrc) do
                    recvCounts[name] = (recvCounts[name] or 0) + 1
                end

                local missingInRecv = false
                for name, count in pairs(gameCounts) do
                    if (recvCounts[name] or 0) < count then
                        missingInRecv = true
                        break
                    end
                end

                local newInRecv = false
                for name, count in pairs(recvCounts) do
                    if (gameCounts[name] or 0) < count then
                        newInRecv = true
                        break
                    end
                end

                local filledSlots, totalSlots = getArrayOccupancy(ps, entry.prop, entry.da)
                local hasVacancy = totalSlots > filledSlots
                if structuralApplyBlocked then
                    if itemCountsEqualByName(gameItems, recvItems) then
                        if applyScalarMetadataForPairs(entry.prop, gameItems, recvItems, metadataGuard) then
                            applyReport.applied = true
                        end
                    end
                elseif missingInRecv or (newInRecv and hasVacancy) then
                    local reason = missingInRecv and "recv has different item names at same count" or "recv adds items and local slot vacancy exists"
                    print(string.format(
                        "[CrabSync:apply] structural apply allowed: reason=%s (%s)\n",
                        reason, entry.prop))
                    print(string.format(
                        "[CrabSync:apply] %s name mismatch (%d game / %d recv, slots %d/%d) - writing slots\n",
                        entry.prop, #gameSorted, #sortedSrc, filledSlots, totalSlots))
                    -- applySlotArray expects a flat name list for its wanted-set logic.
                    applySlotArray(entry.prop, entry.da, entry.list, recvNames)
                    applyReport.applied = true
                    local postWriteItems = getItemsFromPS(ps, entry.prop, entry.da)
                    print(string.format(
                        "[CrabSync:apply] %s structural apply metadata preservation not guaranteed; risky metadata writes remain quarantined\n",
                        entry.prop))
                    if applyScalarMetadataForPairs(entry.prop, postWriteItems, recvItems, metadataGuard) then
                        applyReport.applied = true
                    end
                else
                    print(string.format(
                        "[CrabSync:apply] %s name mismatch (%d game / %d recv, slots %d/%d) - no safe slot write\n",
                        entry.prop, #gameSorted, #sortedSrc, filledSlots, totalSlots))
                    applyReport.partialSkipped = true
                    if applyScalarMetadataForPairs(entry.prop, gameItems, recvItems, metadataGuard) then
                        applyReport.applied = true
                    end
                end
            end
            end
        end
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
            local incoming = clampInt(inv.slots[entry.key], 0, BYTE_MAX)
            if incoming > 0 then
                pcall(function()
                    local current = clampInt(ps:GetPropertyValue(entry.prop), 0, BYTE_MAX)
                    if incoming > current then
                        ps:SetPropertyValue(entry.prop, incoming)
                        -- Anchor the delta tracker to what we just wrote so the very next
                        -- readInventory tick sees delta = 0 and does NOT add the synced
                        -- total to ownSlots again (same pattern as crystals / health).
                        lastGameSlots[entry.key] = incoming
                        applyReport.applied = true
                    end
                end)
            end
        end
    end
    return applyReport
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
    local function vbsEscape(value)
        return tostring(value or ""):gsub('"', '""')
    end
    local serverArg   = vbsEscape(SERVER_URL)
    local passwordArg = vbsEscape(ROOM_PASSWORD)
    local instanceArg = vbsEscape(INSTANCE_ID)

    local lines = {
        'Dim fso : Set fso = CreateObject("Scripting.FileSystemObject")',
        'Dim scriptDir : scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)',
        'Dim bridgeDir : bridgeDir = fso.GetParentFolderName(scriptDir)',
        'Dim bridgePath : bridgePath = bridgeDir & "\\bridge.ps1"',
        'Dim sh : Set sh = CreateObject("WScript.Shell")',
        -- Check for already-running bridge WITH THIS INSTANCE_ID.  We only want to
        -- dedupe against a bridge spawned by this same Lua VM (e.g., if autoLaunch
        -- somehow re-fires); a bridge for a different game instance must coexist.
        'Dim wmi, procs, proc, running',
        'running = False',
        'On Error Resume Next',
        'Set wmi = GetObject("winmgmts:")',
        'Set procs = wmi.ExecQuery("SELECT * FROM Win32_Process WHERE Name = \'powershell.exe\'")',
        'If Not IsNull(procs) And Not IsEmpty(procs) Then',
        '    For Each proc In procs',
        '        If InStr(proc.CommandLine, "bridge.ps1") > 0 And InStr(proc.CommandLine, "' .. instanceArg .. '") > 0 Then running = True',
        '    Next',
        'End If',
        'On Error GoTo 0',
        'If running Then WScript.Quit',
        -- Launch PowerShell bridge. windowStyle=1 = normal visible so errors are readable.
        'Dim playerName : playerName = sh.ExpandEnvironmentStrings("%USERNAME%")',
        'Dim q : q = Chr(34)',
        'sh.CurrentDirectory = bridgeDir',
        'sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File " & q & bridgePath & q & " " & q & "' .. serverArg .. '" & q & " " & q & playerName & q & " " & q & "' .. passwordArg .. '" & q & " " & q & "' .. instanceArg .. '" & q, 1, False',
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
--      (new perk, weapon swap, crystals gained, etc.) PUSH_FILE is updated
--      immediately so the bridge forwards it to the server.
--
--   2. applyIfChanged — reads RECV_FILE and compares it to the last merged
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
EQUIP_HEALTH_ZERO_GRACE_TICKS = math.max(1, math.ceil(EQUIP_HEALTH_ZERO_GRACE_MS / POLL_INTERVAL_MS))
local FORCE_PUSH_INTERVAL_SEC = 10  -- periodic refresh push keeps room state alive after reconnects

local lastPushedJson  = ""     -- inventory JSON last written to PUSH_FILE (change detection)
local lastRecvJson    = ""     -- raw RECV_FILE text we last read
local lastRecvInvJson = ""     -- canonical inventory JSON last applied (format-insensitive)
local lastPushAtSec   = 0      -- os.time() of the last write to PUSH_FILE
local isTransitioning = false  -- pauses polling during level transitions
local skipNextApply   = false  -- true for one tick after a push, so bridge can update RECV_FILE
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

-- Same delta-tracking pattern for health.
-- ownHealth reports our HP contribution; lastGameHealth anchors the delta so that
-- applying the summed pool doesn't inflate our contribution on the next push.

-- Same delta-tracking pattern for max HP.
-- ownMaxHealth      : our personal CurrentMaxHealth contribution.
-- lastGameMaxHealth : raw game CurrentMaxHealth at last read or apply.
-- Server SUMs maxHealth across players just like current HP, so two players
-- each at 250 maxHP → merged 500 maxHP applied to everyone.

-- Same delta-tracking pattern for slot counts.
-- Each slot key (weaponMods, abilityMods, meleeMods, perks) is tracked independently.
-- ownSlots[k]      = how many slots of type k we personally contributed.
-- lastGameSlots[k] = raw game slot count at last read or apply (nil = not yet initialised).
-- The server SUMs contributions from all players, so we must send only our delta,
-- not the already-synced total (which would cause doubling on every subsequent push).
-- NOTE: These are forward-declared above the read/apply helpers so all code paths
-- share one set of upvalues.
-- Write PUSH_FILE when inventory changed, plus a periodic keepalive rewrite.
-- The keepalive prevents stale ghost state after reconnect/server restart:
-- unchanged inventory still gets re-advertised every FORCE_PUSH_INTERVAL_SEC.
-- The file is written as {"room":"...","inventory":{...}} so the bridge can
-- use the correct room for both push POSTs and sync GETs.
-- Room code comes from config.txt (ROOM_CODE).
local function pushIfChanged()
    if isTransitioning then return end
    local ps = getLocalPS()
    if not ps then return end

    local inv = readInventory(ps)
    if inv._itemsReady ~= true then
        print("[CrabSync:read] item push skipped transient startup read - waiting for stable item arrays\n")
        return
    end
    local invJson = encodeInventory(inv)
    local nowSec = os.time()
    local forcePush = false
    if invJson == lastPushedJson then
        if (nowSec - lastPushAtSec) < FORCE_PUSH_INTERVAL_SEC then
            return
        end
        forcePush = true
    end

    -- Wrap inventory with room, session player list, and password.
    local sessionPlayers = getSessionPlayers()
    local playersJson    = jsonStrArray(sessionPlayers)
    lastSentPushSeq = clampInt(lastSentPushSeq + 1, 0, UINT32_MAX)
    inv.clientInstanceId = CLIENT_INSTANCE_ID
    inv.pushSeq = lastSentPushSeq
    local payloadInvJson = encodeInventory(inv)
    local payload = '{"room":' .. jsonStr(ROOM_CODE)
        .. ',"players":' .. playersJson
        .. ',"password":' .. jsonStr(ROOM_PASSWORD)
        .. ',"clientInstanceId":' .. jsonStr(CLIENT_INSTANCE_ID)
        .. ',"pushSeq":' .. tostring(lastSentPushSeq)
        .. ',"inventory":' .. payloadInvJson .. '}'
    local f = io.open(PUSH_FILE, "w")
    if f then
        f:write(payload)
        f:close()
        lastPushedJson = invJson   -- store only the inv portion for change detection
        lastPushAtSec  = nowSec
        skipNextApply  = true      -- give bridge one tick to process push before we apply
        if SYNC_HEALTH and inv.healthValid ~= true then
            print("[CrabSync:health] health omitted from push\n")
        end
        if forcePush then
            print("[CrabInventorySync] Keepalive push refresh sent to bridge.\n")
        else
            print("[CrabInventorySync] Change detected — pushed to bridge.\n")
        end
    end
end

-- Apply RECV_FILE to the local player's own PlayerState whenever the bridge
-- writes a new merged inventory.  Every client does this for themselves.
local function applyIfChanged()
    if isTransitioning then return end
    -- Skip apply for one tick after we pushed: lets the bridge process PUSH_FILE
    -- and update RECV_FILE so we do not immediately apply stale data.
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
    local report = applyInventory(ps, inv) or { applied=false, partialSkipped=false }
    lastRecvJson = json
    lastRecvInvJson = invJson
    if report.applied then
        if report.partialSkipped then
            print("[CrabInventorySync] Applied merged inventory to local player with partial skips.\n")
        else
            print("[CrabInventorySync] Applied merged inventory to local player.\n")
        end
    elseif report.partialSkipped then
        print("[CrabSync:apply] apply skipped or partial-only; no inventory writes performed.\n")
    else
        print("[CrabSync:apply] merged inventory already matched; no apply needed.\n")
    end
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
if CONFIG_VALID then
    autoLaunchBridge()
else
    print("[CrabInventorySync] Bridge not launched due to invalid config. Fix config.txt and restart the game.\n")
end

-- Pause polling for 4 s during level transitions to avoid the 0xe06d7363 crash
-- (PlayerState is mid-destruction when this hook fires; defer until safe).
RegisterHook("/Script/CrabChampions.CrabPC:ClientOnClearedIsland", function()
    isTransitioning = true
    print("[CrabInventorySync] Level transition — pausing sync for 4 s.\n")
    ExecuteWithDelay(4000, function()
        isTransitioning = false
        lastPushedJson  = ""   -- force fresh push in the new level
        lastPushAtSec   = 0
        lastRecvJson    = ""   -- force fresh apply if RECV_FILE has data
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
        resetItemReadiness()
        print("[CrabInventorySync] Resuming continuous sync.\n")
    end)
end)

-- F9: force an immediate re-push and re-apply on the very next tick.
RegisterKeyBind(Key.F9, function()
    lastPushedJson   = ""
    lastPushAtSec    = 0
    lastRecvJson     = ""
    lastRecvInvJson  = ""
    -- NOTE: do NOT reset delta-tracking state (ownCrystals, ownHealth,
    -- ownMaxHealth, ownSlots).  Resetting them re-initialises each player's
    -- contribution to the full pooled total, doubling the pool.
    pendingWeapon  = nil;  pendingWCount = 0;  stableWeapon  = nil
    pendingAbility = nil;  pendingACount = 0;  stableAbility = nil
    pendingMelee   = nil;  pendingMCount = 0;  stableMelee   = nil
    resetItemReadiness()
    print("[CrabInventorySync] Manual sync forced (F9).\n")
end)

-- Kick off the poll loop.  First tick fires after one interval so the game
-- has a moment to finish initialising before we start reading PlayerState.
-- Skip entirely if the config couldn't provide a usable server URL / room code —
-- otherwise we'd spam bridge.log and PUSH_FILE with writes that can't succeed.
if CONFIG_VALID then
    ExecuteWithDelay(POLL_INTERVAL_MS, pollTick)
end

print("[CrabInventorySync] Loaded. Syncing every " .. POLL_INTERVAL_MS .. " ms. Press F9 to force.\n")
