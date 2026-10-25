$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "[DocLeaf] $Message" -ForegroundColor Red
    exit 1
}

function Has-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-Url([string]$Url) {
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

Write-Host "[DocLeaf] Checking runtime..." -ForegroundColor Cyan
if (-not (Has-Command "node")) { Fail "Node.js was not found. Install Node.js 22 or newer: https://nodejs.org/" }
if (-not (Has-Command "npm")) { Fail "npm was not found. Reinstall Node.js." }
$bridgeExe = Join-Path $PSScriptRoot "integrations\fqapp\docleaf_bridge.exe"
if ((-not (Test-Path -LiteralPath $bridgeExe)) -and (-not (Has-Command "cargo"))) {
    Fail "The prebuilt source service is missing and Rust was not found. Download the Windows package from GitHub Releases."
}

$nodeMajorText = (& node -p "Number(process.versions.node.split('.')[0])").Trim()
if ($LASTEXITCODE -ne 0) { Fail "Unable to detect the Node.js version." }
$nodeMajor = 0
if (-not [int]::TryParse($nodeMajorText, [ref]$nodeMajor)) { Fail "Invalid Node.js version: $nodeMajorText" }
if ($nodeMajor -lt 22) { Fail "Node.js 22 or newer is required. Current version: $(& node -v)" }

if (-not (Test-Path -LiteralPath "node_modules")) {
    Write-Host "[DocLeaf] Installing web dependencies..." -ForegroundColor Cyan
    & npm install
    if ($LASTEXITCODE -ne 0) { Fail "npm install failed." }
}

$projectDir = $PSScriptRoot
if (-not (Test-Url "http://127.0.0.1:8787/health")) {
    if (Test-Path -LiteralPath $bridgeExe) {
        Write-Host "[DocLeaf] Starting the prebuilt Fanqie source service..." -ForegroundColor Cyan
        $bridgeCommand = 'cd /d "' + $projectDir + '" && "' + $bridgeExe + '"'
    }
    else {
        Write-Host "[DocLeaf] Building and starting the Fanqie source service..." -ForegroundColor Cyan
        $bridgeCommand = 'cd /d "' + $projectDir + '" && cargo run --manifest-path integrations/fqapp/rust/Cargo.toml --bin docleaf_bridge'
    }
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", $bridgeCommand) | Out-Null
}
else {
    Write-Host "[DocLeaf] Fanqie source service is already running."
}

if (-not (Test-Url "http://localhost:3000/")) {
    Write-Host "[DocLeaf] Starting the reader..." -ForegroundColor Cyan
    $webCommand = 'cd /d "' + $projectDir + '" && npm run dev'
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", $webCommand) | Out-Null
}
else {
    Write-Host "[DocLeaf] Reader is already running."
}

Write-Host "[DocLeaf] Waiting for services..." -ForegroundColor Cyan
for ($attempt = 1; $attempt -le 180; $attempt++) {
    if ((Test-Url "http://localhost:3000/") -and (Test-Url "http://127.0.0.1:8787/health")) {
        Write-Host "[DocLeaf] Ready: http://localhost:3000/" -ForegroundColor Green
        Start-Process "http://localhost:3000/"
        exit 0
    }
    Start-Sleep -Seconds 1
}

Fail "Startup timed out. Check the two DocLeaf command windows for errors."
