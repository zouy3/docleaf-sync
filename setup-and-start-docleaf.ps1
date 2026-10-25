$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "[DocLeaf] $Message" -ForegroundColor Red
    exit 1
}

function Has-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $cargoPath = Join-Path $env:USERPROFILE ".cargo\bin"
    $env:Path = "$machinePath;$userPath;$cargoPath"
}

function Install-WingetPackage([string]$Id, [string]$Label, [string[]]$ExtraArguments = @()) {
    Write-Host "[DocLeaf] Installing $Label..." -ForegroundColor Cyan
    $arguments = @(
        "install", "--id", $Id, "--exact", "--source", "winget",
        "--accept-package-agreements", "--accept-source-agreements"
    ) + $ExtraArguments
    & winget @arguments
    if ($LASTEXITCODE -ne 0) { Fail "$Label installation failed (winget exit code $LASTEXITCODE)." }
    Refresh-Path
}

Write-Host "[DocLeaf] Automatic Windows setup" -ForegroundColor Cyan
if (-not (Has-Command "winget")) {
    Fail "winget was not found. Install or update 'App Installer' from Microsoft Store, then run this file again."
}

if (-not (Has-Command "node")) {
    Install-WingetPackage "OpenJS.NodeJS.LTS" "Node.js LTS"
}

Refresh-Path
$bridgeExe = Join-Path $PSScriptRoot "integrations\fqapp\docleaf_bridge.exe"
$needsBuildTools = -not (Test-Path -LiteralPath $bridgeExe)

if ($needsBuildTools -and (-not (Has-Command "cargo"))) {
    Install-WingetPackage "Rustlang.Rustup" "Rust"
    Refresh-Path
    if (Has-Command "rustup") {
        & rustup default stable
        if ($LASTEXITCODE -ne 0) { Fail "Rust stable toolchain installation failed." }
    }
}

$hasCppTools = $false
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path -LiteralPath $vswhere) {
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $hasCppTools = -not [string]::IsNullOrWhiteSpace(($installation | Out-String))
}

if ($needsBuildTools -and (-not $hasCppTools)) {
    Install-WingetPackage `
        "Microsoft.VisualStudio.2022.BuildTools" `
        "Visual Studio C++ Build Tools" `
        @("--override", "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended")
}

Refresh-Path
Write-Host "[DocLeaf] Runtime setup is complete. Starting DocLeaf..." -ForegroundColor Green
& (Join-Path $PSScriptRoot "start-docleaf.ps1")
exit $LASTEXITCODE
