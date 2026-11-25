using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using LiveSplit.Model;

namespace LiveSplit.MuSplit
{
    /// <summary>
    /// The actual bridge. One per LiveSplit process.
    ///
    /// It attaches itself to LiveSplit's main window as soon as LiveSplit loads the
    /// component DLLs, so it works with ANY layout, no need to add it in Edit Layout.
    ///
    /// When Mu Split launches LiveSplit it sets two environment variables:
    ///   MUSPLIT_HIDDEN=1         keep the LiveSplit window invisible (and stop it drawing)
    ///   MUSPLIT_PARENT_PID=1234  close LiveSplit when Mu Split exits (even if it crashes)
    ///
    /// Autosplitters and global hotkeys keep running while hidden: LiveSplit drives
    /// both from its own background refresh thread, before any drawing happens.
    /// </summary>
    internal sealed class BridgeHost
    {
        public const int Port = 16850;          // LiveSplit's own server uses 16834/16835
        private const int HeartbeatMs = 50;     // 20 Hz; the client interpolates between these

        // ------------------------------------------------------------------ singleton / auto-attach

        private static readonly object gate = new object();
        private static BridgeHost instance;
        private static System.Threading.Timer finder;

        /// <summary>Called from the factory constructor: keep looking for LiveSplit's main window.</summary>
        public static void EnsureStarted()
        {
            lock (gate)
            {
                if (instance != null || finder != null) return;
                finder = new System.Threading.Timer(_ => TryFindTimerForm(), null, 0, 50);
            }
        }

        private static void TryFindTimerForm()
        {
            try
            {
                foreach (Form f in Application.OpenForms)
                {
                    // LiveSplit's main window. (The run/layout editors also have a CurrentState.)
                    if (f.GetType().Name != "TimerForm") continue;
                    var prop = f.GetType().GetProperty("CurrentState", BindingFlags.Public | BindingFlags.Instance);
                    if (prop == null || !f.IsHandleCreated) return;

                    f.BeginInvoke(new Action(() =>
                    {
                        if (prop.GetValue(f, null) is LiveSplitState st) Attach(st, f);
                    }));
                    return;
                }
            }
            catch { /* OpenForms changed while we looked; try again next tick */ }
        }

        /// <summary>Also called by the (optional) layout component.</summary>
        public static void Attach(LiveSplitState state, Form timerForm = null)
        {
            lock (gate)
            {
                if (instance != null) return;
                timerForm = timerForm ?? state.Form;
                if (timerForm == null) return;
                instance = new BridgeHost(state, timerForm);
                finder?.Dispose();
                finder = null;
            }
        }

        // ------------------------------------------------------------------ instance

        private readonly LiveSplitState state;
        private readonly LiveSplitAccess ls;
        private readonly TimerModel model;
        private readonly BridgeServer server;
        private readonly System.Threading.Timer heartbeat;
        private readonly AutoSplitterFeature asl;
        private readonly SettingsFeature settings;
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        private EditorSession editor;
        private bool wantHidden;
        private int seq;

        private BridgeHost(LiveSplitState state, Form timerForm)
        {
            this.state = state;
            ls = new LiveSplitAccess(timerForm);
            model = new TimerModel { CurrentState = state };
            asl = new AutoSplitterFeature(state, ls);
            settings = new SettingsFeature(state, ls);

            wantHidden = Environment.GetEnvironmentVariable("MUSPLIT_HIDDEN") == "1";
            if (wantHidden) ApplyWindow();

            // Push immediately on anything that changes the run, so splits feel instant.
            state.OnStart += (s, e) => PushSoon("start");
            state.OnSplit += (s, e) => PushSoon("split");
            state.OnSkipSplit += (s, e) => PushSoon("skip");
            state.OnUndoSplit += (s, e) => PushSoon("undo");
            state.OnReset += (s, e) => PushSoon("reset");
            state.OnPause += (s, e) => PushSoon("pause");
            state.OnResume += (s, e) => PushSoon("resume");
            state.OnUndoAllPauses += (s, e) => PushSoon("undo_pauses");
            state.OnSwitchComparisonNext += (s, e) => PushSoon("compare");
            state.OnSwitchComparisonPrevious += (s, e) => PushSoon("compare");
            state.RunManuallyModified += (s, e) => PushSoon("run_modified");

            server = new BridgeServer(Port, HandleCommand, () => OnUi(() =>
            {
                server.Broadcast(BuildSnapshot("hello"));
                server.Broadcast(BuildMenu());
            }));

            heartbeat = new System.Threading.Timer(_ => OnUi(() =>
            {
                if (wantHidden) ApplyWindow();   // LiveSplit re-applies layout opacity sometimes
                if (server.HasClients) server.Broadcast(BuildSnapshot(null));
            }), null, HeartbeatMs, HeartbeatMs);

            WatchParent();
        }

