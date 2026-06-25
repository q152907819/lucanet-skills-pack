using System.Diagnostics;
using System.Reflection;
using System.Text;

namespace Lucanet.AgentPack.Installer;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            var options = InstallerOptions.Parse(args);
            if (options.ShowHelp)
            {
                PrintUsage();
                return 0;
            }

            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("This installer targets native Windows.");
                return 2;
            }

            var packDir = ExtractEmbeddedPack();
            var installer = Path.Combine(packDir, "install-claude-cli-windows.ps1");
            var doctor = Path.Combine(packDir, "doctor-claude-cli-windows.ps1");
            var manifest = Path.Combine(packDir, "manifest", "claude-cli-windows.json");
            var offlinePayload = Path.Combine(packDir, "payload", "claude-win32-x64.exe");
            var offlineChecksum = ReadOptionalFile(Path.Combine(packDir, "payload", "claude-win32-x64.sha256"));
            var powershell = ResolvePowerShell();

            var installerArgs = new List<string>
            {
                "-ManifestPath",
                manifest,
                "-DoctorPath",
                doctor
            };

            if (!string.IsNullOrWhiteSpace(options.Proxy))
            {
                installerArgs.Add("-Proxy");
                installerArgs.Add(options.Proxy);
            }
            if (!string.IsNullOrWhiteSpace(options.Method))
            {
                installerArgs.Add("-Method");
                installerArgs.Add(options.Method);
            }
            if (!string.IsNullOrWhiteSpace(options.InstallerUrl))
            {
                installerArgs.Add("-InstallerUrl");
                installerArgs.Add(options.InstallerUrl);
            }
            if (!string.IsNullOrWhiteSpace(options.LocalInstallerPath))
            {
                installerArgs.Add("-LocalInstallerPath");
                installerArgs.Add(options.LocalInstallerPath);
            }
            if (File.Exists(offlinePayload) && !options.DisableOfflinePayload)
            {
                installerArgs.Add("-OfflineClaudeExePath");
                installerArgs.Add(offlinePayload);
                if (!string.IsNullOrWhiteSpace(offlineChecksum))
                {
                    installerArgs.Add("-OfflineClaudeChecksum");
                    installerArgs.Add(offlineChecksum);
                }
            }
            if (options.NoFallback)
            {
                installerArgs.Add("-NoFallback");
            }
            if (options.InstallGitForWindows)
            {
                installerArgs.Add("-InstallGitForWindows");
            }
            if (options.SkipDoctor)
            {
                installerArgs.Add("-SkipDoctor");
            }
            if (options.PromptApiKey)
            {
                installerArgs.Add("-PromptApiKey");
            }
            if (options.RequireApiKey && !options.SkipApiKey)
            {
                installerArgs.Add("-RequireApiKey");
            }
            if (options.Silent)
            {
                installerArgs.Add("-Silent");
            }
            if (options.DryRun)
            {
                installerArgs.Add("-DryRun");
            }

            var psArgs = new List<string>
            {
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-EncodedCommand",
                BuildEncodedScriptCommand(installer, packDir, installerArgs)
            };

            Console.WriteLine("Running self-contained LucaNet Claude CLI installer...");
            return RunProcess(powershell, psArgs);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static string ExtractEmbeddedPack()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "lucanet-claude-cli-pack-" + DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss"));
        var manifestDir = Path.Combine(tempDir, "manifest");
        Directory.CreateDirectory(manifestDir);

        ExtractResource("install-claude-cli-windows.ps1", Path.Combine(tempDir, "install-claude-cli-windows.ps1"));
        ExtractResource("doctor-claude-cli-windows.ps1", Path.Combine(tempDir, "doctor-claude-cli-windows.ps1"));
        ExtractResource("manifest/claude-cli-windows.json", Path.Combine(manifestDir, "claude-cli-windows.json"));
        ExtractOptionalResource("payload/claude-win32-x64.exe", Path.Combine(tempDir, "payload", "claude-win32-x64.exe"));
        ExtractOptionalResource("payload/claude-win32-x64.sha256", Path.Combine(tempDir, "payload", "claude-win32-x64.sha256"));
        return tempDir;
    }

    private static void ExtractResource(string logicalName, string outputPath)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var input = assembly.GetManifestResourceStream(logicalName)
            ?? throw new InvalidOperationException($"Embedded resource missing: {logicalName}");
        using var output = File.Create(outputPath);
        input.CopyTo(output);
    }

    private static void ExtractOptionalResource(string logicalName, string outputPath)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var input = assembly.GetManifestResourceStream(logicalName);
        if (input is null)
        {
            return;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
        using var output = File.Create(outputPath);
        input.CopyTo(output);
    }

    private static string ReadOptionalFile(string path)
    {
        return File.Exists(path) ? File.ReadAllText(path).Trim() : string.Empty;
    }

    private static string BuildEncodedScriptCommand(string scriptPath, string workingDirectory, IReadOnlyList<string> scriptArgs)
    {
        var command = new StringBuilder();
        command.AppendLine("$ErrorActionPreference = 'Stop'");
        command.AppendLine("Set-Location -LiteralPath '" + EscapePowerShellSingleQuoted(workingDirectory) + "'");
        command.AppendLine("$scriptText = [System.IO.File]::ReadAllText('" + EscapePowerShellSingleQuoted(scriptPath) + "')");
        command.AppendLine("$scriptBlock = [ScriptBlock]::Create($scriptText)");
        command.Append("$installerArgs = @(");
        for (var i = 0; i < scriptArgs.Count; i++)
        {
            if (i > 0)
            {
                command.Append(", ");
            }
            command.Append('\'');
            command.Append(EscapePowerShellSingleQuoted(scriptArgs[i]));
            command.Append('\'');
        }
        command.AppendLine(")");
        command.AppendLine("& $scriptBlock @installerArgs");
        return Convert.ToBase64String(Encoding.Unicode.GetBytes(command.ToString()));
    }

    private static string EscapePowerShellSingleQuoted(string value)
    {
        return value.Replace("'", "''", StringComparison.Ordinal);
    }

    private static string ResolvePowerShell()
    {
        var systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var windowsPowerShell = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(windowsPowerShell) ? windowsPowerShell : "powershell.exe";
    }

    private static int RunProcess(string fileName, IReadOnlyList<string> args)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false
        };
        foreach (var arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }

        using var process = Process.Start(startInfo);
        if (process is null)
        {
            throw new InvalidOperationException("Failed to start PowerShell.");
        }

        process.WaitForExit();
        return process.ExitCode;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("""
LucanetAgentPackInstaller.exe

Default:
  Run without arguments to install Claude CLI and prompt for API key.

Common:
  --proxy <url>                     HTTP proxy for Claude installer download.
  --method <native|winget|npm>      Install method, default: native with fallback.
  --installer-url <url>             Override native installer URL.
  --local-installer <path>          Use a pre-downloaded native install.ps1.
  --disable-offline-payload         Ignore embedded Claude payload and use online/native fallback.
  --require-api-key                 Prompt and require ANTHROPIC_API_KEY. Default.
  --prompt-api-key                  Prompt for ANTHROPIC_API_KEY, allow empty.
  --no-api-key                      Do not prompt for ANTHROPIC_API_KEY.
  --no-fallback                     Disable native -> winget/npm fallback.
  --install-git-for-windows         Optionally install Git for Windows.
  --skip-doctor                     Do not run doctor after install.
  --silent                          Reduce installer output.
  --dry-run                         Print intended actions without installing.
  --help                            Show help.

Example:
  LucanetAgentPackInstaller.exe
""");
    }

    private sealed record InstallerOptions
    {
        public string Proxy { get; init; } = string.Empty;
        public string Method { get; init; } = string.Empty;
        public string InstallerUrl { get; init; } = string.Empty;
        public string LocalInstallerPath { get; init; } = string.Empty;
        public bool PromptApiKey { get; init; }
        public bool RequireApiKey { get; init; } = true;
        public bool SkipApiKey { get; init; }
        public bool NoFallback { get; init; }
        public bool DisableOfflinePayload { get; init; }
        public bool InstallGitForWindows { get; init; }
        public bool SkipDoctor { get; init; }
        public bool Silent { get; init; }
        public bool DryRun { get; init; }
        public bool ShowHelp { get; init; }

        public static InstallerOptions Parse(string[] args)
        {
            var options = new MutableOptions();
            for (var i = 0; i < args.Length; i++)
            {
                var arg = args[i];
                switch (arg)
                {
                    case "--proxy":
                        options.Proxy = ReadValue(args, ref i, arg);
                        break;
                    case "--method":
                        options.Method = ReadValue(args, ref i, arg);
                        break;
                    case "--installer-url":
                        options.InstallerUrl = ReadValue(args, ref i, arg);
                        break;
                    case "--local-installer":
                        options.LocalInstallerPath = ReadValue(args, ref i, arg);
                        break;
                    case "--prompt-api-key":
                        options.PromptApiKey = true;
                        break;
                    case "--require-api-key":
                        options.RequireApiKey = true;
                        break;
                    case "--no-api-key":
                        options.RequireApiKey = false;
                        options.SkipApiKey = true;
                        break;
                    case "--no-fallback":
                        options.NoFallback = true;
                        break;
                    case "--disable-offline-payload":
                        options.DisableOfflinePayload = true;
                        break;
                    case "--install-git-for-windows":
                        options.InstallGitForWindows = true;
                        break;
                    case "--skip-doctor":
                        options.SkipDoctor = true;
                        break;
                    case "--silent":
                        options.Silent = true;
                        break;
                    case "--dry-run":
                        options.DryRun = true;
                        break;
                    case "--help":
                    case "-h":
                    case "/?":
                        options.ShowHelp = true;
                        break;
                    default:
                        throw new ArgumentException($"Unknown argument: {arg}");
                }
            }

            return new InstallerOptions
            {
                Proxy = options.Proxy,
                Method = options.Method,
                InstallerUrl = options.InstallerUrl,
                LocalInstallerPath = options.LocalInstallerPath,
                PromptApiKey = options.PromptApiKey,
                RequireApiKey = options.RequireApiKey,
                SkipApiKey = options.SkipApiKey,
                NoFallback = options.NoFallback,
                DisableOfflinePayload = options.DisableOfflinePayload,
                InstallGitForWindows = options.InstallGitForWindows,
                SkipDoctor = options.SkipDoctor,
                Silent = options.Silent,
                DryRun = options.DryRun,
                ShowHelp = options.ShowHelp
            };
        }

        private static string ReadValue(string[] args, ref int index, string name)
        {
            if (index + 1 >= args.Length)
            {
                throw new ArgumentException($"Missing value for {name}.");
            }

            index += 1;
            return args[index];
        }

        private sealed class MutableOptions
        {
            public string Proxy { get; set; } = string.Empty;
            public string Method { get; set; } = string.Empty;
            public string InstallerUrl { get; set; } = string.Empty;
            public string LocalInstallerPath { get; set; } = string.Empty;
            public bool PromptApiKey { get; set; }
            public bool RequireApiKey { get; set; } = true;
            public bool SkipApiKey { get; set; }
            public bool NoFallback { get; set; }
            public bool DisableOfflinePayload { get; set; }
            public bool InstallGitForWindows { get; set; }
            public bool SkipDoctor { get; set; }
            public bool Silent { get; set; }
            public bool DryRun { get; set; }
            public bool ShowHelp { get; set; }
        }
    }
}
