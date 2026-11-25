using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using LiveSplit.Model;
using LiveSplit.Model.Comparisons;
using LiveSplit.Model.Input;
using LiveSplit.Options;
using LiveSplit.Options.SettingsSavers;

namespace LiveSplit.MuSplit
{
    /// <summary>
    /// LiveSplit's Settings window: hotkey profiles, global hotkeys, reset warning,
    /// sum of best, refresh rate, comparison generators. Applied the same way
    /// LiveSplit applies its own dialog, then written to settings.cfg right away.
    /// </summary>
    internal sealed class SettingsFeature
    {
        private static readonly string[] HotkeyNames =
            { "split", "reset", "skip", "undo", "pause", "toggleGlobal", "comparePrev", "compareNext" };

        private readonly LiveSplitState state;
        private readonly LiveSplitAccess ls;

        public SettingsFeature(LiveSplitState state, LiveSplitAccess ls)
        {
            this.state = state;
            this.ls = ls;
        }

        private static KeyOrButton GetKey(HotkeyProfile p, string n)
        {
            switch (n)
            {
                case "split": return p.SplitKey;
                case "reset": return p.ResetKey;
                case "skip": return p.SkipKey;
                case "undo": return p.UndoKey;
                case "pause": return p.PauseKey;
                case "toggleGlobal": return p.ToggleGlobalHotkeys;
                case "comparePrev": return p.SwitchComparisonPrevious;
                case "compareNext": return p.SwitchComparisonNext;
            }
            return null;
        }

        private static void SetKey(HotkeyProfile p, string n, KeyOrButton k)
        {
            switch (n)
            {
                case "split": p.SplitKey = k; break;
                case "reset": p.ResetKey = k; break;
                case "skip": p.SkipKey = k; break;
                case "undo": p.UndoKey = k; break;
                case "pause": p.PauseKey = k; break;
                case "toggleGlobal": p.ToggleGlobalHotkeys = k; break;
                case "comparePrev": p.SwitchComparisonPrevious = k; break;
                case "compareNext": p.SwitchComparisonNext = k; break;
            }
        }

        public string Snapshot(string error)
        {
            var s = ls.Settings;
            var j = new Json().BeginObject()
                .Prop("type", "settings")
                .Prop("error", error)
                .Prop("profile", state.CurrentHotkeyProfile)
                .Prop("warnOnReset", s.WarnOnReset)
                .Prop("simpleSumOfBest", s.SimpleSumOfBest)
                .Prop("refreshRate", s.RefreshRate)
                .Prop("serverPort", s.ServerPort)
                .Prop("hcpHistorySize", s.HcpHistorySize)
                .Prop("hcpNBestRuns", s.HcpNBestRuns);

            j.Key("profileOrder").BeginArray();
            foreach (var name in s.HotkeyProfiles.Keys) j.Val(name);
            j.EndArray();

            j.Key("profiles").BeginObject();
            foreach (var kv in s.HotkeyProfiles)
            {
                var p = kv.Value;
                j.Key(kv.Key).BeginObject();
                foreach (var n in HotkeyNames) j.Prop(n, GetKey(p, n)?.ToString());
                j.Key("delay").Val((double)p.HotkeyDelay)
                 .Prop("global", p.GlobalHotkeysEnabled)
                 .Prop("doubleTap", p.DoubleTapPrevention)
                 .Prop("deactivateOthers", p.DeactivateHotkeysForOtherPrograms)
                 .Prop("gamepads", p.AllowGamepadsAsHotkeys);
                j.EndObject();
            }
            j.EndObject();

            j.Key("generators").BeginArray();
            foreach (var g in new StandardComparisonGeneratorsFactory().GetAllGenerators(state.Run))
            {
                bool on = s.ComparisonGeneratorStates.TryGetValue(g.Name, out bool v) && v;
                j.BeginObject().Prop("name", g.Name).Prop("enabled", on).EndObject();
            }
            j.EndArray();

            return j.EndObject().ToString();
        }

