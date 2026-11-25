// Mu Split race server.
//
// A race is a room with a 6-letter code. Everybody in it is connected by a WebSocket to the
// same Durable Object (one per code), which keeps the room and tells everyone when anything
// changes. It only relays: every runner's timer runs on their own PC, and they send their
// split times here as they go.
//
//   wss://<worker>/room/<CODE>?create=1   make a room (fails if the code is taken)
//   wss://<worker>/room/<CODE>            join one (fails if there's no such room)
//
// Messages are JSON objects with a "t" (type). Client -> server:
//   hello    { id, name, game, category, segments: [names], method }   first message, also after reconnecting
//   ping     { c }                       clock sync: answered with pong { c, s: server time }
//   ready    { ready }
//   setup    { game, category, countdown }        host only, before the start
//   start    {}                          host: countdown starts (startAt = now + countdown)
//   cancel   {}                          host: stop the countdown
//   progress { phase, index, time, splits: [ms or null], method }   your timer changed
//   forfeit  {}
//   rematch  {}                          host, after the race: same room, everyone not ready
//   chat     { text }
//   kick     { id }                      host
//   leave    {}
// Server -> client:
//   welcome  { you, serverTime, room }   room = the whole room (see roomView)
//   room     { room, serverTime }        sent to everyone whenever anything changes
//   pong     { c, s }
//   chat     { from, name, text, at }
//   error    { message, fatal }

const CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const MAX_PLAYERS = 16;
const IDLE_MS = 6 * 60 * 60 * 1000;       // rooms nobody uses are deleted after 6 hours
const MAX_SPLITS = 400;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length === 0) {
      return json({ name: "Mu Split race server", version: 1 });
    }
    if (parts[0] === "room" && parts[1]) {
      const code = parts[1].toUpperCase();
      if (!/^[A-Z0-9]{4,8}$/.test(code)) return json({ error: "bad code" }, 400);
      if (request.headers.get("Upgrade") !== "websocket") return json({ error: "expected a WebSocket" }, 426);
      const stub = env.ROOMS.get(env.ROOMS.idFromName(code));
      return stub.fetch(request);
    }
    return json({ error: "not found" }, 404);
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

function str(v, max) { return typeof v === "string" ? v.slice(0, max) : ""; }

// The id a client sends is its secret (it proves "this is me again" after a reconnect).
// Everyone else only sees a hash of it, so nobody can copy someone's id and act as them.
async function publicId(secret) {
  const bytes = new TextEncoder().encode("musplit:" + secret);
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(hash.slice(0, 9), (b) => b.toString(16).padStart(2, "0")).join("");
}

// per-connection flood limits: messages per 10 s
const LIMITS = { all: 60, chat: 8, hello: 6 };
function num(v) { return typeof v === "number" && isFinite(v) ? v : null; }

