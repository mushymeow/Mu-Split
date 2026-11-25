using System;
using System.Globalization;
using System.Text;

namespace LiveSplit.MuSplit
{
    /// <summary>Tiny dependency-free JSON writer (we only ever write JSON, never read it).</summary>
    internal sealed class Json
    {
        private readonly StringBuilder sb = new StringBuilder(4096);
        private bool needComma;

        public Json BeginObject() { Sep(); sb.Append('{'); needComma = false; return this; }
        public Json EndObject() { sb.Append('}'); needComma = true; return this; }
        public Json BeginArray() { Sep(); sb.Append('['); needComma = false; return this; }
        public Json EndArray() { sb.Append(']'); needComma = true; return this; }

        public Json Key(string k) { Sep(); Str(k); sb.Append(':'); needComma = false; return this; }

        public Json Val(string v) { Sep(); if (v == null) sb.Append("null"); else Str(v); needComma = true; return this; }
        public Json Val(bool v) { Sep(); sb.Append(v ? "true" : "false"); needComma = true; return this; }
        public Json Val(int v) { Sep(); sb.Append(v.ToString(CultureInfo.InvariantCulture)); needComma = true; return this; }
        public Json Val(double v) { Sep(); sb.Append(v.ToString("0.###", CultureInfo.InvariantCulture)); needComma = true; return this; }

        /// <summary>Times are sent as milliseconds (number) or null.</summary>
        public Json Val(TimeSpan? t) { if (t.HasValue) return Val(t.Value.TotalMilliseconds); Sep(); sb.Append("null"); needComma = true; return this; }

        public Json Prop(string k, string v) => Key(k).Val(v);
        public Json Prop(string k, bool v) => Key(k).Val(v);
        public Json Prop(string k, int v) => Key(k).Val(v);
        public Json Prop(string k, TimeSpan? v) => Key(k).Val(v);

        private void Sep() { if (needComma) sb.Append(','); }

        private void Str(string s)
        {
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
            sb.Append('"');
        }

        public override string ToString() => sb.ToString();
    }
}
