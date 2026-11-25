#!/usr/bin/env python3
"""
Fake Mu Split Bridge: speaks the same protocol as the LiveSplit component, so the
Love2D UI can be worked on (on any OS) without LiveSplit.

    python mock_bridge.py            # control it from the Mu Split window
    python mock_bridge.py --auto     # also acts like an autosplitter (starts + splits on its own)

Simulates: real/game time with fake load screens, golds, PB, skip/undo/pause,
the right-click menu data, the Splits Editor, Settings and ASL settings.
Saving/opening only pretends (nothing is written to disk).
"""
import argparse
import copy
import json
import random
import re
import socket
import threading
import time

PORT = 16850
HEARTBEAT = 0.05

SEGMENTS = [
    # name, pb segment length (s), gold segment length (s)
    ("Tutorial Woods", 62.4, 58.9),
    ("Bridge Skip", 41.8, 39.2),
    ("Crystal Caves", 118.3, 109.7),
    ("Boss: Mossback", 74.0, 70.1),
    ("Sky Ferry", 55.6, 52.3),
    ("Clockwork Tower", 133.9, 126.4),
    ("Lava Gauntlet", 88.2, 81.5),
    ("Glitched Archives (any% route)", 47.1, 43.8),
    ("Final Ascent", 96.5, 90.2),
    ("Boss: The Unmaker", 101.7, 95.0),
]

GENERATORS = ["Best Segments", "Average Segments", "Median Segments", "Worst Segments",
              "Balanced PB", "Latest Run", "Best Split Times", "None"]


def parse_time(text):
    """LiveSplit-style: [-][[h:]m:]s[.fff] -> ms. Raises ValueError."""
    text = text.strip()
    neg = text.startswith("-")
    text = text.lstrip("-")
    if not re.fullmatch(r"(\d+:){0,2}\d+(\.\d+)?", text):
        raise ValueError(text)
    parts = text.split(":")
    secs = 0.0
    for p in parts:
        secs = secs * 60 + float(p)
    return (-secs if neg else secs) * 1000


class Run:
    def __init__(self):
        self.game = "Hollow Clockwork (Mock)"
        self.category = "Any%"
        self.attempts = 41
        self.offset = 0.0
        self.custom = ["Personal Best", "Sub 15"]
        self.file = "C:/Splits/Hollow Clockwork - Any%.lss"
        self.changed = False
        cum = 0.0
        self.segs = []
        for name, pb, gold in SEGMENTS:
            cum += pb
            self.segs.append({"name": name, "pb": cum * 1000, "best": gold * 1000,
                              "comps": {"Sub 15": cum * 1000 * 0.96}})

    def comp_time(self, i, comp):
        s = self.segs[i]
        if comp == "Personal Best":
            return s["pb"]
        if comp in s["comps"]:
            return s["comps"][comp]
        if comp == "Best Segments":
            total = 0
            for k in range(i + 1):
                if self.segs[k]["best"] is None:
                    return None
                total += self.segs[k]["best"]
            return total
        if comp == "Average Segments" and s["pb"] is not None:
            return s["pb"] * 1.03
        return None


