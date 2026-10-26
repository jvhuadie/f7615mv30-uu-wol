using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace ZteUuInstaller
{
    // Minimal NVT client. No transcript, credentials or received text is logged.
    public sealed partial class TelnetSession : IDisposable
    {
        private TcpClient client;
        private NetworkStream stream;
        private readonly StringBuilder pending = new StringBuilder();
        private readonly Decoder decoder = Encoding.UTF8.GetDecoder();
        private int telnetState;
        private byte negotiation;
        private const int MaxPending = 2 * 1024 * 1024;

        public TelnetSession(string address, int port, int timeoutMs)
        {
            client = new TcpClient();
            client.ReceiveBufferSize = 65536;
            IAsyncResult result = client.BeginConnect(address, port, null, null);
            try
            {
                if (!result.AsyncWaitHandle.WaitOne(timeoutMs))
                    throw new TimeoutException("Telnet connection timed out.");
                client.EndConnect(result);
                stream = client.GetStream();
                stream.ReadTimeout = 1000;
                stream.WriteTimeout = 10000;
            }
            catch
            {
                client.Close();
                throw;
            }
            finally { result.AsyncWaitHandle.Close(); }
        }

        private void Negotiate(byte command, byte option)
        {
            byte response;
            if (command == 251)
                response = (option == 1 || option == 3) ? (byte)253 : (byte)254;
            else if (command == 253)
                response = option == 3 ? (byte)251 : (byte)252;
            else return;
            byte[] reply = new byte[] {255, response, option};
            stream.Write(reply, 0, reply.Length);
        }

        private void Decode(byte[] bytes, int length)
        {
            using (MemoryStream data = new MemoryStream())
            {
                for (int i = 0; i < length; i++)
                {
                    byte b = bytes[i];
                    if (telnetState == 0)
                    {
                        if (b == 255) telnetState = 1;
                        else if (b != 0) data.WriteByte(b);
                    }
                    else if (telnetState == 1)
                    {
                        if (b == 255) { data.WriteByte(255); telnetState = 0; }
                        else if (b >= 251 && b <= 254) { negotiation = b; telnetState = 2; }
                        else if (b == 250) telnetState = 3;
                        else telnetState = 0;
                    }
                    else if (telnetState == 2)
                    {
                        Negotiate(negotiation, b);
                        telnetState = 0;
                    }
                    else if (telnetState == 3)
                    {
                        if (b == 255) telnetState = 4;
                    }
                    else if (telnetState == 4)
                    {
                        telnetState = b == 240 ? 0 : 3;
                    }
                }
                byte[] clean = data.ToArray();
                char[] chars = new char[Encoding.UTF8.GetMaxCharCount(clean.Length)];
                int count = decoder.GetChars(clean, 0, clean.Length, chars, 0, false);
                pending.Append(chars, 0, count);
                if (pending.Length > MaxPending)
                    throw new IOException("Remote output exceeded the bounded receive buffer.");
            }
        }

        public void PumpAvailable()
        {
            byte[] bytes = new byte[8192];
            int batches = 0;
            while (stream.DataAvailable && batches++ < 64)
            {
                int count = stream.Read(bytes, 0, bytes.Length);
                if (count == 0) throw new IOException("Telnet connection closed.");
                Decode(bytes, count);
            }
        }

        private void SendData(byte[] bytes)
        {
            using (MemoryStream encoded = new MemoryStream())
            {
                foreach (byte b in bytes)
                {
                    encoded.WriteByte(b);
                    if (b == 255) encoded.WriteByte(255);
                }
                byte[] data = encoded.ToArray();
                try
                {
                    stream.Write(data, 0, data.Length);
                    stream.Flush();
                }
                finally
                {
                    Array.Clear(data, 0, data.Length);
                    byte[] internalBuffer = encoded.GetBuffer();
                    Array.Clear(internalBuffer, 0, internalBuffer.Length);
                }
            }
            PumpAvailable();
        }

        public void SendLine(string line)
        {
            if (line.IndexOfAny(new char[] {'\r', '\n', '\0'}) >= 0)
                throw new ArgumentException("SendLine accepts one line only.");
            byte[] bytes = Encoding.UTF8.GetBytes(line + "\r\n");
            try { SendData(bytes); }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }

        public void SendSecureLine(SecureString secret)
        {
            IntPtr pointer = IntPtr.Zero;
            char[] chars = null;
            byte[] bytes = null;
            try
            {
                pointer = Marshal.SecureStringToBSTR(secret);
                int count = Marshal.ReadInt32(pointer, -4) / 2;
                chars = new char[count + 2];
                for (int i = 0; i < count; i++)
                {
                    char c = (char)Marshal.ReadInt16(pointer, i * 2);
                    if (c == '\r' || c == '\n' || c == '\0')
                        throw new ArgumentException("Password contains unsupported line-control characters.");
                    chars[i] = c;
                }
                chars[count] = '\r';
                chars[count + 1] = '\n';
                bytes = Encoding.UTF8.GetBytes(chars);
                SendData(bytes);
            }
            finally
            {
                if (bytes != null) Array.Clear(bytes, 0, bytes.Length);
                if (chars != null) Array.Clear(chars, 0, chars.Length);
                if (pointer != IntPtr.Zero) Marshal.ZeroFreeBSTR(pointer);
            }
        }

        public string ReadUntil(string pattern, int timeoutMs)
        {
            return ReadUntilCancelable(pattern, timeoutMs, CancellationToken.None);
        }

        public string ReadUntilCancelable(string pattern, int timeoutMs, CancellationToken cancellation)
        {
            Regex regex = new Regex(pattern, RegexOptions.Multiline, TimeSpan.FromSeconds(1));
            Stopwatch watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < timeoutMs)
            {
                cancellation.ThrowIfCancellationRequested();
                Match match = regex.Match(pending.ToString());
                if (match.Success)
                {
                    int length = match.Index + match.Length;
                    string result = pending.ToString(0, length);
                    pending.Remove(0, length);
                    return result;
                }
                PumpAvailable();
                if (regex.IsMatch(pending.ToString())) continue;
                // Data may arrive between DataAvailable and Poll. A readable
                // socket is only EOF if it still has no bytes available.
                if (!stream.DataAvailable && client.Client.Poll(0, SelectMode.SelectRead) && client.Client.Available == 0)
                    throw new IOException("Telnet connection closed before command completion.");
                Thread.Sleep(10);
            }
            throw new TimeoutException("Timed out waiting for the expected Telnet response.");
        }

        public void Dispose()
        {
            if (stream != null) stream.Dispose();
            if (client != null) client.Close();
            pending.Clear();
        }
    }
}
