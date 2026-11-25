using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace LiveSplit.MuSplit
{
    /// <summary>
    /// Localhost TCP server. Protocol is newline-delimited:
    ///   bridge -> client : one JSON object per line
    ///   client -> bridge : one plain-text command per line ("split", "reset", ...)
    /// All socket work happens off the UI thread.
    /// </summary>
    internal sealed class BridgeServer : IDisposable
    {
        private readonly TcpListener listener;
        private readonly List<Client> clients = new List<Client>();
        private readonly object clientsLock = new object();
        private readonly BlockingCollection<string> outbox = new BlockingCollection<string>(256);
        private readonly Action<string> onCommand;
        private readonly Action onClientConnected;
        private volatile bool running = true;

        private sealed class Client
        {
            public TcpClient Tcp;
            public StreamWriter Writer;
        }

        public BridgeServer(int port, Action<string> onCommand, Action onClientConnected)
        {
            this.onCommand = onCommand;
            this.onClientConnected = onClientConnected;

            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();

            new Thread(AcceptLoop) { IsBackground = true, Name = "MuSplit-Accept" }.Start();
            new Thread(SendLoop) { IsBackground = true, Name = "MuSplit-Send" }.Start();
        }

        /// <summary>Queue a line for every connected client. Never blocks the caller.</summary>
        public void Broadcast(string line)
        {
            if (!running) return;
            // If the send thread is behind, drop this frame; the next heartbeat carries full state anyway.
            outbox.TryAdd(line);
        }

        public bool HasClients
        {
            get { lock (clientsLock) return clients.Count > 0; }
        }

        private void AcceptLoop()
        {
            while (running)
            {
                TcpClient tcp;
                try { tcp = listener.AcceptTcpClient(); }
                catch { if (!running) return; continue; }

                tcp.NoDelay = true;
                var stream = tcp.GetStream();
                var client = new Client
                {
                    Tcp = tcp,
                    Writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" }
                };

                lock (clientsLock) clients.Add(client);
                new Thread(() => ReadLoop(client)) { IsBackground = true, Name = "MuSplit-Read" }.Start();
                onClientConnected?.Invoke();
            }
        }

        private void ReadLoop(Client client)
        {
            try
            {
                using (var reader = new StreamReader(client.Tcp.GetStream(), Encoding.UTF8))
                {
                    string line;
                    while (running && (line = reader.ReadLine()) != null)
                    {
                        // a web page making the browser send an HTTP request here: drop it before
                        // any line of it (its body could be "reset", "save ...") is run as a command
                        if (LooksLikeWeb(line)) break;
                        line = line.Trim();
                        if (line.Length > 0) onCommand?.Invoke(line);
                    }
                }
            }
            catch { /* client went away */ }
            finally { Drop(client); }
        }

        private static readonly string[] WebMethods =
            { "GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE " };
        private static readonly string[] WebHeaders =
            { "host:", "origin:", "user-agent:", "referer:", "content-type:", "content-length:", "sec-", "accept:", "connection:" };

        /// <summary>
        /// Commands come from Mu Split itself, one per line. Browsers can't open raw connections,
        /// but they always start with an HTTP request line and headers, which no command looks like.
        /// </summary>
        internal static bool LooksLikeWeb(string line)
        {
            if (line == null) return false;
            string t = line.TrimStart();
            foreach (var m in WebMethods)
                if (t.StartsWith(m, StringComparison.Ordinal) && t.IndexOf(" HTTP/", StringComparison.Ordinal) > 0) return true;
            string lower = t.ToLowerInvariant();
            foreach (var h in WebHeaders) if (lower.StartsWith(h, StringComparison.Ordinal)) return true;
            return false;
        }

        private void SendLoop()
        {
            try
            {
                foreach (var line in outbox.GetConsumingEnumerable())
                {
                    Client[] snapshot;
                    lock (clientsLock) snapshot = clients.ToArray();
                    foreach (var c in snapshot)
                    {
                        try { c.Writer.WriteLine(line); }
                        catch { Drop(c); }
                    }
                }
            }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { }
        }

        private void Drop(Client c)
        {
            lock (clientsLock) clients.Remove(c);
            try { c.Tcp.Close(); } catch { }
        }

        public void Dispose()
        {
            running = false;
            try { listener.Stop(); } catch { }
            outbox.CompleteAdding();
            lock (clientsLock)
            {
                foreach (var c in clients) { try { c.Tcp.Close(); } catch { } }
                clients.Clear();
            }
        }
    }
}
