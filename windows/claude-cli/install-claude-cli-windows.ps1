[CmdletBinding()]
param(
    [ValidateSet("native", "winget", "npm")]
    [string]$Method = "native",
    [ValidateSet("latest", "stable")]
    [string]$Channel = "stable",
    [string]$ManifestPath = "",
    [string]$DoctorPath = "",
    [string]$InstallerUrl = "",
    [string]$LocalInstallerPath = "",
    [string]$OfflineClaudeExePath = "",
    [string]$OfflineClaudeChecksum = "",
    [string]$Proxy = "",
    [int]$DownloadRetries = 3,
    [string[]]$FallbackMethods = @("winget", "npm"),
    [ValidateSet("user-env", "process", "none")]
    [string]$ApiKeyStorage = "user-env",
    [switch]$PromptApiKey,
    [switch]$RequireApiKey,
    [switch]$NoFallback,
    [switch]$InstallGitForWindows,
    [switch]$SkipDoctor,
    [switch]$DryRun,
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    if (-not $Silent) {
        Write-Host ("==> {0}" -f $Message) -ForegroundColor Cyan
    }
}

function Write-Warn {
    param([string]$Message)
    Write-Host ("WARN: {0}" -f $Message) -ForegroundColor Yellow
}

function Convert-SecureStringToPlainText {
    param([securestring]$SecureValue)
    if ($null -eq $SecureValue) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Show-ApiKeyDialog {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Claude API Key"
        $form.StartPosition = "CenterScreen"
        $form.Width = 520
        $form.Height = 190
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.TopMost = $true

        $label = New-Object System.Windows.Forms.Label
        $label.Left = 20
        $label.Top = 20
        $label.Width = 460
        $label.Height = 36
        $label.Text = "Enter Anthropic API key. The value is hidden and will be stored in your Windows user environment."
        $form.Controls.Add($label)

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Left = 20
        $textBox.Top = 62
        $textBox.Width = 460
        $textBox.UseSystemPasswordChar = $true
        $form.Controls.Add($textBox)

        $okButton = New-Object System.Windows.Forms.Button
        $okButton.Left = 300
        $okButton.Top = 105
        $okButton.Width = 80
        $okButton.Text = "OK"
        $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.AcceptButton = $okButton
        $form.Controls.Add($okButton)

        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Left = 400
        $cancelButton.Top = 105
        $cancelButton.Width = 80
        $cancelButton.Text = "Cancel"
        $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.CancelButton = $cancelButton
        $form.Controls.Add($cancelButton)

        $result = $form.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            return ""
        }
        return $textBox.Text
    }
    catch {
        Write-Warn ("API key dialog unavailable, falling back to console prompt: {0}" -f $_.Exception.Message)
        $secureKey = Read-Host "Enter Anthropic API key (input hidden; leave empty to skip)" -AsSecureString
        return Convert-SecureStringToPlainText -SecureValue $secureKey
    }
}

function New-TimeStamp {
    return (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}

function Invoke-LoggedCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    $display = "$FilePath $($Arguments -join ' ')"
    Write-Step $display
    if ($DryRun) { return }
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $display"
    }
}

function Invoke-DownloadWithRetry {
    param(
        [string]$Uri,
        [string]$OutFile,
        [int]$Retries,
        [string]$ProxyUrl
    )
    $attempt = 1
    $maxAttempts = [Math]::Max(1, $Retries)
    while ($attempt -le $maxAttempts) {
        try {
            Write-Step ("Downloading {0} attempt {1}/{2}" -f $Uri, $attempt, $maxAttempts)
            if ($DryRun) { return }
            $args = @{
                UseBasicParsing = $true
                Uri = $Uri
                OutFile = $OutFile
            }
            if ($ProxyUrl) {
                $args.Proxy = $ProxyUrl
            }
            Invoke-WebRequest @args
            return
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                throw
            }
            Write-Warn ("Download failed: {0}" -f $_.Exception.Message)
            Start-Sleep -Seconds ([Math]::Min(10, 2 * $attempt))
            $attempt += 1
        }
    }
}

function Backup-IfExists {
    param(
        [string]$Path,
        [string]$BackupRoot
    )
    if (Test-Path $Path) {
        New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
        $leaf = Split-Path -Leaf $Path
        $target = Join-Path $BackupRoot $leaf
        Copy-Item -Path $Path -Destination $target -Force
        Write-Step "Backed up $Path to $target"
    }
}

