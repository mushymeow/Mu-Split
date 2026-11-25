using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;
using System.Xml;
using LiveSplit.Model;
using LiveSplit.UI;
using LiveSplit.UI.Components;

namespace LiveSplit.MuSplit
{
    /// <summary>
    /// Activate/deactivate autosplitters and edit ASL settings without LiveSplit's windows.
    /// ASL settings are changed through the component's own Get/SetSettings XML (the same
    /// thing LiveSplit saves into the .lss), so nothing about how scripts run changes.
    /// Non-ASL autosplitters (custom DLLs) get their own settings window opened instead.
    /// </summary>
    internal sealed class AutoSplitterFeature
    {
        private const BindingFlags Any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        private readonly LiveSplitState state;
        private readonly LiveSplitAccess ls;

        public AutoSplitterFeature(LiveSplitState state, LiveSplitAccess ls)
        {
            this.state = state;
            this.ls = ls;
        }

        private IComponent LiveComponent =>
            state.Run.IsAutoSplitterActive() ? state.Run.AutoSplitter.Component : null;

        private bool IsAsl(IComponent c) => c != null && c.GetType().Name == "ASLComponent";

        // ------------------------------------------------------------------ status

        /// <summary>The engine sets this when a script reports an error (time, text).</summary>
        public static DateTime LastErrorTime = DateTime.MinValue;
        public static string LastError;

        /// <summary>
        /// For the status bar: off | loading | waiting | connected | running | error,
        /// plus the game process it's attached to.
        /// </summary>
        public void WriteStatus(Json j)
        {
            string status = "off", game = null;
            var comp = LiveComponent;
            if (comp != null)
            {
                if (!IsAsl(comp)) status = "running";
                else
                {
                    object script = null;
                    try { script = Prop(comp, "Script"); } catch { }
                    if (script == null) status = "loading";
                    else
                    {
                        System.Diagnostics.Process proc = null;
                        try { proc = Field(script, "_game") as System.Diagnostics.Process; } catch { }
                        bool alive = false;
                        try { alive = proc != null && !proc.HasExited; } catch { }
                        if (alive)
                        {
                            status = "connected";
                            try { game = proc.ProcessName; } catch { }
                        }
                        else status = "waiting";
                    }
                }
                if ((DateTime.Now - LastErrorTime).TotalSeconds < 8 && status != "connected") status = "error";
            }
            j.Prop("autosplitterStatus", status).Prop("autosplitterGame", game)
             .Prop("autosplitterError", (DateTime.Now - LastErrorTime).TotalSeconds < 8 ? LastError : null);
        }

        // ------------------------------------------------------------------ info

        public void WriteInfo(Json j, string gameName)
        {
            AutoSplitter splitter = null;
            try { splitter = AutoSplitterFactory.Instance?.Create(gameName ?? ""); } catch { }

            bool sameGame = state.Run.GameName == gameName;
            var comp = sameGame ? LiveComponent : null;

            j.BeginObject()
                .Prop("available", splitter != null)
                .Prop("description", splitter?.Description)
                .Prop("website", splitter?.Website)
                .Prop("type", splitter?.Type.ToString())
                .Prop("enabled", state.Settings.ActiveAutoSplitters.Contains(gameName ?? ""))
                .Prop("running", comp != null)
                .Prop("asl", IsAsl(comp))
                .Prop("hasSettings", comp != null && SafeHasSettings(comp))
                .Prop("pending", !sameGame)    // game name edited but not applied yet
             .EndObject();
        }

        private static bool SafeHasSettings(IComponent c)
        {
            try { return c.GetSettingsControl(LayoutMode.Vertical) != null; } catch { return false; }
        }

        // ------------------------------------------------------------------ activate

        public string Toggle(string gameName)
        {
            gameName = gameName ?? "";
            var active = state.Settings.ActiveAutoSplitters;
            bool sameGame = state.Run.GameName == gameName;

            if (active.Contains(gameName))
            {
                active.Remove(gameName);
                if (sameGame && state.Run.IsAutoSplitterActive()) state.Run.AutoSplitter.Deactivate();
                return null;
            }

            var probe = AutoSplitterFactory.Instance?.Create(gameName);
            if (probe == null) return "No autosplitter available for this game";
            active.Add(gameName);

            if (sameGame)
            {
                if (state.Run.AutoSplitter == null) state.Run.AutoSplitter = probe;
                state.Run.AutoSplitter.Activate(state);   // downloads the script/DLL if needed
                if (!state.Run.AutoSplitter.IsActivated) return "The autosplitter could not be activated";
                var saved = state.Run.AutoSplitterSettings;
                if (saved != null && saved.GetAttribute("gameName") == gameName)
                    state.Run.AutoSplitter.Component.SetSettings(saved);
            }
            return null;
        }

