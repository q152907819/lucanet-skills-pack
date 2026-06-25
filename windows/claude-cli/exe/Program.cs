using System.Diagnostics;
using System.Net;

namespace Lucanet.AgentPack.Installer;

internal static class Program
{
    private const string DefaultSubPath = "windows/claude-cli";
    private const string DefaultRef = "main";

    private static async Task<int> Main(string[] args)
    {
        try
        {
            var options = InstallerOptions.Parse(args);
            if (options.ShowHelp)
            {
                PrintUsage();
                return 0;
            }

            if (string.IsNullOrWhiteSpace(options.PackRepoUrl))
            {
                Console.Error.WriteLine("Missing required --repo <git-url>.");
                PrintUsage();
                return 2;
            }

            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("This installer targets native Windows.");
                return 2;
            }

            var tempDir = Path.Combine(Path.GetTempPath(), "lucanet-agent-pack-" + DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss"));
            Directory.CreateDirectory(tempDir);

            var bootstrapPath = Path.Combine(tempDir, "bootstrap-from-git.ps1");
            var bootstrapUrl = options.BootstrapUrl;
            if (string.IsNullOrWhiteSpace(bootstrapUrl))
            {
                bootstrapUrl = BuildGitHubRawUrl(options.PackRepoUrl, options.PackRef, options.PackSubPath);
            }

            if (string.IsNullOrWhiteSpace(bootstrapUrl))
            {
                Console.Error.WriteLine("Could not derive a raw bootstrap URL. Pass --bootstrap-url for non-GitHub repositories.");
                return 2;
            }

            Console.WriteLine("Downloading bootstrap script:");
            Console.WriteLine(bootstrapUrl);
            await DownloadFileAsync(bootstrapUrl, bootstrapPath, options.Proxy);

            var powershell = ResolvePowerShell();
            var psArgs = new List<string>
            {
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                bootstrapPath,
                "-PackRepoUrl",
                options.PackRepoUrl,
                "-PackRef",
                options.PackRef,
                "-PackSubPath",
                options.PackSubPath
            };

            if (!string.IsNullOrWhiteSpace(options.Proxy))
            {
                psArgs.Add("-Proxy");
                psArgs.Add(options.Proxy);
            }
            if (options.UseGit)
            {
                psArgs.Add("-UseGit");
            }
            if (options.PromptApiKey)
            {
                psArgs.Add("-PromptApiKey");
            }
            if (options.RequireApiKey)
            {
                psArgs.Add("-RequireApiKey");
            }
            if (options.Silent)
            {
                psArgs.Add("-Silent");
            }
            if (options.DryRun)
            {
                psArgs.Add("-DryRun");
            }

            Console.WriteLine("Running pack bootstrapper...");
            return RunProcess(powershell, psArgs);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static string ResolvePowerShell()
    {
        var systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var windowsPowerShell = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(windowsPowerShell) ? windowsPowerShell : "powershell.exe";
    }

    private static async Task DownloadFileAsync(string url, string outputPath, string? proxy)
    {
        var handler = new HttpClientHandler();
        if (!string.IsNullOrWhiteSpace(proxy))
        {
            handler.Proxy = new WebProxy(proxy);
            handler.UseProxy = true;
        }

        using var client = new HttpClient(handler);
        client.Timeout = TimeSpan.FromMinutes(3);
        using var response = await client.GetAsync(url);
        response.EnsureSuccessStatusCode();
        await using var output = File.Create(outputPath);
        await response.Content.CopyToAsync(output);
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

    private static string BuildGitHubRawUrl(string repoUrl, string repoRef, string packSubPath)
    {
        var normalized = repoUrl.TrimEnd('/');
        if (normalized.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized[..^4];
        }

        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var uri))
        {
            return string.Empty;
        }

        if (!string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase))
        {
            return string.Empty;
        }

        var parts = uri.AbsolutePath.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 2)
        {
            return string.Empty;
        }

        return $"https://raw.githubusercontent.com/{parts[0]}/{parts[1]}/{repoRef}/{packSubPath.Trim('/')}/bootstrap-from-git.ps1";
    }

    private static void PrintUsage()
    {
        Console.WriteLine("""
LucanetAgentPackInstaller.exe

Required:
  --repo <git-url>                  Git repository containing the installer pack.

Common:
  --ref <name>                      Git ref, default: main.
  --subpath <path>                  Pack path in repository.
  --require-api-key                 Prompt and require ANTHROPIC_API_KEY.
  --prompt-api-key                  Prompt for ANTHROPIC_API_KEY, allow empty.
  --proxy <url>                     HTTP proxy for bootstrap download and installer.
  --use-git                         Let bootstrap use git clone instead of GitHub zip.
  --bootstrap-url <raw-url>         Explicit raw bootstrap-from-git.ps1 URL.
  --silent                          Reduce installer output.
  --dry-run                         Print intended actions without installing.
  --help                            Show help.

Example:
  LucanetAgentPackInstaller.exe --repo https://github.com/your-org/agent-pack.git --require-api-key
""");
    }

    private sealed record InstallerOptions
    {
        public string PackRepoUrl { get; init; } = string.Empty;
        public string PackRef { get; init; } = DefaultRef;
        public string PackSubPath { get; init; } = DefaultSubPath;
        public string BootstrapUrl { get; init; } = string.Empty;
        public string Proxy { get; init; } = string.Empty;
        public bool UseGit { get; init; }
        public bool PromptApiKey { get; init; }
        public bool RequireApiKey { get; init; }
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
                    case "--repo":
                        options.PackRepoUrl = ReadValue(args, ref i, arg);
                        break;
                    case "--ref":
                        options.PackRef = ReadValue(args, ref i, arg);
                        break;
                    case "--subpath":
                        options.PackSubPath = ReadValue(args, ref i, arg);
                        break;
                    case "--bootstrap-url":
                        options.BootstrapUrl = ReadValue(args, ref i, arg);
                        break;
                    case "--proxy":
                        options.Proxy = ReadValue(args, ref i, arg);
                        break;
                    case "--use-git":
                        options.UseGit = true;
                        break;
                    case "--prompt-api-key":
                        options.PromptApiKey = true;
                        break;
                    case "--require-api-key":
                        options.RequireApiKey = true;
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
                PackRepoUrl = options.PackRepoUrl,
                PackRef = options.PackRef,
                PackSubPath = options.PackSubPath,
                BootstrapUrl = options.BootstrapUrl,
                Proxy = options.Proxy,
                UseGit = options.UseGit,
                PromptApiKey = options.PromptApiKey,
                RequireApiKey = options.RequireApiKey,
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
            public string PackRepoUrl { get; set; } = string.Empty;
            public string PackRef { get; set; } = DefaultRef;
            public string PackSubPath { get; set; } = DefaultSubPath;
            public string BootstrapUrl { get; set; } = string.Empty;
            public string Proxy { get; set; } = string.Empty;
            public bool UseGit { get; set; }
            public bool PromptApiKey { get; set; }
            public bool RequireApiKey { get; set; }
            public bool Silent { get; set; }
            public bool DryRun { get; set; }
            public bool ShowHelp { get; set; }
        }
    }
}