function Add-UserPathEntry {
    param([string]$Entry)
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $current) { $current = "" }
    $parts = @($current -split ";" | Where-Object { $_ -ne "" })
    if ($parts -contains $Entry) {
        Write-Step "User PATH already contains $Entry"
        return
    }
    $next = (($parts + $Entry) -join ";")
    Write-Step "Adding $Entry to user PATH"
    if (-not $DryRun) {
        [Environment]::SetEnvironmentVariable("Path", $next, "User")
        $env:PATH = "$env:PATH;$Entry"
    }
}

function Set-ClaudeSettings {
    param(
        [string]$ChannelValue,
        [bool]$ConfigureGitBash,
        [string]$BackupRoot
    )
    $settingsDir = Join-Path $env:USERPROFILE ".claude"
    $settingsPath = Join-Path $settingsDir "settings.json"
    Write-Step "Configuring $settingsPath"
    if ($DryRun) { return }

    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    Backup-IfExists -Path $settingsPath -BackupRoot $BackupRoot

    $settings = [pscustomobject]@{}
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content -Raw -Path $settingsPath | ConvertFrom-Json
        }
        catch {
            $brokenBackup = Join-Path $BackupRoot "settings.invalid.json"
            Copy-Item -Path $settingsPath -Destination $brokenBackup -Force
            Write-Warn "Existing settings.json is invalid JSON; copied to $brokenBackup and starting from an empty object."
            $settings = [pscustomobject]@{}
        }
    }

    Add-Member -InputObject $settings -NotePropertyName "autoUpdatesChannel" -NotePropertyValue $ChannelValue -Force

    if ($ConfigureGitBash) {
        $gitBash = Join-Path $env:ProgramFiles "Git\bin\bash.exe"
        if (Test-Path $gitBash) {
            $envIsObject = ($settings.PSObject.Properties.Name -contains "env") -and
                ($null -ne $settings.env) -and
                ($settings.env -is [pscustomobject])
            if (-not $envIsObject) {
                Add-Member -InputObject $settings -NotePropertyName "env" -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            Add-Member -InputObject $settings.env -NotePropertyName "CLAUDE_CODE_GIT_BASH_PATH" -NotePropertyValue $gitBash -Force
        }
        else {
            Write-Warn "Git Bash was requested but not found at $gitBash"
        }
    }

    $settings | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $settingsPath
}

function Set-ClaudeApiKey {
    param(
        [string]$Storage,
        [bool]$Prompt,
        [bool]$Required
    )
    if ($Storage -eq "none") {
        Write-Step "Skipping API key storage because ApiKeyStorage=none"
        return
    }

    $existingUserKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")
    if ($env:ANTHROPIC_API_KEY -or $existingUserKey) {
        Write-Step "ANTHROPIC_API_KEY already exists; keeping existing value."
        if (-not $env:ANTHROPIC_API_KEY -and $existingUserKey) {
            $env:ANTHROPIC_API_KEY = $existingUserKey
        }
        return
    }

    if (-not $Prompt -and -not $Required) {
        Write-Warn "ANTHROPIC_API_KEY is not set. Run claude for browser login, or rerun with -PromptApiKey."
        return
    }

    if ($Silent -and $Required) {
        throw "ANTHROPIC_API_KEY is required but cannot be prompted in -Silent mode. Set it before running the installer."
    }
    if ($Silent) {
        Write-Warn "Skipping API key prompt in -Silent mode."
        return
    }

    $plainKey = Show-ApiKeyDialog
    if (-not $plainKey) {
        if ($Required) {
            throw "API key is required."
        }
        Write-Warn "No API key entered; browser login can still be used."
        return
    }

    if ($Storage -eq "user-env") {
        [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $plainKey, "User")
        $env:ANTHROPIC_API_KEY = $plainKey
        Write-Step "Stored ANTHROPIC_API_KEY in the current user's environment."
    }
    elseif ($Storage -eq "process") {
        $env:ANTHROPIC_API_KEY = $plainKey
        Write-Step "Stored ANTHROPIC_API_KEY for this process only."
    }
}

