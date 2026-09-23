# verify.ps1 — End-to-end verification suite.
# Produces PASS/FAIL output and exits with code 1 if any critical check fails.
# Run with: pwsh -File scripts\verify.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$NAMESPACE = "keycloak"
$HOSTNAME  = "keycloak.local"
$FAILURES  = @()

function Pass  { param($msg) Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Fail  { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:FAILURES += $msg }
function Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Section { param($msg) Write-Host "`n── $msg ──" -ForegroundColor Cyan }

Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor White
Write-Host "  Keycloak Kubernetes — Verification Suite" -ForegroundColor White
Write-Host "════════════════════════════════════════════════════" -ForegroundColor White

# ── 1. Cluster connectivity ───────────────────────────────────────────────
Section "Cluster Connectivity"

$nodes = kubectl get nodes --no-headers 2>&1
if ($LASTEXITCODE -eq 0 -and $nodes) {
    Pass "kubectl connected to cluster"
    $nodes | ForEach-Object { Write-Host "         $_" }
} else {
    Fail "Cannot connect to Kubernetes cluster"
}

# ── 2. Namespace ──────────────────────────────────────────────────────────
Section "Namespace"

$ns = kubectl get namespace $NAMESPACE --no-headers 2>&1
if ($LASTEXITCODE -eq 0) {
    Pass "Namespace '$NAMESPACE' exists"
} else {
    Fail "Namespace '$NAMESPACE' does not exist"
}

# ── 3. Pods ───────────────────────────────────────────────────────────────
Section "Pod Status"

Write-Host "  All pods in $NAMESPACE namespace:" -ForegroundColor White
kubectl get pods -n $NAMESPACE -o wide 2>&1 | ForEach-Object { Write-Host "    $_" }

# Keycloak pod
$kcReady = kubectl get pods -n $NAMESPACE -l "app.kubernetes.io/name=keycloak" `
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1
if ($kcReady -eq "True") {
    Pass "Keycloak pod is Ready"
} else {
    Fail "Keycloak pod is not Ready (status: $kcReady)"
}

# PostgreSQL pod
$pgReady = kubectl get pods -n $NAMESPACE -l "app.kubernetes.io/name=postgresql" `
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1
if ($pgReady -eq "True") {
    Pass "PostgreSQL pod is Ready"
} else {
    Fail "PostgreSQL pod is not Ready (status: $pgReady)"
}

# ── 4. Services ───────────────────────────────────────────────────────────
Section "Services"

$services = kubectl get svc -n $NAMESPACE --no-headers 2>&1
if ($LASTEXITCODE -eq 0 -and $services) {
    Pass "Services exist in namespace"
    $services | ForEach-Object { Write-Host "    $_" }
} else {
    Fail "No services found in namespace $NAMESPACE"
}

# Ensure no NodePort/LoadBalancer for PostgreSQL (should be ClusterIP only)
$pgSvcType = kubectl get svc -n $NAMESPACE postgresql `
    -o jsonpath='{.spec.type}' 2>&1
if ($pgSvcType -eq "ClusterIP") {
    Pass "PostgreSQL service is ClusterIP (not externally exposed)"
} else {
    Warn "PostgreSQL service type is '$pgSvcType' — expected ClusterIP"
}

# ── 5. Ingress ────────────────────────────────────────────────────────────
Section "Ingress"

$ingress = kubectl get ingress -n $NAMESPACE --no-headers 2>&1
if ($LASTEXITCODE -eq 0 -and $ingress) {
    Pass "Ingress resource exists"
    $ingress | ForEach-Object { Write-Host "    $_" }
} else {
    Fail "No Ingress found in namespace $NAMESPACE"
}

# ── 6. TLS Secret ─────────────────────────────────────────────────────────
Section "TLS Secret"

$tlsSecret = kubectl get secret keycloak-tls -n $NAMESPACE --no-headers 2>&1
if ($LASTEXITCODE -eq 0) {
    $tlsType = kubectl get secret keycloak-tls -n $NAMESPACE `
        -o jsonpath='{.type}' 2>&1
    Pass "TLS Secret 'keycloak-tls' exists (type: $tlsType)"
} else {
    Fail "TLS Secret 'keycloak-tls' not found"
}

