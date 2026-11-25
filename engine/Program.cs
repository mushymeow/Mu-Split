using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace MuSplit.Engine
{
    /// <summary>
    /// MuSplitEngine.exe: the timer, splits and autosplitters, with no window of its own.
    /// Mu Split (Love2D) starts it and talks to it on 127.0.0.1:16850 through the bridge,
    /// exactly like it used to talk to the bridge inside LiveSplit.
    /// </summary>
    internal static class Program
    {
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string path);

        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetDllDirectory(string path);

        /// <summary>
        /// LiveSplit's native parts live in x64\ / x86\ folders: livesplit_core.dll (reads
        /// .lss and other splits files) and Components\x64\asr_capi.dll (WebAssembly
        /// autosplitters). LiveSplit.exe points Windows at them on start; we load them
        /// up front by full path, so [DllImport("livesplit_core")] finds the loaded module.
        /// </summary>
        private static void LoadNativeLibraries(string basePath)
        {
            string arch = Environment.Is64BitProcess ? "x64" : "x86";
            SetDllDirectory(Path.Combine(basePath, arch));
            foreach (var file in new[]
            {
                Path.Combine(basePath, arch, "livesplit_core.dll"),
                Path.Combine(basePath, "Components", arch, "asr_capi.dll"),
            })
            {
                if (!File.Exists(file)) { EngineLog.Info("missing native library: " + file); continue; }
                if (LoadLibrary(file) == IntPtr.Zero)
                    EngineLog.Info("couldn't load " + file + " (error " + Marshal.GetLastWin32Error() + ")");
            }
        }

        [STAThread]
        private static void Main()
        {
            string basePath = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
            // LiveSplit keeps its autosplitter list in the working folder
            Environment.CurrentDirectory = basePath;

            using (var mutex = new Mutex(true, "MuSplitEngine", out bool first))
            {
                if (!first) return;   // one engine at a time (the bridge port is fixed)

                EngineLog.Start(Path.Combine(basePath, "engine.log"));
                LoadNativeLibraries(basePath);
                // LiveSplit and the ASL runtime report script errors through Trace: keep them
                System.Diagnostics.Trace.Listeners.Add(new EngineLog.Listener());
                System.Diagnostics.Trace.AutoFlush = true;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (s, e) => EngineLog.Error("unhandled", e.Exception);
                AppDomain.CurrentDomain.FirstChanceException += (s, e) => EngineLog.FirstChance(e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => EngineLog.Error("fatal", e.ExceptionObject as Exception);

                TimerForm form;
                try
                {
                    form = new TimerForm(basePath);
                    form.Show();           // invisible (see TimerForm), but a real, listed window
                    LiveSplit.MuSplit.BridgeHost.Attach(form.CurrentState, form);
                    form.Start();
                }
                catch (Exception e)
                {
                    EngineLog.Error("couldn't start", e);
                    return;
                }

                // Runs until the bridge closes the form ("quit", or Mu Split exiting)
                Application.Run(new ApplicationContext(form));
                EngineLog.Info("engine stopped");
            }
        }
    }

    /// <summary>engine.log next to the exe: startup, autosplitter and file errors.</summary>
    internal static class EngineLog
    {
        private static string path;
        private static readonly object gate = new object();

        public static void Start(string file)
        {
            path = file;
            try { if (File.Exists(path) && new FileInfo(path).Length > 1_000_000) File.Delete(path); } catch { }
            Info("---- Mu Split engine " + typeof(Program).Assembly.GetName().Version);
        }

        public static void Info(string msg) => Write(msg);

        // Autosplitter scripts and their helpers (asl-help) throw inside reflection, so
        // LiveSplit only logs "target of an invocation". Log the real exception, once each.
        private static readonly System.Collections.Generic.HashSet<string> seen = new System.Collections.Generic.HashSet<string>();
        [ThreadStatic] private static bool inFirstChance;
        public static void FirstChance(Exception e)
        {
            if (e == null || inFirstChance || path == null) return;
            inFirstChance = true;
            try
            {
                string trace = e.StackTrace ?? "";
                bool fromScript = trace.Contains("AslHelp") || trace.Contains("ASL") || trace.Contains("CompiledScript")
                                  || (e.Source ?? "").Contains("asl-help") || trace.Contains("ScriptableAutoSplit");
                if (!fromScript || e is System.Reflection.TargetInvocationException) return;
                string key = e.GetType().Name + e.Message;
                lock (seen) { if (seen.Count > 200 || !seen.Add(key)) return; }
                Write("autosplitter exception: " + e.GetType().FullName + ": " + e.Message + Environment.NewLine + trace);
            }
            catch { }
            finally { inFirstChance = false; }
        }

        /// <summary>
        /// "Access is denied" while a script connects (its init {} can't read the game yet).
        /// TimerForm restarts the autosplitter when this keeps happening.
        /// </summary>
        public static int InitAccessDenied;

        /// <summary>Trace output (ASL compile errors, "[ASL] ..." messages) into engine.log.
        /// The same message over and over is written once, with a count.</summary>
        public sealed class Listener : System.Diagnostics.TraceListener
        {
            private readonly System.Text.StringBuilder line = new System.Text.StringBuilder();
            private string last;
            private int repeats;
            public override void Write(string message) { lock (line) line.Append(message); }
            public override void WriteLine(string message)
            {
                string text;
                lock (line) { line.Append(message); text = line.ToString(); line.Clear(); }
                if (string.IsNullOrWhiteSpace(text)) return;
                text = text.TrimEnd();
                if (text.Contains("in 'init' method") && text.Contains("Access is denied"))
                    System.Threading.Interlocked.Increment(ref InitAccessDenied);
                if (text.Contains(" Error: "))
                {
                    // the status bar shows the latest script error for a few seconds
                    string msg = text.Substring(text.IndexOf(" Error: ") + 8);
                    int nl = msg.IndexOf('\n');
                    string detail = nl >= 0 && nl + 1 < msg.Length ? msg.Substring(nl + 1).Trim() : msg;
                    int nl2 = detail.IndexOf('\n');
                    if (nl2 >= 0) detail = detail.Substring(0, nl2).Trim();
                    LiveSplit.MuSplit.AutoSplitterFeature.LastError = detail.Length > 140 ? detail.Substring(0, 140) : detail;
                    LiveSplit.MuSplit.AutoSplitterFeature.LastErrorTime = DateTime.Now;
                }
                // "[ASL/123] Initializing" alternates with the error: treat both as repeats
                bool retrying = last != null && last.Contains("in 'init' method");
                string key = (retrying && text.Contains("] Initializing")) ? last : text;
                if (key == last) { repeats++; return; }
                if (repeats > 0) EngineLog.Write("trace: (the line above repeated " + repeats + " more times)");
                last = text;
                repeats = 0;
                EngineLog.Write("trace: " + text);
            }
        }
        public static void Error(string what, Exception e) => Write("ERROR " + what + ": " + e);

        internal static void Write(string line)
        {
            if (path == null) return;
            lock (gate)
            {
                try { File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff ") + line + Environment.NewLine); }
                catch { }
            }
        }
    }
}
