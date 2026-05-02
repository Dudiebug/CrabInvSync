/**
 * CrabInventorySync REST Server
 *
 * POST /push  — player sends inventory + logs, receives merged result immediately.
 * GET  /sync/:room — poll for latest merged inventory (other players' changes).
 * GET  /logs/:room — all player logs for a room, organised by player → session.
 * GET  /logs/:room/:player — logs for a specific player (optional ?session=).
 * GET  /logs/server — server-side event logs.
 * GET  /health — liveness check.
 *
 * Merge strategy:
 *   weapon / ability / melee  — per-field: from whoever changed THAT field most recently
 *                               (per-field timestamps, not just newest overall pusher)
 *   crystals                  — sum of all players' OWN contribution (delta-tracked)
 *   health / maxHealth        — sum of all players' OWN contribution (delta-tracked)
 *   weaponMods/abilityMods/meleeMods/perks/relics — MAX count per item name across players
 *
 * Disconnect handling:
 *   On /leave or timeout, players are "ghosted": their crystals/slots/items stay in
 *   the pool (frozen), but their health contribution is zeroed (they died/left).
 *   Ghosts are excluded from weapon/ability/melee selection.
 *   Ghosts are fully removed 5 minutes after leaving, or when the room empties.
 *
 * Run: node server.js [port]   (default: 3000)
 */

const express = require('express');
const fs      = require('fs');
const path    = require('path');
const app  = express();
const requestedPort = Number.parseInt(process.argv[2], 10);
const PORT = Number.isInteger(requestedPort) && requestedPort > 0 && requestedPort <= 65535
    ? requestedPort
    : 3000;
const SHARED_PASSWORD = process.env.CRABSYNC_PASSWORD || '4982904';
const MAX_IDENTIFIER_LEN = 96;
const MAX_SESSION_LEN = 128;
const MAX_LOG_BATCH_PER_PUSH = 500;
const MAX_LOG_STRING_LEN = 2048;
const BYTE_MAX = 255;
const UINT32_MAX = 0xFFFFFFFF;
const ITEM_LEVEL_MIN = 1;

const LOGS_DIR = path.join(__dirname, 'logs');
if (!fs.existsSync(LOGS_DIR)) fs.mkdirSync(LOGS_DIR);

app.use(express.json({ limit: '5mb' }));   // increased for log payloads
app.use((err, req, res, next) => {
    if (err && err.type === 'entity.parse.failed') {
        return res.status(400).json({ error: 'Invalid JSON body' });
    }
    return next(err);
});

// ============================================================
// DATA STORES
// ============================================================

// rooms[roomCode][playerName] = { inventory, updatedAt, lastSeen }
const rooms = {};
const serverStartTime = Date.now();

// playerLogs[room][player][session] = [ { t, cat, msg, data }, ... ]
const playerLogs = {};

// serverLogs = [ { t, cat, msg, data }, ... ]
const serverLogs = [];

// Load persisted logs from disk on startup
(function loadPersistedLogs() {
    try {
        const cutoff = Date.now() - 12 * 60 * 60 * 1000;
        const files = fs.readdirSync(LOGS_DIR).filter(f => f.endsWith('.jsonl'));
        let totalEntries = 0;
        for (const file of files) {
            if (file === '__server.jsonl') continue;
            // Filename format: room__player__session.jsonl
            // New files URI-encode each token; legacy files may be raw.
            const base = file.slice(0, -6); // strip .jsonl
            const parts = base.split('__');
            if (parts.length < 3) continue;
            const sessToken   = parts[parts.length - 1];
            const playerToken = parts[parts.length - 2];
            const roomToken   = parts.slice(0, parts.length - 2).join('__');
            const sess    = decodeLogToken(sessToken);
            const player  = decodeLogToken(playerToken);
            const room    = decodeLogToken(roomToken);
            if (!room || !player || !sess) continue;
            const content = fs.readFileSync(path.join(LOGS_DIR, file), 'utf8');
            const entries = content.split('\n').filter(Boolean).map(line => {
                try { return JSON.parse(line); } catch { return null; }
            }).filter(e => e && (e.receivedAt || (e.t < 1e12 ? e.t * 1000 : e.t)) > cutoff);
            if (entries.length > 0) {
                if (!playerLogs[room]) playerLogs[room] = {};
                if (!playerLogs[room][player]) playerLogs[room][player] = {};
                playerLogs[room][player][sess] = entries;
                totalEntries += entries.length;
            } else {
                // All entries expired — remove file
                try { fs.unlinkSync(path.join(LOGS_DIR, file)); } catch {}
            }
        }
        // Load server logs
        const srvFile = path.join(LOGS_DIR, '__server.jsonl');
        if (fs.existsSync(srvFile)) {
            const content = fs.readFileSync(srvFile, 'utf8');
            const entries = content.split('\n').filter(Boolean).map(line => {
                try { return JSON.parse(line); } catch { return null; }
            }).filter(e => e && e.t > cutoff);
            serverLogs.push(...entries);
        }
        const roomCount = Object.keys(playerLogs).length;
        if (roomCount > 0 || serverLogs.length > 0)
            console.log(`[INIT] Loaded persisted logs: ${roomCount} rooms, ${totalEntries} client entries, ${serverLogs.length} server entries`);
    } catch (e) {
        console.error('[INIT] Failed to load persisted logs:', e.message);
    }
})();

// Client pushes a keepalive every FORCE_PUSH_INTERVAL_SEC (currently 10s in
// main.lua).  STALE_MS must be strictly GREATER than that interval, or a slow
// network hop / bridge tick jitter can make the keepalive arrive after we've
// already excluded the player from the merge — producing intermittent
// disappearing-inventory flaps.  15s gives 5s of headroom.
const STALE_MS     = 15_000;   // exclude from merge after 15s of silence
const LOG_TTL_MS   = 12 * 60 * 60 * 1000;  // 12 hours

// ============================================================
// SERVER-SIDE LOGGING
// ============================================================
function srvLog(cat, msg, data) {
    const entry = { t: Date.now(), cat, msg };
    if (data) entry.data = data;
    serverLogs.push(entry);
    const dataStr = data ? ' | ' + JSON.stringify(data) : '';
    console.log(`[SRV:${cat}] ${msg}${dataStr}`);
    try { fs.appendFileSync(path.join(LOGS_DIR, '__server.jsonl'), JSON.stringify(entry) + '\n', 'utf8'); } catch {}
}

// ============================================================
// CLEANUP
// ============================================================

// Remove stale players every 15s, empty rooms
setInterval(() => {
    const cutoff    = Date.now() - 60_000;   // ghost after 60 s of silence
    const ghostCutoff = Date.now() - 5 * 60_000;  // fully remove ghost after 5 min
    for (const [code, room] of Object.entries(rooms)) {
        for (const [name, data] of Object.entries(room)) {
            if (name === '__members') continue;
            if (data.ghost) {
                // Fully remove ghosts that have been sitting for > 5 min.
                if ((data.leftAt || 0) < ghostCutoff) {
                    srvLog('CLEANUP', `Removed expired ghost "${name}"`, { room: code });
                    delete room[name];
                }
                continue;
            }
            if ((data.lastSeen || data.updatedAt) < cutoff) {
                // Timeout: ghost the player (same as a graceful /leave) rather than hard-
                // deleting, so their crystal / slot contribution is not instantly erased.
                invalidateHealth(data.inventory);
                data.ghost  = true;
                data.leftAt = Date.now();
                srvLog('CLEANUP', `Ghosted timed-out player "${name}"`, { room: code });
            }
        }
        const liveCount = Object.entries(room).filter(([k, v]) => k !== '__members' && !v.ghost).length;
        const anyEntry  = Object.keys(room).filter(k => k !== '__members').length;
        if (anyEntry === 0) {
            srvLog('CLEANUP', `Removed empty room`, { room: code });
            delete rooms[code];
        } else if (liveCount === 0) {
            // Only ghosts remain — remove entire room.
            srvLog('CLEANUP', `Removed all-ghost room`, { room: code });
            delete rooms[code];
        }
    }
}, 15_000);

// Purge logs older than 12 hours every 60s
setInterval(() => {
    const cutoff = Date.now() - LOG_TTL_MS;

    // Purge player logs
    for (const [room, players] of Object.entries(playerLogs)) {
        for (const [player, sessions] of Object.entries(players)) {
            for (const [session, entries] of Object.entries(sessions)) {
                // Check the most recent entry's timestamp
                if (entries.length > 0) {
                    const latest = entries[entries.length - 1];
                    // Convert epoch seconds (from Lua os.time()) to ms
                    const latestMs = latest.t < 1e12 ? latest.t * 1000 : latest.t;
                    if (latestMs < cutoff) {
                        delete sessions[session];
                        // Remove expired disk files (encoded + legacy naming).
                        deleteLogFile(room, player, session);
                    }
                }
            }
            if (Object.keys(sessions).length === 0) delete players[player];
        }
        if (Object.keys(players).length === 0) delete playerLogs[room];
    }

    // Purge old server logs from memory, then compact the disk file
    while (serverLogs.length > 0 && serverLogs[0].t < cutoff) {
        serverLogs.shift();
    }
    try {
        const srvFile = path.join(LOGS_DIR, '__server.jsonl');
        fs.writeFileSync(srvFile, serverLogs.map(e => JSON.stringify(e)).join('\n') + (serverLogs.length ? '\n' : ''), 'utf8');
    } catch {}
}, 60_000);

// ============================================================
// HELPERS
// ============================================================

function getRoom(roomCode) {
    if (!rooms[roomCode]) rooms[roomCode] = {};
    return rooms[roomCode];
}

function toFiniteNumber(value, fallback = 0) {
    const n = Number(value);
    return Number.isFinite(n) ? n : fallback;
}

function toOptionalFiniteNumber(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
}

function clampInt(value, min, max) {
    return Math.max(min, Math.min(max, Math.floor(toFiniteNumber(value, min))));
}

