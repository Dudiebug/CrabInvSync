/**
 * CrabInventorySync v0.0.1 — REST Relay Server
 *
 * Merges inventories for players in the same multiplayer session.
 * Sessions are detected automatically via peer-graph connected components —
 * no room codes required.
 *
 * Endpoints:
 *   POST /push        — send inventory + peers, receive merged result
 *   GET  /sync/:name  — poll for latest merged inventory
 *   POST /heartbeat   — keepalive
 *   POST /leave       — player disconnecting
 *   GET  /health      — liveness check + session overview
 *
 * Run:  node server.js [port]   (default 3000)
 */

const express = require('express');
const app = express();
const PORT = process.argv[2] ? parseInt(process.argv[2], 10) : 3000;

app.use(express.json({ limit: '1mb' }));

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// players[name] = { inventory, peers, updatedAt, lastSeen }
const players = {};

const STALE_MS = 10_000;   // ignore players not seen for >10 s in merges
const PRUNE_MS = 60_000;   // remove players not seen for >60 s entirely

setInterval(() => {
    const cutoff = Date.now() - PRUNE_MS;
    for (const [name, d] of Object.entries(players)) {
        if ((d.lastSeen || d.updatedAt) < cutoff) {
            console.log(`[prune] "${name}"`);
            delete players[name];
        }
    }
}, 15_000);

// ---------------------------------------------------------------------------
// Session graph — connected components via BFS on the peer adjacency list
// ---------------------------------------------------------------------------

function isActive(name) {
    const d = players[name];
    return d && (Date.now() - (d.lastSeen || d.updatedAt)) < STALE_MS;
}

function sessionOf(playerName) {
    const group = new Set();
    const queue = [playerName];
    while (queue.length) {
        const p = queue.shift();
        if (group.has(p) || !isActive(p)) continue;
        group.add(p);
        for (const peer of (players[p].peers || [])) {
            if (!group.has(peer)) queue.push(peer);
        }
        for (const [n, d] of Object.entries(players)) {
            if (!group.has(n) && isActive(n) && (d.peers || []).includes(p)) {
                queue.push(n);
            }
        }
    }
    return group;
}

function allSessions() {
    const visited = new Set();
    const sessions = [];
    for (const name of Object.keys(players)) {
        if (visited.has(name)) continue;
        const g = sessionOf(name);
        if (g.size) {
            g.forEach(n => visited.add(n));
            sessions.push(g);
        }
    }
    return sessions;
}

// ---------------------------------------------------------------------------
// Merge
// ---------------------------------------------------------------------------

function merge(group) {
    const now = Date.now();
    const active = [...group]
        .map(n => players[n])
        .filter(d => d && (now - (d.lastSeen || d.updatedAt)) < STALE_MS);

    if (!active.length) return null;

    // newest inventory determines weapon/ability/melee
    active.sort((a, b) => b.updatedAt - a.updatedAt);
    const newest = active.find(d => d.inventory)?.inventory;
    if (!newest) return null;

    const merged = {
        weapon:      newest.weapon  || '',
        ability:     newest.ability || '',
        melee:       newest.melee   || '',
        crystals:    0,
        health:      0,
        maxHealth:   0,
        weaponMods:  [],
        abilityMods: [],
        meleeMods:   [],
        perks:       [],
        relics:      [],
        slots:       { weaponMods: 0, abilityMods: 0, meleeMods: 0, perks: 0 },
    };

    // per-name counters for array categories
    const counts = {
        weaponMods: {}, abilityMods: {}, meleeMods: {}, perks: {}, relics: {},
    };

    for (const { inventory: inv } of active) {
        if (!inv) continue;

        // sum scalars
        if (inv.crystals)  merged.crystals  += inv.crystals;
        if (inv.health)    merged.health    += inv.health;
        if (inv.maxHealth) merged.maxHealth += inv.maxHealth;

        // sum item counts
        for (const key of ['weaponMods', 'abilityMods', 'meleeMods', 'perks', 'relics']) {
            for (const name of (inv[key] || [])) {
                if (name) counts[key][name] = (counts[key][name] || 0) + 1;
            }
        }

        // max slot counts
        if (inv.slots) {
            for (const key of ['weaponMods', 'abilityMods', 'meleeMods', 'perks']) {
                const v = inv.slots[key];
                if (typeof v === 'number' && v > merged.slots[key]) {
                    merged.slots[key] = v;
                }
            }
        }
    }

    // expand counts → flat arrays
    for (const key of ['weaponMods', 'abilityMods', 'meleeMods', 'perks', 'relics']) {
        for (const [name, count] of Object.entries(counts[key])) {
            for (let i = 0; i < count; i++) merged[key].push(name);
        }
    }

    return merged;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

app.post('/push', (req, res) => {
    const { player, peers, inventory } = req.body;
    if (!player || !inventory) return res.status(400).json({ error: 'missing fields' });

    const peersArr = [].concat(peers || []).filter(p => typeof p === 'string');
    const now = Date.now();
    players[player] = { inventory, peers: peersArr, updatedAt: now, lastSeen: now };

    const group  = sessionOf(player);
    const merged = merge(group);

    const fmt = arr => arr?.length ? arr.join(', ') : '(none)';
    console.log(
        `[push] "${player}" | session=[${[...group].join(', ')}]\n` +
        `  W=${inventory.weapon || '-'} A=${inventory.ability || '-'} M=${inventory.melee || '-'}\n` +
        `  crystals=${inventory.crystals ?? 0} health=${Math.round(inventory.health ?? 0)}\n` +
        `  wMods=${fmt(inventory.weaponMods)} aMods=${fmt(inventory.abilityMods)} mMods=${fmt(inventory.meleeMods)}\n` +
        `  perks=${fmt(inventory.perks)} relics=${fmt(inventory.relics)}\n` +
        `  slots=${JSON.stringify(inventory.slots || {})}`
    );

    res.json({ inventory: merged });
});

app.get('/sync/:player', (req, res) => {
    const name = req.params.player;
    if (!players[name]) return res.json({ inventory: null });
    res.json({ inventory: merge(sessionOf(name)) });
});

app.post('/heartbeat', (req, res) => {
    const { player } = req.body || {};
    if (!player) return res.status(400).json({ error: 'missing fields' });
    if (players[player]) players[player].lastSeen = Date.now();
    res.json({ ok: true });
});

app.post('/leave', (req, res) => {
    const { player } = req.body || {};
    if (!player) return res.status(400).json({ error: 'missing fields' });
    if (players[player]) {
        delete players[player];
        console.log(`[leave] "${player}"`);
    }
    res.json({ ok: true });
});

app.get('/health', (req, res) => {
    res.json({
        ok: true,
        sessions: allSessions().map(g => ({ players: [...g] })),
    });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

app.listen(PORT, () => {
    console.log(`CrabInventorySync v0.0.1 server on port ${PORT}`);
    console.log(`  Health: http://localhost:${PORT}/health`);
});