class Mock:
    def __init__(self):
        self.lock = threading.RLock()
        self.run = Run()
        self.method = "real"
        self.comparison = "Personal Best"
        self.event = "init"
        self.seq = 0
        self.hidden = True
        self.editor = None
        self.editor_method = "real"
        self.recent = [
            {"path": self.run.file, "game": self.run.game, "category": self.run.category},
            {"path": "C:/Splits/Hollow Clockwork - 100%.lss", "game": "Hollow Clockwork (Mock)", "category": "100%"},
            {"path": "C:/Splits/Other Game.lss", "game": "Other Game", "category": "Glitchless"},
        ]
        self.settings = {
            "profile": "Default", "profileOrder": ["Default"],
            "profiles": {"Default": {"split": "NumPad1", "reset": "NumPad3", "skip": "NumPad2", "undo": "NumPad8",
                                     "pause": None, "toggleGlobal": None, "comparePrev": "NumPad4",
                                     "compareNext": "NumPad6", "delay": 0, "global": False, "doubleTap": True,
                                     "deactivateOthers": False, "gamepads": False}},
            "warnOnReset": True, "simpleSumOfBest": False, "refreshRate": 40, "serverPort": 16834,
            "hcpHistorySize": 10, "hcpNBestRuns": 20,
            "generators": [{"name": g, "enabled": g in ("Best Segments", "Average Segments")} for g in GENERATORS],
        }
        self.asl_active = True
        self.asl = {
            "basic": [{"id": "Start", "present": True, "value": True},
                      {"id": "Split", "present": True, "value": True},
                      {"id": "Reset", "present": False, "value": True}],
            "custom": [
                {"id": "any", "label": "Any% splits", "parent": None, "tooltip": "Split at the end of each area", "default": True, "value": True},
                {"id": "woods", "label": "Tutorial Woods exit", "parent": "any", "tooltip": None, "default": True, "value": True},
                {"id": "caves", "label": "Crystal Caves exit", "parent": "any", "tooltip": None, "default": True, "value": True},
                {"id": "bosses", "label": "Boss kills", "parent": None, "tooltip": None, "default": False, "value": False},
                {"id": "moss", "label": "Mossback", "parent": "bosses", "tooltip": "Splits on the final hit", "default": True, "value": True},
                {"id": "unmaker", "label": "The Unmaker", "parent": "bosses", "tooltip": None, "default": True, "value": True},
                {"id": "il", "label": "IL mode (reset on area entry)", "parent": None, "tooltip": None, "default": False, "value": False},
            ],
        }
        self.reset_state()

    # ---------------------------------------------------------------- timer
    def reset_state(self):
        self.phase = "NotRunning"
        self.index = -1
        self.start_at = None
        self.pause_total = 0.0
        self.paused_at = None
        self.load_total = 0.0
        self.loading_since = None
        self.splits = [None] * len(self.run.segs)

    def real_ms(self, now=None):
        if self.start_at is None:
            return 0.0
        now = now or time.perf_counter()
        end = self.paused_at or now
        return (end - self.start_at - self.pause_total) * 1000 + self.run.offset

    def game_ms(self, now=None):
        now = now or time.perf_counter()
        loads = self.load_total + ((now - self.loading_since) if self.loading_since else 0)
        return max(0.0, self.real_ms(now) - loads * 1000)

    def cur(self, pair):
        return None if pair is None else pair[0 if self.method == "real" else 1]

    def stop_loading(self, now):
        if self.loading_since:
            self.load_total += now - self.loading_since
            self.loading_since = None

    def save_times(self):
        """Like LiveSplit's Reset(true): update golds, and PB if the run finished faster."""
        prev = 0.0
        for i, sp in enumerate(self.splits):
            if sp is None:
                prev = None
                continue
            t = sp[0]
            seg = self.run.segs[i]
            if prev is not None and (seg["best"] is None or (t - prev) < seg["best"]):
                seg["best"] = t - prev
            prev = t
        last = self.run.segs[-1]["pb"]
        if self.phase == "Ended" and (last is None or self.splits[-1][0] < last):
            for i, sp in enumerate(self.splits):
                self.run.segs[i]["pb"] = sp[0] if sp else None
        self.run.changed = True

    def reset_would_update(self):
        if self.phase == "NotRunning":
            return False
        prev = 0.0
        for i, sp in enumerate(self.splits):
            if sp is None:
                prev = None
                continue
            best = self.run.segs[i]["best"]
            if prev is not None and (best is None or sp[0] - prev < best):
                return True
            prev = sp[0]
        last = self.splits[-1]
        pb = self.run.segs[-1]["pb"]
        return last is not None and (pb is None or last[0] < pb)

    # ---------------------------------------------------------------- messages
    def snapshot(self, event=None):
        with self.lock:
            self.seq += 1
            now = time.perf_counter()
            m = self.method
            segs = []
            for i, s in enumerate(self.run.segs):
                segs.append({"name": s["name"], "split": self.cur(self.splits[i]),
                             "comp": self.run.comp_time(i, self.comparison), "pb": s["pb"], "best": s["best"]})
            return {
                "type": "state", "seq": self.seq, "event": event, "phase": self.phase, "method": m,
                "index": self.index,
                "time": self.real_ms(now) if m == "real" else self.game_ms(now),
                "realTime": self.real_ms(now), "gameTime": self.game_ms(now),
                "gameTimePaused": self.loading_since is not None,
                "comparison": self.comparison, "windowHidden": self.hidden,
                "hasChanged": self.run.changed, "filePath": self.run.file, "timerOnly": False,
                "warnOnReset": self.settings["warnOnReset"],
                "resetPrompt": self.settings["warnOnReset"] and self.reset_would_update(),
                "savePrompt": self.phase in ("Running", "Paused") or (
                    self.phase == "Ended" and self.run.segs[-1]["pb"] is not None
                    and self.splits[-1][0] >= self.run.segs[-1]["pb"]),
                "canUndoPauses": self.pause_total > 0 or self.paused_at is not None,
                "autosplitterRunning": self.asl_active, "editorOpen": self.editor is not None,
                "game": self.run.game, "category": self.run.category, "attempts": self.run.attempts,
                "offset": self.run.offset, "segments": segs,
            }

    def autosplitter_info(self, game):
        available = "Hollow Clockwork" in (game or "") or game == "Poppy Playtime: Chapter 4"
        return {"available": available, "description": "Load removal and auto splitting by MockRunner" if available else None,
                "website": None, "type": "Script" if available else None, "enabled": available and self.asl_active,
                "running": available and self.asl_active and game == self.run.game, "asl": True, "hasSettings": True,
                "pending": game != self.run.game}

    def menu(self):
        gens = [g["name"] for g in self.settings["generators"] if g["enabled"]]
        prof = self.settings["profiles"][self.settings["profile"]]
        return {"type": "menu", "recent": self.recent, "customComparisons": list(self.run.custom),
                "generatedComparisons": gens, "profiles": list(self.settings["profileOrder"]),
                "profile": self.settings["profile"], "globalHotkeys": prof["global"],
                "autosplitter": self.autosplitter_info(self.run.game)}

    def editor_snapshot(self, error=None):
        r = self.editor
        segs, prev = [], 0.0
        m = self.editor_method
        for s in r.segs:
            seg_t = None if s["pb"] is None else s["pb"] - prev
            if s["pb"] is not None:
                prev = s["pb"]
            segs.append({"name": s["name"], "pbSplit": s["pb"], "pbSegment": seg_t, "best": s["best"],
                         "comps": {c: s["comps"].get(c) for c in r.custom if c != "Personal Best"}})
        return {"type": "editor", "error": error, "game": r.game, "category": r.category, "attempts": r.attempts,
                "offset": r.offset, "method": m, "canChangeSegments": self.phase == "NotRunning",
                "hasChanged": r.changed, "comparisons": list(r.custom), "segments": segs,
                "autosplitter": self.autosplitter_info(r.game)}

    def asl_snapshot(self, error=None):
        if not self.asl_active:
            return {"type": "asl", "error": error, "available": False, "native": False}
        return {"type": "asl", "error": error, "available": True, "loaded": True,
                "scriptPath": "C:/LiveSplit/Components/HollowClockwork.asl",
                "basic": self.asl["basic"], "custom": self.asl["custom"]}

    def settings_snapshot(self, error=None):
        d = copy.deepcopy(self.settings)
        d["type"] = "settings"
        d["error"] = error
        return d

    @staticmethod
    def result(cmd, error=None):
        return {"type": "result", "cmd": cmd, "ok": error is None, "error": error}

    # ---------------------------------------------------------------- commands
    def command(self, line):
        """Returns a list of messages to send back."""
        cmd, _, arg = line.strip().partition(" ")
        cmd = cmd.lower()
        arg = arg.strip()
        out = []
        with self.lock:
            now = time.perf_counter()
            if cmd == "splitorstart":
                cmd = "start" if self.phase == "NotRunning" else ("pause" if self.phase == "Paused" else "split")
            if cmd == "start" and self.phase == "NotRunning":
                self.phase, self.index, self.start_at = "Running", 0, now
                self.run.attempts += 1
            elif cmd == "split" and self.phase == "Running":
                self.splits[self.index] = (self.real_ms(now), self.game_ms(now))
                self.index += 1
                if self.index >= len(self.run.segs):
                    self.phase = "Ended"
                    self.stop_loading(now)
            elif cmd == "skip" and self.phase == "Running" and self.index < len(self.run.segs) - 1:
                self.splits[self.index] = None
                self.index += 1
            elif cmd == "undo" and self.phase in ("Running", "Ended") and self.index > 0:
                if self.phase == "Ended":
                    self.phase = "Running"
                self.index -= 1
                self.splits[self.index] = None
            elif cmd == "pause":
                if self.phase == "Running":
                    self.phase, self.paused_at = "Paused", now
                elif self.phase == "Paused":
                    self.pause_total += now - self.paused_at
                    self.phase, self.paused_at = "Running", None
            elif cmd == "undo_pauses":
                if self.paused_at:
                    self.paused_at = now
                self.pause_total = 0
            elif cmd in ("reset", "reset_discard"):
                if cmd == "reset" and self.phase != "NotRunning":
                    self.save_times()
                self.reset_state()
            elif cmd == "timing":
                self.method = arg if arg in ("real", "game") else ("game" if self.method == "real" else "real")
            elif cmd == "compare":
                self.comparison = arg
            elif cmd in ("compare_next", "compare_prev"):
                allc = self.run.custom + [g["name"] for g in self.settings["generators"] if g["enabled"]]
                i = allc.index(self.comparison) if self.comparison in allc else 0
                self.comparison = allc[(i + (1 if cmd == "compare_next" else -1)) % len(allc)]
            elif cmd == "global_hotkeys":
                p = self.settings["profiles"][self.settings["profile"]]
                p["global"] = not p["global"]
                out.append(self.menu())
            elif cmd == "profile":
                if arg in self.settings["profiles"]:
                    self.settings["profile"] = arg
                out.append(self.menu())
            elif cmd == "window":
                self.hidden = arg == "hide"
            # ---- files (pretend)
            elif cmd == "open":
                self.reset_state()
                self.run.file = arg
                self.run.changed = False
                out += [self.result(cmd), self.menu()]
            elif cmd in ("save", "save_pb"):
                if not self.run.file and not arg:
                    out.append(self.result(cmd, "needs_path"))
                else:
                    if arg:
                        self.run.file = arg if arg.lower().endswith(".lss") else arg + ".lss"
                    self.run.changed = False
                    print("  (pretend) saved to", self.run.file)
                    out += [self.result(cmd), self.menu()]
            elif cmd == "discard_changes":
                self.run.changed = False
            elif cmd == "close":
                self.reset_state()
                self.run = Run()
                self.run.game, self.run.category, self.run.file = "", "", None
                self.run.segs = [{"name": "", "pb": None, "best": None, "comps": {}}]
                self.splits = [None]
                out.append(self.menu())
            elif cmd == "menu":
                out.append(self.menu())
            # ---- editor
            elif cmd == "editor_begin":
                self.editor = copy.deepcopy(self.run)
                self.editor_method = self.method
                out.append(self.editor_snapshot())
            elif cmd == "editor_op" and self.editor:
                out.append(self.editor_snapshot(self.editor_op(json.loads(arg))))
            elif cmd == "editor_ok" and self.editor:
                self.editor.changed = True
                self.run = self.editor
                self.editor = None
                if len(self.splits) != len(self.run.segs):
                    self.splits = (self.splits + [None] * len(self.run.segs))[:len(self.run.segs)]
                out += [self.result(cmd), self.menu()]
            elif cmd == "editor_cancel":
                self.editor = None
            # ---- autosplitter
            elif cmd == "asl_toggle":
                self.asl_active = not self.asl_active
                out.append(self.editor_snapshot() if self.editor else self.result(cmd))
                out.append(self.menu())
            elif cmd == "asl_enable":
                self.asl_active = True
                out += [self.result(cmd), self.menu()]
            elif cmd == "asl_get":
                out.append(self.asl_snapshot())
            elif cmd == "asl_set":
                op = json.loads(arg)
                if op.get("reset"):
                    for s in self.asl["custom"]:
                        s["value"] = s["default"]
                else:
                    lst = self.asl["basic"] if op.get("basic") else self.asl["custom"]
                    for s in lst:
                        if s["id"] == op.get("id"):
                            s["value"] = bool(op.get("value"))
                self.run.changed = True
                out.append(self.asl_snapshot())
            elif cmd == "asl_native":
                out.append(self.result(cmd, "The mock has no native settings window"))
            # ---- settings
            elif cmd == "settings_get":
                out.append(self.settings_snapshot())
            elif cmd == "settings_apply":
                d = json.loads(arg)
                for k in ("profile", "profileOrder", "warnOnReset", "simpleSumOfBest", "refreshRate", "serverPort",
                          "hcpHistorySize", "hcpNBestRuns", "generators"):
                    if k in d:
                        self.settings[k] = d[k]
                self.settings["profiles"] = {n: {k: v for k, v in p.items() if k != "from"}
                                             for n, p in d.get("profiles", {}).items()}
                for p in self.settings["profiles"].values():
                    for k, v in list(p.items()):
                        if v == "":
                            p[k] = None
                out += [self.settings_snapshot(), self.result(cmd), self.menu()]
            elif cmd in ("hotkeys_suspend", "hotkeys_resume", "ping", "quit"):
                pass
            else:
                out.append(self.result(cmd, "Unknown command: " + cmd))
                return out
            self.event = cmd
        out.append(self.snapshot(cmd))
        return out

    def editor_op(self, op):
        r = self.editor
        m = op.get("op")
        can = self.phase == "NotRunning"
        try:
            if m == "set":
                f, v = op["field"], op.get("value") or ""
                if f == "game":
                    r.game = v
                elif f == "category":
                    r.category = v
                elif f == "attempts":
                    if not v.isdigit():
                        return "Attempts must be a whole number"
                    r.attempts = int(v)
                elif f == "offset":
                    r.offset = parse_time(v) if v.strip() else 0.0
            elif m == "name":
                r.segs[op["i"]]["name"] = op.get("value") or ""
            elif m == "time":
                i, col, v = op["i"], op["col"], (op.get("value") or "").strip()
                t = parse_time(v) if v else None
                seg = r.segs[i]
                if col == "pbSplit":
                    seg["pb"] = t
                elif col == "best":
                    seg["best"] = t
                elif col == "pbSegment":
                    prev = 0.0
                    seg_times = []
                    for s in r.segs:
                        seg_times.append(None if s["pb"] is None else s["pb"] - prev)
                        if s["pb"] is not None:
                            prev = s["pb"]
                    seg_times[i] = t
                    prev = 0.0
                    for k, s in enumerate(r.segs):
                        s["pb"] = None if seg_times[k] is None else prev + seg_times[k]
                        if s["pb"] is not None:
                            prev = s["pb"]
                elif col.startswith("comp:"):
                    seg["comps"][col[5:]] = t
            elif m == "method":
                self.editor_method = op.get("value")
                return None
            elif m == "insert":
                if not can:
                    return "Can't add splits during a run"
                at = op["i"] + (1 if op.get("where") == "below" else 0)
                r.segs.insert(max(0, min(at, len(r.segs))), {"name": "", "pb": None, "best": None, "comps": {}})
            elif m == "remove":
                if not can:
                    return "Can't remove splits during a run"
                for i in sorted(set(op.get("indices", [])), reverse=True):
                    if len(r.segs) > 1 and 0 <= i < len(r.segs):
                        r.segs.pop(i)
            elif m == "move":
                if not can:
                    return "Can't move splits during a run"
                i, d = op["i"], op["dir"]
                j = i + d
                if 0 <= j < len(r.segs):
                    r.segs[i], r.segs[j] = r.segs[j], r.segs[i]
            elif m == "comp_add":
                n = (op.get("name") or "").strip()
                if not n:
                    return "Name can't be empty"
                if n in r.custom:
                    return "A comparison with this name already exists"
                r.custom.append(n)
            elif m == "comp_rename":
                old, new = op.get("old"), (op.get("new") or "").strip()
                if old == "Personal Best":
                    return "Personal Best can't be renamed"
                if not new or new in r.custom:
                    return "That name is empty or already used"
                r.custom[r.custom.index(old)] = new
                for s in r.segs:
                    if old in s["comps"]:
                        s["comps"][new] = s["comps"].pop(old)
            elif m == "comp_remove":
                n = op.get("name")
                if n == "Personal Best":
                    return "Personal Best can't be removed"
                if n in r.custom:
                    r.custom.remove(n)
                for s in r.segs:
                    s["comps"].pop(n, None)
            elif m == "clear_history":
                pass
            elif m == "clear_times":
                for s in r.segs:
                    s["pb"], s["best"], s["comps"] = None, None, {}
            else:
                return "unknown editor op " + str(m)
        except ValueError:
            return "Invalid time"
        r.changed = True
        return None

    # ---------------------------------------------------------------- fake autosplitter / load remover
    def tick_auto(self, auto):
        with self.lock:
            now = time.perf_counter()
            if self.phase != "Running":
                if auto and self.phase in ("NotRunning", "Ended") and random.random() < 0.004:
                    if self.phase == "Ended":
                        self.command("reset")
                    self.command("start")
                return
            if self.loading_since is None and random.random() < 0.006:
                self.loading_since = now
            elif self.loading_since and now - self.loading_since > random.uniform(1.0, 2.5):
                self.stop_loading(now)
            if auto and self.index < len(self.run.segs):
                prev = self.run.segs[self.index - 1]["pb"] if self.index > 0 else 0
                cur = self.run.segs[self.index]["pb"]
                if cur is None or prev is None:
                    seg_len = 5000
                else:
                    seg_len = (cur - prev) / 10   # 10x speed so you see it happen
                last = self.splits[self.index - 1][0] if self.index > 0 and self.splits[self.index - 1] else 0
                if self.real_ms(now) - last > seg_len * random.uniform(0.9, 1.1):
                    self.command("split")