function Install-ClaudeNative {
    param(
        [string]$Url,
        [string]$LocalPath,
        [string]$ProxyUrl,
        [int]$Retries
    )
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-install-{0}.ps1" -f (New-TimeStamp))
    if ($LocalPath) {
        Write-Step "Using local native installer $LocalPath"
        if (-not $DryRun) {
            if (-not (Test-Path $LocalPath)) {
                throw "Local installer was not found: $LocalPath"
            }
            Copy-Item -Path $LocalPath -Destination $temp -Force
        }
    }
    else {
        Write-Step "Using native installer URL $Url"
        Invoke-DownloadWithRetry -Uri $Url -OutFile $temp -Retries $Retries -ProxyUrl $ProxyUrl
    }
    if ($DryRun) { return }
    try {
        Invoke-LoggedCommand -FilePath "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $temp)
    }
    finally {
        Remove-Item -Path $temp -Force -ErrorAction SilentlyContinue
    }
}

function Install-ClaudeOfflinePayload {
    param(
        [string]$PayloadPath,
        [string]$ExpectedChecksum,
        [string]$TargetChannel
    )
    if (-not $PayloadPath) {
        throw "OfflineClaudeExePath is required for offline install."
    }
    if (-not (Test-Path $PayloadPath)) {
        throw "Offline Claude payload was not found: $PayloadPath"
    }

    if ($ExpectedChecksum) {
        $actualChecksum = (Get-FileHash -Path $PayloadPath -Algorithm SHA256).Hash.ToLower()
        if ($actualChecksum -ne $ExpectedChecksum.ToLower()) {
            throw "Offline Claude payload checksum mismatch. Expected $ExpectedChecksum, got $actualChecksum."
        }
        Write-Step "Offline Claude payload checksum verified."
    }
    else {
        Write-Warn "Offline Claude payload checksum was not provided; skipping checksum verification."
    }

    Invoke-LoggedCommand -FilePath $PayloadPath -Arguments @("install", $TargetChannel)
}

function Install-ClaudeWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget was not found. Use -Method native or install App Installer first."
    }
    Invoke-LoggedCommand -FilePath "winget" -Arguments @(
        "install",
        "--id", "Anthropic.ClaudeCode",
        "-e",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
}

function Install-ClaudeNpm {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm was not found. Install Node.js 18+ or use -Method native."
    }
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeVersionText = (& node --version 2>$null).TrimStart("v")
        $nodeMajor = [int]($nodeVersionText.Split(".")[0])
        if ($nodeMajor -lt 18) {
            throw "Node.js 18+ is required for npm install; found $nodeVersionText."
        }
    }
    Invoke-LoggedCommand -FilePath "npm" -Arguments @("install", "-g", "@anthropic-ai/claude-code@latest")
}

function Install-ClaudeByMethod {
    param([string]$InstallMethod)
    switch ($InstallMethod) {
        "offline" {
            Install-ClaudeOfflinePayload -PayloadPath $OfflineClaudeExePath -ExpectedChecksum $OfflineClaudeChecksum -TargetChannel $Channel
        }
        "native" {
            Install-ClaudeNative -Url $InstallerUrl -LocalPath $LocalInstallerPath -ProxyUrl $Proxy -Retries $DownloadRetries
        }
        "winget" { Install-ClaudeWinget }
        "npm" { Install-ClaudeNpm }
        default { throw "Unsupported install method: $InstallMethod" }
    }
}

if (-not ($IsWindows -or $env:OS -eq "Windows_NT")) {
    throw "This installer targets native Windows PowerShell."
}

$scriptRoot = ""
if ($MyInvocation.MyCommand.Path) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $scriptRoot = (Get-Location).Path
}
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $scriptRoot "manifest\claude-cli-windows.json"
}

