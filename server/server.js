/**
 * CrabInventorySync REST Server
 *
 * POST /push  — player sends inventory, receives merged result immediately.
 * GET  /sync/:room — poll for latest merged inventory (other players' changes).
 * GET  /health — liveness check.
 *
 * Merge strategy:
 *   weapon / ability / melee  — from the most recently updated player
 *   crystals                  — sum of all players' OWN contribution (clients track this
 *                               via delta-tracking to avoid the feedback loop)
 *   health                    — sum of all players' OWN contribution (same delta-tracking
 *                               as crystals — damage to one player shrinks the shared pool)
 *   weaponMods/abilityMods/meleeMods/perks/relics — sum of each player's OWN count per
 *                              item name; clients delta-track so they never push synced items back
 *
 * No authentication — rooms are isolated by the session host's name (auto-detected by clients).
 *
 * Run: node server.js [port]   (default: 3000)
 */

const express = require('express');
const app  = express();
const PORT = process.argv[2] ? parseInt(process.argv[2]) : 3000;

app.use(express.json({ limit: '1mb' }));

// rooms[roomCode][playerName] = { inventory, updatedAt, lastSeen }
const rooms = {};

// Players not seen (via sync heartbeat) for longer than this are excluded from
// the merge — they've disconnected or crashed.  10 s = 20 missed 500 ms polls.
const STALE_MS = 10_000;

// Periodically remove players silent for >60 s and empty rooms to free memory.
setInterval(() => {
    const cutoff = Date.now() - 60_000;
    for (const [code, room] of Object.entries(rooms)) {
        for (const [name, data] of Object.entries(room)) {
            if ((data.lastSeen || data.updatedAt) < cutoff) {
                console.log(`[${code}] Pruning inactive player "${name}"`);
                delete room[name];
            }
        }
        if (Object.keys(room).length === 0) delete rooms[code];
    }
}, 15_000);

function getRoom(roomCode) {
    if (!rooms[roomCode]) rooms[roomCode] = {};
    return rooms[roomCode];
}

function mergeInventories(room) {
    const now = Date.now();
    // Only include players whose heartbeat (lastSeen) is fresh enough.
    // Fall back to updatedAt for players who joined before heartbeat tracking.
    const players = Object.values(room).filter(p => (now - (p.lastSeen || p.updatedAt)) < STALE_MS);
    if (players.length === 0) return null;

    players.sort((a, b) => b.updatedAt - a.updatedAt);
    const newestEntry = players.find(p => p.inventory);
    if (!newestEntry) return null;
    const newest = newestEntry.inventory;

    const merged = {
        weapon:      newest.weapon  || '',
        ability:     newest.ability || '',
        melee:       newest.melee   || '',
        crystals:    0,
        health:      0,
        weaponMods:  [],
        abilityMods: [],
        meleeMods:   [],
        perks:       [],
        relics:      [],
        weaponModSlots:  0,
        abilityModSlots: 0,
        meleeModSlots:   0,
        perkSlots:       0,
        relicSlots:      0,
    };

    // Clients delta-track their own contributions so they never push items received
    // via a sync apply back to the server.  We sum counts directly — this correctly
    // handles stacked duplicates (same name N times = N stacks) without feedback loops.
    const modCounts = {
        weaponMods:  {},
        abilityMods: {},
        meleeMods:   {},
        perks:       {},
        relics:      {},
    };

    for (const { inventory: inv } of players) {
        if (!inv) continue;
        if (inv.crystals) merged.crystals += inv.crystals;
        if (inv.health)   merged.health   += inv.health;
        for (const key of ['weaponMods', 'abilityMods', 'meleeMods', 'perks', 'relics']) {
            for (const name of (inv[key] || [])) {
                if (name) modCounts[key][name] = (modCounts[key][name] || 0) + 1;
            }
        }
        // Slot counts: take the max across all players so everyone gets the most unlocked.
        for (const key of ['weaponModSlots', 'abilityModSlots', 'meleeModSlots', 'perkSlots', 'relicSlots']) {
            if ((inv[key] || 0) > merged[key]) merged[key] = inv[key];
        }
    }

    for (const key of ['weaponMods', 'abilityMods', 'meleeMods', 'perks', 'relics']) {
        for (const [name, count] of Object.entries(modCounts[key])) {
            for (let i = 0; i < count; i++) merged[key].push(name);
        }
    }

    return merged;
}

