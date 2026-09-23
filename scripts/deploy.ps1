# deploy.ps1 — Generate secrets, configure Pulumi, and run pulumi up.
# Run with: pwsh -File scripts\deploy.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red; exit 1 }

# Ensure Pulumi is on PATH (may have been just installed)
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + `
            [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + `
            "$env:USERPROFILE\.pulumi\bin"

$env:PULUMI_BACKEND_URL = "file://$RepoRoot/.pulumi-state"

# ── 1. Generate strong passwords if not already set ───────────────────────
Write-Step "Configuring Pulumi secrets..."

Push-Location "$RepoRoot\pulumi"
try {
    pulumi stack select dev 2>&1 | Out-Null

    # Check if keycloakAdminPassword is set
    $existingSecrets = pulumi config 2>&1
    if ($existingSecrets -notmatch "keycloakAdminPassword") {
        Write-Step "Generating strong admin password..."
        $AdminPassword = -join ((65..90) + (97..122) + (48..57) + @(33,35,36,37,42,43,45,61) |
            Get-Random -Count 24 | ForEach-Object { [char]$_ })
        pulumi config set --secret keycloakAdminPassword $AdminPassword
        Write-OK "Admin password generated and stored as Pulumi secret."
    } else {
        Write-OK "Admin password already configured."
    }

    if ($existingSecrets -notmatch "postgresPassword") {
        Write-Step "Generating strong PostgreSQL password..."
        $PgPassword = -join ((65..90) + (97..122) + (48..57) |
            Get-Random -Count 20 | ForEach-Object { [char]$_ })
        pulumi config set --secret postgresPassword $PgPassword
        Write-OK "PostgreSQL password generated and stored as Pulumi secret."
    } else {
        Write-OK "PostgreSQL password already configured."
    }

    # ── 2. Set namespace and hostname ─────────────────────────────────────
    pulumi config set keycloak-kubernetes-pulumi:namespace keycloak
    pulumi config set keycloak-kubernetes-pulumi:hostname keycloak.local

    # ── 3. Run pulumi up ──────────────────────────────────────────────────
    Write-Step "Running pulumi up (deploying all resources)..."
    Write-Host "    This deploys: namespace, secrets, TLS cert, PostgreSQL, Keycloak, NetworkPolicies"

    pulumi up --yes --skip-preview

    if ($LASTEXITCODE -ne 0) { Write-Fail "pulumi up failed." }
    Write-OK "pulumi up succeeded."

    # ── 4. Show stack outputs ─────────────────────────────────────────────
    Write-Step "Stack outputs:"
    pulumi stack output

} finally {
    Pop-Location
}

# ── 5. Wait for pods to become Ready ─────────────────────────────────────
Write-Step "Waiting for Keycloak pod to become Ready (may take 3-5 mins)..."
$timeout = 600
$interval = 15
$elapsed = 0

while ($elapsed -lt $timeout) {
    $ready = kubectl get pods -n keycloak -l "app.kubernetes.io/name=keycloak" `
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1
    if ($ready -eq "True") {
        Write-OK "Keycloak pod is Ready."
        break
    }
    $phase = kubectl get pods -n keycloak -l "app.kubernetes.io/name=keycloak" `
        -o jsonpath='{.items[0].status.phase}' 2>&1
    Write-Warn "Keycloak pod not ready yet ($phase) — waiting... (${elapsed}s/${timeout}s)"
    Start-Sleep -Seconds $interval
    $elapsed += $interval
}

if ($elapsed -ge $timeout) {
    Write-Warn "Keycloak pod not ready within ${timeout}s — run 'make status' or check logs."
}

Write-Host "`n=====================================" -ForegroundColor Green
Write-Host "  Deployment complete!" -ForegroundColor Green
Write-Host "  URL:  https://keycloak.local" -ForegroundColor Cyan
Write-Host "  User: admin" -ForegroundColor Cyan
Write-Host "  Pass: make credentials" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Green