export class Room {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.room = null;     // loaded lazily (the object may have hibernated)
  }

  async load() {
    if (!this.room) this.room = (await this.ctx.storage.get("room")) || null;
    return this.room;
  }
  async save() {
    this.room.touched = Date.now();
    await this.ctx.storage.put("room", this.room);
    // one alarm does both jobs: the countdown's end, and deleting the room when idle
    const r = this.room;
    const next = r.status === "countdown" ? r.startAt : Date.now() + IDLE_MS;
    await this.ctx.storage.setAlarm(next);
  }

  async fetch(request) {
    const url = new URL(request.url);
    const code = url.pathname.split("/").filter(Boolean)[1].toUpperCase();
    const create = url.searchParams.get("create") === "1";
    await this.load();

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ id: null });

    if (create && this.room) {
      this.fail(server, "taken");
    } else if (!create && !this.room) {
      this.fail(server, "There's no race with the code " + code + ".");
    } else {
      if (!this.room) {
        this.room = { code, status: "open", host: null, startAt: 0, countdown: 10000,
                      game: "", category: "", players: {}, order: [], created: Date.now(), finishedAt: 0 };
        await this.save();
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  fail(ws, message) {
    try { ws.send(JSON.stringify({ t: "error", message, fatal: true })); ws.close(4000, "rejected"); } catch (e) {}
  }

  roomView() {
    const r = this.room;
    return {
      code: r.code, status: r.status, host: r.host, startAt: r.startAt, countdown: r.countdown,
      game: r.game, category: r.category,
      players: r.order.map((id) => r.players[id]).filter(Boolean).map((p) => {
        const { segments, ...rest } = p;
        return { ...rest, segCount: segments ? segments.length : 0 };
      }),
    };
  }

  send(ws, obj) { try { ws.send(JSON.stringify(obj)); } catch (e) {} }

  // too many messages from one connection in 10 s are dropped (counts live in memory:
  // they reset if the room hibernates, which is fine)
  allow(ws, type) {
    if (!this.rate) this.rate = new Map();
    const now = Date.now();
    let r = this.rate.get(ws);
    if (!r || now - r.start > 10000) { r = { start: now, all: 0, chat: 0, hello: 0 }; this.rate.set(ws, r); }
    r.all++;
    if (type === "chat" || type === "hello") r[type]++;
    return r.all <= LIMITS.all && r.chat <= LIMITS.chat && r.hello <= LIMITS.hello;
  }

  broadcast() {
    const msg = JSON.stringify({ t: "room", room: this.roomView(), serverTime: Date.now() });
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment();
      if (a && a.id) { try { ws.send(msg); } catch (e) {} }
    }
  }

  connectedIds() {
    const ids = new Set();
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment();
      if (a && a.id) ids.add(a.id);
    }
    return ids;
  }

  pickHost() {
    const r = this.room;
    const live = this.connectedIds();
    if (r.host && r.players[r.host] && live.has(r.host)) return;
    r.host = r.order.find((id) => live.has(id)) || r.order[0] || null;
  }

  // everyone finished or forfeited -> the race is over
  checkFinished() {
    const r = this.room;
    if (r.status !== "running") return;
    const ps = r.order.map((id) => r.players[id]).filter((p) => p && p.racing);
    if (ps.length > 0 && ps.every((p) => p.finished || p.forfeit)) {
      r.status = "finished";
      r.finishedAt = Date.now();
    }
  }

  async webSocketMessage(ws, data) {
    if (typeof data !== "string" || data.length > 32000) return;
    let m;
    try { m = JSON.parse(data); } catch (e) { return; }
    if (!m || typeof m.t !== "string") return;
    if (!this.allow(ws, m.t)) return;
    if (m.t === "ping") { this.send(ws, { t: "pong", c: m.c, s: Date.now() }); return; }

    await this.load();
    if (!this.room) { this.fail(ws, "This race has ended."); return; }
    const r = this.room;
    const att = ws.deserializeAttachment() || {};
    const me = att.id ? r.players[att.id] : null;
    const isHost = me && r.host === me.id;

    switch (m.t) {
      case "hello": {
        const secret = str(m.id, 64);
        if (secret.length < 8) return;
        const id = await publicId(secret);
        let p = r.players[id];
        if (!p) {
          if (r.order.length >= MAX_PLAYERS) { this.fail(ws, "This race is full."); return; }
          p = { id, ready: false, racing: false, phase: "NotRunning", index: -1, time: 0,
                splits: [], finished: false, finalTime: null, forfeit: false, joined: Date.now() };
          // joining a race that's already going: you watch it
          r.players[id] = p;
          r.order.push(id);
        }
        p.name = str(m.name, 32) || "Runner";
        p.game = str(m.game, 80);
        p.category = str(m.category, 80);
        p.method = str(m.method, 8);
        if (Array.isArray(m.segments)) p.segments = m.segments.slice(0, MAX_SPLITS).map((s) => str(s, 60));
        p.connected = true;
        ws.serializeAttachment({ id });
        // the first runner hosts, and sets the game for the room
        if (!r.host) r.host = id;
        if (r.host === id && !r.game) { r.game = p.game; r.category = p.category; }
        this.pickHost();
        await this.save();
        this.send(ws, { t: "welcome", you: id, serverTime: Date.now(), room: this.roomView() });
        this.broadcast();
        return;
      }
      case "ready": {
        if (!me || r.status !== "open") return;
        me.ready = !!m.ready;
        break;
      }
      case "setup": {
        if (!isHost || r.status !== "open") return;
        if (typeof m.game === "string") r.game = str(m.game, 80);
        if (typeof m.category === "string") r.category = str(m.category, 80);
        const cd = num(m.countdown);
        if (cd !== null) r.countdown = Math.max(3000, Math.min(60000, cd));
        break;
      }
      case "start": {
        if (!isHost || r.status !== "open") return;
        r.status = "countdown";
        r.startAt = Date.now() + r.countdown;
        for (const id of r.order) {
          const p = r.players[id];
          // everyone connected races (ready or not: the host decided to go)
          p.racing = this.connectedIds().has(id);
          p.finished = false; p.forfeit = false; p.finalTime = null;
          p.splits = []; p.index = -1; p.time = 0; p.phase = "NotRunning";
        }
        break;
      }
      case "cancel": {
        if (!isHost || r.status !== "countdown") return;
        r.status = "open";
        r.startAt = 0;
        for (const id of r.order) r.players[id].racing = false;
        break;
      }
      case "progress": {
        if (!me) return;
        me.phase = str(m.phase, 12);
        me.index = num(m.index) ?? -1;
        me.time = num(m.time) ?? 0;
        me.method = str(m.method, 8) || me.method;
        if (Array.isArray(m.splits)) me.splits = m.splits.slice(0, MAX_SPLITS).map((v) => num(v));
        if (me.racing && r.status === "running" && !me.forfeit) {
          const n = me.segments && me.segments.length ? me.segments.length : me.splits.length;
          const last = me.splits[n - 1];
          if (me.phase === "Ended" && last != null) { me.finished = true; me.finalTime = last; }
          else if (me.finished && me.phase !== "Ended") { me.finished = false; me.finalTime = null; }  // undid the last split
        }
        this.checkFinished();
        break;
      }
      case "forfeit": {
        if (!me || !me.racing || me.finished) return;
        me.forfeit = true;
        this.checkFinished();
        break;
      }
      case "rematch": {
        if (!isHost || r.status === "countdown") return;
        r.status = "open";
        r.startAt = 0;
        for (const id of r.order) {
          const p = r.players[id];
          p.ready = false; p.racing = false; p.finished = false; p.forfeit = false;
          p.finalTime = null; p.splits = []; p.index = -1; p.time = 0;
        }
        break;
      }
      case "chat": {
        if (!me) return;
        const text = str(m.text, 200).trim();
        if (!text) return;
        const msg = JSON.stringify({ t: "chat", from: me.id, name: me.name, text, at: Date.now() });
        for (const s of this.ctx.getWebSockets()) { try { s.send(msg); } catch (e) {} }
        return;
      }
      case "kick": {
        if (!isHost || m.id === me.id) return;
        this.removePlayer(str(m.id, 40), "The host removed you from the race.");
        break;
      }
      case "leave": {
        if (!me) return;
        this.removePlayer(me.id, null);
        break;
      }
      default:
        return;
    }
    await this.save();
    this.broadcast();
  }

  removePlayer(id, why) {
    const r = this.room;
    if (!r.players[id]) return;
    delete r.players[id];
    r.order = r.order.filter((x) => x !== id);
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment();
      if (a && a.id === id) {
        if (why) this.send(ws, { t: "error", message: why, fatal: true });
        ws.serializeAttachment({ id: null });
        try { ws.close(4001, "removed"); } catch (e) {}
      }
    }
    if (r.host === id) r.host = null;
    this.pickHost();
    this.checkFinished();
  }

  async webSocketClose(ws) { await this.gone(ws); }
  async webSocketError(ws) { await this.gone(ws); }

  async gone(ws) {
    try { ws.close(1000, "bye"); } catch (e) {}   // answer the close
    await this.load();
    if (!this.room) return;
    const a = ws.deserializeAttachment() || {};
    ws.serializeAttachment({ id: null });
    if (!a.id || !this.room.players[a.id]) return;
    const r = this.room;
    const stillHere = this.connectedIds().has(a.id);   // (another tab/reconnect)
    if (!stillHere) {
      const p = r.players[a.id];
      p.connected = false;
      // in the lobby, people who leave are gone; in a race they may come back
      if (r.status === "open" || !p.racing) this.removePlayer(a.id, null);
    }
    this.pickHost();
    await this.save();
    this.broadcast();
  }

  async alarm() {
    await this.load();
    if (!this.room) return;
    const r = this.room;
    if (r.status === "countdown" && Date.now() >= r.startAt - 50) {
      r.status = "running";
      await this.save();
      this.broadcast();
      return;
    }
    if (Date.now() - (r.touched || 0) >= IDLE_MS - 1000 && this.ctx.getWebSockets().length === 0) {
      await this.ctx.storage.deleteAll();
      this.room = null;
      return;
    }
    await this.save();
  }
}