        // ------------------------------------------------------------------ window + lifetime

        private void ApplyWindow()
        {
            var f = ls.Form;
            if (f == null || f.IsDisposed) return;
            if (wantHidden)
            {
                if (f.Opacity > 0) f.Opacity = 0;
                if (f.ShowInTaskbar) f.ShowInTaskbar = false;
                // Skip LiveSplit's own drawing entirely; autosplitter + hotkeys run before this check.
                ls.Set("DontRedraw", true);
            }
            else
            {
                ls.Set("DontRedraw", false);
                if (f.WindowState == FormWindowState.Minimized) f.WindowState = FormWindowState.Normal;
                f.Opacity = 1;
                f.ShowInTaskbar = true;
                f.Invalidate();
            }
        }

        private void WatchParent()
        {
            var pidText = Environment.GetEnvironmentVariable("MUSPLIT_PARENT_PID");
            if (!int.TryParse(pidText, out int pid)) return;
            try
            {
                var parent = Process.GetProcessById(pid);
                parent.EnableRaisingEvents = true;
                parent.Exited += (s, e) => OnUi(CloseLiveSplit);
            }
            catch
            {
                OnUi(CloseLiveSplit);   // parent already gone
            }
        }

        /// <summary>Show the window first so any "save your splits?" prompt is visible.</summary>
        private void CloseLiveSplit()
        {
            wantHidden = false;
            ApplyWindow();
            ls.Form.Close();
        }

        // ------------------------------------------------------------------ threading

        /// <summary>Run on LiveSplit's UI thread, where it's safe to touch state/model.</summary>
        private void OnUi(Action a)
        {
            var form = ls.Form;
            if (form == null || form.IsDisposed) return;
            if (form.InvokeRequired)
            {
                try { form.BeginInvoke(a); } catch (ObjectDisposedException) { } catch (InvalidOperationException) { }
            }
            else a();
        }

        private void PushSoon(string evt) => OnUi(() => server.Broadcast(BuildSnapshot(evt)));

        private void Result(string cmd, string error) =>
            server.Broadcast(new Json().BeginObject()
                .Prop("type", "result").Prop("cmd", cmd).Prop("ok", error == null).Prop("error", error)
                .EndObject().ToString());

        // ------------------------------------------------------------------ commands

        private void HandleCommand(string line)
        {
            string cmd = line, arg = null;
            int sp = line.IndexOf(' ');
            if (sp > 0) { cmd = line.Substring(0, sp); arg = line.Substring(sp + 1).Trim(); }
            cmd = cmd.ToLowerInvariant();

            OnUi(() =>
            {
                try { Dispatch(cmd, arg); }
                catch (Exception e)
                {
                    Result(cmd, e.Message);
                }
                server.Broadcast(BuildSnapshot(cmd));
            });
        }

        private Dictionary<string, object> Obj(string arg) =>
            string.IsNullOrEmpty(arg) ? new Dictionary<string, object>() : json.DeserializeObject(arg) as Dictionary<string, object>;

