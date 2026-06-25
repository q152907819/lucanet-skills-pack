# LucaNet Skills Pack

首版只发布 Windows Claude CLI 一键部署包。Skills 后续再追加，避免首版安装链路
和技能资源混在一起。

## Windows Claude CLI 一键部署

用户侧统一入口是一个 EXE：

```powershell
.\LucanetAgentPackInstaller.exe
```

EXE 自带安装脚本和 manifest，不需要用户安装 Git，也不需要访问 private repo
raw 文件。运行到 API key 步骤时会弹出输入框。API key 不写入 Git 文件、
manifest、日志或 doctor report；默认保存为当前 Windows 用户环境变量
`ANTHROPIC_API_KEY`。

网络受限时：

```powershell
.\LucanetAgentPackInstaller.exe --proxy http://127.0.0.1:7890
```

内部开发/兜底 PowerShell 方式仍可用，但 private 仓库下需要 GitHub 访问权限；
普通用户入口不要走这条路：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
irm https://raw.githubusercontent.com/q152907819/lucanet-skills-pack/main/windows/claude-cli/bootstrap-from-git.ps1 -OutFile $env:TEMP\lucanet-skills-pack-bootstrap.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\lucanet-skills-pack-bootstrap.ps1 -PackRepoUrl https://github.com/q152907819/lucanet-skills-pack.git -RequireApiKey
```

## 目录

```text
windows/claude-cli/
  bootstrap-from-git.ps1
  install-claude-cli-windows.ps1
  doctor-claude-cli-windows.ps1
  manifest/claude-cli-windows.json
  exe/
```

## 后续

- 补 Windows 实机 dry-run。
- 将 GitHub Actions 生成的自包含 `LucanetAgentPackInstaller.exe` 发布到 GitHub Release。
- Claude CLI 一键部署稳定后，再追加 skills pack。
