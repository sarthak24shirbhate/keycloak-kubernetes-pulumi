# Keycloak on Kubernetes — Local IaC

A production-minded local deployment of Keycloak on Kubernetes, automated end-to-end with Pulumi (Go) and k3d.

---

## Overview

This repository implements a fully automated, secure Keycloak deployment on a local Kubernetes cluster. Everything from cluster provisioning to TLS certificate generation, PostgreSQL deployment, and network hardening is managed as Infrastructure as Code — no manual kubectl applies or Helm commands.

The intent is to demonstrate how a real platform team would approach this problem: reproducible, idempotent, secure by default, and clearly documented about where local-dev shortcuts differ from a production-grade implementation.

---

## Architecture

```
Browser
   │
   │  HTTPS :443
   ▼
k3d LoadBalancer (host port 8443 → cluster port 443)
   │
   ▼
Traefik Ingress Controller (kube-system)
   │  IngressClass: traefik
   │  TLS termination using keycloak-tls Secret
   ▼
Keycloak Service (ClusterIP :80, namespace: keycloak)
   │
   ▼
Keycloak Pod (Bitnami chart, Keycloak 26.x)
   │  DB connection via internal DNS: postgresql:5432
   ▼
PostgreSQL Service (ClusterIP :5432, namespace: keycloak)
   │
   ▼
PostgreSQL Pod (Bitnami chart, PostgreSQL 16)
```

All inter-service communication stays inside the cluster. PostgreSQL is never reachable from outside. NetworkPolicies enforce this at the kernel level.

---

## Technology Stack

| Component | Version | Role |
|-----------|---------|------|
| k3d | v5.8.3 | Local Kubernetes via Docker containers |
| Kubernetes | v1.31.x (k3s) | Container orchestration |
| Pulumi | v3.264.0 | Infrastructure as Code engine |
| Go | 1.26.x | Pulumi program language |
| Helm | v3.16.x | Chart packaging (via Pulumi) |
| Keycloak | 26.x | Identity and Access Management |
| PostgreSQL | 16.x | Keycloak backend database |
| Traefik | v3.x | Ingress controller |
| TLS | Go crypto/x509 | Self-signed cert (local dev) |

---

## Prerequisites

| Software | Minimum Version | Notes |
|----------|----------------|-------|
| Windows 11 | — | Scripts use PowerShell 7+ |
| Docker Desktop | 4.x | Must be running before `make bootstrap` |
| kubectl | v1.28+ | `winget install Kubernetes.kubectl` |
| Helm | v3.14+ | `winget install Helm.Helm` |
| Go | 1.21+ | `winget install GoLang.Go` |
| k3d | v5.x | `winget install k3d.k3d` |
| Git | 2.x | For cloning and committing |
| Pulumi | v3.x | Installed automatically by `make bootstrap` |

---

## Quick Start

```powershell
git clone https://github.com/sarthak24shirbhate/keycloak-kubernetes-pulumi.git
cd keycloak-kubernetes-pulumi

# 1. Ensure Docker Desktop is running (whale icon in system tray)

# 2. Bootstrap: install Pulumi, create k3d cluster, configure ingress
make bootstrap

# 3. Deploy everything via Pulumi
make deploy

# 4. Verify the deployment
make verify
```

That's it. The full deployment takes approximately 5–8 minutes on first run (image pulls dominate).

---

## Accessing Keycloak

**URL:** https://keycloak.local

> If `keycloak.local` does not resolve, the bootstrap script attempts to add it to
> `C:\Windows\System32\drivers\etc\hosts` automatically. If that fails (needs admin),
> add this line manually:
> ```
> 127.0.0.1   keycloak.local
> ```
> Alternatively, access via https://localhost:8443 (the k3d LoadBalancer port mapping).

**Username:** `admin`