        private void Dispatch(string cmd, string arg)
        {
            switch (cmd)
            {
                // ---------------------------------------------------- timer control
                case "start": model.Start(); break;
                case "split": model.Split(); break;
                case "splitorstart":
                    if (state.CurrentPhase == TimerPhase.NotRunning) model.Start();
                    else if (state.CurrentPhase == TimerPhase.Paused) model.Pause();   // resume, like LiveSplit
                    else model.Split();
                    break;
                case "undo": model.UndoSplit(); break;
                case "skip": model.SkipSplit(); break;
                case "pause": model.Pause(); break;                 // toggles
                case "undo_pauses": model.UndoAllPauses(); break;
                case "reset": model.Reset(true); break;             // keep golds / history
                case "reset_discard": model.Reset(false); break;    // throw the attempt away

                case "timing":
                    state.CurrentTimingMethod =
                        arg == "game" ? TimingMethod.GameTime :
                        arg == "real" ? TimingMethod.RealTime :
                        state.CurrentTimingMethod == TimingMethod.RealTime ? TimingMethod.GameTime : TimingMethod.RealTime;
                    break;

                case "compare":
                    if (!string.IsNullOrEmpty(arg) && state.Run.Comparisons.Contains(arg)) state.CurrentComparison = arg;
                    break;
                case "compare_next": model.SwitchComparisonNext(); break;
                case "compare_prev": model.SwitchComparisonPrevious(); break;

                case "global_hotkeys": settings.ToggleGlobalHotkeys(); server.Broadcast(BuildMenu()); break;
                case "profile": settings.SwitchProfile(arg); server.Broadcast(BuildMenu()); break;

                // ---------------------------------------------------- splits files
                case "open":
                    if (string.IsNullOrEmpty(arg)) throw new Exception("No file given");
                    state.Run.HasChanged = false;               // Mu Split already asked about saving
                    bool opened = SafeBool(() => ls.Call("OpenRunFromFile", ("filePath", arg), ("suppressPrompts", true)),
                                           () => ls.Call("OpenRunFromFile", ("filePath", arg)));
                    Result(cmd, opened ? null : "That file couldn't be opened as splits");
                    server.Broadcast(BuildMenu());
                    break;

                case "save":
                case "save_pb":
                    if (string.IsNullOrEmpty(state.Run.FilePath) && string.IsNullOrEmpty(arg)) throw new Exception("needs_path");
                    if (cmd == "save_pb") model.ResetAndSetAttemptAsPB();
                    if (!string.IsNullOrEmpty(arg))
                    {
                        if (!arg.EndsWith(".lss", StringComparison.OrdinalIgnoreCase)) arg += ".lss";
                        state.Run.FilePath = arg;
                    }
                    bool saved = SafeBool(() => ls.Call("SaveSplits", ("promptPBMessage", false), ("suppressPrompts", true)),
                                          () => ls.Call("SaveSplits", ("promptPBMessage", false)));
                    Result(cmd, saved ? null : "Splits could not be saved");
                    server.Broadcast(BuildMenu());
                    break;

                case "discard_changes": state.Run.HasChanged = false; break;

                case "close":
                    state.Run.HasChanged = false;
                    ls.Call("CloseSplits");
                    server.Broadcast(BuildMenu());
                    break;

                case "menu": server.Broadcast(BuildMenu()); break;

                // ---------------------------------------------------- splits editor
                case "editor_begin":
                    editor = new EditorSession(state, ls);
                    server.Broadcast(editor.Snapshot(null, asl));
                    break;
                case "editor_op":
                    if (editor == null) throw new Exception("Editor isn't open");
                    server.Broadcast(editor.Snapshot(editor.Apply(Obj(arg)), asl));
                    break;
                case "editor_ok":
                    if (editor == null) break;
                    editor.Ok(); editor = null;
                    Result(cmd, null);
                    server.Broadcast(BuildMenu());
                    break;
                case "editor_cancel":
                    editor?.Cancel(); editor = null;
                    break;

                // ---------------------------------------------------- autosplitter
                case "asl_toggle":
                {
                    string err = asl.Toggle(string.IsNullOrEmpty(arg) ? state.Run.GameName : arg);
                    if (editor != null) server.Broadcast(editor.Snapshot(err, asl));
                    else Result(cmd, err);
                    server.Broadcast(BuildMenu());
                    break;
                }
                case "asl_enable":
                    Result(cmd, asl.Enable(string.IsNullOrEmpty(arg) ? state.Run.GameName : arg));
                    server.Broadcast(BuildMenu());
                    break;
                case "asl_get": server.Broadcast(asl.Snapshot(null)); break;
                case "asl_set": server.Broadcast(asl.Snapshot(asl.Set(Obj(arg)))); break;
                case "asl_native": Result(cmd, asl.OpenNativeSettings()); break;

                // ---------------------------------------------------- settings
                case "settings_get": server.Broadcast(settings.Snapshot(null)); break;
                case "hotkeys_suspend": settings.SuspendHotkeys(); break;   // while the Settings window is open,
                case "hotkeys_resume": settings.ResumeHotkeys(); break;     // like LiveSplit's own dialog
                case "settings_apply":
                {
                    string err = settings.Apply(Obj(arg));
                    server.Broadcast(settings.Snapshot(err));
                    Result(cmd, err);
                    server.Broadcast(BuildMenu());
                    break;
                }

                // ---------------------------------------------------- app
                case "window":
                    wantHidden = arg == "hide";
                    ApplyWindow();
                    break;
                case "quit": CloseLiveSplit(); break;
                case "ping": break;

                // ---------------------------------------------------- workshop downloads
                // The Love2D app can't do HTTPS itself. Only GitHub addresses, text only.
                case "http_get":
                {
                    string url = (arg ?? "").Trim();
                    bool allowed = url.StartsWith("https://raw.githubusercontent.com/", StringComparison.OrdinalIgnoreCase)
                                || url.StartsWith("https://api.github.com/", StringComparison.OrdinalIgnoreCase);
                    if (!allowed) throw new Exception("Only GitHub workshop addresses can be downloaded");
                    System.Threading.ThreadPool.QueueUserWorkItem(_ =>
                    {
                        string body = null, err = null;
                        try
                        {
                            System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
                            using (var wc = new System.Net.WebClient())
                            {
                                wc.Headers.Add("User-Agent", "MuSplit");
                                wc.Encoding = System.Text.Encoding.UTF8;
                                body = wc.DownloadString(url);
                            }
                            if (body != null && body.Length > 8 * 1024 * 1024) { body = null; err = "That file is too big"; }
                        }
                        catch (Exception e) { err = e.Message; }
                        OnUi(() => server.Broadcast(new Json().BeginObject()
                            .Prop("type", "http").Prop("url", url).Prop("ok", err == null)
                            .Prop("body", body).Prop("error", err).EndObject().ToString()));
                    });
                    break;
                }
                default: throw new Exception("Unknown command: " + cmd);
            }
        }