function sanitizeEnhancements(value) {
    if (!Array.isArray(value)) return [];
    const out = [];
    for (const raw of value) {
        const n = Number(raw);
        if (!Number.isFinite(n)) continue;
        out.push(clampInt(n, 0, BYTE_MAX));
    }
    return out;
}

function mergeEnhancements(a, b) {
    const seen = new Set();
    for (const value of sanitizeEnhancements(a)) seen.add(value);
    for (const value of sanitizeEnhancements(b)) seen.add(value);
    return [...seen].sort((left, right) => left - right);
}

function sanitizeItemArray(items) {
    if (!Array.isArray(items)) return [];
    const out = [];
    for (const item of items) {
        if (typeof item === 'string') {
            const name = item.trim();
            if (!name) continue;
            out.push({ n: name, l: ITEM_LEVEL_MIN, a: 0, e: [] });
            continue;
        }
        if (!item || typeof item !== 'object') continue;
        const name = typeof item.n === 'string' ? item.n.trim() : '';
        if (!name) continue;
        out.push({
            n: name,
            l: clampInt(item.l ?? ITEM_LEVEL_MIN, ITEM_LEVEL_MIN, BYTE_MAX),
            a: toFiniteNumber(item.a, 0),
            e: sanitizeEnhancements(item.e),
        });
    }
    return out;
}

function sanitizeHealthFields(inv, prevInv) {
    if (inv.healthValid === false) {
        return { healthValid: false };
    }

    const hasHealth = Object.prototype.hasOwnProperty.call(inv, 'health');
    const hasMaxHealth = Object.prototype.hasOwnProperty.call(inv, 'maxHealth');
    if (!hasHealth && !hasMaxHealth) {
        return { healthValid: false };
    }
    if (!hasHealth || !hasMaxHealth) {
        return { healthValid: false };
    }

    const health = toOptionalFiniteNumber(inv.health);
    const maxHealth = toOptionalFiniteNumber(inv.maxHealth);
    if (health == null || maxHealth == null || health < 0 || maxHealth <= 0) {
        return { healthValid: false };
    }

    const hadPriorValidHealth = !!(prevInv && (prevInv.healthEverValid || (prevInv.healthValid && prevInv.health > 0)));
    if (health === 0 && !hadPriorValidHealth) {
        return { healthValid: false };
    }

    return {
        healthValid: true,
        health: Math.max(0, health),
        maxHealth: Math.max(0, maxHealth),
    };
}

function invalidateHealth(inventory) {
    if (!inventory) return;
    delete inventory.health;
    delete inventory.maxHealth;
    inventory.healthValid = false;
    inventory.healthEverValid = false;
}

function sanitizeInventory(inventory, prevInv = null) {
    const inv = (inventory && typeof inventory === 'object') ? inventory : {};
    const cleanName = (v) => (typeof v === 'string' ? v : '');
    const slots = (inv.slots && typeof inv.slots === 'object') ? inv.slots : {};
    const healthFields = sanitizeHealthFields(inv, prevInv);
    const out = {
        weapon: cleanName(inv.weapon),
        ability: cleanName(inv.ability),
        melee: cleanName(inv.melee),
        crystals: clampInt(inv.crystals ?? 0, 0, UINT32_MAX),
        healthValid: healthFields.healthValid,
        healthEverValid: !!(prevInv && prevInv.healthEverValid),
        weaponMods: sanitizeItemArray(inv.weaponMods),
        abilityMods: sanitizeItemArray(inv.abilityMods),
        meleeMods: sanitizeItemArray(inv.meleeMods),
        perks: sanitizeItemArray(inv.perks),
        relics: sanitizeItemArray(inv.relics),
        slots: {
            weaponMods: clampInt(slots.weaponMods ?? 0, 0, BYTE_MAX),
            abilityMods: clampInt(slots.abilityMods ?? 0, 0, BYTE_MAX),
            meleeMods: clampInt(slots.meleeMods ?? 0, 0, BYTE_MAX),
            perks: clampInt(slots.perks ?? 0, 0, BYTE_MAX),
        },
    };
    if (healthFields.healthValid) {
        out.health = healthFields.health;
        out.maxHealth = healthFields.maxHealth;
        if (healthFields.health > 0) out.healthEverValid = true;
    }
    return out;
}

function normalizeIdentifier(value, maxLen = MAX_IDENTIFIER_LEN) {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (!trimmed || trimmed.length > maxLen) return null;
    // Disallow path separators and control chars.
    if (/[\u0000-\u001f\\\/]/.test(trimmed)) return null;
    return trimmed;
}

function normalizeSessionId(value) {
    if (value == null) return null;
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (!trimmed || trimmed.length > MAX_SESSION_LEN) return null;
    if (/[\u0000-\u001f\\\/]/.test(trimmed)) return null;
    return trimmed;
}

function parseSinceParam(value) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function encodeLogToken(value) {
    return encodeURIComponent(String(value));
}

function decodeLogToken(value) {
    try { return decodeURIComponent(value); } catch { return value; }
}

function buildLogFileName(room, player, session) {
    return `${encodeLogToken(room)}__${encodeLogToken(player)}__${encodeLogToken(session)}.jsonl`;
}

function buildLegacyLogFileName(room, player, session) {
    return `${room}__${player}__${session}.jsonl`;
}

function getLogFileCandidates(room, player, session) {
    return [
        buildLogFileName(room, player, session),
        buildLegacyLogFileName(room, player, session),
    ];
}

function getPrimaryLogFilePath(room, player, session) {
    return path.join(LOGS_DIR, buildLogFileName(room, player, session));
}

function deleteLogFile(room, player, session) {
    for (const file of getLogFileCandidates(room, player, session)) {
        try { fs.unlinkSync(path.join(LOGS_DIR, file)); } catch {}
    }
}

function sanitizePlayersList(players) {
    if (!Array.isArray(players)) return null;
    const out = [];
    const seen = new Set();
    for (const raw of players) {
        const name = normalizeIdentifier(raw, MAX_IDENTIFIER_LEN);
        if (!name || seen.has(name)) continue;
        seen.add(name);
        out.push(name);
        if (out.length >= 32) break;
    }
    return out;
}

function sanitizeClientLogEntries(logs, nowMs) {
    if (!Array.isArray(logs)) return [];
    const out = [];
    for (const entry of logs) {
        if (!entry || typeof entry !== 'object') continue;
        const tRaw = toFiniteNumber(entry.t, nowMs);
        const t = Math.floor(tRaw);
        const catRaw = typeof entry.cat === 'string' ? entry.cat.trim() : '?';
        const cat = catRaw ? catRaw.slice(0, 32) : '?';
        const msgRaw = typeof entry.msg === 'string' ? entry.msg : '';
        const msg = msgRaw.length > MAX_LOG_STRING_LEN ? msgRaw.slice(0, MAX_LOG_STRING_LEN) : msgRaw;
        let data = entry.data ?? null;
        if (typeof data === 'string') {
            if (data.length > MAX_LOG_STRING_LEN) data = data.slice(0, MAX_LOG_STRING_LEN);
        } else if (data && typeof data === 'object') {
            try {
                const serialized = JSON.stringify(data);
                data = serialized.length > MAX_LOG_STRING_LEN
                    ? serialized.slice(0, MAX_LOG_STRING_LEN)
                    : serialized;
            } catch {
                data = null;
            }
        } else if (typeof data === 'number' || typeof data === 'boolean') {
            // keep primitive scalars
        } else {
            data = null;
        }
        out.push({
            t,
            cat,
            msg,
            data,
            receivedAt: nowMs,
        });
        if (out.length >= MAX_LOG_BATCH_PER_PUSH) break;
    }
    return out;
}

