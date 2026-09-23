# Architecture Notes — Keycloak Kubernetes IaC

## Component Decisions

### Why k3d?

k3d was chosen over the other available options (minikube, kind) for the following reasons:

| Factor | k3d | minikube | kind |
|--------|-----|----------|------|
| Docker-based (no VM) | ✅ | ❌ (Docker driver available but less stable on Windows) | ✅ |
| Built-in LoadBalancer | ✅ port-map | Tunnel required | ❌ manual |
| Traefik bundled | ✅ | ❌ | ❌ |
| Multi-node support | ✅ | Limited | ✅ |
| Startup time | ~30s | ~2-3m | ~45s |
| Production similarity | High | Medium | High |

Minikube was available but its Docker driver on Windows requires the Linux Engine pipe, which was not running. k3d works directly against the Docker daemon without this constraint.

### Why Bitnami Helm Charts?

Bitnami charts are industry-standard for local and production-adjacent deployments:
- Actively maintained with security patches
- Proper securityContext defaults (non-root, uid 1001)
- Well-tested configuration surface
- Support for `existingSecret` references (avoids passwords in chart values)

Alternative considered: official Keycloak Helm chart from `registry1.dss.mil` or the community chart. Bitnami was chosen for its PostgreSQL integration and broader adoption.

### Why Local Pulumi State?

Pulumi supports multiple backends: Pulumi Cloud, S3, GCS, Azure Blob, and local filesystem. For a self-contained local assignment:
- Local state requires no cloud account setup
- State is stored in `.pulumi-state/` (gitignored)
- Secrets within state are encrypted using a passphrase
- Easy to inspect with `pulumi stack export`

In production, use a remote backend (S3 + DynamoDB, Pulumi Cloud) with state locking.

### TLS Certificate Generation

The self-signed certificate is generated in Go using `crypto/x509` inside the Pulumi program. This approach:
- Eliminates the `openssl` binary dependency
- Keeps cert generation within the IaC boundary (reproducible)
- Certificate is stored as a Kubernetes TLS Secret (type: kubernetes.io/tls)
- Private key is **never written to disk** — it exists only in memory and in the encrypted K8s Secret

The certificate is a P-256 ECDSA cert (more modern than RSA, smaller, equally secure).

## Network Flow Details

```
External Request (HTTPS)
         │
         │ Host port 8443 (or 443 if /etc/hosts configured)
         ▼
  k3d LoadBalancer Container
         │ Port mapping: 8443 → cluster port 443
         ▼
  Traefik (kube-system, DaemonSet)
         │ TLS termination using keycloak-tls Secret
         │ Routes via IngressClass: traefik
         │ Host-based routing: keycloak.local → keycloak/keycloak:80
         ▼
  Keycloak Service (ClusterIP, port 80)
         │
         ▼
  Keycloak Pod (port 8080, proxy=edge mode)
         │ Internal DNS: postgresql.keycloak.svc.cluster.local:5432
         ▼
  PostgreSQL Service (ClusterIP, port 5432)
         │
         ▼
  PostgreSQL Pod
```

## Security Model

The NetworkPolicy topology enforces a strict allow-list:

```
[Internet] ──→ [k3d LB :443] ──→ [Traefik ns=kube-system]
                                           │
                              NetworkPolicy: allow ingress from kube-system
                                           │
                                  [Keycloak Pod ns=keycloak]
                                           │
                              NetworkPolicy: allow egress to postgresql
                                           │
                                  [PostgreSQL Pod ns=keycloak]
```

All other traffic is implicitly denied by the NetworkPolicy selectors.

**Note on k3d NetworkPolicy support:** k3d uses k3s which includes Flannel as the CNI by default. Flannel does NOT enforce NetworkPolicy rules (it creates them but ignores the policy). For NetworkPolicy enforcement in production, use Calico, Cilium, or Weave. In this local environment, NetworkPolicies are created and valid Kubernetes objects — they document intent and work correctly on any compliant CNI. This limitation is documented rather than hidden.

## Keycloak Configuration

Keycloak runs in `proxy=edge` mode, meaning it trusts the `X-Forwarded-*` headers from Traefik. This is appropriate when TLS is terminated at the ingress layer.

The production mode flag is set to `false` for local development. In production, enable production mode and configure `KC_HOSTNAME` and `KC_HOSTNAME_STRICT`.

## Database Schema

On first startup, Keycloak runs Liquibase migrations to create its schema in the `keycloak` database. This takes 30–60 seconds. The startup probe (60 failures × 10s = 600s budget) accommodates this.

## Idempotency

Running `pulumi up` multiple times is safe:
- Existing resources are compared against desired state
- Only diffs are applied
- The TLS cert is regenerated each run (same hostname, new serial) — this causes a Secret update but no downtime
- Helm releases are upgraded in-place if chart values change