        /// <summary>Try the newer LiveSplit signature first, then the older one.</summary>
        private static bool SafeBool(Func<object> newer, Func<object> older)
        {
            object r;
            try { r = newer(); }
            catch (MissingMethodException) { r = older(); }
            return !(r is bool b) || b;
        }

        // ------------------------------------------------------------------ snapshots

        private bool ResetWouldUpdateTimes()
        {
            // Same check as LiveSplit's "You have beaten some of your best times" prompt
            var m = state.CurrentTimingMethod;
            var run = state.Run;
            if (run.Count == 0 || state.CurrentPhase == TimerPhase.NotRunning) return false;
            for (int i = 0; i < run.Count; i++)
                if (LiveSplitStateHelper.CheckBestSegment(state, i, m)) return true;
            var last = run[run.Count - 1];
            return (last.SplitTime[m] != null && last.PersonalBestSplitTime[m] == null)
                || last.SplitTime[m] < last.PersonalBestSplitTime[m];
        }

        private bool SaveWouldAskAboutPb()
        {
            // Same check as LiveSplit's "This run did not beat your current splits" prompt
            var m = state.CurrentTimingMethod;
            var run = state.Run;
            if (run.Count == 0) return false;
            var last = run[run.Count - 1];
            return (state.CurrentPhase == TimerPhase.Ended
                    && last.PersonalBestSplitTime[m] != null
                    && last.SplitTime[m] >= last.PersonalBestSplitTime[m])
                || state.CurrentPhase == TimerPhase.Running
                || state.CurrentPhase == TimerPhase.Paused;
        }

