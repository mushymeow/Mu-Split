using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace System.Runtime.CompilerServices
{
    // .NET Framework doesn't ship this attribute, but the C# compiler honours our own copy:
    // a [ModuleInitializer] method runs as soon as the engine loads, before Main.
    [AttributeUsage(AttributeTargets.Method, Inherited = false)]
    internal sealed class ModuleInitializerAttribute : Attribute { }
}

namespace MuSplit.Engine
{
    /// <summary>
    /// Races: a WebSocket to the Mu Split race server, for the Love2D UI (which can't do
    /// secure WebSockets itself). The same connection carries Discord status updates
    /// ("discord <appId> <activity>", see DiscordPresence.cs). The UI connects to 127.0.0.1:16851 and talks in lines:
    ///
    ///   UI -> engine:   connect wss://...      send {json}      close
    ///   engine -> UI:   {"type":"open"}  {"type":"msg","data":"<the server's JSON, as a string>"}
    ///                   {"type":"close","reason":"..."}
    ///
    /// It's self-contained: it starts itself when the engine loads.
    /// </summary>
    internal static class RaceRelay
    {
        public const int Port = 16851;

        private static TcpClient ui;
        private static StreamWriter uiOut;
        private static readonly object uiGate = new object();
        private static ClientWebSocket ws;
        private static CancellationTokenSource wsCancel;
        private static readonly SemaphoreSlim sendGate = new SemaphoreSlim(1, 1);

        [System.Runtime.CompilerServices.ModuleInitializer]
        internal static void Init()
        {
            EngineLinux.TakeOver();          // another engine running? (Linux: see EngineLinux.cs)
            EngineLinux.StartWatchdog();
            var t = new Thread(Listen) { IsBackground = true, Name = "Race relay" };
            t.Start();
        }

        private static void Log(string msg)
        {
            try { EngineLog.Info("race: " + msg); } catch { }
        }

        private static void Listen()
        {
            TcpListener listener = null;
            try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
            // (an engine we took over from may take a moment to let go of the port)
            for (int attempt = 0; listener == null; attempt++)
            {
                try
                {
                    var l = new TcpListener(IPAddress.Loopback, Port);
                    l.Start();
                    listener = l;
                }
                catch (Exception e)
                {
                    if (attempt >= 60) { Log("can't listen on " + Port + ": " + e.Message); return; }
                    Thread.Sleep(500);
                }
            }

            while (true)
            {
                TcpClient client;
                try { client = listener.AcceptTcpClient(); }
                catch (Exception) { Thread.Sleep(500); continue; }
                // one UI at a time: a new connection replaces the old one
                lock (uiGate)
                {
                    try { ui?.Close(); } catch { }
                    ui = client;
                    client.NoDelay = true;
                    uiOut = new StreamWriter(client.GetStream(), new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
                }
                EngineLinux.Contact();
                ToUi(EngineLinux.Hello());
                var reader = new Thread(() => ReadUi(client)) { IsBackground = true, Name = "Race relay UI" };
                reader.Start();
            }
        }

        private static void ReadUi(TcpClient client)
        {
            try
            {
                using (var r = new StreamReader(client.GetStream(), new UTF8Encoding(false)))
                {
                    string line;
                    while ((line = r.ReadLine()) != null)
                    {
                        if (LocalOnly.LooksLikeWeb(line)) { Log("refused a web page's request"); break; }
                        EngineLinux.Contact();
                        int sp = line.IndexOf(' ');
                        string cmd = sp < 0 ? line : line.Substring(0, sp);
                        string arg = sp < 0 ? "" : line.Substring(sp + 1);
                        if (cmd == "connect") Connect(arg);
                        else if (cmd == "send") Send(arg);
                        else if (cmd == "close") CloseSocket("closed");
                        else if (cmd == "discord")
                        {
                            // "discord <appId> <activity json | null>"
                            int sp2 = arg.IndexOf(' ');
                            if (sp2 > 0) DiscordPresence.Update(arg.Substring(0, sp2), arg.Substring(sp2 + 1));
                        }
                        else if (cmd == "discord_clear") DiscordPresence.Clear();
                        else if (cmd == "quit_engine") EngineLinux.QuitForTakeover();
                        // "ping": just keeps the private engine alive (EngineLinux watchdog)
                    }
                }
            }
            catch (Exception) { }
            // the UI went away: so does the race connection, and the Discord status
            bool current;
            lock (uiGate) { current = ui == client; if (current) { ui = null; uiOut = null; } }
            if (current) { CloseSocket("ui gone"); DiscordPresence.Clear(); }
        }

        private static void ToUi(string json)
        {
            lock (uiGate)
            {
                try { uiOut?.WriteLine(json); } catch { }
            }
        }

        private static string Quote(string s)
        {
            var sb = new StringBuilder(s.Length + 16);
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }

        private static void Connect(string url)
        {
            CloseSocket(null);
            var socket = new ClientWebSocket();
            socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
            var cancel = new CancellationTokenSource();
            ws = socket;
            wsCancel = cancel;
            Task.Run(async () =>
            {
                try
                {
                    await socket.ConnectAsync(new Uri(url), cancel.Token);
                    ToUi("{\"type\":\"open\"}");
                    var buf = new byte[16384];
                    var msg = new MemoryStream();
                    while (socket.State == WebSocketState.Open)
                    {
                        var res = await socket.ReceiveAsync(new ArraySegment<byte>(buf), cancel.Token);
                        if (res.MessageType == WebSocketMessageType.Close) break;
                        msg.Write(buf, 0, res.Count);
                        if (!res.EndOfMessage) continue;
                        string text = Encoding.UTF8.GetString(msg.ToArray());
                        msg.SetLength(0);
                        ToUi("{\"type\":\"msg\",\"data\":" + Quote(text) + "}");
                    }
                    string why = socket.CloseStatusDescription ?? "";
                    if (ws == socket) ToUi("{\"type\":\"close\",\"reason\":" + Quote(why) + "}");
                }
                catch (Exception e)
                {
                    if (ws == socket && !cancel.IsCancellationRequested)
                    {
                        Log(e.GetType().Name + ": " + e.Message);
                        string why = e.InnerException != null ? e.InnerException.Message : e.Message;
                        ToUi("{\"type\":\"close\",\"reason\":" + Quote(why) + "}");
                    }
                }
            });
        }

        private static void Send(string text)
        {
            var socket = ws;
            if (socket == null || socket.State != WebSocketState.Open) return;
            var bytes = Encoding.UTF8.GetBytes(text);
            Task.Run(async () =>
            {
                await sendGate.WaitAsync();
                try { await socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch (Exception) { }
                finally { sendGate.Release(); }
            });
        }

        private static void CloseSocket(string reason)
        {
            var socket = ws;
            var cancel = wsCancel;
            ws = null;
            wsCancel = null;
            if (socket == null) return;
            try { cancel?.Cancel(); } catch { }
            try { socket.Abort(); } catch { }
            try { socket.Dispose(); } catch { }
        }
    }
}
