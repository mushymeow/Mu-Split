using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;
using System.Xml;
using LiveSplit.Model;
using LiveSplit.Model.Comparisons;
using LiveSplit.Model.Input;
using LiveSplit.Model.RunFactories;
using LiveSplit.Model.RunSavers;
using LiveSplit.Options;
using LiveSplit.Options.SettingsFactories;
using LiveSplit.Options.SettingsSavers;
using LiveSplit.UI;
using LiveSplit.UI.Components;

namespace MuSplit.Engine
{
    /// <summary>
    /// The Mu Split engine's main object: an invisible window that does the job of
    /// LiveSplit's main window (TimerForm), using LiveSplit's own libraries.
    ///
    /// The bridge calls TimerForm's methods by name (OpenRunFromFile, SaveSplits,
    /// CloseSplits, SetRun, RegenerateComparisons, SwitchComparisonGenerators,
    /// SaveSettingsToDisk...) and reads Settings / Hook / BasePath, so this class has
    /// the same names and does what TimerForm does, minus everything visual.
    ///
    /// It stays a (hidden) window because autosplitters, global hotkeys and the bridge
    /// all expect a UI thread with a message loop to Invoke onto (state.Form).
    ///
    /// It's called TimerForm (class name and Form.Name) on purpose: asl-help, the helper
    /// library most modern autosplitters load, finds LiveSplit's main window by that name
    /// in Application.OpenForms and reads its CurrentState.
    /// </summary>
    public sealed class TimerForm : Form
    {
        // ------------------------------------------------------------------ what the bridge reads

        public string BasePath { get; }
        public LiveSplitState CurrentState { get; }
        public DoubleTapPrevention Model { get; }
        public ISettings Settings { get; private set; }
        public CompositeHook Hook { get; }
        public ISettingsSaver SettingsSaver { get; } = new XMLSettingsSaver();
        public bool InTimerOnlyMode => false;
        public bool DontRedraw { get; set; }          // nothing to draw; the bridge sets it anyway

        private readonly Timer refresh;
        private string SettingsPath => Path.Combine(BasePath, "settings.cfg");

