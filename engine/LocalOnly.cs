using System;

namespace MuSplit.Engine
{
    /// <summary>
    /// Mu Split's local ports (16850 the timer, 16851 races/Discord) take one plain command per
    /// line, from Mu Split itself. A web page can't open a raw connection, but it can make the
    /// browser send an HTTP request to 127.0.0.1, and every line of that (including a body the
    /// page chose, like "reset" or "save ...") would read as a command. Browsers always start
    /// with an HTTP request line and headers, so a connection that does is dropped at once,
    /// before any line of it is acted on.
    /// </summary>
    internal static class LocalOnly
    {
        private static readonly string[] Methods =
            { "GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE " };
        private static readonly string[] Headers =
            { "host:", "origin:", "user-agent:", "referer:", "content-type:", "content-length:", "sec-", "accept:", "connection:" };

        public static bool LooksLikeWeb(string line)
        {
            if (line == null) return false;
            string t = line.TrimStart();
            foreach (var m in Methods)
                if (t.StartsWith(m, StringComparison.Ordinal) && t.IndexOf(" HTTP/", StringComparison.Ordinal) > 0) return true;
            string lower = t.ToLowerInvariant();
            foreach (var h in Headers) if (lower.StartsWith(h, StringComparison.Ordinal)) return true;
            return false;
        }
    }
}