        /// <summary>Turn on (never off): safe to call when it may already be running.</summary>
        public string Enable(string gameName)
        {
            gameName = gameName ?? "";
            bool sameGame = state.Run.GameName == gameName;
            if (!state.Settings.ActiveAutoSplitters.Contains(gameName)) return Toggle(gameName);
            if (sameGame && !state.Run.IsAutoSplitterActive())
            {
                if (state.Run.AutoSplitter == null) state.Run.AutoSplitter = AutoSplitterFactory.Instance?.Create(gameName);
                if (state.Run.AutoSplitter == null) return "No autosplitter available for this game";
                state.Run.AutoSplitter.Activate(state);
                if (!state.Run.AutoSplitter.IsActivated) return "The autosplitter could not be activated";
                var saved = state.Run.AutoSplitterSettings;
                if (saved != null && saved.GetAttribute("gameName") == gameName)
                    state.Run.AutoSplitter.Component.SetSettings(saved);
            }
            return null;
        }

        // ------------------------------------------------------------------ ASL settings

        public string Snapshot(string error)
        {
            var comp = LiveComponent;
            var j = new Json().BeginObject().Prop("type", "asl").Prop("error", error);

            if (!IsAsl(comp))
            {
                j.Prop("available", false)
                 .Prop("native", comp != null && SafeHasSettings(comp));
                return j.EndObject().ToString();
            }

            object script = Prop(comp, "Script");
            object aslSettings = script == null ? null : Field(script, "_settings");

            // Current values as LiveSplit would save them
            var doc = new XmlDocument();
            var xml = comp.GetSettings(doc) as XmlElement;
            var savedCustom = new Dictionary<string, bool>();
            var custom = xml?["CustomSettings"];
            if (custom != null)
                foreach (XmlNode n in custom.ChildNodes)
                    if (n is XmlElement e && e.Name == "Setting" && bool.TryParse(e.InnerText, out bool b))
                        savedCustom[e.GetAttribute("id")] = b;

            j.Prop("available", true)
             .Prop("loaded", aslSettings != null)
             .Prop("scriptPath", xml?["ScriptPath"]?.InnerText);

            // Start / Split / Reset checkboxes (only the ones the script implements)
            j.Key("basic").BeginArray();
            var basicPresent = aslSettings == null ? null : Prop(aslSettings, "BasicSettings") as IDictionary;
            foreach (var key in new[] { "Start", "Split", "Reset" })
            {
                bool present = basicPresent != null && basicPresent.Contains(key.ToLower());
                bool value = xml?[key] != null ? bool.Parse(xml[key].InnerText) : true;
                j.BeginObject().Prop("id", key).Prop("present", present).Prop("value", value).EndObject();
            }
            j.EndArray();

            // The script's custom settings tree, in declaration order
            j.Key("custom").BeginArray();
            if (aslSettings != null && Prop(aslSettings, "OrderedSettings") is IEnumerable ordered)
            {
                foreach (var s in ordered)
                {
                    string id = (string)Prop(s, "Id");
                    bool def = (bool)Prop(s, "DefaultValue");
                    bool val = savedCustom.TryGetValue(id, out bool v) ? v : (bool)Prop(s, "Value");
                    j.BeginObject()
                        .Prop("id", id)
                        .Prop("label", (string)Prop(s, "Label") ?? id)
                        .Prop("parent", (string)Prop(s, "Parent"))
                        .Prop("tooltip", (string)Prop(s, "ToolTip"))
                        .Prop("default", def)
                        .Prop("value", val)
                     .EndObject();
                }
            }
            j.EndArray();

            return j.EndObject().ToString();
        }

