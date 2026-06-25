[CmdletBinding()]
param(
    [string]$ReportPath = "",
    [switch]$RunClaudeDoctor,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function New-Check {
    param(
        [string]$Name,
        [ValidateSet("OK", "WARN", "FAIL")]
        [string]$Status,
        [string]$Detail
    )
    [pscustomobject]@{
        name = $Name
        status = $Status
        detail = $Detail
    }
}

function Add-Check {
    param([pscustomobject]$Check)
    $script:Checks += $Check
    if (-not $Json) {
        $color = "White"
        if ($Check.status -eq "OK") { $color = "Green" }
        elseif ($Check.status -eq "WARN") { $color = "Yellow" }
        elseif ($Check.status -eq "FAIL") { $color = "Red" }
        Write-Host ("[{0}] {1} - {2}" -f $Check.status, $Check.name, $Check.detail) -ForegroundColor $color
    }
}

function Get-CommandDetail {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    return $cmd.Source
}

function Invoke-CommandCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    try {
        $output = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{
            exitCode = $LASTEXITCODE
            output = ($output | Out-String).Trim()
        }
    }
    catch {
        return [pscustomobject]@{
            exitCode = 1
            output = $_.Exception.Message
        }
    }
}

$Checks = @()
$startedAt = (Get-Date).ToUniversalTime().ToString("o")

if ($IsWindows -or $env:OS -eq "Windows_NT") {
    Add-Check (New-Check "windows" "OK" "Windows environment detected.")
}
else {
    Add-Check (New-Check "windows" "FAIL" "This doctor targets native Windows PowerShell.")
}

if ($PSVersionTable.PSVersion.Major -ge 5) {
    Add-Check (New-Check "powershell" "OK" ("PowerShell {0}" -f $PSVersionTable.PSVersion))
}
else {
    Add-Check (New-Check "powershell" "FAIL" ("PowerShell {0}; version 5+ is required." -f $PSVersionTable.PSVersion))
}

$claudePath = Get-CommandDetail "claude"
if ($claudePath) {
    Add-Check (New-Check "claude-path" "OK" $claudePath)
    $version = Invoke-CommandCapture "claude" @("--version")
    if ($version.exitCode -eq 0) {
        Add-Check (New-Check "claude-version" "OK" $version.output)
    }
    else {
        Add-Check (New-Check "claude-version" "FAIL" $version.output)
    }
}
else {
    Add-Check (New-Check "claude-path" "FAIL" "claude command was not found in PATH.")
}

$userBin = Join-Path $env:USERPROFILE ".local\bin"
$pathParts = (($env:PATH -split ";") | Where-Object { $_ -ne "" })
if ($pathParts -contains $userBin) {
    Add-Check (New-Check "user-bin-path" "OK" "$userBin is in current PATH.")
}
else {
    Add-Check (New-Check "user-bin-path" "WARN" "$userBin is not in current PATH; open a new terminal after install.")
}

$gitBash = Join-Path $env:ProgramFiles "Git\bin\bash.exe"
if (Test-Path $gitBash) {
    Add-Check (New-Check "git-bash" "OK" $gitBash)
}
else {
    Add-Check (New-Check "git-bash" "WARN" "Git Bash not found. Claude can still use the PowerShell tool on native Windows.")
}

$settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Raw -Path $settingsPath | ConvertFrom-Json
        $channel = ""
        if ($settings.PSObject.Properties.Name -contains "autoUpdatesChannel") {
            $channel = [string]$settings.autoUpdatesChannel
        }
        if ($channel) {
            Add-Check (New-Check "settings-channel" "OK" "autoUpdatesChannel=$channel")
        }
        else {
            Add-Check (New-Check "settings-channel" "WARN" "settings.json exists but autoUpdatesChannel is not set.")
        }
    }
    catch {
        Add-Check (New-Check "settings-json" "FAIL" $_.Exception.Message)
    }
}
else {
    Add-Check (New-Check "settings-json" "WARN" "$settingsPath does not exist yet.")
}

if ($env:ANTHROPIC_API_KEY) {
    Add-Check (New-Check "anthropic-api-key" "OK" "ANTHROPIC_API_KEY is set in this process.")
}
else {
    Add-Check (New-Check "anthropic-api-key" "WARN" "ANTHROPIC_API_KEY is not set; browser login may still be used.")
}

if ($RunClaudeDoctor -and $claudePath) {
    $doctor = Invoke-CommandCapture "claude" @("doctor")
    if ($doctor.exitCode -eq 0) {
        Add-Check (New-Check "claude-doctor" "OK" $doctor.output)
    }
    else {
        Add-Check (New-Check "claude-doctor" "FAIL" $doctor.output)
    }
}

$failed = @($Checks | Where-Object { $_.status -eq "FAIL" })
$summaryStatus = "passed"
if ($failed.Count -gt 0) { $summaryStatus = "failed" }

$report = [pscustomobject]@{
    schema = "lucanet.agent-pack.claude-cli-windows.doctor/v1"
    startedAt = $startedAt
    finishedAt = (Get-Date).ToUniversalTime().ToString("o")
    status = $summaryStatus
    checks = $Checks
}

if (-not $ReportPath) {
    $reportDir = Join-Path $env:USERPROFILE ".agent-pack\reports"
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $ReportPath = Join-Path $reportDir "claude-cli-windows-doctor-report.json"
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $ReportPath

if ($Json) {
    $report | ConvertTo-Json -Depth 8
}
else {
    Write-Host ("Report: {0}" -f $ReportPath)
}

if ($summaryStatus -eq "failed") { exit 1 }
exit 0
