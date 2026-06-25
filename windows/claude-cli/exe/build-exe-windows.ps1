[CmdletBinding()]
param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",
    [string]$Configuration = "Release",
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $scriptRoot "LucanetAgentPackInstaller.csproj"
if (-not $OutputDir) {
    $OutputDir = Join-Path $scriptRoot "dist\$Runtime"
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK was not found. Install .NET 8 SDK first."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

dotnet publish $project `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:PublishTrimmed=true `
    -p:EnableCompressionInSingleFile=true `
    -o $OutputDir

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed."
}

$exe = Join-Path $OutputDir "LucanetAgentPackInstaller.exe"
if (-not (Test-Path $exe)) {
    throw "Expected exe was not produced: $exe"
}

Write-Host "Built: $exe"