        public string Apply(Dictionary<string, object> d)
        {
            var s = ls.Settings;
            var hook = ls.Hook;

            // Validate every hotkey first so a typo can't leave hotkeys half-registered.
            var profilesIn = d.TryGetValue("profiles", out var po) ? po as Dictionary<string, object> : null;
            var orderIn = d.TryGetValue("profileOrder", out var oo) && oo is IEnumerable oe && !(oo is string)
                ? oe.Cast<object>().Select(x => x.ToString()).ToList() : null;
            if (profilesIn == null || orderIn == null || orderIn.Count == 0) return "No hotkey profiles given";

            var parsed = new Dictionary<string, HotkeyProfile>();
            foreach (var name in orderIn)
            {
                if (!(profilesIn.TryGetValue(name, out var pv) && pv is Dictionary<string, object> p)) continue;
                string from = EditorSession.Str(p, "from") ?? name;
                var hp = s.HotkeyProfiles.TryGetValue(from, out var existing) ? (HotkeyProfile)existing.Clone() : new HotkeyProfile();

                foreach (var n in HotkeyNames)
                {
                    string text = EditorSession.Str(p, n);
                    if (string.IsNullOrWhiteSpace(text)) { SetKey(hp, n, null); continue; }
                    try { SetKey(hp, n, new KeyOrButton(text)); }
                    catch { return $"Couldn't read hotkey \"{text}\""; }
                }
                if (p.ContainsKey("delay")) hp.HotkeyDelay = Math.Max(0f, Convert.ToSingle(p["delay"], CultureInfo.InvariantCulture));
                hp.GlobalHotkeysEnabled = EditorSession.Bool(p, "global");
                hp.DoubleTapPrevention = EditorSession.Bool(p, "doubleTap");
                hp.DeactivateHotkeysForOtherPrograms = hp.GlobalHotkeysEnabled && EditorSession.Bool(p, "deactivateOthers");
                hp.AllowGamepadsAsHotkeys = EditorSession.Bool(p, "gamepads");
                parsed[name] = hp;

                // keep "last used profile" of recent splits pointing at renamed profiles
                if (from != name)
                    for (int i = 0; i < s.RecentSplits.Count; i++)
                    {
                        var f = s.RecentSplits[i];
                        if (f.LastHotkeyProfile == from) { f.LastHotkeyProfile = name; s.RecentSplits[i] = f; }
                    }
            }
            if (parsed.Count == 0) return "No hotkey profiles given";

            if (hook != null) s.UnregisterAllHotkeys(hook);
            suspended = false;
            try
            {
                s.HotkeyProfiles.Clear();
                foreach (var kv in parsed) s.HotkeyProfiles[kv.Key] = kv.Value;

                bool sobBefore = s.SimpleSumOfBest;
                if (d.ContainsKey("warnOnReset")) s.WarnOnReset = EditorSession.Bool(d, "warnOnReset");
                if (d.ContainsKey("simpleSumOfBest")) s.SimpleSumOfBest = EditorSession.Bool(d, "simpleSumOfBest");
                if (d.ContainsKey("refreshRate")) s.RefreshRate = Math.Min(Math.Max(EditorSession.Int(d, "refreshRate"), 20), 300);
                if (d.ContainsKey("serverPort")) s.ServerPort = EditorSession.Int(d, "serverPort");
                if (d.ContainsKey("hcpHistorySize")) s.HcpHistorySize = Math.Max(1, EditorSession.Int(d, "hcpHistorySize"));
                if (d.ContainsKey("hcpNBestRuns")) s.HcpNBestRuns = Math.Max(1, EditorSession.Int(d, "hcpNBestRuns"));

                if (d.TryGetValue("generators", out var gv) && gv is IEnumerable ge && !(gv is string))
                    foreach (var g in ge.OfType<Dictionary<string, object>>())
                        s.ComparisonGeneratorStates[EditorSession.Str(g, "name")] = EditorSession.Bool(g, "enabled");

                ls.Call("SwitchComparisonGenerators");
                if (sobBefore != s.SimpleSumOfBest) ls.Call("RegenerateComparisons");

                string profile = EditorSession.Str(d, "profile");
                state.CurrentHotkeyProfile = profile != null && parsed.ContainsKey(profile) ? profile : parsed.Keys.First();
            }
            finally
            {
                if (hook != null) s.RegisterHotkeys(hook, state.CurrentHotkeyProfile);
            }

            try { ls.Call("SetProgressBar"); } catch { }
            SaveToDisk();
            return null;
        }

        /// <summary>Write settings.cfg now (LiveSplit otherwise only saves it when it closes).</summary>
        private void SaveToDisk()
        {
            try
            {
                if (ls.Has("SaveSettingsToDisk")) { ls.Call("SaveSettingsToDisk"); return; }

                // LiveSplit 1.8.x: do what SaveSettingsToDisk does in newer versions
                string basePath = ls.Get<string>("BasePath") ?? "";
                string path = Path.Combine(basePath, "settings.cfg");
                var saver = ls.Get<ISettingsSaver>("SettingsSaver") ?? new XMLSettingsSaver();
                using (var memory = new MemoryStream())
                {
                    saver.Save(ls.Settings, memory);
                    using (var file = File.Open(path, FileMode.Create, FileAccess.Write))
                        file.Write(memory.GetBuffer(), 0, (int)memory.Length);
                }
            }
            catch { /* LiveSplit still saves its settings when it closes */ }
        }

        private bool suspended;

        public void SuspendHotkeys()
        {
            var hook = ls.Hook;
            if (hook == null || suspended) return;
            ls.Settings.UnregisterAllHotkeys(hook);
            suspended = true;
        }

        public void ResumeHotkeys()
        {
            var hook = ls.Hook;
            if (hook == null || !suspended) return;
            ls.Settings.RegisterHotkeys(hook, state.CurrentHotkeyProfile);
            suspended = false;
        }

        public void ToggleGlobalHotkeys()
        {
            var s = ls.Settings;
            if (!s.HotkeyProfiles.TryGetValue(state.CurrentHotkeyProfile, out var p)) return;
            p.GlobalHotkeysEnabled = !p.GlobalHotkeysEnabled;
            try { ls.Call("SetProgressBar"); } catch { }
        }

        public void SwitchProfile(string name)
        {
            var s = ls.Settings;
            if (!s.HotkeyProfiles.ContainsKey(name)) return;
            var hook = ls.Hook;
            if (hook != null) s.UnregisterAllHotkeys(hook);
            state.CurrentHotkeyProfile = name;
            if (hook != null) s.RegisterHotkeys(hook, name);
        }
    }
}