        private string BuildSnapshot(string evt)
        {
            var m = state.CurrentTimingMethod;
            var run = state.Run;
            var comp = state.CurrentComparison;
            var s = state.Settings;

            var j = new Json().BeginObject()
                .Prop("type", "state")
                .Prop("seq", ++seq)
                .Prop("event", evt)
                .Prop("phase", state.CurrentPhase.ToString())
                .Prop("method", m == TimingMethod.GameTime ? "game" : "real")
                .Prop("index", state.CurrentSplitIndex)
                .Prop("time", state.CurrentTime[m])
                .Prop("realTime", state.CurrentTime.RealTime)
                .Prop("gameTime", state.CurrentTime.GameTime)
                .Prop("gameTimePaused", state.IsGameTimePaused)
                .Prop("comparison", comp)
                .Prop("windowHidden", wantHidden)
                .Prop("standalone", ls.Form.GetType().Namespace == "MuSplit.Engine")   // no LiveSplit window to show
                .Prop("hasChanged", run.HasChanged)
                .Prop("filePath", run.FilePath)
                .Prop("timerOnly", SafeGet(() => ls.InTimerOnlyMode))
                .Prop("warnOnReset", s.WarnOnReset)
                .Prop("resetPrompt", s.WarnOnReset && !SafeGet(() => ls.InTimerOnlyMode) && ResetWouldUpdateTimes())
                .Prop("savePrompt", SaveWouldAskAboutPb())
                .Prop("canUndoPauses", state.PauseTime.HasValue && state.PauseTime.Value > TimeSpan.Zero)
                .Prop("autosplitterRunning", run.IsAutoSplitterActive())
                .Prop("editorOpen", editor != null);

            asl.WriteStatus(j);
            j.Prop("game", run.GameName)
             .Prop("category", run.CategoryName)
             .Prop("attempts", run.AttemptCount)
             .Prop("offset", run.Offset);

            j.Key("segments").BeginArray();
            foreach (var seg in run)
            {
                TimeSpan? compTime = null;
                try { compTime = seg.Comparisons[comp][m]; } catch { }

                j.BeginObject()
                    .Prop("name", seg.Name)
                    .Prop("split", seg.SplitTime[m])                  // this run (null if not reached)
                    .Prop("comp", compTime)                           // selected comparison, cumulative
                    .Prop("pb", seg.PersonalBestSplitTime[m])
                    .Prop("best", seg.BestSegmentTime[m])             // gold, segment length
                 .EndObject();
            }
            j.EndArray();

            return j.EndObject().ToString();
        }

        /// <summary>Everything the right-click menu needs.</summary>
        private string BuildMenu()
        {
            var s = ls.Settings ?? state.Settings;
            var run = state.Run;
            var j = new Json().BeginObject().Prop("type", "menu");

            j.Key("recent").BeginArray();
            // LiveSplit keeps the newest last; show newest first, skip blanks and duplicates
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var f in s.RecentSplits.Reverse())
            {
                if (string.IsNullOrEmpty(f.Path) || !seen.Add(f.Path)) continue;
                j.BeginObject().Prop("path", f.Path).Prop("game", f.GameName).Prop("category", f.CategoryName).EndObject();
                if (seen.Count >= 25) break;
            }
            j.EndArray();

            j.Key("customComparisons").BeginArray();
            foreach (var c in run.CustomComparisons) j.Val(c);
            j.EndArray();
            j.Key("generatedComparisons").BeginArray();
            foreach (var g in run.ComparisonGenerators) j.Val(g.Name);
            j.EndArray();

            j.Key("profiles").BeginArray();
            foreach (var p in s.HotkeyProfiles.Keys) j.Val(p);
            j.EndArray();
            j.Prop("profile", state.CurrentHotkeyProfile);
            j.Prop("globalHotkeys", s.HotkeyProfiles.TryGetValue(state.CurrentHotkeyProfile, out var hp) && hp.GlobalHotkeysEnabled);

            j.Key("autosplitter");
            asl.WriteInfo(j, run.GameName);

            return j.EndObject().ToString();
        }

        private static bool SafeGet(Func<bool> f) { try { return f(); } catch { return false; } }
    }
}