if (Test-Path $ManifestPath) {
    Write-Step "Reading manifest $ManifestPath"
    $manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
    if ($PSBoundParameters.ContainsKey("Method") -eq $false -and $manifest.install.defaultMethod) {
        $Method = [string]$manifest.install.defaultMethod
    }
    if ($PSBoundParameters.ContainsKey("Channel") -eq $false -and $manifest.install.defaultChannel) {
        $Channel = [string]$manifest.install.defaultChannel
    }
    if (-not $InstallerUrl -and $manifest.install.nativeInstallerUrl) {
        $InstallerUrl = [string]$manifest.install.nativeInstallerUrl
    }
    if (-not $Proxy -and $manifest.network.proxy) {
        $Proxy = [string]$manifest.network.proxy
    }
    if ($PSBoundParameters.ContainsKey("DownloadRetries") -eq $false -and $manifest.network.downloadRetries) {
        $DownloadRetries = [int]$manifest.network.downloadRetries
    }
    if ($PSBoundParameters.ContainsKey("FallbackMethods") -eq $false -and $manifest.network.fallbackMethods) {
        $FallbackMethods = @($manifest.network.fallbackMethods | ForEach-Object { [string]$_ })
    }
    if ($PSBoundParameters.ContainsKey("ApiKeyStorage") -eq $false -and $manifest.auth.apiKeyStorage) {
        $ApiKeyStorage = [string]$manifest.auth.apiKeyStorage
    }
    if ($manifest.auth.promptApiKeyByDefault -and -not $PSBoundParameters.ContainsKey("PromptApiKey")) {
        $PromptApiKey = $true
    }
}
else {
    Write-Warn "Manifest not found: $ManifestPath"
}

if ($OfflineClaudeExePath) {
    $Method = "offline"
}

if (-not $InstallerUrl) {
    $InstallerUrl = "https://claude.ai/install.ps1"
}

$backupRoot = Join-Path $env:USERPROFILE (".agent-pack\backup\{0}" -f (New-TimeStamp))
$reportDir = Join-Path $env:USERPROFILE ".agent-pack\reports"
$userBin = Join-Path $env:USERPROFILE ".local\bin"

Write-Step "Claude CLI Windows install method=$Method channel=$Channel"
Write-Step "Backup root: $backupRoot"
if ($Proxy) {
    Write-Step "Download proxy: $Proxy"
}

if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
}

Add-UserPathEntry -Entry $userBin
Set-ClaudeApiKey -Storage $ApiKeyStorage -Prompt:$PromptApiKey -Required:$RequireApiKey

if ($InstallGitForWindows) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Invoke-LoggedCommand -FilePath "winget" -Arguments @(
            "install",
            "--id", "Git.Git",
            "-e",
            "--accept-package-agreements",
            "--accept-source-agreements"
        )
    }
    else {
        Write-Warn "winget not found; skipping Git for Windows installation."
    }
}

try {
    Install-ClaudeByMethod -InstallMethod $Method
}
catch {
    $primaryError = $_.Exception.Message
    if ($NoFallback -or $Method -ne "native" -or $FallbackMethods.Count -eq 0) {
        throw
    }
    Write-Warn "Primary native install failed: $primaryError"
    $fallbackSucceeded = $false
    foreach ($fallback in $FallbackMethods) {
        if ($fallback -eq "native" -or -not $fallback) { continue }
        try {
            Write-Warn "Trying fallback install method: $fallback"
            Install-ClaudeByMethod -InstallMethod $fallback
            $fallbackSucceeded = $true
            break
        }
        catch {
            Write-Warn ("Fallback {0} failed: {1}" -f $fallback, $_.Exception.Message)
        }
    }
    if (-not $fallbackSucceeded) {
        throw "All install methods failed. Primary native error: $primaryError"
    }
}

Set-ClaudeSettings -ChannelValue $Channel -ConfigureGitBash:$true -BackupRoot $backupRoot

if (-not $SkipDoctor) {
    $doctor = $DoctorPath
    if (-not $doctor) {
        $doctor = Join-Path $scriptRoot "doctor-claude-cli-windows.ps1"
    }
    if (Test-Path $doctor) {
        $doctorReport = Join-Path $reportDir "claude-cli-windows-doctor-report.json"
        Write-Step "Running doctor"
        if (-not $DryRun) {
            $doctorText = [System.IO.File]::ReadAllText($doctor)
            $doctorBlock = [ScriptBlock]::Create($doctorText)
            & $doctorBlock @{ ReportPath = $doctorReport }
            if ($LASTEXITCODE -ne 0) {
                throw "Doctor reported failures. See $doctorReport"
            }
        }
    }
    else {
        Write-Warn "Doctor script not found: $doctor"
    }
}

Write-Step "Done. Open a new terminal and run: claude --version"