app.post('/push', (req, res) => {
    const { room, player, inventory } = req.body;
    if (!room || !player || !inventory) {
        return res.status(400).json({ error: 'Missing fields' });
    }

    const r = getRoom(room);
    const now = Date.now();
    r[player] = { inventory, updatedAt: now, lastSeen: now };
    const merged = mergeInventories(r);

    const fmt = (arr) => arr?.length ? arr.join(', ') : '(none)';
    console.log(
        `[${room}] Push from "${player}"\n` +
        `  weapon     : ${inventory.weapon || '(none)'}\n` +
        `  ability    : ${inventory.ability || '(none)'}\n` +
        `  melee      : ${inventory.melee || '(none)'}\n` +
        `  crystals   : ${inventory.crystals ?? 0}\n` +
        `  health     : ${inventory.health ?? 0}\n` +
        `  weaponMods : ${fmt(inventory.weaponMods)} (slots:${inventory.weaponModSlots ?? 0})\n` +
        `  abilityMods: ${fmt(inventory.abilityMods)} (slots:${inventory.abilityModSlots ?? 0})\n` +
        `  meleeMods  : ${fmt(inventory.meleeMods)} (slots:${inventory.meleeModSlots ?? 0})\n` +
        `  perks      : ${fmt(inventory.perks)} (slots:${inventory.perkSlots ?? 0})\n` +
        `  relics     : ${fmt(inventory.relics)} (slots:${inventory.relicSlots ?? 0})`
    );

    res.json({ inventory: merged });
});

app.get('/sync/:room', (req, res) => {
    const r = rooms[req.params.room];
    if (!r) return res.json({ inventory: null });
    res.json({ inventory: mergeInventories(r) });
});

// Dedicated heartbeat — silent, no logging.  Bridge calls this every 500 ms
// so the server knows the player is still connected even if inventory is unchanged.
app.post('/heartbeat', (req, res) => {
    const { room, player } = req.body || {};
    if (!room || !player) return res.status(400).json({ error: 'Missing fields' });
    const r = rooms[room];
    if (r && r[player]) r[player].lastSeen = Date.now();
    res.json({ ok: true });
});

app.post('/leave', (req, res) => {
    const { room, player } = req.body || {};
    if (!room || !player) return res.status(400).json({ error: 'Missing fields' });
    const r = rooms[room];
    if (r && r[player]) {
        delete r[player];
        if (Object.keys(r).length === 0) delete rooms[room];
        console.log(`[${room}] "${player}" left`);
    }
    res.json({ ok: true });
});

app.get('/health', (req, res) => {
    const summary = Object.entries(rooms).map(([code, room]) => ({
        room:    code,
        players: Object.keys(room).length,
    }));
    res.json({ ok: true, rooms: summary });
});

// Full rooms state for the dashboard — returns every room with per-player
// inventories and timestamps, plus the pre-computed merged inventory.
app.get('/rooms', (req, res) => {
    const out = {};
    for (const [code, room] of Object.entries(rooms)) {
        const players = {};
        for (const [name, data] of Object.entries(room)) {
            players[name] = { inventory: data.inventory, updatedAt: data.updatedAt, lastSeen: data.lastSeen || data.updatedAt };
        }
        out[code] = { players, merged: mergeInventories(room) };
    }
    res.json(out);
});