function mergeInventories(room) {
    const now = Date.now();
    const members = room.__members;
    const players = Object.entries(room)
        .filter(([name]) => name !== '__members')
        // Ghost players (left/disconnected) are always included in the pool — their
        // contribution is frozen at the moment they left.  Live players must have been
        // seen within STALE_MS.
        .filter(([name, p]) => p.ghost || (now - (p.lastSeen || p.updatedAt)) < STALE_MS)
        .filter(([name]) => !members || members.has(name))
        .map(([name, data]) => ({ name, ...data }));
    if (players.length === 0) return null;

    // For weapon / ability / melee we pick per-field from whoever changed that field
    // most recently (not just whoever pushed most recently overall).  This fixes the
    // race condition where two players push at the same tick but only one changed their
    // weapon — previously "newest overall" could overwrite the second player's weapon
    // with stale data from the first player.
    // Ghost (disconnected) players are excluded from weapon/ability/melee selection
    // because they are no longer actively playing.
    const livePlayers = players.filter(p => !p.ghost && p.inventory);
    const pickField = (field, tsField) => {
        const candidates = livePlayers.filter(p => p.inventory[field]);
        if (candidates.length === 0) return '';
        candidates.sort((a, b) => (b[tsField] || 0) - (a[tsField] || 0));
        return candidates[0].inventory[field] || '';
    };

    const merged = {
        weapon:      pickField('weapon',  'weaponChangedAt'),
        ability:     pickField('ability', 'abilityChangedAt'),
        melee:       pickField('melee',   'meleeChangedAt'),
        crystals:    0,
        healthValid: false,
        weaponMods:  [],
        abilityMods: [],
        meleeMods:   [],
        perks:       [],
        relics:      [],
        slots:       { weaponMods: 0, abilityMods: 0, meleeMods: 0, perks: 0 },
    };

    // modMax[category][name] = { count, level, accum, enhancements }
    // Tracks the best values seen across all players for each item.
    // Handles both the new {n,l,a,e} object format and legacy {n,l,a}/string formats.
    const modMax = {
        weaponMods:  {},
        abilityMods: {},
        meleeMods:   {},
        perks:       {},
        relics:      {},
    };

    let mergedHealth = 0;
    let mergedMaxHealth = 0;
    let validHealthContributors = 0;

    for (const p of players) {
        const inv = p.inventory;
        if (!inv) continue;
        if (inv.crystals) merged.crystals += inv.crystals;
        if (inv.healthValid) {
            mergedHealth += inv.health || 0;
            mergedMaxHealth += inv.maxHealth || 0;
            validHealthContributors++;
        }
        // maxHealth: SUM contributions from each player (delta-tracked on client).
        // Two players each contributing 250 maxHP → merged 500 maxHP for everyone.
        // Items that boost maxHP are already shared via item sync, so the maxHealth
        // pool naturally reflects perk bonuses without double-counting.
        for (const key of ['weaponMods', 'abilityMods', 'meleeMods', 'perks', 'relics']) {
            // Each element is either a legacy plain string or a {n, l, a, e} object.
            // Normalise to { name, level, accum, enhancements } then merge into modMax.
            const playerBest = {};   // name → { count, level, accum, enhancements } for this player's push
            for (const item of (inv[key] || [])) {
                const name  = typeof item === 'string' ? item : (item && item.n);
                const level = (typeof item === 'object' && item)
                    ? clampInt(item.l ?? ITEM_LEVEL_MIN, ITEM_LEVEL_MIN, BYTE_MAX)
                    : ITEM_LEVEL_MIN;
                const accum = (typeof item === 'object' && item) ? toFiniteNumber(item.a, 0) : 0;
                const enhancements = (typeof item === 'object' && item) ? sanitizeEnhancements(item.e) : [];
                if (!name) continue;
                if (!playerBest[name]) playerBest[name] = { count: 0, level, accum, enhancements: [] };
                playerBest[name].count++;
                if (level > playerBest[name].level) playerBest[name].level = level;
                if (accum > playerBest[name].accum) playerBest[name].accum = accum;
                playerBest[name].enhancements = mergeEnhancements(playerBest[name].enhancements, enhancements);
            }
            for (const [name, data] of Object.entries(playerBest)) {
                if (!modMax[key][name]) {
                    modMax[key][name] = { count: 0, level: data.level, accum: data.accum, enhancements: [] };
                }
                // count: take the max across players (so if two players both have 3×EscalatingShot,
                //        merged still shows 3, not 6).
                if (data.count > modMax[key][name].count) modMax[key][name].count = data.count;
                // level: take the highest level seen (best version wins).
                if (data.level > modMax[key][name].level) modMax[key][name].level = data.level;
                // accum: take the highest accumulated buff (relics accumulate over time).
                if (data.accum > modMax[key][name].accum) modMax[key][name].accum = data.accum;
                // enhancements: preserve all enum values observed for this item name.
                modMax[key][name].enhancements = mergeEnhancements(modMax[key][name].enhancements, data.enhancements);
            }
        }
        if (inv.slots) {
            // SUM contributions from each player (delta-tracked on client, just like crystals).
            // Each player reports only the slots they personally unlocked, so summing
            // is correct and avoids the doubling feedback loop.
            for (const k of ['weaponMods', 'abilityMods', 'meleeMods', 'perks']) {
                merged.slots[k] += (inv.slots[k] || 0);
            }
        }
    }

    merged.crystals = clampInt(merged.crystals, 0, UINT32_MAX);
    if (validHealthContributors > 0) {
        merged.health = Math.max(0, mergedHealth);
        merged.maxHealth = Math.max(0, mergedMaxHealth);
        merged.healthValid = true;
    }
    for (const k of ['weaponMods', 'abilityMods', 'meleeMods', 'perks']) {
        merged.slots[k] = clampInt(merged.slots[k], 0, BYTE_MAX);
    }

    // Output merged mod arrays in the new {n, l, a, e} object format.
    // The client's parseItemArray decoder handles both this and the legacy string format,
    // but sending the full object ensures CrabInventoryInfo metadata round-trips correctly.
    for (const key of ['weaponMods', 'abilityMods', 'meleeMods', 'perks', 'relics']) {
        for (const [name, data] of Object.entries(modMax[key])) {
            for (let i = 0; i < data.count; i++) {
                merged[key].push({ n: name, l: data.level, a: data.accum, e: data.enhancements });
            }
        }
    }

    if (livePlayers.length === 1 && livePlayers[0].clientInstanceId) {
        merged.clientInstanceId = livePlayers[0].clientInstanceId;
        merged.pushSeq = clampInt(livePlayers[0].pushSeq ?? 0, 0, UINT32_MAX);
    }

    return merged;
}

// ============================================================
// ROUTES
// ============================================================

app.post('/push', (req, res) => {
    const { room, player, inventory, password, players, session, logs, clientInstanceId, pushSeq } = req.body;
    if (password !== SHARED_PASSWORD) return res.status(403).json({ error: 'Forbidden' });
    const roomCode = normalizeIdentifier(room);
    const playerName = normalizeIdentifier(player);
    if (!roomCode || !playerName || !inventory || typeof inventory !== 'object' || Array.isArray(inventory)) {
        return res.status(400).json({ error: 'Missing fields' });
    }
    const sessionId = normalizeSessionId(session);

    const r = getRoom(roomCode);
    const now = Date.now();
    const prev = r[playerName];
    const prevInv = prev && prev.inventory;
    const cleanInventory = sanitizeInventory(inventory, prevInv);
    const cleanClientInstanceId = normalizeSessionId(clientInstanceId)
        || normalizeSessionId(inventory.clientInstanceId);
    const cleanPushSeq = clampInt(pushSeq ?? inventory.pushSeq ?? 0, 0, UINT32_MAX);
    // Per-field change timestamps for weapon / ability / melee.
    // If the player's new value differs from what they last pushed, bump the timestamp
    // so mergeInventories can pick the most recently changed value per-field across
    // all players, rather than all-or-nothing from the most recent overall pusher.
    const weaponChangedAt  = (prevInv && prevInv.weapon  === cleanInventory.weapon)  ? (prev.weaponChangedAt  || now) : now;
    const abilityChangedAt = (prevInv && prevInv.ability === cleanInventory.ability) ? (prev.abilityChangedAt || now) : now;
    const meleeChangedAt   = (prevInv && prevInv.melee   === cleanInventory.melee)   ? (prev.meleeChangedAt   || now) : now;
    r[playerName] = {
        inventory: cleanInventory,
        updatedAt: now,
        lastSeen: now,
        weaponChangedAt,
        abilityChangedAt,
        meleeChangedAt,
        clientInstanceId: cleanClientInstanceId,
        pushSeq: cleanPushSeq,
    };

    const members = sanitizePlayersList(players);
    if (members && members.length > 0) {
        r.__members = new Set(members);
    }

    // Store client logs
    if (Array.isArray(logs) && logs.length > 0 && sessionId) {
        if (!playerLogs[roomCode]) playerLogs[roomCode] = {};
        if (!playerLogs[roomCode][playerName]) playerLogs[roomCode][playerName] = {};
        if (!playerLogs[roomCode][playerName][sessionId]) playerLogs[roomCode][playerName][sessionId] = [];
        const arr = playerLogs[roomCode][playerName][sessionId];
        const newEntries = sanitizeClientLogEntries(logs, now);
        for (const entry of newEntries) arr.push(entry);
        // Persist to disk
        const logFile = getPrimaryLogFilePath(roomCode, playerName, sessionId);
        const lines = newEntries.map(e => JSON.stringify(e)).join('\n') + (newEntries.length ? '\n' : '');
        try { if (lines) fs.appendFileSync(logFile, lines, 'utf8'); } catch {}
    }

    const merged = mergeInventories(r);

    srvLog('PUSH', `Push from "${playerName}" in room "${roomCode}"`, {
        weapon: cleanInventory.weapon || '(none)',
        ability: cleanInventory.ability || '(none)',
        melee: cleanInventory.melee || '(none)',
        crystals: cleanInventory.crystals ?? 0,
        healthValid: cleanInventory.healthValid,
        health: cleanInventory.health,
        maxHealth: cleanInventory.maxHealth,
        wMods: (cleanInventory.weaponMods || []).length,
        aMods: (cleanInventory.abilityMods || []).length,
        mMods: (cleanInventory.meleeMods || []).length,
        perks: (cleanInventory.perks || []).length,
        relics: (cleanInventory.relics || []).length,
        clientLogs: (logs || []).length,
        session: sessionId || '(none)',
        clientInstanceId: cleanClientInstanceId || '(none)',
        pushSeq: cleanPushSeq,
    });

    res.json({ inventory: merged });
});

app.get('/sync/:room', (req, res) => {
    const roomCode = normalizeIdentifier(req.params.room);
    if (!roomCode) return res.status(400).json({ error: 'Invalid room' });
    const r = rooms[roomCode];
    if (!r) return res.json({ inventory: null });
    res.json({ inventory: mergeInventories(r) });
});

app.post('/heartbeat', (req, res) => {
    const { room, player, password } = req.body || {};
    if (password !== SHARED_PASSWORD) return res.status(403).json({ error: 'Forbidden' });
    const roomCode = normalizeIdentifier(room);
    const playerName = normalizeIdentifier(player);
    if (!roomCode || !playerName) return res.status(400).json({ error: 'Missing fields' });
    const r = rooms[roomCode];
    if (r && r[playerName]) {
        const entry = r[playerName];
        entry.lastSeen = Date.now();
        if (entry.ghost) {
            entry.ghost = false;
            delete entry.leftAt;
            srvLog('ROOM', `Heartbeat revived ghost "${playerName}"`, { room: roomCode });
        }
    }
    res.json({ ok: true });
});

