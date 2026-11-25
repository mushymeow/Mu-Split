using System;
using System.Collections.Generic;
using System.Linq;
using LiveSplit.Model;
using LiveSplit.Model.Comparisons;
using LiveSplit.UI;

namespace LiveSplit.MuSplit
{
    /// <summary>
    /// The Splits Editor, without the WinForms window. Works on a copy of the run;
    /// "ok" swaps it in through LiveSplit's own SetRun, "cancel" throws it away.
    /// The time-editing rules are ported from LiveSplit's RunEditorDialog so the
    /// results are identical (segment/split fixing, deleting merges history, etc.).
    /// </summary>
    internal sealed class EditorSession
    {
        private readonly LiveSplitState state;
        private readonly LiveSplitAccess ls;
        private readonly IRun run;                       // the working copy
        private readonly List<string> activeAutoSplittersBefore;
        private TimingMethod method;
        private TimeSpan? previousPbTime;

        public bool AllowChangingSegments => state.CurrentPhase == TimerPhase.NotRunning;

        public EditorSession(LiveSplitState state, LiveSplitAccess ls)
        {
            this.state = state;
            this.ls = ls;
            run = (IRun)state.Run.Clone();
            activeAutoSplittersBefore = state.Settings.ActiveAutoSplitters.ToList();
            method = state.CurrentTimingMethod;
            previousPbTime = run.Count > 0 ? run[run.Count - 1].PersonalBestSplitTime[method] : null;
        }

        // ------------------------------------------------------------------ ops

        /// <summary>Apply one edit. Returns an error message, or null on success.</summary>
        public string Apply(Dictionary<string, object> op)
        {
            string name = Str(op, "op");
            switch (name)
            {
                case "set":
                {
                    string field = Str(op, "field"), value = Str(op, "value") ?? "";
                    switch (field)
                    {
                        case "game": run.GameName = value; break;
                        case "category": run.CategoryName = value; break;
                        case "attempts":
                            if (!int.TryParse(value, out int a) || a < 0) return "Attempts must be a whole number";
                            run.AttemptCount = a; break;
                        case "offset":
                            try { run.Offset = string.IsNullOrWhiteSpace(value) ? TimeSpan.Zero : TimeSpanParser.Parse(value); }
                            catch { return "Invalid time"; }
                            break;
                        default: return "unknown field " + field;
                    }
                    break;
                }

                case "name":
                    run[Int(op, "i")].Name = Str(op, "value") ?? "";
                    break;

                case "time":
                    return EditTime(Int(op, "i"), Str(op, "col"), Str(op, "value"));

                case "method":
                    method = Str(op, "value") == "game" ? TimingMethod.GameTime : TimingMethod.RealTime;
                    return null; // view change only

                case "insert":
                {
                    if (!AllowChangingSegments) return "Can't add splits during a run";
                    int i = Int(op, "i");
                    bool below = Str(op, "where") == "below";
                    int at = below ? i + 1 : i;
                    if (below) { if (i + 1 < run.Count) run.ImportBestSegment(i + 1); }
                    else run.ImportBestSegment(i);

                    var seg = new Segment(Str(op, "name") ?? "");
                    int maxIndex = run.AttemptHistory.Select(x => x.Index).DefaultIfEmpty(0).Max();
                    for (int x = run.GetMinSegmentHistoryIndex(); x <= maxIndex; x++)
                        seg.SegmentHistory.Add(x, default);
                    run.Insert(Math.Max(0, Math.Min(at, run.Count)), seg);
                    run.FixSplits();
                    break;
                }

                case "remove":
                {
                    if (!AllowChangingSegments) return "Can't remove splits during a run";
                    var indices = IntList(op, "indices").Distinct().OrderByDescending(x => x).ToList();
                    foreach (int i in indices)
                    {
                        if (run.Count <= 1 || i < 0 || i >= run.Count) continue;
                        FixAfterDeletion(i);
                        run.RemoveAt(i);
                    }
                    run.FixSplits();
                    break;
                }

                case "move":
                {
                    if (!AllowChangingSegments) return "Can't move splits during a run";
                    int i = Int(op, "i"), dir = Int(op, "dir");
                    int first = dir < 0 ? i - 1 : i;           // swap first and first+1
                    if (first < 0 || first + 1 >= run.Count) return null;
                    SwitchSegments(first);
                    run.FixSplits();
                    break;
                }

                case "comp_add":
                {
                    string n = (Str(op, "name") ?? "").Trim();
                    if (n.Length == 0) return "Name can't be empty";
                    if (run.Comparisons.Contains(n)) return "A comparison with this name already exists";
                    if (n.StartsWith("[Race]")) return "A comparison name can't start with [Race]";
                    run.CustomComparisons.Add(n);
                    break;
                }

                case "comp_rename":
                {
                    string from = Str(op, "old"), to = (Str(op, "new") ?? "").Trim();
                    if (from == Run.PersonalBestComparisonName) return "Personal Best can't be renamed";
                    if (to.Length == 0) return "Name can't be empty";
                    if (to == from) return null;
                    if (run.Comparisons.Contains(to)) return "A comparison with this name already exists";
                    if (to.StartsWith("[Race]")) return "A comparison name can't start with [Race]";
                    int idx = run.CustomComparisons.IndexOf(from);
                    if (idx < 0) return "No such comparison";
                    run.CustomComparisons[idx] = to;
                    foreach (var seg in run)
                    {
                        if (seg.Comparisons.TryGetValue(from, out Time t)) { seg.Comparisons.Remove(from); seg.Comparisons[to] = t; }
                    }
                    renamed.Add((from, to));
                    break;
                }

                case "comp_remove":
                {
                    string n = Str(op, "name");
                    if (n == Run.PersonalBestComparisonName) return "Personal Best can't be removed";
                    run.CustomComparisons.Remove(n);
                    foreach (var seg in run) seg.Comparisons.Remove(n);
                    renamed.Add((n, "Current Comparison"));
                    break;
                }

                case "clear_history": run.ClearHistory(); break;
                case "clear_times": run.ClearTimes(); break;

                default: return "unknown editor op " + name;
            }
            run.HasChanged = true;
            return null;
        }

