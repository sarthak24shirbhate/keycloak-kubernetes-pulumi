# Manifests Directory

All Kubernetes manifests for this project are managed through Pulumi IaC (`pulumi/main.go`).

There are no standalone YAML manifests to apply manually. This is by design:

- Resources defined in code are version-controlled, reviewable, and type-safe
- Pulumi tracks state and handles create/update/delete idempotently
- Secrets are managed as encrypted Pulumi config — never as plain YAML files

## Resources managed by Pulumi

| Resource | Kind | Namespace |
|----------|------|-----------|
| `keycloak` | Namespace | — |
| `postgres-credentials` | Secret | keycloak |
| `keycloak-admin-credentials` | Secret | keycloak |
| `keycloak-tls` | Secret (TLS) | keycloak |
| `postgresql` | Helm Release (Bitnami) | keycloak |
| `keycloak` | Helm Release (Bitnami) | keycloak |
| `postgres-allow-keycloak` | NetworkPolicy | keycloak |
| `keycloak-network-policy` | NetworkPolicy | keycloak |

## To inspect deployed resources

```powershell
kubectl get all -n keycloak
kubectl get networkpolicy -n keycloak
kubectl get ingress -n keycloak
kubectl get secret -n keycloak
```