        /// <summary>op: {id, value, basic?} or {reset: true}</summary>
        public string Set(Dictionary<string, object> op)
        {
            var comp = LiveComponent;
            if (!IsAsl(comp)) return "No ASL autosplitter is running";

            var doc = new XmlDocument();
            var xml = (XmlElement)comp.GetSettings(doc);
            doc.AppendChild(xml);

            object script = Prop(comp, "Script");
            object aslSettings = script == null ? null : Field(script, "_settings");

            if (EditorSession.Bool(op, "reset"))
            {
                // back to the script's defaults
                xml["CustomSettings"]?.RemoveAll();
                if (aslSettings != null && Prop(aslSettings, "OrderedSettings") is IEnumerable ordered)
                    foreach (var s in ordered)
                        SetCustom(doc, xml, (string)Prop(s, "Id"), (bool)Prop(s, "DefaultValue"));
                foreach (var key in new[] { "Start", "Split", "Reset" }) SetBasic(doc, xml, key, true);
            }
            else
            {
                string id = EditorSession.Str(op, "id");
                bool value = EditorSession.Bool(op, "value");
                if (EditorSession.Bool(op, "basic")) SetBasic(doc, xml, id, value);
                else SetCustom(doc, xml, id, value);
            }

            comp.SetSettings(xml);

            // The settings TreeView may never have been created (we never show it),
            // so push values straight into the script's settings objects as well.
            if (aslSettings != null)
            {
                if (Prop(aslSettings, "Settings") is IDictionary all)
                    foreach (XmlElement e in xml["CustomSettings"]?.ChildNodes.OfType<XmlElement>() ?? Enumerable.Empty<XmlElement>())
                    {
                        string id = e.GetAttribute("id");
                        if (all.Contains(id) && bool.TryParse(e.InnerText, out bool b)) SetProp(all[id], "Value", b);
                    }
                if (Prop(aslSettings, "BasicSettings") is IDictionary basic)
                    foreach (var key in new[] { "Start", "Split", "Reset" })
                        if (basic.Contains(key.ToLower()) && xml[key] != null) SetProp(basic[key.ToLower()], "Value", bool.Parse(xml[key].InnerText));
            }

            SaveIntoRun(comp);
            return null;
        }

        private static void SetBasic(XmlDocument doc, XmlElement xml, string key, bool value)
        {
            var e = xml[key];
            if (e == null) { e = doc.CreateElement(key); xml.AppendChild(e); }
            e.InnerText = value ? "True" : "False";
        }

        private static void SetCustom(XmlDocument doc, XmlElement xml, string id, bool value)
        {
            var parent = xml["CustomSettings"];
            if (parent == null) { parent = doc.CreateElement("CustomSettings"); xml.AppendChild(parent); }
            var e = parent.ChildNodes.OfType<XmlElement>().FirstOrDefault(x => x.Name == "Setting" && x.GetAttribute("id") == id);
            if (e == null)
            {
                e = doc.CreateElement("Setting");
                e.SetAttribute("id", id);
                e.SetAttribute("type", "bool");
                parent.AppendChild(e);
            }
            e.InnerText = value ? "True" : "False";
        }

        /// <summary>Same as LiveSplit's run editor after its settings dialog closes with OK.</summary>
        private void SaveIntoRun(IComponent comp)
        {
            var document = new XmlDocument();
            var element = document.CreateElement("AutoSplitterSettings");
            element.InnerXml = comp.GetSettings(document).InnerXml;
            element.SetAttribute("gameName", state.Run.GameName);
            state.Run.AutoSplitterSettings = element;
            state.Run.HasChanged = true;
        }

        // ------------------------------------------------------------------ native window (DLL autosplitters)

        public string OpenNativeSettings()
        {
            var comp = LiveComponent;
            if (comp == null) return "No autosplitter is running";

            var dlgType = ls.Form.GetType().Assembly.GetType("LiveSplit.View.ComponentSettingsDialog");
            if (dlgType == null)
            {
                // standalone engine: the dialog lives in LiveSplit.View.dll next to us
                try { dlgType = Assembly.Load("LiveSplit.View").GetType("LiveSplit.View.ComponentSettingsDialog"); } catch { }
            }
            if (dlgType == null) return "This LiveSplit version has no component settings dialog";

            using (var dialog = (Form)Activator.CreateInstance(dlgType, comp))
            {
                dialog.StartPosition = FormStartPosition.CenterScreen;
                dialog.TopMost = true;
                dialog.Shown += (s, e) => { dialog.Activate(); dialog.BringToFront(); };
                if (dialog.ShowDialog() == DialogResult.OK) SaveIntoRun(comp);
            }
            return null;
        }

        // ------------------------------------------------------------------ reflection helpers

        private static object Prop(object o, string name) => o?.GetType().GetProperty(name, Any)?.GetValue(o, null);
        private static object Field(object o, string name) => o?.GetType().GetField(name, Any)?.GetValue(o);
        private static void SetProp(object o, string name, object v) => o?.GetType().GetProperty(name, Any)?.SetValue(o, v, null);
    }
}
