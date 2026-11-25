// Stubs for the Workers runtime, enough to run Room's logic.
class FakeWS {
  constructor() { this.sent = []; this.att = null; this.closed = false; }
  send(s) { if (this.closed) throw new Error("closed"); this.sent.push(JSON.parse(s)); }
  close() { this.closed = true; }
  serializeAttachment(a) { this.att = a; }
  deserializeAttachment() { return this.att; }
  last(t) { return [...this.sent].reverse().find((m) => !t || m.t === t); }
}
globalThis.WebSocketPair = class { constructor() { this[0] = new FakeWS(); this[1] = new FakeWS(); } };
globalThis.Response = class { constructor(b, o) { this.status = o && o.status; this.webSocket = o && o.webSocket; } };
const { Room } = await import(process.argv[2]);

function makeCtx() {
  const store = new Map(); let alarm = null; const sockets = [];
  return {
    storage: { get: async (k) => structuredClone(store.get(k)), put: async (k, v) => store.set(k, structuredClone(v)),
               setAlarm: async (t) => { alarm = t; }, deleteAll: async () => store.clear(), _alarm: () => alarm },
    acceptWebSocket: (ws) => sockets.push(ws),
    getWebSockets: () => sockets.filter((s) => !s.closed),
    _sockets: sockets,
  };
}
const ctx = makeCtx();
let room = new Room(ctx, {});
const assert = (c, m) => { if (!c) { console.log("FAIL:", m); process.exit(1); } };

async function connect(code, create) {
  const before = ctx._sockets.length;
  await room.fetch({ url: `https://x/room/${code}${create ? "?create=1" : ""}` });
  return ctx._sockets[before];
}
const msg = (ws, o) => room.webSocketMessage(ws, JSON.stringify(o));

// joining a room that doesn't exist fails
let bad = await connect("ABCDEF", false);
assert(bad.last().t === "error" && bad.closed, "no such room");
// create
const a = await connect("ABCDEF", true);
await msg(a, { t: "hello", id: "secret-A-123", name: "Mushy", game: "Poppy Playtime Chapter 5", category: "Any%", segments: ["One", "Two"] });
const A = a.last("welcome").you;
assert(A && A !== "secret-A-123" && /^[0-9a-f]{18}$/.test(A), "welcome with a public id");
let r = a.last("room").room;
assert(r.host === A && !JSON.stringify(r).includes("secret-A") && r.players[0].segCount === 2 && !r.players[0].segments && r.game === "Poppy Playtime Chapter 5" && r.players.length === 1, "host + game");
// creating the same code again fails (taken)
const dup = await connect("ABCDEF", true);
assert(dup.last().message === "taken", "taken");
// join
const b = await connect("ABCDEF", false);
await msg(b, { t: "hello", id: "secret-B-456", name: "Friend", segments: ["One", "Two"] });
const B = b.last("welcome").you;
// someone copying A's public id can't become A
const evil = await connect("ABCDEF", false);
await msg(evil, { t: "hello", id: A, name: "Impostor" });
assert(evil.last("welcome").you !== A && a.last("room").room.host === A, "public id can't be used to act as someone");
await msg(evil, { t: "leave" });
assert(a.last("room").room.players.length === 2, "two players");
// only the host starts
await msg(b, { t: "start" });
assert(a.last("room").room.status === "open", "non-host can't start");
await msg(b, { t: "ready", ready: true });
assert(a.last("room").room.players[1].ready, "ready");
await msg(a, { t: "setup", countdown: 5000 });
await msg(a, { t: "start" });
r = a.last("room").room;
assert(r.status === "countdown" && r.startAt > Date.now() + 4000, "countdown");
// clock
await msg(a, { t: "ping", c: 123 });
assert(a.last("pong").c === 123 && a.last("pong").s > 0, "pong");
// alarm at startAt -> running
const realNow = Date.now; Date.now = () => r.startAt + 10;
await room.alarm();
assert(a.last("room").room.status === "running", "running");
// progress
await msg(a, { t: "progress", phase: "Running", index: 1, time: 61000, splits: [60000, null] });
await msg(b, { t: "progress", phase: "Running", index: 1, time: 63000, splits: [62500, null] });
r = a.last("room").room;
assert(r.players[0].splits[0] === 60000 && r.players[1].splits[0] === 62500, "splits relayed");
await msg(a, { t: "progress", phase: "Ended", index: 2, time: 120000, splits: [60000, 120000] });
assert(a.last("room").room.players[0].finished && a.last("room").room.players[0].finalTime === 120000, "A finished");
assert(a.last("room").room.status === "running", "still running (B going)");
// undo the last split un-finishes
await msg(a, { t: "progress", phase: "Running", index: 1, time: 120500, splits: [60000, null] });
assert(!a.last("room").room.players[0].finished, "undo un-finishes");
await msg(a, { t: "progress", phase: "Ended", index: 2, time: 120000, splits: [60000, 120000] });
// B forfeits -> finished
await msg(b, { t: "forfeit" });
assert(a.last("room").room.status === "finished", "race over");
// chat
await msg(b, { t: "chat", text: " gg " });
assert(a.last("chat").text === "gg" && a.last("chat").name === "Friend", "chat");
// rematch
await msg(a, { t: "rematch" });
r = a.last("room").room;
assert(r.status === "open" && !r.players[1].ready && r.players[0].splits.length === 0, "rematch");
// host leaves -> B hosts
await msg(a, { t: "leave" });
r = b.last("room").room;
assert(r.host === B && r.players.length === 1, "host handed over");
// hibernation: a new Room object reloads from storage
room = new Room(ctx, {});
await msg(b, { t: "ready", ready: true });
assert(b.last("room").room.players[0].ready && b.last("room").room.code === "ABCDEF", "survives hibernation");
// disconnect in lobby removes
b.closed = true; await room.webSocketClose(b);
const c = await connect("ABCDEF", false);
await msg(c, { t: "hello", id: "secret-C-789", name: "Late" });
r = c.last("room").room;
assert(r.players.length === 1 && r.host === c.last("welcome").you, "lobby leaver removed; new host");
// chat flood: only the first 8 in 10 s get through
const before = c.sent.filter((m) => m.t === "chat").length;
for (let i = 0; i < 20; i++) await msg(c, { t: "chat", text: "spam " + i });
assert(c.sent.filter((m) => m.t === "chat").length - before === 8, "chat flood limited");
Date.now = realNow;
console.log("WORKER OK");
