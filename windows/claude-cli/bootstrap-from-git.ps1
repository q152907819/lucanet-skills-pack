[CmdletBinding()]
param(
    [string]$PackRepoUrl = "",
    [string]$PackRef = "main",
    [string]$PackSubPath = "windows/claude-cli",
    [string]$InstallRoot = "",
    [string]$Proxy = "",
    [switch]$UseGit,
    [switch]$PromptApiKey,
    [switch]$RequireApiKey,
    [switch]$Silent,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    if (-not $Silent) {
        Write-Host ("==> {0}" -f $Message) -ForegroundColor Cyan
    }
}

function New-TimeStamp {
    return (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}

function Invoke-Download {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$ProxyUrl
    )
    $args = @{
        UseBasicParsing = $true
        Uri = $Uri
        OutFile = $OutFile
    }
    if ($ProxyUrl) {
        $args.Proxy = $ProxyUrl
    }
    Invoke-WebRequest @args
}

function Convert-GitHubRepoToZipUrl {
    param(
        [string]$RepoUrl,
        [string]$Ref
    )
    $normalized = $RepoUrl.TrimEnd("/")
    if ($normalized -match "^https://github\.com/([^/]+)/([^/]+?)(\.git)?$") {
        $owner = $Matches[1]
        $repo = $Matches[2]
        return "https://github.com/$owner/$repo/archive/refs/heads/$Ref.zip"
    }
    return ""
}

if (-not ($IsWindows -or $env:OS -eq "Windows_NT")) {
    throw "This bootstrap targets native Windows PowerShell."
}

if (-not $PackRepoUrl) {
    throw "PackRepoUrl is required. Example: -PackRepoUrl https://github.com/your-org/agent-pack.git"
}

if (-not $InstallRoot) {
    $InstallRoot = Join-Path $env:USERPROFILE ".agent-pack\packs\claude-cli-windows"
}

Write-Step "Installing pack from $PackRepoUrl ref=$PackRef"
Write-Step "Install root: $InstallRoot"

if ($DryRun) {
    Write-Step "DryRun enabled; no files will be downloaded."
    exit 0
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

if ($UseGit) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git was not found. Install Git or run without -UseGit to use GitHub zip download."
    }
    if (Test-Path (Join-Path $InstallRoot ".git")) {
        Write-Step "Updating existing git checkout"
        & git -C $InstallRoot fetch --all --prune
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
        & git -C $InstallRoot checkout $PackRef
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed" }
        & git -C $InstallRoot pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw "git pull failed" }
    }
    else {
        Write-Step "Cloning pack repository"
        & git clone --branch $PackRef --depth 1 $PackRepoUrl $InstallRoot
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
    $packDir = Join-Path $InstallRoot $PackSubPath
}
else {
    $zipUrl = Convert-GitHubRepoToZipUrl -RepoUrl $PackRepoUrl -Ref $PackRef
    if (-not $zipUrl) {
        throw "Zip download only supports GitHub repository URLs. Use -UseGit for other Git servers."
    }
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-pack-{0}" -f (New-TimeStamp))
    $zipPath = Join-Path $tmpRoot "pack.zip"
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    Write-Step "Downloading $zipUrl"
    Invoke-Download -Uri $zipUrl -OutFile $zipPath -ProxyUrl $Proxy
    Write-Step "Expanding pack zip"
    Expand-Archive -Path $zipPath -DestinationPath $tmpRoot -Force
    $expandedRoot = Get-ChildItem -Path $tmpRoot -Directory | Where-Object { $_.Name -ne "__MACOSX" } | Select-Object -First 1
    if ($null -eq $expandedRoot) {
        throw "Could not find expanded repository root in $tmpRoot"
    }
    $sourcePackDir = Join-Path $expandedRoot.FullName $PackSubPath
    if (-not (Test-Path $sourcePackDir)) {
        throw "Pack subpath was not found in repository: $PackSubPath"
    }
    Remove-Item -Path $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    Copy-Item -Path (Join-Path $sourcePackDir "*") -Destination $InstallRoot -Recurse -Force
    Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    $packDir = $InstallRoot
}

$installer = Join-Path $packDir "install-claude-cli-windows.ps1"
if (-not (Test-Path $installer)) {
    throw "Installer was not found: $installer"
}

$args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer)
if ($Proxy) { $args += @("-Proxy", $Proxy) }
if ($PromptApiKey) { $args += "-PromptApiKey" }
if ($RequireApiKey) { $args += "-RequireApiKey" }
if ($Silent) { $args += "-Silent" }

Write-Step "Running installer from pack"
& powershell.exe @args
if ($LASTEXITCODE -ne 0) {
    throw "Pack installer failed with exit code $LASTEXITCODE"
}
