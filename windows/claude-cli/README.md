# Windows Claude CLI 一键安装器

本目录提供一个最小可交付的 Windows Claude Code CLI 安装包雏形。第一版先做
PowerShell 入口，后续可以把同一套脚本和 manifest 包进 `.exe` bootstrapper。

## 文件

| 文件 | 作用 |
| --- | --- |
| `bootstrap-from-git.ps1` | 从 Git 仓库拉取完整 pack 后执行安装。 |
| `install-claude-cli-windows.ps1` | 一键安装 Claude Code CLI，默认使用官方 native installer。 |
| `doctor-claude-cli-windows.ps1` | 安装后检查 PowerShell、Claude CLI、Git Bash、settings 和可选 API key。 |
| `manifest/claude-cli-windows.json` | 默认安装声明，供脚本和未来 exe 包装器读取。 |
| `exe/` | .NET 8 单文件 exe bootstrapper 源码和构建脚本。 |

## 快速使用

普通用户推荐使用 Release 里的 `LucanetAgentPackInstaller.exe`。下面的 PowerShell
bootstrap 只作为内部开发/兜底方式；private 仓库下需要 GitHub 访问权限。
GitHub 示例：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
irm https://raw.githubusercontent.com/<org>/<repo>/main/windows/claude-cli/bootstrap-from-git.ps1 -OutFile $env:TEMP\agent-pack-bootstrap.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\agent-pack-bootstrap.ps1 -PackRepoUrl https://github.com/<org>/<repo>.git -RequireApiKey
```

如果用户已经拿到整个仓库，也可以在 Windows PowerShell 里进入本目录后执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-claude-cli-windows.ps1 -RequireApiKey
```

安装后检查：

```powershell
.\doctor-claude-cli-windows.ps1
```

静默模式示例：

```powershell
.\install-claude-cli-windows.ps1 -Silent -Channel stable
```

只预览动作，不实际安装：

```powershell
.\install-claude-cli-windows.ps1 -DryRun
```

## API key 输入

安装器默认支持中途输入 API key：

```powershell
.\install-claude-cli-windows.ps1 -PromptApiKey
```

强制必须输入：

```powershell
.\install-claude-cli-windows.ps1 -RequireApiKey
```

默认保存到当前 Windows 用户环境变量：

```text
ANTHROPIC_API_KEY
```

安全边界：

- 输入优先使用 Windows 弹窗，输入框会隐藏内容；如果弹窗不可用，才回退到
  PowerShell hidden prompt。
- 不把 API key 写入仓库文件、manifest、doctor report 或日志。
- 如果用户环境变量里已经有 `ANTHROPIC_API_KEY`，安装器会复用，不覆盖。
- `-ApiKeyStorage process` 只在当前安装进程中设置。
- `-ApiKeyStorage none` 跳过保存，可让用户后续浏览器登录。

## Git 托管资源模式

推荐仓库结构保持如下路径：

```text
windows/claude-cli/
  bootstrap-from-git.ps1
  install-claude-cli-windows.ps1
  doctor-claude-cli-windows.ps1
  manifest/claude-cli-windows.json
```

GitHub zip 下载模式不要求用户预装 Git；其它 Git 服务可用 `-UseGit`：

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap-from-git.ps1 `
  -PackRepoUrl https://git.example.com/agent-pack.git `
  -UseGit `
  -RequireApiKey
```

## EXE 形式

EXE 是自包含入口：它不嵌入 API key，但会内嵌安装脚本、doctor、manifest 和
Claude CLI Windows x64 离线 payload。用户运行 EXE 时不需要安装 Git，也不需要
访问 private repo raw 文件或 `downloads.claude.ai`。

在 Windows 上安装 .NET 8 SDK 后构建：

```powershell
.\exe\build-exe-windows.ps1 -Runtime win-x64
```

产物位置：

```text
exe\dist\win-x64\LucanetAgentPackInstaller.exe
```

用户运行：

```powershell
.\LucanetAgentPackInstaller.exe
```

运行到 API key 步骤时会弹出输入框，用户只需要填一次 key。

网络受限时：

```powershell
.\LucanetAgentPackInstaller.exe --proxy http://127.0.0.1:7890
```

默认离线路径不需要代理；`--proxy` 只用于显式在线 fallback。

非 GitHub 仓库可显式传 raw bootstrap URL：

```powershell
.\LucanetAgentPackInstaller.exe --installer-url https://mirror.example.com/claude/install.ps1
```

## 安装策略

默认使用 Anthropic 官方 native installer：

```powershell
irm https://claude.ai/install.ps1 | iex
```

脚本实际执行时会先下载到本机临时文件再运行，便于记录日志和失败定位。
可显式选择其它方法：

```powershell
.\install-claude-cli-windows.ps1 -Method winget
.\install-claude-cli-windows.ps1 -Method npm
```

官方说明里，native installer 支持后台自动更新；WinGet 由包管理器负责更新；
npm 需要 Node.js 18+ 且必须允许 optional dependencies。

## 网络受限环境

如果 `https://claude.ai/install.ps1` 访问不稳定，不要依赖单一路径。脚本默认
会在 native 下载/执行失败后依次尝试 `winget` 和 `npm`：

```powershell
.\install-claude-cli-windows.ps1
```

企业代理：

```powershell
.\install-claude-cli-windows.ps1 -Proxy http://127.0.0.1:7890
```

企业内网镜像：

```powershell
.\install-claude-cli-windows.ps1 -InstallerUrl https://mirror.example.com/claude/install.ps1
```

提前下载好的离线 installer：

```powershell
.\install-claude-cli-windows.ps1 -LocalInstallerPath C:\Installers\claude-install.ps1
```

只用 WinGet，绕开官方脚本下载：

```powershell
.\install-claude-cli-windows.ps1 -Method winget
```

只用 npm，绕开官方脚本下载：

```powershell
.\install-claude-cli-windows.ps1 -Method npm
```

禁用自动 fallback：

```powershell
.\install-claude-cli-windows.ps1 -NoFallback
```

## 安全边界

- 不内置、不写死任何 API key。
- 不删除现有 `~\.claude` 配置。
- 修改 `~\.claude\settings.json` 前会备份到
  `~\.agent-pack\backup\<timestamp>\`。
- 默认不要求管理员权限。
- 默认不安装 Git for Windows，只在 `-InstallGitForWindows` 时尝试通过
  WinGet 安装。

## 当前依据

- Claude Code Windows native install: `https://claude.ai/install.ps1`
- Claude Code WinGet package id: `Anthropic.ClaudeCode`
- Claude Code npm package: `@anthropic-ai/claude-code`
- 官方 setup 文档：`https://code.claude.com/docs/en/setup`
