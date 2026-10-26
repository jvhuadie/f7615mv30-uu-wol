using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;

namespace ZteUuInstaller
{
    public sealed class BackupTransferResult
    {
        public long Bytes;
        public string Sha256;
        public int SourceExitCode = -1;
        public int ReadExitCode = -1;
    }

    public sealed partial class TelnetSession
    {
        // Read a bounded, hex-encoded stream directly to disk. No whole-file buffering.
        // The caller has already consumed a unique start marker with ReadUntil.
        public BackupTransferResult ReceiveHexFile(string destination, string token,
            long maxBytes, int idleTimeoutMs, CancellationToken cancellation, Action<long> progress)
        {
            if (!Regex.IsMatch(token, "^[a-f0-9]{32}$") || maxBytes < 1)
                throw new ArgumentException("Invalid transfer parameters.");
            string end = "__DATA_END_" + token + "__";
            string source = "__SOURCE_RC_" + token + ":";
            string read = "__READ_RC_" + token + ":";
            var result = new BackupTransferResult();
            var idle = Stopwatch.StartNew();
            string carry = "";
            string buffered = "";
            int offset = 0;
            long nextProgress = 4L * 1024 * 1024;
            using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            using (var hash = SHA256.Create())
            {
                bool ended = false;
                while (!ended)
                {
                    cancellation.ThrowIfCancellationRequested();
                    int newline = buffered.IndexOf('\n', offset);
                    if (newline >= 0)
                    {
                        string line = buffered.Substring(offset, newline - offset).Trim();
                        offset = newline + 1;
                        idle.Restart();
                        if (line == end) { ended = true; continue; }
                        if (line.StartsWith(source, StringComparison.Ordinal))
                        {
                            if (result.SourceExitCode != -1 || !Int32.TryParse(line.Substring(source.Length), out result.SourceExitCode))
                                throw new IOException("Invalid source status.");
                            continue;
                        }
                        if (line.StartsWith(read, StringComparison.Ordinal))
                        {
                            if (result.ReadExitCode != -1 || !Int32.TryParse(line.Substring(read.Length), out result.ReadExitCode))
                                throw new IOException("Invalid read status.");
                            continue;
                        }
                        if (line.Length == 0) continue;
                        if (line.Length > 4096 || !Regex.IsMatch(line, "^[0-9a-fA-F]+$"))
                            throw new IOException("Unexpected data in backup stream.");
                        line = carry + line;
                        int length = line.Length - line.Length % 2;
                        carry = line.Substring(length);
                        byte[] bytes = new byte[length / 2];
                        for (int i = 0; i < bytes.Length; i++)
                        {
                            char a = line[i * 2], b = line[i * 2 + 1];
                            int hi = a <= '9' ? a - '0' : (a | 32) - 'a' + 10;
                            int lo = b <= '9' ? b - '0' : (b | 32) - 'a' + 10;
                            bytes[i] = (byte)((hi << 4) | lo);
                        }
                        if (result.Bytes > maxBytes - bytes.Length)
                            throw new IOException("Backup exceeded the configured size limit.");
                        output.Write(bytes, 0, bytes.Length);
                        hash.TransformBlock(bytes, 0, bytes.Length, bytes, 0);
                        result.Bytes += bytes.Length;
                        if (progress != null && result.Bytes >= nextProgress)
                        {
                            progress(result.Bytes);
                            nextProgress = result.Bytes + 4L * 1024 * 1024;
                        }
                        continue;
                    }
                    string remainder = buffered.Substring(offset);
                    if (remainder.Length > 4096) throw new IOException("Unbounded backup line.");
                    PumpAvailable();
                    if (pending.Length > 0)
                    {
                        buffered = remainder + pending.ToString();
                        offset = 0;
                        pending.Clear();
                        idle.Restart();
                        continue;
                    }
                    if (idle.ElapsedMilliseconds >= idleTimeoutMs)
                        throw new TimeoutException("Backup stream timed out.");
                    if (!stream.DataAvailable && client.Client.Poll(0, System.Net.Sockets.SelectMode.SelectRead) && client.Client.Available == 0)
                        throw new IOException("Connection closed during backup.");
                    Thread.Sleep(5);
                }
                pending.Insert(0, buffered.Substring(offset));
                if (carry.Length != 0 || result.SourceExitCode < 0 || result.ReadExitCode < 0)
                    throw new IOException("Backup stream ended without complete data or status.");
                hash.TransformFinalBlock(new byte[0], 0, 0);
                result.Sha256 = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
                output.Flush();
            }
            return result;
        }
    }
}