        private readonly List<(string from, string to)> renamed = new List<(string, string)>();

        private string EditTime(int i, string col, string value)
        {
            TimeSpan? t = null;
            if (!string.IsNullOrWhiteSpace(value))
            {
                try { t = TimeSpanParser.Parse(value); }
                catch { return "Invalid time"; }
            }

            var seg = run[i];
            if (col == "pbSplit")
            {
                var time = new Time(seg.PersonalBestSplitTime); time[method] = t; seg.PersonalBestSplitTime = time;
            }
            else if (col == "best")
            {
                var time = new Time(seg.BestSegmentTime); time[method] = t; seg.BestSegmentTime = time;
            }
            else if (col == "pbSegment")
            {
                var segTimes = SegmentTimes();
                segTimes[i] = t;
                // FixSplitsFromSegments
                TimeSpan prev = TimeSpan.Zero;
                for (int k = 0; k < run.Count; k++)
                {
                    var time = new Time(run[k].PersonalBestSplitTime);
                    time[method] = prev + segTimes[k];
                    run[k].PersonalBestSplitTime = time;
                    if (segTimes[k] != null) prev = run[k].PersonalBestSplitTime[method].Value;
                }
            }
            else if (col != null && col.StartsWith("comp:"))
            {
                string name = col.Substring(5);
                var time = new Time(seg.Comparisons[name]); time[method] = t; seg.Comparisons[name] = time;
            }
            else return "unknown column " + col;

            run.FixSplits();

            // TimesModified: a new PB time invalidates the speedrun.com run link
            var pb = run[run.Count - 1].PersonalBestSplitTime[method];
            if (pb != previousPbTime)
            {
                try { run.Metadata.RunID = null; } catch { }
                previousPbTime = pb;
            }
            run.HasChanged = true;
            return null;
        }

        private List<TimeSpan?> SegmentTimes()
        {
            var list = new List<TimeSpan?>();
            TimeSpan prev = TimeSpan.Zero;
            foreach (var seg in run)
            {
                var split = seg.PersonalBestSplitTime[method];
                list.Add(split - prev);
                if (split != null) prev = split.Value;
            }
            return list;
        }

        // Ported from RunEditorDialog.SwitchSegments
        private void SwitchSegments(int segIndex)
        {
            ISegment a = run[segIndex], b = run[segIndex + 1];
            int maxIndex = run.AttemptHistory.Select(x => x.Index).DefaultIfEmpty(0).Max();
            for (int r = run.GetMinSegmentHistoryIndex(); r <= maxIndex; r++)
            {
                bool aHas = a.SegmentHistory.TryGetValue(r, out Time ah);
                bool bHas = b.SegmentHistory.TryGetValue(r, out Time bh);
                if (aHas && bHas
                    && (ah[TimingMethod.RealTime].HasValue != bh[TimingMethod.RealTime].HasValue
                     || ah[TimingMethod.GameTime].HasValue != bh[TimingMethod.GameTime].HasValue))
                {
                    a.SegmentHistory.Remove(r);
                    b.SegmentHistory.Remove(r);
                }
            }

            foreach (string comparison in a.Comparisons.Keys.ToList())
            {
                Time previous = segIndex > 0 ? run[segIndex - 1].Comparisons[comparison] : new Time(TimeSpan.Zero, TimeSpan.Zero);
                Time aSeg = a.Comparisons[comparison] - previous;
                Time bSeg = b.Comparisons[comparison] - a.Comparisons[comparison];
                b.Comparisons[comparison] = new Time(previous + bSeg);
                a.Comparisons[comparison] = new Time(b.Comparisons[comparison] + aSeg);
            }

            run.RemoveAt(segIndex + 1);
            run.Insert(segIndex, b);
        }

        // Ported from RunEditorDialog.FixAfterDeletion
        private void FixAfterDeletion(int index)
        {
            FixWithTimingMethod(index, TimingMethod.RealTime);
            FixWithTimingMethod(index, TimingMethod.GameTime);
        }

