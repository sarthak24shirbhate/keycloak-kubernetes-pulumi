# generate-certs.ps1 — Generate a self-signed TLS certificate for keycloak.local.
# NOTE: Certificate generation is also handled directly by the Pulumi Go code
#       (using Go's crypto/x509). This script exists as a standalone helper for
#       manual inspection or CI workflows where you need the cert files on disk.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$HOSTNAME  = "keycloak.local"
$CERT_DIR  = Join-Path (Split-Path -Parent $PSScriptRoot) "certs"
$CERT_FILE = Join-Path $CERT_DIR "tls.crt"
$KEY_FILE  = Join-Path $CERT_DIR "tls.key"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }

New-Item -ItemType Directory -Force -Path $CERT_DIR | Out-Null

Write-Step "Generating self-signed TLS certificate for $HOSTNAME..."

# Use PowerShell's New-SelfSignedCertificate (no external openssl dependency)
$cert = New-SelfSignedCertificate `
    -DnsName $HOSTNAME, "localhost" `
    -CertStoreLocation "cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(1) `
    -KeyAlgorithm ECDH_P256 `
    -HashAlgorithm SHA256 `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -FriendlyName "Keycloak Local Dev"

# Export PEM certificate
$certPEM = "-----BEGIN CERTIFICATE-----`n" + `
    [Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks) + `
    "`n-----END CERTIFICATE-----"
Set-Content -Path $CERT_FILE -Value $certPEM -Encoding ASCII

Write-OK "Certificate written to $CERT_FILE"
Write-OK "Thumbprint: $($cert.Thumbprint)"
Write-OK "Expires: $($cert.NotAfter)"

Write-Host ""
Write-Host "NOTE: This is a self-signed certificate for local development only." -ForegroundColor Yellow
Write-Host "      In production, use cert-manager with Let's Encrypt or your org PKI." -ForegroundColor Yellow
Write-Host ""
Write-Host "To trust this cert in Windows (optional, removes browser warning):" -ForegroundColor Cyan
Write-Host "  Import-Certificate -FilePath '$CERT_FILE' -CertStoreLocation 'cert:\LocalMachine\Root'" -ForegroundColor White