**Password** (retrieve with):
```powershell
make credentials
```
Or directly from the Kubernetes Secret:
```powershell
kubectl get secret keycloak-admin-credentials -n keycloak `
  -o jsonpath='{.data.admin-password}' | `
  ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

The password is randomly generated at deploy time. It is stored encrypted in the local Pulumi state and as a Kubernetes Secret. It is **never committed to Git**.

---

## TLS / HTTPS

A self-signed TLS certificate is generated programmatically in Go (`crypto/x509`) during `pulumi up`. No external `openssl` dependency is required.

**Expected browser warning:** Your browser will show a certificate warning (NET::ERR_CERT_AUTHORITY_INVALID or similar) because the certificate is not issued by a trusted CA. This is expected for local development. Click "Advanced → Proceed" to continue.

**curl with -k flag:**
```bash
curl -k https://keycloak.local/health/ready
```

**Production note:** In a real environment, replace the self-signed cert with:
- `cert-manager` + Let's Encrypt (ACME) for internet-accessible clusters
- Your organization's internal PKI for corporate environments
- A managed certificate from your cloud provider (ACM, GCP Certificate Manager, etc.)

---

## Security Controls

The following hardening measures are applied — all managed via Pulumi IaC:

| Control | Status | Notes |
|---------|--------|-------|
| Non-root containers | ✅ | `runAsUser: 1001` (Bitnami convention) |
| No privilege escalation | ✅ | `allowPrivilegeEscalation: false` |
| Capability drops | ✅ | `capabilities.drop: [ALL]` |
| Resource requests/limits | ✅ | CPU and memory bounded |
| Readiness + Liveness probes | ✅ | Keycloak `/health/ready`, `/health/live` |
| Startup probe | ✅ | Allows slow initial boot |
| Kubernetes Secrets | ✅ | All passwords stored as Secrets |
| Secrets not in Git | ✅ | Pulumi encrypts; state excluded via .gitignore |
| NetworkPolicy: PostgreSQL | ✅ | Accepts connections from Keycloak pods only |
| NetworkPolicy: Keycloak | ✅ | Accepts connections from Traefik namespace only |
| PostgreSQL ClusterIP only | ✅ | Not reachable outside cluster |
| Keycloak ClusterIP only | ✅ | Only reachable through ingress |
| Pinned image versions | ✅ | Chart versions pinned; no `latest` |
| Read-only root filesystem | ⚠️ | Not applied — Keycloak writes temp files at startup |

The read-only filesystem trade-off: Keycloak (and its JVM) writes to temp directories during startup. Enabling `readOnlyRootFilesystem` requires adding emptyDir volume mounts for those paths, which adds complexity for marginal security gain in a single-replica local environment. This is documented rather than silently omitted.

---

## Verification

```powershell
make verify
```

Checks performed:
- Cluster connectivity
- Namespace `keycloak` exists
- Keycloak pod Running + Ready
- PostgreSQL pod Running + Ready
- Services exist (PostgreSQL is ClusterIP)
- Ingress resource exists
- TLS Secret `keycloak-tls` exists
- NetworkPolicies exist
- HTTPS endpoint returns 2xx/3xx
- Keycloak `/health/ready` reports UP
- Pod log sanity (no ERROR/FATAL lines)

Produces readable PASS/FAIL output and exits non-zero if critical checks fail.

---

## Cluster and Pod Status

```powershell
make status
```

---

## Cleanup

```powershell
make destroy
```

Runs `pulumi destroy` to remove all managed resources, then optionally deletes the k3d cluster.

---

## Troubleshooting

### keycloak.local does not resolve
The bootstrap script tries to update `C:\Windows\System32\drivers\etc\hosts`. If it fails (needs elevation), add manually:
```
127.0.0.1   keycloak.local
```

### Browser certificate warning
Expected — self-signed cert. Click "Advanced → Proceed" or use `curl -k`.

### Keycloak pod not becoming Ready
Keycloak takes 3–5 minutes to start on first boot (JVM warm-up + DB schema migration):
```powershell
kubectl get pods -n keycloak -w
kubectl logs -n keycloak -l app.kubernetes.io/name=keycloak -f
```

### Docker daemon not running
Start Docker Desktop from the Start menu. Wait for the system tray icon to stabilize before running `make bootstrap`.

### Image pull slow/failing
k3d runs on Docker. If images are slow to pull, this is network-dependent. The k3d cluster caches images once pulled — subsequent `make deploy` runs are much faster.

### Pulumi not found after install
Restart your terminal session to pick up the updated PATH, or run:
```powershell
$env:PATH += ";$env:USERPROFILE\.pulumi\bin"
```

### Pulumi stack state issues
If the stack gets into a bad state:
```powershell
cd pulumi
$env:PULUMI_BACKEND_URL = "file://../.pulumi-state"
pulumi stack export | pulumi stack import  # refresh
```

### k3d cluster stuck
```powershell
k3d cluster delete keycloak-cluster
make bootstrap
```

---

## Production Considerations

This deployment is optimized for a local development environment. A production deployment would differ in these key areas:

| Area | Local (this repo) | Production |
|------|------------------|------------|
| Kubernetes | k3d (Docker) | EKS / GKE / AKS / on-prem |
| PostgreSQL | Bitnami chart in-cluster | RDS / Cloud SQL / managed DB |
| TLS | Self-signed, Go-generated | cert-manager + Let's Encrypt or org PKI |
| Secrets | Pulumi local state / K8s Secrets | HashiCorp Vault / AWS Secrets Manager / ESO |
| HA | 1 replica | 3+ replicas + PodDisruptionBudget |
| Backups | None | Velero / cloud snapshots |
| Monitoring | None | Prometheus + Grafana + Keycloak metrics |
| Logging | kubectl logs | EFK / Loki / cloud logging |
| Autoscaling | None | HPA + KEDA |
| Ingress | Traefik local | NGINX / AWS ALB / GCP LB |
| DNS | /etc/hosts | External DNS + Route53 / Cloud DNS |
| GitOps | Manual `pulumi up` | ArgoCD / Flux |
| CI/CD | None | GitHub Actions / GitLab CI |

None of these production controls are implemented in this repository — they are listed as required next steps for a production hardening sprint.

---

## Time Spent

Estimated implementation effort: approximately 6–8 hours.

| Phase | Time |
|-------|------|
| Environment inspection & tooling decisions | ~45 min |
| Pulumi/IaC implementation (Go) | ~2.5 hrs |
| k3d cluster, Traefik, Helm chart configuration | ~1.5 hrs |
| Security hardening (NetworkPolicy, securityContext) | ~1 hr |
| Scripts (bootstrap, deploy, verify, destroy) | ~1 hr |
| Documentation (README, architecture) | ~1 hr |

---

## Repository Structure

```
keycloak-kubernetes-pulumi/
├── README.md                    # This file
├── .gitignore                   # Excludes secrets, state, binaries
├── Makefile                     # Developer entrypoints
├── pulumi/
│   ├── Pulumi.yaml              # Project metadata
│   ├── Pulumi.dev.yaml.example  # Stack config template
│   ├── go.mod                   # Go module definition
│   ├── go.sum                   # Go dependency checksums
│   └── main.go                  # Pulumi program (all K8s resources)
├── scripts/
│   ├── bootstrap.ps1            # Cluster setup + deps
│   ├── generate-certs.ps1       # Standalone TLS cert helper
│   ├── deploy.ps1               # Pulumi deploy orchestrator
│   ├── verify.ps1               # PASS/FAIL verification suite
│   └── destroy.ps1              # Teardown
├── manifests/
│   └── README.md                # Explains manifests-via-Pulumi approach
└── docs/
    └── architecture.md          # Extended architecture notes
```

---

## Assumptions

- Docker Desktop is installed (it is on this machine, v29.6.1)
- The machine has at least 4 GB RAM available for Docker
- Internet connectivity is available for Helm chart and image pulls
- The deployment target is a single-developer local workstation
- No existing cluster or namespace named `keycloak-cluster`/`keycloak` is in a conflicting state
- PowerShell 7+ (`pwsh`) is available (comes with Windows 11 or installable separately)