app.post('/leave', (req, res) => {
    const { room, player, password } = req.body || {};
    if (password !== SHARED_PASSWORD) return res.status(403).json({ error: 'Forbidden' });
    const roomCode = normalizeIdentifier(room);
    const playerName = normalizeIdentifier(player);
    if (!roomCode || !playerName) return res.status(400).json({ error: 'Missing fields' });
    const r = rooms[roomCode];
    if (r && r[playerName]) {
        // Ghost the player rather than deleting them immediately.  This preserves their
        // crystals, slots, and item contributions in the pool so the remaining players
        // don't instantly lose those values.  Health is zeroed — the player died/left,
        // so their HP should stop contributing to the shared pool.
        // Ghost entries are excluded from weapon/ability/melee selection (dead players
        // don't get a vote on which weapon the survivors equip).
        // The ghost is cleaned up by the normal stale-player sweep once the room
        // becomes idle, or immediately if the room has no other live players.
        const entry = r[playerName];
        invalidateHealth(entry.inventory);
        entry.ghost    = true;
        entry.leftAt   = Date.now();
        srvLog('LEAVE', `"${playerName}" ghosted in room "${roomCode}" — pool contribution frozen`);

        // If no live players remain, remove the room entirely.
        const liveCount = Object.entries(r).filter(([k, v]) => k !== '__members' && !v.ghost).length;
        if (liveCount === 0) {
            delete rooms[roomCode];
            srvLog('LEAVE', `Room "${roomCode}" removed — no live players`);
        }
    }
    res.json({ ok: true });
});

app.get('/health', (req, res) => {
    const summary = Object.entries(rooms).map(([code, room]) => ({
        room:    code,
        players: Object.entries(room).filter(([k, v]) => k !== '__members' && !v.ghost).length,
    }));
    res.json({ ok: true, rooms: summary });
});

// ============================================================
// LOG ENDPOINTS
// ============================================================

// Server-side logs — must be defined BEFORE /logs/:room to prevent Express
// matching "server" as a room name.
app.get('/logs/server', (req, res) => {
    const since = parseSinceParam(req.query.since);
    const filtered = since ? serverLogs.filter(e => e.t > since) : serverLogs;
    res.json(filtered);
});

// Index of all rooms that have logs (works even when room is no longer active)
app.get('/logs', (req, res) => {
    const result = {};
    for (const [room, players] of Object.entries(playerLogs)) {
        result[room] = {};
        for (const [player, sessions] of Object.entries(players)) {
            result[room][player] = Object.keys(sessions).map(s => ({
                session: s,
                count: sessions[s].length,
                latest: sessions[s].length > 0 ? sessions[s][sessions[s].length - 1].receivedAt : 0,
            }));
        }
    }
    res.json({ rooms: result, serverLogCount: serverLogs.length });
});

// All logs for a room, organised by player → session
app.get('/logs/:room', (req, res) => {
    const room = normalizeIdentifier(req.params.room);
    if (!room) return res.status(400).json({ error: 'Invalid room' });
    const since = parseSinceParam(req.query.since);
    const data = playerLogs[room];
    if (!data) return res.json({});
    const result = {};
    for (const [player, sessions] of Object.entries(data)) {
        result[player] = {};
        for (const [session, entries] of Object.entries(sessions)) {
            const filtered = since ? entries.filter(e => (e.receivedAt || 0) > since) : entries;
            if (filtered.length > 0) result[player][session] = filtered;
        }
        if (Object.keys(result[player]).length === 0) delete result[player];
    }
    res.json(result);
});

// Logs for a specific player in a room
app.get('/logs/:room/:player', (req, res) => {
    const room = normalizeIdentifier(req.params.room);
    const player = normalizeIdentifier(req.params.player);
    if (!room || !player) return res.status(400).json({ error: 'Invalid room or player' });
    const sessionFilter = req.query.session ? normalizeSessionId(req.query.session) : null;
    const since = parseSinceParam(req.query.since);
    const data = playerLogs[room]?.[player];
    if (!data) return res.json({});
    if (req.query.session && !sessionFilter) {
        return res.status(400).json({ error: 'Invalid session' });
    }
    if (sessionFilter) {
        const entries = data[sessionFilter] || [];
        const filtered = since ? entries.filter(e => (e.receivedAt || 0) > since) : entries;
        return res.json({ [sessionFilter]: filtered });
    }
    const result = {};
    for (const [session, entries] of Object.entries(data)) {
        const filtered = since ? entries.filter(e => (e.receivedAt || 0) > since) : entries;
        if (filtered.length > 0) result[session] = filtered;
    }
    res.json(result);
});

// ============================================================
// ROOMS ENDPOINT (dashboard data)
// ============================================================

app.get('/rooms', (req, res) => {
    const out = {};
    for (const [code, room] of Object.entries(rooms)) {
        const players = {};
        for (const [name, data] of Object.entries(room)) {
            if (name === '__members') continue;
            players[name] = {
                inventory: data.inventory,
                updatedAt: data.updatedAt,
                lastSeen: data.lastSeen || data.updatedAt,
                ghost: !!data.ghost,
            };
        }
        out[code] = {
            players,
            merged:  mergeInventories(room),
            members: room.__members ? [...room.__members] : null,
        };
    }
    const totalPlayers = Object.values(out).reduce(
        (sum, r) => sum + Object.values(r.players).filter(p => !p.ghost).length,
        0
    );
    // Include log session info for the dashboard
    const logInfo = {};
    for (const [room, players] of Object.entries(playerLogs)) {
        logInfo[room] = {};
        for (const [player, sessions] of Object.entries(players)) {
            logInfo[room][player] = Object.keys(sessions);
        }
    }
    res.json({ rooms: out, uptime: Date.now() - serverStartTime, totalPlayers, logInfo });
});

// ============================================================
// DASHBOARD HTML
// ============================================================

const DASHBOARD_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>CrabInventorySync</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0a0d12;color:#e6edf3;font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh}

