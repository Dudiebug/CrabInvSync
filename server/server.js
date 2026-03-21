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
const serverStartTime = Date.now();

// Players not seen (via sync heartbeat) for longer than this are excluded from
// the merge — they've disconnected or crashed.  10 s = 20 missed 500 ms polls.
const STALE_MS = 10_000;

// Periodically remove players silent for >60 s and empty rooms to free memory.
setInterval(() => {
    const cutoff = Date.now() - 60_000;
    for (const [code, room] of Object.entries(rooms)) {
        for (const [name, data] of Object.entries(room)) {
            if (name === '__members') continue;
            if ((data.lastSeen || data.updatedAt) < cutoff) {
                console.log(`[${code}] Pruning inactive player "${name}"`);
                delete room[name];
            }
        }
        const playerCount = Object.keys(room).filter(k => k !== '__members').length;
        if (playerCount === 0) delete rooms[code];
    }
}, 15_000);

function getRoom(roomCode) {
    if (!rooms[roomCode]) rooms[roomCode] = {};
    return rooms[roomCode];
}

function mergeInventories(room) {
    const now = Date.now();
    const members = room.__members;
    // Only include players whose heartbeat (lastSeen) is fresh enough.
    // Fall back to updatedAt for players who joined before heartbeat tracking.
    // If the room has a members set (from the latest push), also restrict to those names.
    const players = Object.entries(room)
        .filter(([name]) => name !== '__members')
        .filter(([name, p]) => (now - (p.lastSeen || p.updatedAt)) < STALE_MS)
        .filter(([name]) => !members || members.has(name))
        .map(([, data]) => data);
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
        slots:       { weaponMods: 0, abilityMods: 0, meleeMods: 0, perks: 0 },
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
        if (inv.slots) {
            for (const k of ['weaponMods', 'abilityMods', 'meleeMods', 'perks']) {
                if ((inv.slots[k] || 0) > merged.slots[k]) merged.slots[k] = inv.slots[k];
            }
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
    const { room, player, inventory, password, players } = req.body;
    if (password !== '4982904') return res.status(403).json({ error: 'Forbidden' });
    if (!room || !player || !inventory) {
        return res.status(400).json({ error: 'Missing fields' });
    }

    const r = getRoom(room);
    const now = Date.now();
    r[player] = { inventory, updatedAt: now, lastSeen: now };

    // If the client sent a players list, record it — used to restrict merge to session members.
    if (Array.isArray(players) && players.length > 0) {
        r.__members = new Set(players);
    }
    const merged = mergeInventories(r);

    const fmt = (arr) => arr?.length ? arr.join(', ') : '(none)';
    console.log(
        `[${room}] Push from "${player}"\n` +
        `  weapon     : ${inventory.weapon || '(none)'}\n` +
        `  ability    : ${inventory.ability || '(none)'}\n` +
        `  melee      : ${inventory.melee || '(none)'}\n` +
        `  crystals   : ${inventory.crystals ?? 0}\n` +
        `  health     : ${inventory.health ?? 0}\n` +
        `  weaponMods : ${fmt(inventory.weaponMods)}\n` +
        `  abilityMods: ${fmt(inventory.abilityMods)}\n` +
        `  meleeMods  : ${fmt(inventory.meleeMods)}\n` +
        `  perks      : ${fmt(inventory.perks)}\n` +
        `  relics     : ${fmt(inventory.relics)}`
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
    const { room, player, password } = req.body || {};
    if (password !== '4982904') return res.status(403).json({ error: 'Forbidden' });
    if (!room || !player) return res.status(400).json({ error: 'Missing fields' });
    const r = rooms[room];
    if (r && r[player]) r[player].lastSeen = Date.now();
    res.json({ ok: true });
});

app.post('/leave', (req, res) => {
    const { room, player, password } = req.body || {};
    if (password !== '4982904') return res.status(403).json({ error: 'Forbidden' });
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
// inventories, timestamps, expected member list, plus the pre-computed merged inventory.
app.get('/rooms', (req, res) => {
    const out = {};
    for (const [code, room] of Object.entries(rooms)) {
        const players = {};
        for (const [name, data] of Object.entries(room)) {
            if (name === '__members') continue;
            players[name] = { inventory: data.inventory, updatedAt: data.updatedAt, lastSeen: data.lastSeen || data.updatedAt };
        }
        out[code] = {
            players,
            merged:  mergeInventories(room),
            members: room.__members ? [...room.__members] : null,
        };
    }
    const totalPlayers = Object.values(out).reduce((s, r) => s + Object.keys(r.players).length, 0);
    res.json({ rooms: out, uptime: Date.now() - serverStartTime, totalPlayers });
});

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
</style>
</head>
<body>
<header>
  <div class="hdr-left">
    <h1>&#x1F980; CrabInventorySync</h1>
    <div class="live-badge"><span class="dot"></span>Live</div>
  </div>
  <span id="statusLine">connecting&hellip;</span>
</header>
<div class="stats-bar" id="statsBar"></div>
<main id="app"></main>
<script>
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
  return arr.map(function(x){return pill(x,cls);}).join('');
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
function renderRoom(code,roomData){
  var playerEntries=Object.entries(roomData.players||{});
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
  if(playerEntries.length){
    var cards=playerEntries.map(function(e){return renderPlayerCard(e[0],e[1]);}).join('');
    playersSection=
      '<div><div class="sec sec-players">&#x1F464; Player Contributions</div>' +
      '<div class="players-grid">'+cards+'</div></div>';
  }

  return '<div class="room">' +
    '<div class="room-header">' +
      '<span class="room-name">'+esc(code)+'</span>' +
      '<div class="room-badges">'+badges+'</div>' +
    '</div>' +
    mrow +
    '<div class="room-body">'+mergedSection+playersSection+'</div>' +
    '</div>';
}
async function refresh(){
  try{
    var data=await fetch('/rooms').then(function(r){return r.json();});
    var entries=Object.entries(data.rooms||{});

    document.getElementById('statsBar').innerHTML=
      '<div class="stat"><span class="stat-icon">&#x1F3E0;</span><span class="stat-label">Rooms</span><span class="stat-value">'+entries.length+'</span></div>'+
      '<div class="stat"><span class="stat-icon">&#x1F464;</span><span class="stat-label">Players</span><span class="stat-value">'+(data.totalPlayers||0)+'</span></div>'+
      '<div class="stat"><span class="stat-icon">&#x23F1;</span><span class="stat-label">Uptime</span><span class="stat-value">'+(data.uptime?formatUptime(data.uptime):'&mdash;')+'</span></div>';

    var app=document.getElementById('app');
    if(!entries.length){
      app.innerHTML='<div class="no-rooms">No active rooms &mdash; waiting for players to connect.</div>';
    } else {
      app.innerHTML=entries.map(function(e){return renderRoom(e[0],e[1]);}).join('');
    }
    document.getElementById('statusLine').textContent='updated '+new Date().toLocaleTimeString();
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

app.listen(PORT, () => {
    console.log(`CrabInventorySync REST server running on port ${PORT}`);
    console.log(`Health check: http://localhost:${PORT}/health`);
    console.log(`Dashboard:    http://localhost:${PORT}/`);
});
