using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

// One in-memory public program file, one selected interface and one router.
// No filesystem serving, directory listing, credentials, or device reports.
public sealed class G7615LanTransfer : IDisposable
{
    readonly TcpListener listener;
    readonly Thread worker;
    readonly IPAddress peer;
    readonly byte[] payload;
    readonly string requestPath;
    readonly object gate = new object();
    TcpClient active;
    volatile bool stopping;
    long sent;
    public int Port { get; private set; }
    public string Url { get; private set; }
    public long BytesSent { get { return Interlocked.Read(ref sent); } }

    public G7615LanTransfer(string address, string router, string name, byte[] bytes)
    {
        if (bytes == null || bytes.Length > 8 * 1024 * 1024 ||
            !System.Text.RegularExpressions.Regex.IsMatch(name, "^[A-Za-z0-9_.-]+$"))
            throw new ArgumentException("Invalid transfer payload");
        IPAddress local = IPAddress.Parse(address);
        peer = IPAddress.Parse(router);
        if (local.AddressFamily != AddressFamily.InterNetwork ||
            peer.AddressFamily != AddressFamily.InterNetwork || local.Equals(IPAddress.Any))
            throw new ArgumentException("An explicit IPv4 interface is required");
        payload = bytes;
        requestPath = "/" + Guid.NewGuid().ToString("N") + "/" + name;
        listener = new TcpListener(local, 0);
        listener.Start(4);
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Url = "http://" + address + ":" + Port + requestPath;
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }

    void Run()
    {
        while (!stopping)
        {
            try
            {
                using (TcpClient client = listener.AcceptTcpClient())
                {
                    lock (gate) { if (stopping) return; active = client; }
                    try
                    {
                        if (!((IPEndPoint)client.Client.RemoteEndPoint).Address.Equals(peer)) continue;
                        client.ReceiveTimeout = 3000;
                        client.SendTimeout = 10000;
                        client.NoDelay = true;
                        using (NetworkStream stream = client.GetStream())
                        {
                            StringBuilder header = new StringBuilder();
                            bool complete = false;
                            DateTime deadline = DateTime.UtcNow.AddSeconds(5);
                            while (header.Length < 8192 && DateTime.UtcNow < deadline)
                            {
                                int value = stream.ReadByte();
                                if (value < 0) break;
                                header.Append((char)value);
                                int n = header.Length;
                                if (n >= 4 && header[n - 4] == '\r' && header[n - 3] == '\n' &&
                                    header[n - 2] == '\r' && header[n - 1] == '\n')
                                { complete = true; break; }
                            }
                            string first = header.ToString().Split(new[] { "\r\n" }, StringSplitOptions.None)[0];
                            bool allowed = complete && (first == "GET " + requestPath + " HTTP/1.1" ||
                                first == "GET " + requestPath + " HTTP/1.0");
                            byte[] response = Encoding.ASCII.GetBytes("HTTP/1.0 " +
                                (allowed ? "200 OK" : "404 Not Found") + "\r\nContent-Length: " +
                                (allowed ? payload.Length : 0) + "\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n");
                            stream.Write(response, 0, response.Length);
                            if (!allowed) continue;
                            Interlocked.Exchange(ref sent, 0);
                            for (int offset = 0; offset < payload.Length && !stopping; offset += 65536)
                            {
                                int count = Math.Min(65536, payload.Length - offset);
                                stream.Write(payload, offset, count);
                                Interlocked.Add(ref sent, count);
                            }
                        }
                    }
                    finally { lock (gate) { active = null; } }
                }
            }
            catch (SocketException) { if (stopping) return; }
            catch (IOException) { if (stopping) return; }
            catch (ObjectDisposedException) { if (stopping) return; }
        }
    }

    public void Dispose()
    {
        stopping = true;
        listener.Stop();
        lock (gate) { if (active != null) active.Close(); }
        worker.Join(1500);
    }
}
