using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;
using LiveSplit.Model.Input;
using LiveSplit.Options;

namespace LiveSplit.MuSplit
{
    /// <summary>
    /// Calls LiveSplit's own (private) TimerForm methods, so "Open Splits", "Save",
    /// "Close Splits" etc. behave exactly like clicking them in LiveSplit: same
    /// autosplitter activation, recent files list, layout switching and so on.
    ///
    /// Arguments are matched by parameter name, and anything not given gets its
    /// default, so small signature changes between LiveSplit versions don't break us.
    /// </summary>
    internal sealed class LiveSplitAccess
    {
        private const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        private readonly Form form;
        private readonly Type type;

        public LiveSplitAccess(Form timerForm)
        {
            form = timerForm;
            type = timerForm.GetType();
        }

        public Form Form => form;

        public bool Has(string method) => type.GetMethods(Flags).Any(m => m.Name == method);

        /// <summary>Invoke a TimerForm method. named: parameter name → value.</summary>
        public object Call(string method, params (string name, object value)[] named)
        {
            var candidates = type.GetMethods(Flags).Where(m => m.Name == method)
                .OrderByDescending(m => m.GetParameters().Length).ToList();
            if (candidates.Count == 0) throw new MissingMethodException(type.Name, method);

            foreach (var m in candidates)
            {
                var ps = m.GetParameters();
                var args = new object[ps.Length];
                var filled = new bool[ps.Length];
                bool ok = true;

                // 1) by name
                var leftovers = new List<(string name, object value)>();
                foreach (var (name, value) in named)
                {
                    int i = Array.FindIndex(ps, p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));
                    if (i >= 0) { args[i] = value; filled[i] = true; }
                    else leftovers.Add((name, value));
                }
                // 2) a parameter renamed in another LiveSplit version: first free slot of a fitting type
                foreach (var (_, value) in leftovers)
                {
                    int i = Array.FindIndex(ps, p => !filled[Array.IndexOf(ps, p)] &&
                        (value == null ? !p.ParameterType.IsValueType : p.ParameterType.IsInstanceOfType(value)));
                    if (i < 0) { ok = false; break; }
                    args[i] = value; filled[i] = true;
                }
                if (!ok) continue;
                // 3) defaults for the rest
                for (int i = 0; i < ps.Length && ok; i++)
                {
                    if (filled[i]) continue;
                    if (ps[i].HasDefaultValue) args[i] = ps[i].DefaultValue;
                    else if (ps[i].ParameterType.IsValueType) args[i] = Activator.CreateInstance(ps[i].ParameterType);
                    else ok = false;
                }
                if (!ok) continue;

                try { return m.Invoke(form, args); }
                catch (TargetInvocationException e) when (e.InnerException != null) { throw e.InnerException; }
            }
            throw new MissingMethodException(type.Name, method + " (no matching overload)");
        }

        public T Get<T>(string member)
        {
            var p = type.GetProperty(member, Flags);
            if (p != null) return (T)p.GetValue(form, null);
            var f = type.GetField(member, Flags);
            if (f != null) return (T)f.GetValue(form);
            return default;
        }

        public void Set(string member, object value)
        {
            var p = type.GetProperty(member, Flags);
            if (p != null) { p.SetValue(form, value, null); return; }
            type.GetField(member, Flags)?.SetValue(form, value);
        }

        public ISettings Settings => Get<ISettings>("Settings");
        public CompositeHook Hook => Get<CompositeHook>("Hook");
        public bool InTimerOnlyMode => Get<bool>("InTimerOnlyMode");

        /// <summary>Try each method name in order; returns false if none exist.</summary>
        public bool TryCall(IEnumerable<string> methods, params (string, object)[] named)
        {
            foreach (var m in methods)
            {
                if (!Has(m)) continue;
                Call(m, named);
                return true;
            }
            return false;
        }
    }
}