        private void FixWithTimingMethod(int index, TimingMethod m)
        {
            int cur = index + 1;
            if (cur >= run.Count) return;

            int maxIndex = run.AttemptHistory.Select(x => x.Index).DefaultIfEmpty(0).Max();
            for (int r = run.GetMinSegmentHistoryIndex(); r <= maxIndex; r++)
            {
                cur = index + 1;
                if (!run[index].SegmentHistory.TryGetValue(r, out Time removed))
                {
                    if (run[cur].SegmentHistory.ContainsKey(r)) run[cur].SegmentHistory.Remove(r);
                    continue;
                }

                TimeSpan? curSegment = removed[m];
                while (curSegment != null && cur < run.Count)
                {
                    if (run[cur].SegmentHistory.TryGetValue(r, out Time s) && s[m] != null)
                    {
                        s[m] = curSegment + s[m];
                        run[cur].SegmentHistory[r] = s;
                        break;
                    }
                    cur++;
                }
            }

            cur = index + 1;
            TimeSpan? minBest = run[index].BestSegmentTime[m] + run[cur].BestSegmentTime[m];
            foreach (var h in run[cur].SegmentHistory)
                if (h.Value[m] < minBest) minBest = h.Value[m];

            Time newTime = run[cur].BestSegmentTime;
            newTime[m] = minBest;
            run[cur].BestSegmentTime = newTime;
        }

        // ------------------------------------------------------------------ finish

        public void Ok()
        {
            // Autosplitter settings are edited live (like LiveSplit does), keep them.
            run.AutoSplitterSettings = state.Run.AutoSplitterSettings;
            run.HasChanged = true;

            ls.Call("SetRun", ("run", run));
            foreach (var (from, to) in renamed)
            {
                if (state.CurrentComparison == from) state.CurrentComparison = to == "Current Comparison" ? Run.PersonalBestComparisonName : to;
                state.CallComparisonRenamed(new RenameEventArgs { OldName = from, NewName = to });
            }
            ls.Call("RegenerateComparisons");
            state.CallRunManuallyModified();
        }

        public void Cancel()
        {
            var now = state.Settings.ActiveAutoSplitters;
            bool changed = now.Count != activeAutoSplittersBefore.Count || now.Except(activeAutoSplittersBefore).Any();
            if (changed)
            {
                state.Settings.ActiveAutoSplitters = activeAutoSplittersBefore;
                ls.Call("SetRun", ("run", state.Run));   // re-creates the autosplitter like LiveSplit's cancel
            }
        }

        // ------------------------------------------------------------------ snapshot

        public string Snapshot(string error, AutoSplitterFeature asl)
        {
            var j = new Json().BeginObject()
                .Prop("type", "editor")
                .Prop("error", error)
                .Prop("game", run.GameName)
                .Prop("category", run.CategoryName)
                .Prop("attempts", run.AttemptCount)
                .Prop("offset", (TimeSpan?)run.Offset)
                .Prop("method", method == TimingMethod.GameTime ? "game" : "real")
                .Prop("canChangeSegments", AllowChangingSegments)
                .Prop("hasChanged", run.HasChanged);

            j.Key("comparisons").BeginArray();
            foreach (var c in run.CustomComparisons) j.Val(c);
            j.EndArray();

            var segTimes = SegmentTimes();
            j.Key("segments").BeginArray();
            for (int i = 0; i < run.Count; i++)
            {
                var seg = run[i];
                j.BeginObject()
                    .Prop("name", seg.Name)
                    .Prop("pbSplit", seg.PersonalBestSplitTime[method])
                    .Prop("pbSegment", segTimes[i])
                    .Prop("best", seg.BestSegmentTime[method]);
                j.Key("comps").BeginObject();
                foreach (var c in run.CustomComparisons)
                {
                    if (c == Run.PersonalBestComparisonName) continue;
                    TimeSpan? t = null;
                    try { t = seg.Comparisons[c][method]; } catch { }
                    j.Prop(c, t);
                }
                j.EndObject();
                j.EndObject();
            }
            j.EndArray();

            j.Key("autosplitter");
            asl.WriteInfo(j, run.GameName);

            return j.EndObject().ToString();
        }

        // ------------------------------------------------------------------ arg helpers

        internal static string Str(Dictionary<string, object> d, string k) =>
            d != null && d.TryGetValue(k, out var v) && v != null ? Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture) : null;

        internal static int Int(Dictionary<string, object> d, string k) =>
            d != null && d.TryGetValue(k, out var v) && v != null ? Convert.ToInt32(v, System.Globalization.CultureInfo.InvariantCulture) : 0;

        internal static bool Bool(Dictionary<string, object> d, string k) =>
            d != null && d.TryGetValue(k, out var v) && v is bool b && b;

        internal static List<int> IntList(Dictionary<string, object> d, string k)
        {
            var list = new List<int>();
            if (d != null && d.TryGetValue(k, out var v) && v is System.Collections.IEnumerable e && !(v is string))
                foreach (var x in e) list.Add(Convert.ToInt32(x, System.Globalization.CultureInfo.InvariantCulture));
            return list;
        }
    }
}
