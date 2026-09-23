# destroy.ps1 — Tear down all deployed resources and optionally the k3d cluster.
# Run with: pwsh -File scripts\destroy.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$CLUSTER_NAME = "keycloak-cluster"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + `
            [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + `
            "$env:USERPROFILE\.pulumi\bin"
$env:PULUMI_BACKEND_URL = "file://$RepoRoot/.pulumi-state"

# ── 1. Pulumi destroy ─────────────────────────────────────────────────────
Write-Step "Running pulumi destroy..."

Push-Location "$RepoRoot\pulumi"
try {
    pulumi stack select dev 2>&1 | Out-Null
    pulumi destroy --yes --skip-preview 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Pulumi resources destroyed."
    } else {
        Write-Warn "pulumi destroy had errors — continuing with cluster teardown."
    }
} finally {
    Pop-Location
}

# ── 2. Optionally delete k3d cluster ─────────────────────────────────────
Write-Step "Delete k3d cluster '$CLUSTER_NAME'? (y/N)"
$answer = Read-Host
if ($answer -match "^[yY]") {
    k3d cluster delete $CLUSTER_NAME 2>&1
    Write-OK "k3d cluster '$CLUSTER_NAME' deleted."
} else {
    Write-Warn "Skipping cluster deletion. Run 'k3d cluster delete $CLUSTER_NAME' manually."
}

# ── 3. Clean up local state (optional) ───────────────────────────────────
Write-Step "Remove local Pulumi state? (y/N)"
$answer = Read-Host
if ($answer -match "^[yY]") {
    Remove-Item -Recurse -Force "$RepoRoot\.pulumi-state" -ErrorAction SilentlyContinue
    Write-OK "Local Pulumi state removed."
}

Write-Host "`n=====================================" -ForegroundColor Green
Write-Host "  Destroy complete." -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green