const DASHBOARD_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>CrabInventorySync</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d1117;color:#e6edf3;font-family:'Segoe UI',system-ui,sans-serif;padding:20px;min-height:100vh}
h1{color:#f0883e;font-size:22px;margin-bottom:2px}
.subtitle{color:#8b949e;font-size:12px;margin-bottom:24px;display:flex;align-items:center;gap:8px}
.dot{width:8px;height:8px;border-radius:50%;background:#3fb950;display:inline-block;animation:pulse 1.5s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.25}}
#status{color:#8b949e}

.room{background:#161b22;border:1px solid #30363d;border-radius:10px;margin-bottom:24px;overflow:hidden}
.room-header{background:#1c2128;padding:12px 16px;display:flex;align-items:center;gap:10px;border-bottom:1px solid #30363d}
.room-name{font-size:16px;font-weight:700;color:#f0883e}
.badge{background:#30363d;border-radius:20px;padding:1px 9px;font-size:11px;color:#8b949e}
.room-body{padding:16px;display:flex;flex-direction:column;gap:16px}

.section-title{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.08em;margin-bottom:8px}
.merged-title{color:#58a6ff}
.players-title{color:#8b949e}

.merged-box{background:#0d1117;border:1px solid #1f4070;border-radius:6px;padding:12px}
.players-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:10px}
.player-card{background:#21262d;border:1px solid #30363d;border-radius:6px;padding:12px}
.player-name{font-weight:600;font-size:14px;margin-bottom:2px}
.player-time{font-size:11px;margin-bottom:10px}
.fresh{color:#3fb950}.recent{color:#d29922}.stale{color:#f85149}

.inv-row{display:flex;align-items:flex-start;gap:6px;margin-bottom:5px;font-size:12px}
.inv-label{color:#8b949e;width:72px;flex-shrink:0;padding-top:3px}
.pills{display:flex;flex-wrap:wrap;gap:3px}
.pill{border-radius:4px;padding:2px 7px;font-size:11px;white-space:nowrap}
.p-weapon {background:#1a3555;color:#79c0ff}
.p-ability{background:#2a1f5a;color:#d2a8ff}
.p-melee  {background:#3a1a1a;color:#ffa198}
.p-mod    {background:#1a3a28;color:#7ee787}
.p-perk   {background:#3a2a1a;color:#ffa657}
.p-relic  {background:#341a3a;color:#f0a6ff}
.p-crystal{background:#1a2a3a;color:#79c0ff}
.p-health {background:#3a1a28;color:#ff7b7b}
.none{color:#484f58;font-style:italic}

.no-rooms{color:#8b949e;font-style:italic;text-align:center;padding:60px 20px;font-size:15px}
</style>
</head>
<body>
<h1>&#x1F980; CrabInventorySync</h1>
<div class="subtitle">
  <span class="dot"></span>
  Live dashboard &mdash; refreshes every 500&nbsp;ms &mdash;
  <span id="status">connecting&hellip;</span>
</div>
<div id="app"></div>
<script>
function ago(ts) {
  const s = (Date.now() - ts) / 1000;
  if (s < 5)  return { text: 'just now',              cls: 'fresh'  };
  if (s < 20) return { text: s.toFixed(0) + 's ago',  cls: 'fresh'  };
  if (s < 60) return { text: s.toFixed(0) + 's ago',  cls: 'recent' };
  return       { text: s.toFixed(0) + 's ago',         cls: 'stale'  };
}

function pill(text, cls) {
  return '<span class="pill ' + cls + '">' + text + '</span>';
}

function renderInv(d) {
  if (!d) d = {};
  const none = '<span class="none">—</span>';
  function row(label, html) {
    return '<div class="inv-row"><span class="inv-label">' + label + '</span><div class="pills">' + html + '</div></div>';
  }
  return [
    row('Weapon',   d.weapon  ? pill(d.weapon,  'p-weapon')  : none),
    row('Ability',  d.ability ? pill(d.ability, 'p-ability') : none),
    row('Melee',    d.melee   ? pill(d.melee,   'p-melee')   : none),
    row('W.Mods',   (d.weaponMods  ||[]).length ? d.weaponMods .map(x=>pill(x,'p-mod')).join('') : none),
    row('A.Mods',   (d.abilityMods ||[]).length ? d.abilityMods.map(x=>pill(x,'p-mod')).join('') : none),
    row('M.Mods',   (d.meleeMods   ||[]).length ? d.meleeMods  .map(x=>pill(x,'p-mod')).join('') : none),
    row('Perks',    (d.perks       ||[]).length ? d.perks      .map(x=>pill(x,'p-perk')).join('') : none),
    row('Relics',   (d.relics      ||[]).length ? d.relics     .map(x=>pill(x,'p-relic')).join('') : none),
    row('Crystals', pill((d.crystals ?? 0), 'p-crystal')),
    row('Health',   pill(Math.round(d.health ?? 0), 'p-health')),
  ].join('');
}

async function refresh() {
  try {
    const data = await fetch('/rooms').then(r => r.json());
    const entries = Object.entries(data);
    const app = document.getElementById('app');

    if (entries.length === 0) {
      app.innerHTML = '<div class="no-rooms">No active rooms &mdash; waiting for players to connect.</div>';
    } else {
      app.innerHTML = entries.map(([code, { players, merged }]) => {
        const playerEntries = Object.entries(players);
        const playerCards = playerEntries.map(([name, { inventory, lastSeen }]) => {
          const t = ago(lastSeen);
          return '<div class="player-card">' +
            '<div class="player-name">' + name + '</div>' +
            '<div class="player-time ' + t.cls + '">' + t.text + '</div>' +
            renderInv(inventory) +
            '</div>';
        }).join('');

        return '<div class="room">' +
          '<div class="room-header">' +
            '<span class="room-name">' + code + '</span>' +
            '<span class="badge">' + playerEntries.length + ' player' + (playerEntries.length !== 1 ? 's' : '') + '</span>' +
          '</div>' +
          '<div class="room-body">' +
            '<div>' +
              '<div class="section-title merged-title">Merged inventory</div>' +
              '<div class="merged-box">' + renderInv(merged) + '</div>' +
            '</div>' +
            (playerEntries.length > 0 ? (
              '<div>' +
                '<div class="section-title players-title">Per-player</div>' +
                '<div class="players-grid">' + playerCards + '</div>' +
              '</div>'
            ) : '') +
          '</div>' +
        '</div>';
      }).join('');
    }

    document.getElementById('status').textContent = 'updated ' + new Date().toLocaleTimeString();
  } catch(e) {
    document.getElementById('status').textContent = 'error: ' + e.message;
  }
}

refresh();
setInterval(refresh, 500);
</script>
</body>
</html>`;

app.get('/', (req, res) => res.setHeader('Content-Type', 'text/html').send(DASHBOARD_HTML));

app.listen(PORT, () => {
    console.log(`CrabInventorySync REST server running on port ${PORT}`);
    console.log(`Health check: http://localhost:${PORT}/health`);
    console.log(`Dashboard:    http://localhost:${PORT}/`);
});
