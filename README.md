# LucaNet Skills Pack

首版只发布 Windows Claude CLI 一键部署包。Skills 后续再追加，避免首版安装链路
和技能资源混在一起。

## Windows Claude CLI 一键部署

PowerShell 方式：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
irm https://raw.githubusercontent.com/q152907819/lucanet-skills-pack/main/windows/claude-cli/bootstrap-from-git.ps1 -OutFile $env:TEMP\lucanet-skills-pack-bootstrap.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\lucanet-skills-pack-bootstrap.ps1 -PackRepoUrl https://github.com/q152907819/lucanet-skills-pack.git -RequireApiKey
```

EXE 方式：

```powershell
.\LucanetAgentPackInstaller.exe --repo https://github.com/q152907819/lucanet-skills-pack.git --require-api-key
```

运行到 API key 步骤时会弹出输入框。API key 不写入 Git 文件、manifest、日志或
doctor report；默认保存为当前 Windows 用户环境变量 `ANTHROPIC_API_KEY`。

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
- 构建并发布 `LucanetAgentPackInstaller.exe` 到 GitHub Release。
- Claude CLI 一键部署稳定后，再追加 skills pack。