header{background:#161b22;border-bottom:1px solid #30363d;padding:12px 24px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:100;gap:12px;flex-wrap:wrap}
.hdr-left{display:flex;align-items:center;gap:12px}
h1{color:#f0883e;font-size:20px;font-weight:700;letter-spacing:-.3px}
.live-badge{display:flex;align-items:center;gap:5px;background:#0f2b10;border:1px solid #238636;border-radius:20px;padding:2px 10px;font-size:11px;color:#3fb950;font-weight:600}
.dot{width:7px;height:7px;border-radius:50%;background:#3fb950;animation:pulse 1.5s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.25}}
#statusLine{font-size:12px;color:#8b949e}

.stats-bar{background:#0d1117;border-bottom:1px solid #21262d;padding:10px 24px;display:flex;gap:28px;flex-wrap:wrap}
.stat{display:flex;align-items:center;gap:7px;font-size:13px}
.stat-icon{font-size:15px;line-height:1}
.stat-label{color:#8b949e}
.stat-value{color:#e6edf3;font-weight:700}

main{padding:22px 24px;max-width:1800px;margin:0 auto}

.room{background:#161b22;border:1px solid #30363d;border-radius:12px;margin-bottom:28px;overflow:hidden}
.room-header{background:#1c2128;padding:13px 20px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #30363d;flex-wrap:wrap;gap:8px}
.room-name{font-size:17px;font-weight:700;color:#f0883e;font-family:'Cascadia Code','Consolas',monospace;margin-right:10px}
.room-badges{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
.badge{border-radius:20px;padding:2px 10px;font-size:11px;font-weight:600;white-space:nowrap}
.badge-players{background:#1c3b5e;color:#79c0ff}
.badge-ok{background:#0f2b10;color:#3fb950}
.badge-partial{background:#2d2206;color:#d29922}

.members-row{padding:8px 20px;background:#0d1117;border-bottom:1px solid #21262d;display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:12px;color:#8b949e}
.member-chip{border-radius:20px;padding:1px 9px;font-size:11px;font-weight:600}
.chip-on{background:#0f2b10;color:#3fb950}
.chip-off{background:#2d0f0f;color:#f85149}

.room-body{padding:18px 20px;display:flex;flex-direction:column;gap:20px}

.sec{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.1em;margin-bottom:10px;display:flex;align-items:center;gap:6px}
.sec-merged{color:#58a6ff}
.sec-players{color:#8b949e}
.sec-logs{color:#d2a8ff}

.merged-box{background:#0d1117;border:1px solid #1c3b5e;border-radius:8px;padding:14px 16px}

.players-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:12px}

.player-card{background:#21262d;border:1px solid #30363d;border-radius:8px;padding:14px;transition:border-color .15s}
.card-fresh{border-color:#1a4d2a}
.card-stale{border-color:#4d1a1a}
.card-hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:11px;gap:6px}
.card-name{font-weight:700;font-size:14px;display:flex;align-items:center;gap:7px;min-width:0}
.card-name-text{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sdot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.sdot-f{background:#3fb950}
.sdot-r{background:#d29922}
.sdot-s{background:#f85149}
.card-time{font-size:11px;white-space:nowrap;flex-shrink:0}
.fresh{color:#3fb950}.recent{color:#d29922}.stale{color:#f85149}

.inv-row{display:flex;align-items:flex-start;gap:6px;margin-bottom:4px;font-size:12px}
.inv-lbl{color:#8b949e;width:64px;flex-shrink:0;padding-top:3px;font-size:11px}
.pills{display:flex;flex-wrap:wrap;gap:3px;min-height:20px;align-items:center}
.pill{border-radius:4px;padding:2px 7px;font-size:11px;white-space:nowrap;font-weight:500}
.pw{background:#1a3555;color:#79c0ff}
.pa{background:#2a1f5a;color:#d2a8ff}
.pm{background:#3a1a1a;color:#ffa198}
.pmod{background:#0f2b1a;color:#7ee787}
.pperk{background:#2d1f0a;color:#ffa657}
.prelic{background:#2a1030;color:#f0a6ff}
.pcrys{background:#0f1e30;color:#79c0ff;font-weight:700}
.php{background:#2d0f1a;color:#ff7b7b;font-weight:700}
.none{color:#484f58;font-style:italic;font-size:11px}

.inv-div{border:none;border-top:1px solid #21262d;margin:5px 0}

.slot-chips{display:flex;flex-wrap:wrap;gap:4px}
.slot-chip{background:#1c2128;border:1px solid #30363d;border-radius:4px;padding:2px 8px;font-size:10px;color:#8b949e;white-space:nowrap}
.slot-chip b{color:#c9d1d9}

.no-rooms{color:#8b949e;font-style:italic;text-align:center;padding:80px 20px;font-size:15px}

/* Log viewer styles */
.log-panel{background:#0d1117;border:1px solid #30363d;border-radius:8px;overflow:hidden}
.log-tabs{display:flex;gap:0;border-bottom:1px solid #30363d;overflow-x:auto}
.log-tab{padding:8px 16px;font-size:12px;font-weight:600;cursor:pointer;border:none;background:transparent;color:#8b949e;white-space:nowrap;border-bottom:2px solid transparent;transition:all .15s}
.log-tab:hover{color:#e6edf3;background:#161b22}
.log-tab.active{color:#d2a8ff;border-bottom-color:#d2a8ff;background:#161b22}
.log-filters{display:flex;gap:4px;padding:8px 12px;border-bottom:1px solid #21262d;flex-wrap:wrap;align-items:center}
.log-filter{padding:2px 8px;border-radius:4px;font-size:10px;font-weight:600;cursor:pointer;border:1px solid #30363d;transition:all .15s}
.log-filter.on{opacity:1}.log-filter.off{opacity:0.35}
.lf-INIT{background:#21262d;color:#8b949e}
.lf-READ{background:#0f1e30;color:#79c0ff}
.lf-PUSH{background:#0f2b1a;color:#7ee787}
.lf-APPLY{background:#2a1f5a;color:#d2a8ff}
.lf-ROOM{background:#0f2b2a;color:#56d4dd}
.lf-TRANSITION{background:#2d1f0a;color:#ffa657}
.lf-F9{background:#2d2206;color:#d29922}
.lf-ERROR{background:#3a0f0f;color:#ff7b7b}
.lf-CLEANUP{background:#21262d;color:#8b949e}
.lf-LEAVE{background:#2d0f1a;color:#ffa198}
.lf-MERGE{background:#1c3b5e;color:#79c0ff}
.log-search{background:#0d1117;border:1px solid #30363d;color:#e6edf3;padding:4px 8px;border-radius:4px;font-size:11px;flex:1;min-width:120px;max-width:250px}
.log-body{max-height:500px;overflow-y:auto;font-family:'Cascadia Code','Consolas',monospace;font-size:11px;line-height:1.6}
.log-entry{padding:2px 12px;border-bottom:1px solid #161b22;display:flex;gap:8px;align-items:flex-start}
.log-entry:hover{background:#161b22}
.log-ts{color:#484f58;flex-shrink:0;min-width:70px}
.log-cat{border-radius:3px;padding:0 5px;font-size:10px;font-weight:700;flex-shrink:0;min-width:64px;text-align:center}
.log-msg{color:#c9d1d9;flex:1;word-break:break-word}
.log-data{color:#8b949e;cursor:pointer;text-decoration:underline dotted;font-size:10px;flex-shrink:0}
.log-data-expanded{color:#8b949e;font-size:10px;padding:2px 12px 6px 155px;word-break:break-all;border-bottom:1px solid #161b22;background:#0a0d12}
.log-controls{display:flex;gap:8px;padding:6px 12px;border-bottom:1px solid #21262d;align-items:center}
.log-btn{background:#21262d;border:1px solid #30363d;color:#8b949e;padding:3px 10px;border-radius:4px;font-size:10px;cursor:pointer}
.log-btn:hover{color:#e6edf3;background:#30363d}
.log-btn.active{color:#3fb950;border-color:#238636}
.log-count{font-size:10px;color:#484f58;margin-left:auto}
</style>
</head>
<body>
<header>
  <div class="hdr-left">
    <h1>&#x1F980; CrabInventorySync</h1>
    <div class="live-badge"><span class="dot"></span>Live</div>
    <a href="/log-viewer" style="color:#d2a8ff;font-size:12px;font-weight:600;text-decoration:none;padding:3px 10px;border:1px solid #3d2b5e;border-radius:20px;background:#1a0f2e">&#x1F4CB; Logs</a>
  </div>
  <span id="statusLine">connecting&hellip;</span>
</header>
<div class="stats-bar" id="statsBar"></div>
<main id="app"></main>
<script>
var logState={};  // per-room state: { activeTab, filters, search, autoScroll, expandedRows, lastSince }
var cachedLogs={};  // per-room cached log data

function esc(s){
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function formatUptime(ms){
  var s=Math.floor(ms/1000),m=Math.floor(s/60),h,d;
  s%=60; h=Math.floor(m/60); m%=60; d=Math.floor(h/24); h%=24;
  if(d>0) return d+'d '+h+'h '+m+'m';
  if(h>0) return h+'h '+m+'m '+s+'s';
  if(m>0) return m+'m '+s+'s';
  return s+'s';
}
function ago(ts){
  var s=(Date.now()-ts)/1000;
  if(s<5)  return {text:'just now',    cls:'fresh'};
  if(s<20) return {text:Math.floor(s)+'s ago', cls:'fresh'};
  if(s<60) return {text:Math.floor(s)+'s ago', cls:'recent'};
  return          {text:Math.floor(s)+'s ago', cls:'stale'};
}
function pill(text,cls){
  return '<span class="pill '+cls+'">'+esc(text)+'</span>';
}
function pillList(arr,cls){
  if(!arr||!arr.length) return '<span class="none">&mdash;</span>';
  return arr.map(function(x){
    // Items are now {n,l,a,e} objects; fall back to plain strings for legacy payloads.
    var name = (x && typeof x === 'object') ? (x.n || '?') : String(x);
    var meta = [];
    if(x && typeof x === 'object' && x.l > 1) meta.push('L'+x.l);
    if(x && typeof x === 'object' && x.a) meta.push('A'+x.a);
    if(x && typeof x === 'object' && Array.isArray(x.e) && x.e.length) meta.push('E['+x.e.join(',')+']');
    var suffix = meta.length ? ' <small>'+esc(meta.join(' '))+'</small>' : '';
    return '<span class="pill '+cls+'">'+esc(name)+suffix+'</span>';
  }).join('');
}
function row(label,html){
  return '<div class="inv-row"><span class="inv-lbl">'+label+'</span><div class="pills">'+html+'</div></div>';
}
function renderSlots(slots){
  if(!slots) return '';
  var defs=[['W.Mods','weaponMods'],['A.Mods','abilityMods'],['M.Mods','meleeMods'],['Perks','perks']];
  var chips=defs.map(function(d){
    return '<span class="slot-chip">'+d[0]+': <b>'+(slots[d[1]]||0)+'</b></span>';
  }).join('');
  return row('Slots','<div class="slot-chips">'+chips+'</div>');
}
function renderInv(d){
  if(!d) d={};
  var parts=[
    row('Weapon',  d.weapon  ? pill(d.weapon,'pw')  : '<span class="none">&mdash;</span>'),
    row('Ability', d.ability ? pill(d.ability,'pa') : '<span class="none">&mdash;</span>'),
    row('Melee',   d.melee   ? pill(d.melee,'pm')   : '<span class="none">&mdash;</span>'),
    '<hr class="inv-div">',
    row('W.Mods',  pillList(d.weaponMods,  'pmod')),
    row('A.Mods',  pillList(d.abilityMods, 'pmod')),
    row('M.Mods',  pillList(d.meleeMods,   'pmod')),
    row('Perks',   pillList(d.perks,       'pperk')),
    row('Relics',  pillList(d.relics,      'prelic')),
    '<hr class="inv-div">',
    row('Crystals',pill(((d.crystals||0)).toLocaleString(),'pcrys')),
    row('Health',  pill(Math.round(d.health||0),'php')),
  ];
  if(d.slots) parts.push(renderSlots(d.slots));
  return parts.join('');
}
function renderPlayerCard(name,data){
  var t=ago(data.lastSeen);
  var sdot=t.cls==='fresh'?'sdot-f':t.cls==='recent'?'sdot-r':'sdot-s';
  var card=t.cls==='fresh'?'card-fresh':t.cls==='stale'?'card-stale':'';
  return '<div class="player-card '+card+'">' +
    '<div class="card-hdr">' +
      '<div class="card-name"><span class="sdot '+sdot+'"></span><span class="card-name-text">'+esc(name)+'</span></div>' +
      '<span class="card-time '+t.cls+'">'+t.text+'</span>' +
    '</div>' +
    renderInv(data.inventory) +
    '</div>';
}

function getLogState(room){
  if(!logState[room]) logState[room]={activeTab:null,filters:{INIT:true,READ:true,PUSH:true,APPLY:true,ROOM:true,TRANSITION:true,F9:true,ERROR:true,CLEANUP:true,LEAVE:true,MERGE:true,PUSH_RECV:true},search:'',autoScroll:true,expandedRows:{}};
  return logState[room];
}

function formatLogTime(t){
  // t may be epoch seconds (Lua) or epoch ms (server)
  var d = t < 1e12 ? new Date(t*1000) : new Date(t);
  return d.toLocaleTimeString('en-US',{hour12:false,hour:'2-digit',minute:'2-digit',second:'2-digit'});
}

function catClass(cat){
  var known=['INIT','READ','PUSH','APPLY','ROOM','TRANSITION','F9','ERROR','CLEANUP','LEAVE','MERGE','PUSH_RECV'];
  return known.indexOf(cat)>=0 ? 'lf-'+cat : 'lf-INIT';
}

function renderLogEntries(entries, state, room){
  var search=state.search.toLowerCase();
  var filtered=entries.filter(function(e){
    if(!state.filters[e.cat] && state.filters[e.cat]!==undefined) return false;
    if(search){
      var txt=(e.msg||'')+(e.data||'')+(e.cat||'');
      if(txt.toLowerCase().indexOf(search)<0) return false;
    }
    return true;
  });
  // Show newest at top
  var reversed=filtered.slice().reverse();
  var html='';
  for(var i=0;i<reversed.length;i++){
    var e=reversed[i];
    var rowId=room+'_'+i;
    var expanded=!!state.expandedRows[rowId];
    html+='<div class="log-entry">'+
      '<span class="log-ts">'+formatLogTime(e.t)+'</span>'+
      '<span class="log-cat '+catClass(e.cat)+'">'+esc(e.cat)+'</span>'+
      '<span class="log-msg">'+esc(e.msg)+'</span>';
    if(e.data){
      html+='<span class="log-data" onclick="toggleLogData(\\''+esc(room)+'\\',\\''+rowId+'\\')">'+
        (expanded?'[-]':'[+] data')+'</span>';
    }
    html+='</div>';
    if(expanded && e.data){
      html+='<div class="log-data-expanded">'+esc(e.data)+'</div>';
    }
  }
  return {html:html,total:entries.length,shown:filtered.length};
}

function renderLogPanel(room, logInfo){
  var state=getLogState(room);
  // Build tab list: players + Server
  var tabs=[];
  if(logInfo && logInfo[room]){
    for(var player in logInfo[room]){
      tabs.push({id:'p:'+player,label:player,type:'player',player:player});
    }
  }
  tabs.push({id:'server',label:'Server',type:'server'});

  if(!state.activeTab && tabs.length>0) state.activeTab=tabs[0].id;

  var tabHtml=tabs.map(function(t){
    var cls=t.id===state.activeTab?'log-tab active':'log-tab';
    return '<button class="'+cls+'" onclick="setLogTab(\\''+esc(room)+'\\',\\''+esc(t.id)+'\\')">'+esc(t.label)+'</button>';
  }).join('');

  var cats=['INIT','READ','PUSH','APPLY','ROOM','TRANSITION','F9','ERROR','CLEANUP','LEAVE','MERGE'];
  var filterHtml=cats.map(function(c){
    var on=state.filters[c]!==false;
    return '<span class="log-filter '+(on?'on':'off')+' lf-'+c+'" onclick="toggleLogFilter(\\''+esc(room)+'\\',\\''+c+'\\')">'+c+'</span>';
  }).join('');

  var searchVal=state.search||'';

  // Get cached entries for the active tab
  var entries=[];
  var cached=cachedLogs[room];
  if(cached){
    var at=state.activeTab;
    if(at==='server'){
      entries=cached.__server||[];
    } else if(at && at.startsWith('p:')){
      var pname=at.substring(2);
      if(cached[pname]){
        // Flatten all sessions
        for(var sess in cached[pname]){
          entries=entries.concat(cached[pname][sess]);
        }
        entries.sort(function(a,b){return a.t-b.t;});
      }
    }
  }

  var result=renderLogEntries(entries, state, room);

  return '<div class="log-panel">'+
    '<div class="log-tabs">'+tabHtml+'</div>'+
    '<div class="log-controls">'+
      '<div class="log-filters">'+filterHtml+'</div>'+
      '<input class="log-search" placeholder="Search logs..." value="'+esc(searchVal)+'" oninput="setLogSearch(\\''+esc(room)+'\\',this.value)">'+
      '<button class="log-btn '+(state.autoScroll?'active':'')+'" onclick="toggleAutoScroll(\\''+esc(room)+'\\')">Auto-scroll</button>'+
      '<span class="log-count">'+result.shown+'/'+result.total+' entries</span>'+
    '</div>'+
    '<div class="log-body" id="logBody_'+esc(room)+'">'+result.html+'</div>'+
    '</div>';
}

function renderRoom(code,roomData,logInfo){
  var allPlayerEntries=Object.entries(roomData.players||{});
  var playerEntries=allPlayerEntries.filter(function(e){return !e[1].ghost;});
  var members=roomData.members;
  var connectedSet={};
  playerEntries.forEach(function(e){connectedSet[e[0]]=true;});

  var badges='<span class="badge badge-players">'+playerEntries.length+' connected</span>';
  if(members&&members.length){
    var present=members.filter(function(m){return connectedSet[m];}).length;
    var bcls=present===members.length?'badge-ok':'badge-partial';
    badges+='<span class="badge '+bcls+'">'+present+'/'+members.length+' expected</span>';
  }

  var mrow='';
  if(members&&members.length){
    var chips=members.map(function(m){
      var on=!!connectedSet[m];
      return '<span class="member-chip '+(on?'chip-on':'chip-off')+'">'+(on?'&#x25CF;':'&#x25CB;')+' '+esc(m)+'</span>';
    }).join('');
    mrow='<div class="members-row"><span>Session members:</span>'+chips+'</div>';
  }

  var mergedSection=
    '<div><div class="sec sec-merged">&#x2728; Merged Inventory</div>' +
    '<div class="merged-box">'+renderInv(roomData.merged)+'</div></div>';

  var playersSection='';
  if(allPlayerEntries.length){
    var cards=allPlayerEntries.map(function(e){return renderPlayerCard(e[0],e[1]);}).join('');
    playersSection=
      '<div><div class="sec sec-players">&#x1F464; Player Contributions</div>' +
      '<div class="players-grid">'+cards+'</div></div>';
  }

  var logSection=
    '<div><div class="sec sec-logs">&#x1F4CB; Logs</div>' +
    renderLogPanel(code, logInfo) + '</div>';

  return '<div class="room">' +
    '<div class="room-header">' +
      '<span class="room-name">'+esc(code)+'</span>' +
      '<div class="room-badges">'+badges+'</div>' +
    '</div>' +
    mrow +
    '<div class="room-body">'+mergedSection+playersSection+logSection+'</div>' +
    '</div>';
}

// Log interaction handlers
window.setLogTab=function(room,tab){getLogState(room).activeTab=tab;renderNow();};
window.toggleLogFilter=function(room,cat){var s=getLogState(room);s.filters[cat]=s.filters[cat]===false?true:false;renderNow();};
window.setLogSearch=function(room,val){getLogState(room).search=val;renderNow();};
window.toggleAutoScroll=function(room){var s=getLogState(room);s.autoScroll=!s.autoScroll;renderNow();};
window.toggleLogData=function(room,rowId){var s=getLogState(room);s.expandedRows[rowId]=!s.expandedRows[rowId];renderNow();};

var lastLogFetch=0;
async function fetchLogs(roomCodes){
  var now=Date.now();
  // Fetch logs every 2 seconds
  if(now-lastLogFetch<2000) return;
  lastLogFetch=now;
  for(var i=0;i<roomCodes.length;i++){
    var code=roomCodes[i];
    try{
      var data=await fetch('/logs/'+encodeURIComponent(code)).then(function(r){return r.json();});
      cachedLogs[code]=data;
    }catch(e){}
  }
  // Fetch server logs
  try{
    var sdata=await fetch('/logs/server').then(function(r){return r.json();});
    // Store server logs under a special key for each room
    for(var i=0;i<roomCodes.length;i++){
      if(!cachedLogs[roomCodes[i]]) cachedLogs[roomCodes[i]]={};
      cachedLogs[roomCodes[i]].__server=sdata;
    }
  }catch(e){}
}

function renderNow(){
  if(window._lastRoomData) doRender(window._lastRoomData);
}
function doRender(data){
  window._lastRoomData=data;
  var entries=Object.entries(data.rooms||{});

  document.getElementById('statsBar').innerHTML=
    '<div class="stat"><span class="stat-icon">&#x1F3E0;</span><span class="stat-label">Rooms</span><span class="stat-value">'+entries.length+'</span></div>'+
    '<div class="stat"><span class="stat-icon">&#x1F464;</span><span class="stat-label">Players</span><span class="stat-value">'+(data.totalPlayers||0)+'</span></div>'+
    '<div class="stat"><span class="stat-icon">&#x23F1;</span><span class="stat-label">Uptime</span><span class="stat-value">'+(data.uptime?formatUptime(data.uptime):'&mdash;')+'</span></div>';

  var app=document.getElementById('app');
  if(!entries.length){
    app.innerHTML='<div class="no-rooms">No active rooms &mdash; waiting for players to connect.</div>';
  } else {
    app.innerHTML=entries.map(function(e){return renderRoom(e[0],e[1],data.logInfo);}).join('');
  }
  document.getElementById('statusLine').textContent='updated '+new Date().toLocaleTimeString();
}

async function refresh(){
  try{
    var data=await fetch('/rooms').then(function(r){return r.json();});
    var roomCodes=Object.keys(data.rooms||{});
    await fetchLogs(roomCodes);
    doRender(data);
  } catch(e){
    document.getElementById('statusLine').textContent='error: '+e.message;
  }
}
refresh();
setInterval(refresh,500);
</script>
</body>
</html>`;

app.get('/', (req, res) => res.setHeader('Content-Type', 'text/html').send(DASHBOARD_HTML));

// ============================================================
// FULL LOG VIEWER PAGE
// ============================================================
const LOG_VIEWER_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>CrabInventorySync &mdash; Logs</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0a0d12;color:#e6edf3;font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh;display:flex;flex-direction:column}
a{color:inherit;text-decoration:none}

header{background:#161b22;border-bottom:1px solid #30363d;padding:12px 24px;display:flex;align-items:center;gap:16px;position:sticky;top:0;z-index:100;flex-wrap:wrap}
h1{color:#f0883e;font-size:20px;font-weight:700;letter-spacing:-.3px}
.back-btn{color:#8b949e;font-size:12px;padding:3px 10px;border:1px solid #30363d;border-radius:20px;background:#161b22;cursor:pointer}
.back-btn:hover{color:#e6edf3;border-color:#58a6ff}
.hdr-status{margin-left:auto;font-size:12px;color:#8b949e}

.layout{display:flex;flex:1;min-height:0;overflow:hidden}

/* Sidebar */
.sidebar{width:260px;flex-shrink:0;background:#0d1117;border-right:1px solid #21262d;overflow-y:auto;display:flex;flex-direction:column}
.sidebar-title{padding:12px 14px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.1em;color:#484f58;border-bottom:1px solid #21262d}
.tree-room{border-bottom:1px solid #1c2128}
.tree-room-hdr{padding:8px 14px;font-size:13px;font-weight:700;color:#f0883e;display:flex;align-items:center;gap:6px;cursor:pointer;user-select:none}
.tree-room-hdr:hover{background:#161b22}
.tree-room-hdr .caret{font-size:10px;transition:transform .15s;display:inline-block}
.tree-room-hdr.collapsed .caret{transform:rotate(-90deg)}
.tree-player{padding:0}
.tree-player-btn{width:100%;text-align:left;padding:6px 14px 6px 26px;font-size:12px;font-weight:600;color:#c9d1d9;background:none;border:none;cursor:pointer;display:flex;align-items:center;gap:6px}
.tree-player-btn:hover{background:#161b22;color:#e6edf3}
.tree-player-btn.active{background:#1c2128;color:#d2a8ff;border-left:2px solid #d2a8ff}
.tree-session{width:100%;text-align:left;padding:4px 14px 4px 40px;font-size:11px;color:#8b949e;background:none;border:none;cursor:pointer;display:flex;align-items:center;justify-content:space-between}
.tree-session:hover{background:#161b22;color:#c9d1d9}
.tree-session.active{background:#1c2128;color:#d2a8ff}
.tree-session-count{font-size:10px;color:#484f58;margin-left:auto}
.tree-server{width:100%;text-align:left;padding:8px 14px;font-size:12px;font-weight:600;color:#8b949e;background:none;border:none;cursor:pointer;display:flex;align-items:center;gap:6px;border-top:1px solid #21262d}
.tree-server:hover{background:#161b22;color:#e6edf3}
.tree-server.active{color:#d2a8ff;background:#1c2128}
.no-logs-tree{padding:20px 14px;font-size:12px;color:#484f58;font-style:italic}

/* Main log area */
.log-main{flex:1;display:flex;flex-direction:column;min-width:0;overflow:hidden}
.log-toolbar{padding:10px 16px;border-bottom:1px solid #21262d;display:flex;gap:8px;align-items:center;flex-wrap:wrap;background:#0d1117}
.log-toolbar-title{font-size:13px;font-weight:700;color:#e6edf3;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
.filter-row{display:flex;gap:4px;flex-wrap:wrap;align-items:center}
.log-filter{padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;cursor:pointer;border:1px solid #30363d;transition:opacity .15s;user-select:none}
.log-filter.on{opacity:1}.log-filter.off{opacity:0.3}
.lf-INIT{background:#21262d;color:#8b949e}
.lf-READ{background:#0f1e30;color:#79c0ff}
.lf-PUSH{background:#0f2b1a;color:#7ee787}
.lf-APPLY{background:#2a1f5a;color:#d2a8ff}
.lf-ROOM{background:#0f2b2a;color:#56d4dd}
.lf-TRANSITION{background:#2d1f0a;color:#ffa657}
.lf-F9{background:#2d2206;color:#d29922}
.lf-ERROR{background:#3a0f0f;color:#ff7b7b}
.lf-CLEANUP{background:#21262d;color:#8b949e}
.lf-LEAVE{background:#2d0f1a;color:#ffa198}
.lf-MERGE{background:#1c3b5e;color:#79c0ff}
.search-box{background:#161b22;border:1px solid #30363d;color:#e6edf3;padding:5px 10px;border-radius:6px;font-size:12px;width:220px}
.search-box:focus{outline:none;border-color:#58a6ff}
.log-count-badge{font-size:11px;color:#484f58;white-space:nowrap}
.auto-scroll-btn{padding:4px 10px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer;border:1px solid #30363d;background:#161b22;color:#8b949e}
.auto-scroll-btn.on{border-color:#238636;color:#3fb950;background:#0f2b10}
.copy-btn{padding:4px 10px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer;border:1px solid #1c3b5e;background:#0f1e30;color:#79c0ff}
.copy-btn:hover{border-color:#58a6ff;color:#e6edf3}
.dl-btn{padding:4px 10px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer;border:1px solid #2d1f0a;background:#1a1000;color:#ffa657}
.dl-btn:hover{border-color:#ffa657;color:#e6edf3}

.log-body{flex:1;overflow-y:auto;font-family:'Cascadia Code','Consolas',monospace;font-size:11.5px;line-height:1.7}
.log-entry{padding:1px 16px;display:flex;gap:10px;align-items:flex-start;border-bottom:1px solid #0d1117}
.log-entry:hover{background:#161b22}
.log-entry.err{background:#1a0808}
.log-ts{color:#484f58;flex-shrink:0;min-width:76px;font-size:11px;padding-top:1px}
.log-cat-badge{border-radius:3px;padding:1px 6px;font-size:10px;font-weight:700;flex-shrink:0;min-width:72px;text-align:center;line-height:1.6}
.log-msg{color:#c9d1d9;flex:1;word-break:break-word}
.log-data-toggle{color:#484f58;font-size:10px;cursor:pointer;flex-shrink:0;padding:0 4px}
.log-data-toggle:hover{color:#8b949e}
.log-data-row{padding:2px 16px 6px 176px;font-size:10.5px;color:#8b949e;word-break:break-all;background:#0a0d12;border-bottom:1px solid #0d1117}

.no-selection{display:flex;align-items:center;justify-content:center;flex:1;color:#484f58;font-size:14px;font-style:italic}
.empty-log{padding:40px 20px;text-align:center;color:#484f58;font-size:13px;font-style:italic}
</style>
</head>
<body>
<header>
  <a href="/" class="back-btn">&#x2190; Dashboard</a>
  <h1>&#x1F4CB; Log Viewer</h1>
  <span class="hdr-status" id="hdrStatus">loading&hellip;</span>
</header>
<div class="layout">
  <div class="sidebar" id="sidebar"><div class="no-logs-tree">Loading&hellip;</div></div>
  <div class="log-main" id="logMain">
    <div class="no-selection">Select a player or session from the sidebar</div>
  </div>
</div>
<script>
var state={
  selection:null,  // {type:'player'|'session'|'server', room, player, session}
  filters:{INIT:true,READ:true,PUSH:true,APPLY:true,ROOM:true,TRANSITION:true,F9:true,ERROR:true,CLEANUP:true,LEAVE:true,MERGE:true},
  search:'',
  autoScroll:true,
  expanded:{},   // room keys that are collapsed
  expandedRows:{} // log entry data expansions
};
var allLogs={};     // room→player→session→entries
var serverLogData=[];
var logIndex={};    // from /logs index endpoint
var refreshInterval=null;
var lastScrollPos=0;

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

function formatTs(t){
  var d=t<1e12?new Date(t*1000):new Date(t);
  return d.toLocaleTimeString('en-US',{hour12:false,hour:'2-digit',minute:'2-digit',second:'2-digit'})+'.'+String(d.getMilliseconds()).padStart(3,'0');
}
function formatDate(t){
  var d=t<1e12?new Date(t*1000):new Date(t);
  return d.toLocaleDateString('en-US',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false});
}

function catClass(cat){
  var known=['INIT','READ','PUSH','APPLY','ROOM','TRANSITION','F9','ERROR','CLEANUP','LEAVE','MERGE'];
  return known.includes(cat)?'lf-'+cat:'lf-INIT';
}

async function fetchAll(){
  try{
    document.getElementById('hdrStatus').textContent='loading index\u2026';
    var idx=await fetch('/logs',{signal:AbortSignal.timeout(10000)}).then(function(r){
      if(!r.ok) throw new Error('/logs returned '+r.status);
      return r.json();
    });
    logIndex=idx.rooms||{};

    document.getElementById('hdrStatus').textContent='loading logs\u2026';
    for(var room of Object.keys(logIndex)){
      var data=await fetch('/logs/'+encodeURIComponent(room),{signal:AbortSignal.timeout(10000)}).then(function(r){
        if(!r.ok) throw new Error('/logs/'+encodeURIComponent(room)+' returned '+r.status);
        return r.json();
      });
      allLogs[room]=data;
    }

    document.getElementById('hdrStatus').textContent='loading server logs\u2026';
    serverLogData=await fetch('/logs/server',{signal:AbortSignal.timeout(10000)}).then(function(r){
      if(!r.ok) throw new Error('/logs/server returned '+r.status);
      return r.json();
    });

    document.getElementById('hdrStatus').textContent='updated '+new Date().toLocaleTimeString();
    renderSidebar();
    renderLogArea();
  }catch(e){
    console.error('[LogViewer] fetchAll error:',e);
    document.getElementById('hdrStatus').textContent='error: '+e.message;
    document.getElementById('sidebar').innerHTML=
      '<div class="no-logs-tree" style="color:#ff7b7b">Load failed:<br>'+esc(String(e.message))+
      '<br><br><button onclick="fetchAll()" style="margin-top:8px;padding:4px 12px;background:#21262d;'+
      'border:1px solid #30363d;color:#c9d1d9;border-radius:4px;cursor:pointer">&#x21BB; Retry</button></div>';
  }
}

function renderSidebar(){
  var rooms=Object.keys(logIndex).sort();
  if(rooms.length===0 && serverLogData.length===0){
    document.getElementById('sidebar').innerHTML='<div class="no-logs-tree">No logs yet.<br>Start the game to begin collecting logs.</div>';
    return;
  }
  var html='<div class="sidebar-title">Log Browser</div>';

  // Server logs entry
  var srvActive=state.selection&&state.selection.type==='server'?'active':'';
  html+='<button class="tree-server '+srvActive+'" onclick="selectServer()">&#x1F4BB; Server ('+serverLogData.length+')</button>';

  for(var room of rooms){
    var collapsed=state.expanded[room]===false;
    var caretCls=collapsed?'caret collapsed':'caret';
    html+='<div class="tree-room">';
    html+='<div class="tree-room-hdr '+(collapsed?'collapsed':'')+'" onclick="toggleRoom(\''+esc(room)+'\')"><span class="'+caretCls+'">&#x25BC;</span>&#x1F4E6; '+esc(room)+'</div>';
    if(!collapsed){
      var players=Object.keys(logIndex[room]||{}).sort();
      for(var player of players){
        var sessions=logIndex[room][player]||[];
        var pActive=state.selection&&state.selection.type==='player'&&state.selection.room===room&&state.selection.player===player?'active':'';
        var totalCount=sessions.reduce(function(s,x){return s+x.count;},0);
        html+='<div class="tree-player">';
        html+='<button class="tree-player-btn '+pActive+'" onclick="selectPlayer(\''+esc(room)+'\',\''+esc(player)+'\')">&#x1F464; '+esc(player)+' <span style="color:#484f58;font-size:10px;margin-left:auto">'+totalCount+'</span></button>';
        sessions.sort(function(a,b){return b.latest-a.latest;});
        for(var s of sessions){
          var sActive=state.selection&&state.selection.type==='session'&&state.selection.room===room&&state.selection.player===player&&state.selection.session===s.session?'active':'';
          html+='<button class="tree-session '+sActive+'" onclick="selectSession(\''+esc(room)+'\',\''+esc(player)+'\',\''+esc(s.session)+'\')">'+esc(s.session)+'<span class="tree-session-count">'+s.count+'</span></button>';
        }
        html+='</div>';
      }
    }
    html+='</div>';
  }
  document.getElementById('sidebar').innerHTML=html;
}

function getEntries(){
  if(!state.selection) return [];
  var s=state.selection;
  if(s.type==='server') return serverLogData;
  if(s.type==='session'){
    return (allLogs[s.room]&&allLogs[s.room][s.player]&&allLogs[s.room][s.player][s.session])||[];
  }
  if(s.type==='player'){
    var all=allLogs[s.room]&&allLogs[s.room][s.player]||{};
    var combined=[];
    for(var sess of Object.keys(all)) combined=combined.concat(all[sess]);
    combined.sort(function(a,b){return a.t-b.t;});
    return combined;
  }
  return [];
}

function filterEntries(entries){
  var search=state.search.toLowerCase();
  return entries.filter(function(e){
    if(state.filters[e.cat]===false) return false;
    if(search){
      var txt=(e.msg||'')+(e.data||'')+(e.cat||'');
      if(txt.toLowerCase().indexOf(search)<0) return false;
    }
    return true;
  });
}

function renderLogArea(){
  var main=document.getElementById('logMain');
  if(!state.selection){
    main.innerHTML='<div class="no-selection">Select a player or session from the sidebar</div>';
    return;
  }
  var s=state.selection;
  var title=s.type==='server'?'Server Events':
    s.type==='session'?(s.player+' / '+s.session):
    (s.player+' (all sessions)');

  var cats=Object.keys(state.filters);
  var filterBtns=cats.map(function(c){
    var on=state.filters[c]!==false;
    return '<span class="log-filter '+(on?'on':'off')+' lf-'+c+'" onclick="toggleFilter(\''+c+'\')">'+c+'</span>';
  }).join('');

  var entries=getEntries();
  var filtered=filterEntries(entries);

  var copyLabel=s.type==='server'?'Copy Server Logs':'Copy Room Logs';
  var dlLabel=s.type==='server'?'Download Server':'Download Room';
  var html='<div class="log-toolbar">'+
    '<span class="log-toolbar-title">'+esc(title)+'</span>'+
    '<button class="copy-btn" onclick="copyAllLogs()">&#x1F4CB; '+copyLabel+'</button>'+
    '<button class="dl-btn" onclick="downloadAllLogs()">&#x2B07; '+dlLabel+'</button>'+
    '<button class="auto-scroll-btn '+(state.autoScroll?'on':'')+'" onclick="toggleAutoScroll()">Auto-scroll '+(state.autoScroll?'ON':'OFF')+'</button>'+
    '</div>'+
    '<div class="log-toolbar" style="padding-top:6px;padding-bottom:6px">'+
    '<div class="filter-row">'+filterBtns+'</div>'+
    '<input class="search-box" placeholder="Search..." value="'+esc(state.search)+'" oninput="setSearch(this.value)">'+
    '<span class="log-count-badge">'+filtered.length+'/'+entries.length+'</span>'+
    '</div>'+
    '<div class="log-body" id="logBody">';

  if(filtered.length===0){
    html+='<div class="empty-log">No log entries match the current filters.</div>';
  } else {
    for(var i=0;i<filtered.length;i++){
      var e=filtered[i];
      var rowId='row_'+i;
      var isErr=e.cat==='ERROR';
      html+='<div class="log-entry'+(isErr?' err':'')+'">'+
        '<span class="log-ts">'+formatTs(e.t)+'</span>'+
        '<span class="log-cat-badge '+catClass(e.cat)+'">'+esc(e.cat)+'</span>'+
        '<span class="log-msg">'+esc(e.msg)+'</span>';
      if(e.data){
        var expanded=!!state.expandedRows[rowId];
        html+='<span class="log-data-toggle" onclick="toggleData(\''+rowId+'\')">'+(expanded?'[-]':'[+]')+'</span>';
      }
      html+='</div>';
      if(e.data && state.expandedRows[rowId]){
        html+='<div class="log-data-row">'+esc(typeof e.data==='object'&&e.data!==null?JSON.stringify(e.data,null,2):String(e.data))+'</div>';
      }
    }
  }
  html+='</div>';

  var scrollTop=lastScrollPos;
  main.innerHTML=html;
  var body=document.getElementById('logBody');
  if(body){
    if(state.autoScroll){
      body.scrollTop=body.scrollHeight;
    } else {
      body.scrollTop=scrollTop;
    }
    body.addEventListener('scroll',function(){
      if(!state.autoScroll) lastScrollPos=body.scrollTop;
    });
  }
}

// Interaction handlers
window.toggleRoom=function(room){state.expanded[room]=state.expanded[room]===false?undefined:false;renderSidebar();};
window.selectServer=function(){state.selection={type:'server'};lastScrollPos=0;renderSidebar();renderLogArea();};
window.selectPlayer=function(room,player){state.selection={type:'player',room,player};lastScrollPos=0;renderSidebar();renderLogArea();};
window.selectSession=function(room,player,session){state.selection={type:'session',room,player,session};lastScrollPos=0;renderSidebar();renderLogArea();};
window.toggleFilter=function(cat){state.filters[cat]=state.filters[cat]===false?true:false;renderLogArea();};
window.setSearch=function(v){state.search=v;renderLogArea();};
window.toggleAutoScroll=function(){state.autoScroll=!state.autoScroll;renderLogArea();};
window.toggleData=function(rowId){state.expandedRows[rowId]=!state.expandedRows[rowId];renderLogArea();};

function buildAllLogsText(){
  var lines=['=== CrabInventorySync Log Export ===','Exported: '+new Date().toLocaleString(),''];
  var s=state.selection;
  var room=s&&s.room;
  if(serverLogData.length>0){
    lines.push('=== SERVER LOGS ('+serverLogData.length+' entries) ===');
    for(var i=0;i<serverLogData.length;i++){
      var e=serverLogData[i];
      var line=formatTs(e.t)+' ['+e.cat+'] '+e.msg;
      if(e.data) line+=' | '+JSON.stringify(e.data);
      lines.push(line);
    }
    lines.push('');
  }
  if(room&&allLogs[room]){
    var players=Object.keys(allLogs[room]).sort();
    for(var pi=0;pi<players.length;pi++){
      var player=players[pi];
      var sessions=Object.keys(allLogs[room][player]).sort();
      for(var si=0;si<sessions.length;si++){
        var session=sessions[si];
        var entries=allLogs[room][player][session];
        lines.push('=== PLAYER: '+player+' / Session: '+session+' ('+entries.length+' entries) ===');
        for(var ei=0;ei<entries.length;ei++){
          var e2=entries[ei];
          var line2=formatTs(e2.t)+' ['+e2.cat+'] '+e2.msg;
          if(e2.data) line2+=' | '+e2.data;
          lines.push(line2);
        }
        lines.push('');
      }
    }
  }
  return lines.join('\n');
}
function fallbackCopy(text){
  var ta=document.createElement('textarea');
  ta.value=text; ta.style.position='fixed'; ta.style.opacity='0';
  document.body.appendChild(ta); ta.select(); document.execCommand('copy');
  document.body.removeChild(ta);
}
window.copyAllLogs=function(){
  var text=buildAllLogsText();
  var btn=document.querySelector('.copy-btn');
  function done(){if(btn){var old=btn.textContent;btn.textContent='\u2713 Copied!';setTimeout(function(){btn.textContent=old;},1500);}}
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(text).then(done).catch(function(){fallbackCopy(text);done();});
  } else { fallbackCopy(text); done(); }
};
window.downloadAllLogs=function(){
  var text=buildAllLogsText();
  var s=state.selection;
  var room=s&&s.room?s.room:'server';
  var ts=new Date().toISOString().replace(/[:.]/g,'-').slice(0,19);
  var filename='crabsync-'+room+'-'+ts+'.txt';
  var blob=new Blob([text],{type:'text/plain'});
  var url=URL.createObjectURL(blob);
  var a=document.createElement('a');
  a.href=url; a.download=filename; a.click();
  URL.revokeObjectURL(url);
};

fetchAll();
setInterval(fetchAll,3000);
</script>
</body>
</html>`;

app.get('/log-viewer', (req, res) => res.setHeader('Content-Type', 'text/html').send(LOG_VIEWER_HTML));

app.listen(PORT, () => {
    srvLog('INIT', `Server started on port ${PORT}`);
    console.log(`Dashboard:    http://localhost:${PORT}/`);
});
