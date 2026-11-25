using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace MuSplit.Engine
{
    /// <summary>
    /// Linux (Wine/Proton) support. On Linux the Mu Split window is a native program and only
    /// the engine runs under Wine. There can be two engines:
    ///
    ///  * the "private" one Mu Split starts itself (MUSPLIT_PRIVATE=1), in its own Wine prefix:
    ///    the timer works, but it can't see games (they're in other prefixes);
    ///  * one Steam starts inside a game's prefix with the game (launch option
    ///    PROTON_REMOTE_DEBUG_CMD=".../MuSplitEngine.exe" %command%): it can read the game's
    ///    memory, so autosplitters work.
    ///
    /// The newest engine takes over: when it starts it asks the running one (on the relay port)
    /// to save and quit, then waits for the ports to free up. A private engine never takes over
    /// from a game's engine. The private engine also quits when Mu Split stops talking to it,
    /// since Wine can't watch a Linux process id (MUSPLIT_PARENT_PID is Windows only).
    /// </summary>
    internal static class EngineLinux
    {
        public static bool IsPrivate => Environment.GetEnvironmentVariable("MUSPLIT_PRIVATE") == "1";
        public static string GameAppId =>
            Environment.GetEnvironmentVariable("SteamAppId") ?? Environment.GetEnvironmentVariable("STEAM_COMPAT_APP_ID") ?? "";

        private static void Log(string msg) { try { EngineLog.Info("engine: " + msg); } catch { } }

        // the line the relay sends a new connection, so Mu Split (and other engines) know who we are
        public static string Hello()
        {
            return "{\"type\":\"hello\",\"private\":" + (IsPrivate ? "true" : "false")
                   + ",\"appid\":\"" + GameAppId.Replace("\"", "") + "\",\"pid\":"
                   + System.Diagnostics.Process.GetCurrentProcess().Id + "}";
        }

        private static bool PortBusy(int port)
        {
            try
            {
                using (var c = new TcpClient())
                {
                    var ar = c.BeginConnect("127.0.0.1", port, null, null);
                    bool ok = ar.AsyncWaitHandle.WaitOne(300) && c.Connected;
                    try { c.EndConnect(ar); } catch { }
                    return ok;
                }
            }
            catch { return false; }
        }

        /// <summary>Runs before anything else starts (from RaceRelay's module initializer).</summary>
        public static void TakeOver()
        {
            try
            {
                if (!PortBusy(RaceRelay.Port)) return;   // nobody else running
                string theirHello = null;
                using (var c = new TcpClient())
                {
                    c.Connect("127.0.0.1", RaceRelay.Port);
                    c.ReceiveTimeout = 2000;
                    var stream = c.GetStream();
                    var reader = new StreamReader(stream, new UTF8Encoding(false));
                    try { theirHello = reader.ReadLine(); } catch { }
                    bool theyArePrivate = theirHello != null && theirHello.Contains("\"private\":true");
                    if (IsPrivate && theirHello != null && !theyArePrivate)
                    {
                        // a game's engine is running: it's the useful one, so we go
                        Log("a game's engine is already running; this private one quits");
                        Environment.Exit(0);
                    }
                    var w = new StreamWriter(stream, new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
                    w.WriteLine("quit_engine");
                }
                // wait for it to save and let go of the ports
                for (int i = 0; i < 60 && (PortBusy(RaceRelay.Port) || PortBusy(16850)); i++) Thread.Sleep(250);
                Log("took over from the engine that was running" + (theirHello != null ? " (" + theirHello + ")" : ""));
            }
            catch (Exception e) { Log("takeover: " + e.Message); }
        }

        /// <summary>Another engine asked us to go: close like the user closed us (settings saved).</summary>
        public static void QuitForTakeover()
        {
            Log("another engine is taking over: quitting");
            try
            {
                Form f = null;
                foreach (Form form in Application.OpenForms) if (form.Name == "TimerForm") { f = form; break; }
                if (f != null) f.BeginInvoke(new Action(() => { try { f.Close(); } catch { } Application.Exit(); }));
                else Application.Exit();
            }
            catch { }
            // whatever happens, be gone in 5 s
            new Thread(() => { Thread.Sleep(5000); Environment.Exit(0); }) { IsBackground = true }.Start();
        }

        // ---------------------------------------------------------------- private engine watchdog

        private static long lastContact = DateTime.UtcNow.Ticks;
        public static void Contact() { Interlocked.Exchange(ref lastContact, DateTime.UtcNow.Ticks); }

        public static void StartWatchdog()
        {
            if (!IsPrivate) return;
            new Thread(() =>
            {
                while (true)
                {
                    Thread.Sleep(5000);
                    var quiet = TimeSpan.FromTicks(DateTime.UtcNow.Ticks - Interlocked.Read(ref lastContact));
                    if (quiet > TimeSpan.FromSeconds(30))
                    {
                        Log("Mu Split stopped talking to us for 30 s: quitting");
                        QuitForTakeover();
                        return;
                    }
                }
            }) { IsBackground = true, Name = "Private engine watchdog" }.Start();
        }
    }
}