        public TimerForm(string basePath)
        {
            BasePath = basePath;
            Name = "TimerForm";                 // Application.OpenForms["TimerForm"] (asl-help)
            Text = "Mu Split Engine";
            // "shown" (so it's surely in Application.OpenForms) but invisible: fully transparent,
            // 1x1, never focused, not in the taskbar or Alt-Tab. It sits at the screen's centre
            // so a message box a script attaches to it (asl-help's "switch to Game Time?")
            // appears in the middle of the screen, not off it.
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            var area = Screen.PrimaryScreen.WorkingArea;
            Location = new System.Drawing.Point(area.Left + area.Width / 2, area.Top + area.Height / 2);
            Size = new System.Drawing.Size(1, 1);
            Opacity = 0;

            // Autosplitter scripts/DLLs and the autosplitter list live next to us
            ComponentManager.BasePath = basePath;
            LoadComponentFactories();

            Settings = LoadSettings();
            var layoutSettings = new StandardLayoutSettingsFactory().Create();
            var layout = new LiveSplit.UI.Layout { Settings = layoutSettings };
            CurrentState = new LiveSplitState(NewEmptyRun(), this, layout, layoutSettings, Settings);
            CurrentState.CurrentHotkeyProfile = Settings.HotkeyProfiles.Keys.FirstOrDefault() ?? "Default";

            Model = new DoubleTapPrevention(new TimerModel());
            Model.CurrentState = CurrentState;

            Hook = new CompositeHook(false);
            Hook.KeyOrButtonPressed += OnHotkey;
            RegisterHotkeys();

            SwitchComparisonGenerators();

            // ~66 Hz, like LiveSplit's refresh: runs the autosplitter and polls gamepads
            refresh = new Timer { Interval = 15 };
            refresh.Tick += (s, e) => Tick();
        }

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x80 | 0x08000000;   // WS_EX_TOOLWINDOW (no Alt-Tab) | WS_EX_NOACTIVATE
                return cp;
            }
        }

        // the bridge's "show LiveSplit window" makes no sense here: stay invisible
        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Opacity = 0;
        }

        // ------------------------------------------------------------------ LiveSplit's own TimerForm

        private Form twin;

        /// <summary>
        /// Some helper libraries (uhara, used by e.g. Poppy Playtime Chapter 5) don't look the
        /// main window up by name like asl-help does: they go through Application.OpenForms
        /// for an object of LiveSplit's real type (LiveSplit.View.TimerForm, in LiveSplit.View.dll)
        /// and read its CurrentState. Without one they never find the script and the
        /// autosplitter never loads.
        ///
        /// So we make one: a real LiveSplit.View.TimerForm, but built WITHOUT running its
        /// constructor (that would start all of LiveSplit: settings, layout, hotkeys, server...).
        /// Only the Form part is set up, its CurrentState points at ours, and it's never shown.
        /// It does nothing but sit in Application.OpenForms.
        /// </summary>
        private void CreateLiveSplitTwin()
        {
            try
            {
                // loaded by name (not by path) so it's the very same type helpers compiled against
                Assembly view;
                try { view = Assembly.Load("LiveSplit.View"); }
                catch (Exception) { EngineLog.Info("LiveSplit.View.dll not found: no TimerForm twin"); return; }
                var type = view.GetType("LiveSplit.View.TimerForm", false);
                if (type == null) { EngineLog.Info("LiveSplit.View.TimerForm not found: no TimerForm twin"); return; }

                var form = (Form)System.Runtime.Serialization.FormatterServices.GetUninitializedObject(type);
                // run Form's own constructor on it (not TimerForm's)
                typeof(Form).GetConstructor(Type.EmptyTypes).Invoke(form, null);
                // TimerForm's field initialisers didn't run: give its lists their empty values
                foreach (var f in type.GetFields(BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.DeclaredOnly))
                {
                    if (f.GetValue(form) != null || f.FieldType.IsValueType || f.FieldType.IsAbstract || f.FieldType.IsInterface) continue;
                    if (f.FieldType.IsGenericType && f.FieldType.GetGenericTypeDefinition() == typeof(List<>))
                        f.SetValue(form, Activator.CreateInstance(f.FieldType));
                }
                var cs = type.GetProperty("CurrentState", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                if (cs != null && cs.CanWrite) cs.SetValue(form, CurrentState);
                else type.GetField("<CurrentState>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)?.SetValue(form, CurrentState);
                var bp = type.GetProperty("BasePath", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                if (bp != null && bp.CanWrite) try { bp.SetValue(form, BasePath); } catch { }

                form.Name = "LiveSplitTimerForm";   // ours keeps the name "TimerForm" (asl-help)
                form.Text = "Mu Split Engine (LiveSplit)";
                form.ShowInTaskbar = false;
                form.FormBorderStyle = FormBorderStyle.None;
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new System.Drawing.Point(-32000, -32000);
                form.Size = new System.Drawing.Size(1, 1);
                form.Opacity = 0;

                // a window handle puts it in Application.OpenForms; if not, show and hide it once
                var h = form.Handle;
                if (!Application.OpenForms.Cast<Form>().Contains(form)) { form.Show(); form.Hide(); }
                twin = form;
                EngineLog.Info("LiveSplit TimerForm twin ready (" + (Application.OpenForms.Cast<Form>().Contains(form) ? "in" : "NOT in") + " OpenForms)");
            }
            catch (Exception ex)
            {
                EngineLog.Info("couldn't make the LiveSplit TimerForm twin: " + ex);
            }
        }

        /// <summary>Called once the bridge is attached: reopen the last splits, start ticking.</summary>
        public void Start()
        {
            CreateLiveSplitTwin();
            // (the newest entry is last; read by name so it works whether it's a class or struct)
            var recent = Settings.RecentSplits;
            object last = recent != null && recent.Count > 0 ? (object)recent[recent.Count - 1] : null;
            string path = Read(last, "Path") as string;
            if (!string.IsNullOrEmpty(path) && File.Exists(path))
            {
                if (OpenRunFromFile(path, true))
                {
                    if (Read(last, "LastTimingMethod") is TimingMethod tm) CurrentState.CurrentTimingMethod = tm;
                    if (Read(last, "LastHotkeyProfile") is string hp && Settings.HotkeyProfiles.ContainsKey(hp))
                    {
                        CurrentState.CurrentHotkeyProfile = hp;
                        RegisterHotkeys();
                    }
                }
            }
            SwitchComparison(Settings.LastComparison);
            refresh.Start();
            EngineLog.Info("engine started" + (string.IsNullOrEmpty(path) ? "" : ", splits: " + path));
        }

        // ------------------------------------------------------------------ per tick

        private bool updateErrorLogged;
        private object watchedComponent;      // for "script loaded" / "still loading" log lines
        private DateTime watchedSince;
        private bool scriptLogged, slowLogged;

        /// <summary>Log when an ASL script finishes loading (or that it's taking long).</summary>
        private void WatchScript(object component)
        {
            if (!ReferenceEquals(component, watchedComponent))
            {
                watchedComponent = component;
                watchedSince = DateTime.Now;
                scriptLogged = slowLogged = false;
                EngineLog.Info("autosplitter component: " + component.GetType().FullName);
            }
            if (scriptLogged || component.GetType().Name != "ASLComponent") return;
            object script = Read(component, "Script");
            if (script != null)
            {
                scriptLogged = true;
                EngineLog.Info("ASL script loaded after " + (int)(DateTime.Now - watchedSince).TotalMilliseconds + " ms");
            }
            else if (!slowLogged && (DateTime.Now - watchedSince).TotalSeconds > 5)
            {
                slowLogged = true;
                EngineLog.Info("ASL script still not loaded after 5 s (see trace lines above for errors)");
            }
        }

        private DateTime lastAutoRestart = DateTime.MinValue;

        /// <summary>
        /// A script that connected while the game was still starting can be refused access to
        /// it ("Access is denied" in init {}) and keeps retrying with that same refused handle.
        /// Turning the autosplitter off and on connects again, which works: do that for the user.
        /// </summary>
        private void RestartAutoSplitterIfStuck()
        {
            if (EngineLog.InitAccessDenied < 40) return;
            if ((DateTime.Now - lastAutoRestart).TotalSeconds < 4) return;
            System.Threading.Interlocked.Exchange(ref EngineLog.InitAccessDenied, 0);
            lastAutoRestart = DateTime.Now;
            var run = CurrentState.Run;
            if (run == null || !run.IsAutoSplitterActive()) return;
            EngineLog.Info("the game refused access while starting up: reconnecting the autosplitter");
            try
            {
                var splitter = run.AutoSplitter;
                splitter.Deactivate();
                splitter.Activate(CurrentState);
                var saved = run.AutoSplitterSettings;
                if (saved != null && saved.GetAttribute("gameName") == run.GameName && splitter.Component != null)
                    splitter.Component.SetSettings(saved);
            }
            catch (Exception e) { EngineLog.Error("reconnecting the autosplitter", e); }
        }

        private void Tick()
        {
            try { Hook.Poll(); } catch { }
            RestartAutoSplitterIfStuck();

            var run = CurrentState.Run;
            if (run != null && run.IsAutoSplitterActive())
            {
                try
                {
                    // LiveSplit runs the autosplitter from its refresh loop; so do we
                    var comp = run.AutoSplitter.Component;
                    WatchScript(comp);
                    comp.Update(null, CurrentState, 0, 0, LayoutMode.Vertical);
                    updateErrorLogged = false;
                }
                catch (Exception e)
                {
                    if (!updateErrorLogged) EngineLog.Error("autosplitter update", e);
                    updateErrorLogged = true;
                }
            }
        }

        // ------------------------------------------------------------------ settings

        private ISettings LoadSettings()
        {
            try
            {
                if (File.Exists(SettingsPath))
                    using (var stream = File.OpenRead(SettingsPath))
                        return new XMLSettingsFactory(stream).Create();
            }
            catch (Exception e) { EngineLog.Error("settings.cfg couldn't be read, using defaults", e); }
            return new StandardSettingsFactory().Create();
        }

        public void SaveSettingsToDisk()
        {
            try
            {
                using (var memory = new MemoryStream())
                {
                    SettingsSaver.Save(Settings, memory);
                    File.WriteAllBytes(SettingsPath, memory.ToArray());
                }
            }
            catch (Exception e) { EngineLog.Error("saving settings.cfg", e); }
        }

        public void SetProgressBar() { }   // taskbar progress: no taskbar button here

        // ------------------------------------------------------------------ splits files

        private static IRun NewEmptyRun()
        {
            var run = new Run(new StandardComparisonGeneratorsFactory()) { GameName = "", CategoryName = "" };
            run.Add(new Segment(""));
            run.HasChanged = false;
            return run;
        }

        private IRun LoadRunFromFile(string filePath)
        {
            IRun run;
            using (var stream = File.OpenRead(filePath))
                run = new StandardFormatsRunFactory(stream, filePath).Create(new StandardComparisonGeneratorsFactory());
            run.FilePath = filePath;
            run.HasChanged = false;

            AddCurrentToRecent();
            Settings.AddToRecentSplits(filePath, run, CurrentState.CurrentTimingMethod, CurrentState.CurrentHotkeyProfile);
            return run;
        }

        private void AddCurrentToRecent()
        {
            var cur = CurrentState.Run;
            if (cur != null && !string.IsNullOrEmpty(cur.FilePath))
                Settings.AddToRecentSplits(cur.FilePath, cur, CurrentState.CurrentTimingMethod, CurrentState.CurrentHotkeyProfile);
        }

        public bool OpenRunFromFile(string filePath, bool suppressPrompts = false)
        {
            try
            {
                Model.Reset(true);
                var run = LoadRunFromFile(filePath);
                SetRun(run);
                CurrentState.CallRunManuallyModified();
                return true;
            }
            catch (Exception e)
            {
                EngineLog.Error("opening " + filePath, e);
                return false;
            }
        }

        public bool SaveSplits(bool promptPBMessage, bool suppressPrompts = false)
        {
            var run = CurrentState.Run;
            if (string.IsNullOrEmpty(run.FilePath)) return false;
            try
            {
                StoreAutoSplitterSettings();
                using (var memory = new MemoryStream())
                {
                    new XMLRunSaver().Save(run, memory);
                    File.WriteAllBytes(run.FilePath, memory.ToArray());
                }
                run.HasChanged = false;
                Settings.AddToRecentSplits(run.FilePath, run, CurrentState.CurrentTimingMethod, CurrentState.CurrentHotkeyProfile);
                SaveSettingsToDisk();
                return true;
            }
            catch (Exception e)
            {
                EngineLog.Error("saving " + run.FilePath, e);
                return false;
            }
        }

        /// <summary>The autosplitter's options are saved inside the .lss, like LiveSplit does.</summary>
        private void StoreAutoSplitterSettings()
        {
            var run = CurrentState.Run;
            if (!run.IsAutoSplitterActive()) return;
            try
            {
                var doc = new XmlDocument();
                var element = run.AutoSplitter.Component.GetSettings(doc) as XmlElement;
                if (element == null) return;
                element.SetAttribute("gameName", run.GameName);
                run.AutoSplitterSettings = element;
            }
            catch (Exception e) { EngineLog.Error("reading autosplitter settings", e); }
        }

        public void CloseSplits()
        {
            AddCurrentToRecent();
            Model.Reset(true);
            SetRun(NewEmptyRun());
        }

        /// <summary>Same steps as TimerForm.SetRun: swap the run, comparisons, autosplitter.</summary>
        public void SetRun(IRun run)
        {
            run.FixSplits();
            var old = CurrentState.Run;
            if (old != null && old.IsAutoSplitterActive()) old.AutoSplitter.Deactivate();
            CurrentState.Run = run;
            SwitchComparisonGenerators();
            CreateAutoSplitter();
        }

        private void CreateAutoSplitter()
        {
            var run = CurrentState.Run;
            AutoSplitter splitter = null;
            try { splitter = AutoSplitterFactory.Instance?.Create(run.GameName ?? ""); }
            catch (Exception e) { EngineLog.Error("autosplitter list", e); }
            run.AutoSplitter = splitter;
            if (splitter != null && Settings.ActiveAutoSplitters.Contains(run.GameName))
            {
                try
                {
                    splitter.Activate(CurrentState);   // downloads the script if needed
                    EngineLog.Info("autosplitter on for " + run.GameName);
                }
                catch (Exception e) { EngineLog.Error("starting the autosplitter for " + run.GameName, e); }
            }
        }

        // ------------------------------------------------------------------ comparisons

        public void SwitchComparisonGenerators()
        {
            var run = CurrentState.Run;
            foreach (var generator in new StandardComparisonGeneratorsFactory().GetAllGenerators(run))
            {
                var existing = run.ComparisonGenerators.FirstOrDefault(x => x.Name == generator.Name);
                if (existing != null) run.ComparisonGenerators.Remove(existing);
                if (Settings.ComparisonGeneratorStates.TryGetValue(generator.Name, out bool on) && on)
                    run.ComparisonGenerators.Add(generator);
            }
            SwitchComparison(CurrentState.CurrentComparison);
            RegenerateComparisons();
        }

        public void RegenerateComparisons()
        {
            var run = CurrentState?.Run;
            if (run == null) return;
            foreach (var generator in run.ComparisonGenerators)
                generator.Generate(CurrentState.Settings);
        }

        public void SwitchComparison(string name)
        {
            if (string.IsNullOrEmpty(name) || !CurrentState.Run.Comparisons.Contains(name))
                name = Run.PersonalBestComparisonName;
            CurrentState.CurrentComparison = name;
        }

        // ------------------------------------------------------------------ global hotkeys

        private HotkeyProfile Profile =>
            Settings.HotkeyProfiles.TryGetValue(CurrentState.CurrentHotkeyProfile ?? "", out var p) ? p
            : Settings.HotkeyProfiles.Values.FirstOrDefault();

        private void RegisterHotkeys()
        {
            try
            {
                Settings.UnregisterAllHotkeys(Hook);
                var p = Profile;
                if (p != null) Hook.AllowGamepads = p.AllowGamepadsAsHotkeys;
                Settings.RegisterHotkeys(Hook, CurrentState.CurrentHotkeyProfile);
            }
            catch (Exception e) { EngineLog.Error("registering hotkeys", e); }
        }

        // The hook can call from its own thread: do the work on ours.
        private void OnHotkey(object sender, KeyOrButton key)
        {
            if (IsDisposed) return;
            try { BeginInvoke(new Action(() => HandleHotkey(key))); } catch (InvalidOperationException) { }
        }

        /// <summary>
        /// TimerForm's hotkey handler. Hotkeys only fire with global hotkeys on (this window
        /// never has focus; with them off, Mu Split's window forwards keys over the bridge).
        /// </summary>
        private void HandleHotkey(KeyOrButton key)
        {
            var p = Profile;
            if (p == null) return;

            if (Equals(key, p.ToggleGlobalHotkeys))
            {
                p.GlobalHotkeysEnabled = !p.GlobalHotkeysEnabled;
                return;
            }
            if (!p.GlobalHotkeysEnabled) return;

            if (Equals(key, p.SplitKey)) Delayed(p, StartOrSplit);
            else if (Equals(key, p.UndoKey)) Model.UndoSplit();
            else if (Equals(key, p.SkipKey)) Model.SkipSplit();
            else if (Equals(key, p.ResetKey)) Model.Reset(true);   // keeps golds/history: LiveSplit's "Yes"
            else if (Equals(key, p.PauseKey)) Delayed(p, () => Model.Pause());
            else if (Equals(key, p.SwitchComparisonPrevious)) Model.SwitchComparisonPrevious();
            else if (Equals(key, p.SwitchComparisonNext)) Model.SwitchComparisonNext();
        }

        private void StartOrSplit()
        {
            switch (CurrentState.CurrentPhase)
            {
                case TimerPhase.NotRunning: Model.Start(); break;
                case TimerPhase.Paused: Model.Pause(); break;      // resume, like LiveSplit
                default: Model.Split(); break;
            }
        }

        /// <summary>The profile's hotkey delay (split and pause only, like LiveSplit).</summary>
        private void Delayed(HotkeyProfile p, Action action)
        {
            float delay = p.HotkeyDelay;
            if (delay <= 0) { action(); return; }
            var t = new Timer { Interval = Math.Max(1, (int)(delay * 1000)) };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); action(); };
            t.Start();
        }

        // ------------------------------------------------------------------ shutdown

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            refresh.Stop();
            try
            {
                Settings.LastComparison = CurrentState.CurrentComparison;
                AddCurrentToRecent();
                SaveSettingsToDisk();
                var run = CurrentState.Run;
                if (run != null && run.IsAutoSplitterActive()) run.AutoSplitter.Deactivate();
                Settings.UnregisterAllHotkeys(Hook);
            }
            catch (Exception ex) { EngineLog.Error("shutting down", ex); }
            base.OnFormClosing(e);
        }

        // ------------------------------------------------------------------ components

        /// <summary>
        /// LiveSplit's window fills ComponentManager's factory lists (race providers,
        /// comparison generators, components...) at startup, and other code assumes they're
        /// there: the default settings read RaceProviderFactories, for one. Load each list
        /// from Components\ (or make it empty if it won't load) so nothing finds a null.
        /// </summary>
        private static void LoadComponentFactories()
        {
            const BindingFlags stat = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
            var cm = typeof(ComponentManager);
            var loader = cm.GetMethods(stat).FirstOrDefault(m => m.Name == "LoadAllFactories" && m.IsGenericMethodDefinition);

            foreach (var prop in cm.GetProperties(stat))
            {
                var type = prop.PropertyType;
                if (!prop.Name.EndsWith("Factories") || !type.IsGenericType || prop.GetSetMethod(true) == null) continue;
                var args = type.GetGenericArguments();
                if (args.Length != 2 || args[0] != typeof(string)) continue;
                if (prop.GetValue(null, null) != null) continue;

                object value = null;
                try { value = loader?.MakeGenericMethod(args[1]).Invoke(null, null); }
                catch (Exception e) { EngineLog.Error("loading " + prop.Name, e.InnerException ?? e); }
                if (value == null || !type.IsInstanceOfType(value))
                    value = Activator.CreateInstance(typeof(Dictionary<,>).MakeGenericType(args));
                try
                {
                    prop.SetValue(null, value, null);
                    EngineLog.Info(prop.Name + ": " + ((System.Collections.ICollection)value).Count);
                }
                catch (Exception e) { EngineLog.Error("setting " + prop.Name, e); }
            }
        }

        // ------------------------------------------------------------------ helpers

        private static object Read(object o, string name)
        {
            if (o == null) return null;
            const BindingFlags any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            var t = o.GetType();
            return t.GetProperty(name, any)?.GetValue(o, null) ?? t.GetField(name, any)?.GetValue(o);
        }
    }
}