# ── 7. NetworkPolicy ──────────────────────────────────────────────────────
Section "NetworkPolicy"

$netpols = kubectl get networkpolicy -n $NAMESPACE --no-headers 2>&1
if ($LASTEXITCODE -eq 0 -and $netpols) {
    Pass "NetworkPolicies exist"
    $netpols | ForEach-Object { Write-Host "    $_" }
} else {
    Fail "No NetworkPolicies found in namespace $NAMESPACE"
}

# ── 8. HTTPS Endpoint ─────────────────────────────────────────────────────
Section "HTTPS Connectivity"

# Test via curl (ignore cert error for self-signed)
$curlResult = curl.exe -sk --max-time 30 -o NUL -w "%{http_code}" "https://$HOSTNAME" 2>&1
if ($curlResult -match "^(200|301|302|303)$") {
    Pass "HTTPS endpoint https://$HOSTNAME returned HTTP $curlResult"
} else {
    Warn "HTTPS returned: '$curlResult' — may still be starting up or needs hosts entry"
    # Try via localhost port if hosts not configured
    $curlAlt = curl.exe -sk --max-time 30 -o NUL -w "%{http_code}" "https://localhost:8443" 2>&1
    if ($curlAlt -match "^(200|301|302|303)$") {
        Pass "HTTPS via localhost:8443 returned HTTP $curlAlt"
    } else {
        Fail "HTTPS endpoint not reachable (returned: $curlAlt)"
    }
}

# ── 9. Keycloak Health ────────────────────────────────────────────────────
Section "Keycloak Health"

$healthUrl = "https://$HOSTNAME/health/ready"
$healthResult = curl.exe -sk --max-time 30 "$healthUrl" 2>&1

if ($healthResult -match '"status"\s*:\s*"UP"') {
    Pass "Keycloak health endpoint reports UP"
} else {
    # Try via kubectl exec
    $podName = kubectl get pods -n $NAMESPACE -l "app.kubernetes.io/name=keycloak" `
        -o jsonpath='{.items[0].metadata.name}' 2>&1
    if ($podName) {
        $internalHealth = kubectl exec -n $NAMESPACE $podName -- `
            curl -s http://localhost:9000/health/ready 2>&1
        if ($internalHealth -match '"status"\s*:\s*"UP"') {
            Pass "Keycloak health UP (verified via pod exec)"
        } else {
            Warn "Keycloak health response: $internalHealth"
        }
    } else {
        Fail "Cannot verify Keycloak health — pod not found"
    }
}

# ── 10. Pod logs (quick sanity) ───────────────────────────────────────────
Section "Pod Log Sanity"

$podName = kubectl get pods -n $NAMESPACE -l "app.kubernetes.io/name=keycloak" `
    -o jsonpath='{.items[0].metadata.name}' 2>&1
if ($podName) {
    $logs = kubectl logs -n $NAMESPACE $podName --tail=20 2>&1
    $hasErrors = $logs | Where-Object { $_ -match "ERROR|FATAL|Exception" }
    if ($hasErrors) {
        Warn "Keycloak pod logs contain errors (review manually):"
        $hasErrors | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    } else {
        Pass "No ERROR/FATAL lines in recent Keycloak logs"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor White

if ($FAILURES.Count -eq 0) {
    Write-Host "  RESULT: ALL CHECKS PASSED" -ForegroundColor Green
    Write-Host "════════════════════════════════════════════════════" -ForegroundColor White
    exit 0
} else {
    Write-Host "  RESULT: $($FAILURES.Count) CHECK(S) FAILED:" -ForegroundColor Red
    $FAILURES | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "════════════════════════════════════════════════════" -ForegroundColor White
    exit 1
}
