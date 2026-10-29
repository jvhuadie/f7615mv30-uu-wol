using System;
using System.IO;
using System.Collections.Generic;
using System.IO.Compression;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class GuiLauncher
{
    private static readonly string[] PayloadFiles = {
"Gui.ps1","Manage.ps1","INSTALL.txt","VALIDATION.txt","tools/Network.ps1","tools/TelnetSession.cs","tools/Profiles.ps1","tools/GuiWorker.ps1","profiles/f7615/Auto.ps1","profiles/f7615/install.sh","profiles/f7615/tools/Network.ps1","profiles/f7615/tools/Prompts.ps1","profiles/f7615/tools/TelnetSession.cs","profiles/f7615/tools/Manage.ps1","profiles/f7615/src/full-uninstall.sh","profiles/f7615/defaults.json","profiles/f7005/Manage.ps1","profiles/f7005/tools/FrameworkRepair.ps1","profiles/f7005/tools/framework-repair.sh","profiles/f7005/payload/andlink.delta","profiles/f7005/control.sh","profiles/f7005/tools/Network.ps1","profiles/f7005/tools/TelnetSession.cs","profiles/f7005/tools/LanFiles.cs","profiles/f7005/payload/service.jar","profiles/f7005/payload/manifest.json","profiles/f7005/payload/cap-uu-set.template","profiles/f7005/payload/cap-pid-set.template","profiles/f7005/payload/cap-get.template","profiles/f7005/payload/cap-remove.template","profiles/f7005/payload/flags-get.template","profiles/f7005/payload/flags-lock.template","profiles/f7005/payload/flags-unlock.template","profiles/g7615/Manage.ps1","profiles/g7615/preflight.sh","profiles/g7615/control.sh","profiles/g7615/service.sh","profiles/g7615/run.sh"
    };

    private static string ExtractPayload()
    {
        string temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
        string root = Path.Combine(temp, "ZteOntUuWol-runtime-" + Guid.NewGuid().ToString("N"));
        DirectorySecurity acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
        acl.SetOwner(user);
        acl.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.CreateDirectory(root, acl);
        File.WriteAllText(Path.Combine(root, ".uu-owned"), Path.GetFileName(root));
        try
        {
            HashSet<string> expected = new HashSet<string>(PayloadFiles, StringComparer.Ordinal);
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("ZteOntUuWol.Payload"))
            {
                if (resource == null) throw new InvalidDataException();
                using (GZipStream gzip = new GZipStream(resource, CompressionMode.Decompress))
                using (BinaryReader reader = new BinaryReader(gzip, Encoding.UTF8))
                {
                    if (Encoding.ASCII.GetString(reader.ReadBytes(4)) != "UUW1") throw new InvalidDataException();
                    int count = reader.ReadInt32();
                    if (count != PayloadFiles.Length) throw new InvalidDataException();
                    long total = 0;
                    for (int i = 0; i < count; i++)
                    {
                        string relative = reader.ReadString();
                        if (!expected.Remove(relative)) throw new InvalidDataException();
                        int length = reader.ReadInt32();
                        total += length;
                        if (length < 0 || length > 8 * 1024 * 1024 || total > 32 * 1024 * 1024) throw new InvalidDataException();
                        byte[] wanted = reader.ReadBytes(32);
                        byte[] bytes = reader.ReadBytes(length);
                        if (wanted.Length != 32 || bytes.Length != length) throw new InvalidDataException();
                        using (SHA256 sha = SHA256.Create())
                        {
                            byte[] actual = sha.ComputeHash(bytes);
                            for (int j = 0; j < actual.Length; j++) if (actual[j] != wanted[j]) throw new InvalidDataException();
                        }
                        string path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
                        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
                        Directory.CreateDirectory(Path.GetDirectoryName(path));
                        using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                            output.Write(bytes, 0, bytes.Length);
                    }
                    if (expected.Count != 0 || gzip.ReadByte() != -1) throw new InvalidDataException();
                }
            }
            return root;
        }
        catch { Cleanup(root); throw; }
    }

    private static void DeleteOwnedTree(string root)
    {
        DirectoryInfo directory = new DirectoryInfo(root);
        if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException();
        foreach (FileSystemInfo entry in directory.GetFileSystemInfos())
        {
            if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException();
            if ((entry.Attributes & FileAttributes.Directory) != 0) DeleteOwnedTree(entry.FullName);
            else entry.Delete();
        }
        directory.Delete();
    }

    private static void Cleanup(string root)
    {
        if (String.IsNullOrEmpty(root) || !Directory.Exists(root)) return;
        string temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
        string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        string name = Path.GetFileName(full);
        if (!String.Equals(Path.GetDirectoryName(full), temp, StringComparison.OrdinalIgnoreCase) ||
            !name.StartsWith("ZteOntUuWol-runtime-", StringComparison.Ordinal) || name.Length != 52) return;
        if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0) return;
        if (!File.Exists(Path.Combine(full, ".uu-owned")) || File.ReadAllText(Path.Combine(full, ".uu-owned")) != name) return;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try { DeleteOwnedTree(full); return; }
            catch (IOException) { Thread.Sleep(100); }
            catch (UnauthorizedAccessException) { Thread.Sleep(100); }
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool selfTest = Array.IndexOf(args, "--self-test") >= 0;
        int previewIndex = Array.IndexOf(args, "--preview");
        string root = null;
        int result = 1;
        Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass", EnvironmentVariableTarget.Process);
        try
        {
            root = ExtractPayload();
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    if (selfTest)
                    {
                        ps.AddScript("param($root) $ErrorActionPreference='Stop'; Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 | ForEach-Object { $tokens=$null; $errors=$null; $null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors); if($errors.Count){throw 'Embedded script syntax error'} }").AddArgument(root);
                    }
                    else
                    {
                        ps.AddCommand(Path.Combine(root, "Gui.ps1"));
                        if (Array.IndexOf(args, "--check") >= 0) ps.AddParameter("CheckOnly");
                        if (previewIndex >= 0)
                        {
                            if (previewIndex + 1 >= args.Length) throw new ArgumentException();
                            ps.AddParameter("PreviewImage", Path.GetFullPath(args[previewIndex + 1]));
                        }
                    }
                    ps.Invoke();
                    if (ps.HadErrors) throw new InvalidOperationException();
                }
            }
            result = 0;
        }
        catch
        {
            if (!selfTest && previewIndex < 0)
                MessageBox.Show("工具启动未完成。请重新下载单文件版本，确认 Windows PowerShell 5.1 可用后再试。", "中兴光猫 UU 远程开机", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { Cleanup(root); }
        if (selfTest && root != null && Directory.Exists(root)) return 2;
        return result;
    }
}