class Server:
    def __init__(self, mock):
        self.mock = mock
        self.clients = []
        self.lock = threading.Lock()

    def broadcast(self, msg):
        data = (json.dumps(msg) + "\n").encode()
        with self.lock:
            for c in list(self.clients):
                try:
                    c.sendall(data)
                except OSError:
                    self.clients.remove(c)

    def handle(self, conn):
        f = conn.makefile("r", encoding="utf-8")
        try:
            for line in f:
                if line.strip():
                    print("cmd:", line.strip()[:120])
                    for msg in self.mock.command(line):
                        self.broadcast(msg)
        except OSError:
            pass
        finally:
            with self.lock:
                if conn in self.clients:
                    self.clients.remove(conn)
            conn.close()
            print("client disconnected")

    def serve(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", PORT))
        srv.listen()
        print(f"mock Mu Split Bridge listening on 127.0.0.1:{PORT}")
        while True:
            conn, _ = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                self.clients.append(conn)
            print("client connected")
            conn.sendall((json.dumps(self.mock.snapshot("hello")) + "\n").encode())
            conn.sendall((json.dumps(self.mock.menu()) + "\n").encode())
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--auto", action="store_true", help="start and split automatically, like an autosplitter")
    args = ap.parse_args()

    mock = Mock()
    server = Server(mock)
    threading.Thread(target=server.serve, daemon=True).start()

    last = None
    try:
        while True:
            mock.tick_auto(args.auto)
            ev = None
            if (mock.index, mock.phase) != last:
                ev = mock.event
                last = (mock.index, mock.phase)
            server.broadcast(mock.snapshot(ev))
            time.sleep(HEARTBEAT)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
