using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;

namespace MuSplit.Engine
{
    /// <summary>
    /// Discord Rich Presence ("Playing Mu Split · Poppy Playtime · Keycard (3/12) · 05:40 elapsed").
    ///
    /// Discord's desktop app listens on a local named pipe (\\.\pipe\discord-ipc-0..9). We send it
    /// frames: [int32 opcode][int32 length][JSON]. Opcode 0 = handshake with the app's id, 1 = a
    /// command (SET_ACTIVITY), 2 = close, 3/4 = ping/pong. No library needed.
    ///
    /// The UI builds the activity JSON and sends "discord &lt;appId&gt; &lt;activity json or null&gt;"
    /// through RaceRelay's connection; the newest one wins. If Discord isn't running we keep
    /// trying every 15 s, so it shows up when Discord is started later.
    /// </summary>
    internal static class DiscordPresence
    {
        private static readonly object gate = new object();
        private static readonly object writeGate = new object();
        private static readonly AutoResetEvent wake = new AutoResetEvent(false);
        private static string wantApp, wantActivity;
        private static bool dirty;
        private static Thread worker;

        private static NamedPipeClientStream pipe;
        private static string connectedApp;
        private static string lastError;

        public static void Update(string appId, string activityJson)
        {
            // an application id is digits only (it goes into the handshake JSON as it is)
            if (string.IsNullOrEmpty(appId) || appId.Length > 24) return;
            foreach (char c in appId) if (c < '0' || c > '9') return;
            lock (gate)
            {
                wantApp = appId;
                wantActivity = string.IsNullOrEmpty(activityJson) ? "null" : activityJson;
                dirty = true;
                if (worker == null)
                {
                    worker = new Thread(Loop) { IsBackground = true, Name = "Discord presence" };
                    worker.Start();
                }
            }
            wake.Set();
        }

        public static void Clear()
        {
            lock (gate) { if (wantApp == null) return; }
            Update(wantApp, "null");
        }

        private static void Log(string msg) { try { EngineLog.Info("discord: " + msg); } catch { } }

        private static void Loop()
        {
            while (true)
            {
                wake.WaitOne(15000);
                string app, act;
                bool send;
                lock (gate) { app = wantApp; act = wantActivity; send = dirty; dirty = false; }
                if (string.IsNullOrEmpty(app)) continue;

                if (pipe == null || !pipe.IsConnected || connectedApp != app)
                {
                    if (act == "null" && (pipe == null || !pipe.IsConnected)) continue;   // nothing to clear
                    if (!Connect(app)) { lock (gate) dirty = true; continue; }        // Discord not running: retry later
                    send = true;
                }
                if (!send) continue;
                string pid = System.Diagnostics.Process.GetCurrentProcess().Id.ToString();
                string cmd = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":" + pid + ",\"activity\":" + act + "},\"nonce\":\""
                             + Guid.NewGuid().ToString("N") + "\"}";
                if (!Write(1, cmd)) { Disconnect(); lock (gate) dirty = true; }
            }
        }

        private static bool Connect(string app)
        {
            Disconnect();
            for (int i = 0; i < 10; i++)
            {
                var p = new NamedPipeClientStream(".", "discord-ipc-" + i, PipeDirection.InOut, PipeOptions.None);
                try { p.Connect(150); }
                catch (Exception) { p.Dispose(); continue; }
                pipe = p;
                connectedApp = app;
                if (!Write(0, "{\"v\":1,\"client_id\":\"" + app + "\"}")) { Disconnect(); return false; }
                var reader = new Thread(() => Read(p)) { IsBackground = true, Name = "Discord presence reader" };
                reader.Start();
                Log("connected (discord-ipc-" + i + ")");
                return true;
            }
            return false;
        }

        private static void Disconnect()
        {
            var p = pipe;
            pipe = null;
            connectedApp = null;
            if (p == null) return;
            try { lock (writeGate) Frame(p, 2, "{}"); } catch { }
            try { p.Dispose(); } catch { }
        }

        private static bool Write(int op, string json)
        {
            var p = pipe;
            if (p == null) return false;
            try { lock (writeGate) Frame(p, op, json); return true; }
            catch (Exception e) { Log("write failed: " + e.Message); return false; }
        }

        private static void Frame(Stream s, int op, string json)
        {
            var body = Encoding.UTF8.GetBytes(json);
            var buf = new byte[8 + body.Length];
            BitConverter.GetBytes(op).CopyTo(buf, 0);
            BitConverter.GetBytes(body.Length).CopyTo(buf, 4);
            body.CopyTo(buf, 8);
            s.Write(buf, 0, buf.Length);
            s.Flush();
        }

        private static bool ReadExactly(Stream s, byte[] buf, int n)
        {
            int got = 0;
            while (got < n)
            {
                int r = s.Read(buf, got, n - got);
                if (r <= 0) return false;
                got += r;
            }
            return true;
        }

        // Discord's replies: must be read (or the pipe fills up); answer pings; log errors
        private static void Read(NamedPipeClientStream p)
        {
            try
            {
                var head = new byte[8];
                while (p.IsConnected)
                {
                    if (!ReadExactly(p, head, 8)) break;
                    int op = BitConverter.ToInt32(head, 0);
                    int len = BitConverter.ToInt32(head, 4);
                    if (len < 0 || len > 1 << 20) break;
                    var body = new byte[len];
                    if (!ReadExactly(p, body, len)) break;
                    string json = Encoding.UTF8.GetString(body);
                    if (op == 3) { lock (writeGate) Frame(p, 4, json); continue; }   // ping -> pong
                    if (op == 2) { Log("Discord closed the connection: " + json); break; }
                    if (json.Contains("\"evt\":\"ERROR\"") && json != lastError)
                    {
                        lastError = json;
                        Log("error: " + json);
                    }
                }
            }
            catch (Exception) { }
            if (pipe == p) { pipe = null; connectedApp = null; lock (gate) dirty = true; }
            try { p.Dispose(); } catch { }
        }
    }
}
