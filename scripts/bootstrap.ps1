# bootstrap.ps1 — Install prerequisites, start Docker, create k3d cluster, add hosts entry.
# Run with: pwsh -File scripts\bootstrap.ps1
# Must be run from the repo root.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CLUSTER_NAME  = "keycloak-cluster"
$K3D_API_PORT  = "6443"
$LB_HTTP_PORT  = "8080"
$LB_HTTPS_PORT = "8443"
$HOSTNAME      = "keycloak.local"
$NAMESPACE     = "keycloak"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red; exit 1 }
function Write-Warn { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }

# ── 0. Locate repo root ────────────────────────────────────────────────────
$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Step "Repository root: $RepoRoot"

# ── 1. Check required tools ────────────────────────────────────────────────
Write-Step "Checking required tools..."

foreach ($tool in @("kubectl","helm","git","go","k3d")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fail "$tool not found in PATH. Please install it."
    }
    Write-OK "$tool found: $(& $tool version 2>&1 | Select-Object -First 1)"
}

# Check Pulumi
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + `
            [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + `
            "$env:USERPROFILE\.pulumi\bin"
if (-not (Get-Command pulumi -ErrorAction SilentlyContinue)) {
    Write-Warn "Pulumi not found — attempting winget install..."
    winget install --id Pulumi.Pulumi --silent --accept-package-agreements --accept-source-agreements
    $env:PATH += ";$env:USERPROFILE\.pulumi\bin"
    if (-not (Get-Command pulumi -ErrorAction SilentlyContinue)) {
        Write-Fail "Pulumi install failed. Install manually from https://www.pulumi.com/docs/install/"
    }
}
Write-OK "pulumi: $(pulumi version 2>&1 | Select-Object -First 1)"

# ── 2. Ensure Docker daemon is running ────────────────────────────────────
Write-Step "Checking Docker daemon..."

$dockerRunning = $false
$maxWait = 120
$elapsed = 0

while ($elapsed -lt $maxWait) {
    $result = docker info 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dockerRunning = $true
        break
    }
    Write-Warn "Docker daemon not ready — attempting to start Docker Desktop (wait ${elapsed}s/${maxWait}s)..."
    if ($elapsed -eq 0) {
        $dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $dockerExe) {
            Start-Process $dockerExe -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 10
    $elapsed += 10
}

if (-not $dockerRunning) {
    Write-Fail "Docker daemon did not start within ${maxWait}s. Please start Docker Desktop manually."
}
Write-OK "Docker daemon is running."

# ── 3. Create or reuse k3d cluster ────────────────────────────────────────
Write-Step "Provisioning k3d cluster: $CLUSTER_NAME..."

$existing = k3d cluster list --no-headers 2>&1 | Where-Object { $_ -match "^$CLUSTER_NAME\s" }
if ($existing) {
    Write-Warn "Cluster '$CLUSTER_NAME' already exists — reusing it."
} else {
    Write-Host "    Creating k3d cluster (this may take 2-3 minutes)..."
    k3d cluster create $CLUSTER_NAME `
        --api-port $K3D_API_PORT `
        --port "${LB_HTTPS_PORT}:443@loadbalancer" `
        --port "${LB_HTTP_PORT}:80@loadbalancer" `
        --k3s-arg "--disable=traefik@server:0" `
        --wait

    if ($LASTEXITCODE -ne 0) { Write-Fail "k3d cluster creation failed." }
    Write-OK "k3d cluster created."
}

# ── 4. Configure kubectl context ──────────────────────────────────────────
Write-Step "Configuring kubectl context..."
k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-switch-context
if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to set kubectl context." }

kubectl cluster-info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Fail "Cannot connect to cluster." }
Write-OK "kubectl context set to k3d-$CLUSTER_NAME"

# ── 5. Create namespace ───────────────────────────────────────────────────
Write-Step "Ensuring namespace '$NAMESPACE' exists..."
$nsExists = kubectl get namespace $NAMESPACE 2>&1
if ($LASTEXITCODE -ne 0) {
    kubectl create namespace $NAMESPACE
}
Write-OK "Namespace '$NAMESPACE' ready."

# ── 6. Install Traefik ingress controller via Helm ───────────────────────
Write-Step "Installing Traefik ingress controller..."

helm repo add traefik https://helm.traefik.io/traefik 2>&1 | Out-Null
helm repo update 2>&1 | Out-Null

$traefikInstalled = helm list -n kube-system --filter traefik 2>&1
if ($traefikInstalled -match "traefik") {
    Write-Warn "Traefik already installed — skipping."
} else {
    helm upgrade --install traefik traefik/traefik `
        --namespace kube-system `
        --version "33.2.1" `
        --set "service.type=LoadBalancer" `
        --set "ports.web.port=8000" `
        --set "ports.websecure.port=8443" `
        --set "ports.websecure.tls.enabled=true" `
        --set "ingressClass.enabled=true" `
        --set "ingressClass.isDefaultClass=true" `
        --wait --timeout 5m

    if ($LASTEXITCODE -ne 0) { Write-Fail "Traefik installation failed." }
    Write-OK "Traefik installed."
}

# ── 7. Add Bitnami Helm repo ──────────────────────────────────────────────
Write-Step "Adding Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>&1 | Out-Null
helm repo update 2>&1 | Out-Null
Write-OK "Helm repos updated."

# ── 8. /etc/hosts entry ───────────────────────────────────────────────────
Write-Step "Configuring hosts file for $HOSTNAME..."

$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
$loopback = "127.0.0.1"

if ($hostsContent -match [regex]::Escape($HOSTNAME)) {
    Write-OK "$HOSTNAME already in hosts file."
} else {
    try {
        Add-Content -Path $hostsFile -Value "`n$loopback   $HOSTNAME" -ErrorAction Stop
        Write-OK "Added '$loopback $HOSTNAME' to hosts file."
    } catch {
        Write-Warn "Could not write to hosts file (needs admin). Add this line manually:"
        Write-Host "    $loopback   $HOSTNAME" -ForegroundColor Yellow
        Write-Warn "  File: $hostsFile"
    }
}

# ── 9. Initialize Pulumi stack ────────────────────────────────────────────
Write-Step "Initializing Pulumi stack..."

Push-Location "$RepoRoot\pulumi"
try {
    $env:PULUMI_BACKEND_URL = "file://$RepoRoot/.pulumi-state"

    # Create state dir
    New-Item -ItemType Directory -Force -Path "$RepoRoot\.pulumi-state" | Out-Null

    # Init stack if not exists
    $stackExists = pulumi stack ls 2>&1 | Where-Object { $_ -match "\bdev\b" }
    if (-not $stackExists) {
        pulumi stack init dev --non-interactive 2>&1
    } else {
        Write-Warn "Stack 'dev' already exists."
    }

    pulumi stack select dev 2>&1
    Write-OK "Pulumi stack 'dev' selected."
} finally {
    Pop-Location
}

Write-Host "`n=====================================" -ForegroundColor Green
Write-Host "  Bootstrap complete! Run:" -ForegroundColor Green
Write-Host "  make deploy" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Green
