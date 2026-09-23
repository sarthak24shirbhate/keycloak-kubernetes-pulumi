package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"time"

	corev1 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/core/v1"
	helmv3 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/helm/v3"
	metav1 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/meta/v1"
	networkingv1 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/networking/v1"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// generateSelfSignedCert creates a self-signed TLS certificate for the given hostname.
// In production this would be replaced by cert-manager + Let's Encrypt or organizational PKI.
func generateSelfSignedCert(hostname string) (certPEM, keyPEM string, err error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", fmt.Errorf("generating private key: %w", err)
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return "", "", fmt.Errorf("generating serial number: %w", err)
	}

	template := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			Organization:       []string{"Keycloak Local Dev"},
			OrganizationalUnit: []string{"Platform Engineering"},
			CommonName:         hostname,
		},
		DNSNames:              []string{hostname, "localhost"},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return "", "", fmt.Errorf("creating certificate: %w", err)
	}

	certBuf := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})

	privDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return "", "", fmt.Errorf("marshalling private key: %w", err)
	}
	keyBuf := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privDER})

	return string(certBuf), string(keyBuf), nil
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")

		// ── Configuration ────────────────────────────────────────────────────
		namespace := cfg.Get("namespace")
		if namespace == "" {
			namespace = "keycloak"
		}

		hostname := cfg.Get("hostname")
		if hostname == "" {
			hostname = "keycloak.local"
		}

		keycloakAdminPassword, err := config.TrySecret(ctx, "keycloakAdminPassword")
		if err != nil {
			// fallback: use random if not set (should be set via pulumi config set --secret)
			keycloakAdminPassword = pulumi.ToSecret(pulumi.String("")).(pulumi.StringOutput)
		}

		postgresPassword, err := config.TrySecret(ctx, "postgresPassword")
		if err != nil {
			postgresPassword = pulumi.ToSecret(pulumi.String("")).(pulumi.StringOutput)
		}

		// ── Namespace ─────────────────────────────────────────────────────────
		ns, err := corev1.NewNamespace(ctx, "keycloak-ns", &corev1.NamespaceArgs{
			Metadata: &metav1.ObjectMetaArgs{
				Name: pulumi.String(namespace),
				Labels: pulumi.StringMap{
					"app.kubernetes.io/managed-by": pulumi.String("pulumi"),
					"environment":                  pulumi.String("dev"),
				},
			},
		}, pulumi.RetainOnDelete(false))
		if err != nil {
			return fmt.Errorf("creating namespace: %w", err)
		}

		// ── PostgreSQL Credentials Secret ────────────────────────────────────
		pgSecret, err := corev1.NewSecret(ctx, "postgres-credentials", &corev1.SecretArgs{
			Metadata: &metav1.ObjectMetaArgs{
				Name:      pulumi.String("postgres-credentials"),
				Namespace: ns.Metadata.Name().Elem(),
				Labels: pulumi.StringMap{
					"app.kubernetes.io/managed-by": pulumi.String("pulumi"),
					"app.kubernetes.io/component":  pulumi.String("database"),
				},
			},
			Type: pulumi.String("Opaque"),
			StringData: pulumi.StringMap{
				"postgres-password":    postgresPassword,
				"password":             postgresPassword,
				"replication-password": postgresPassword,
			},
		}, pulumi.DependsOn([]pulumi.Resource{ns}))
		if err != nil {
			return fmt.Errorf("creating postgres secret: %w", err)
		}

		// ── Keycloak Admin Credentials Secret ────────────────────────────────
		kcAdminSecret, err := corev1.NewSecret(ctx, "keycloak-admin-credentials", &corev1.SecretArgs{
			Metadata: &metav1.ObjectMetaArgs{
				Name:      pulumi.String("keycloak-admin-credentials"),
				Namespace: ns.Metadata.Name().Elem(),
				Labels: pulumi.StringMap{
					"app.kubernetes.io/managed-by": pulumi.String("pulumi"),
					"app.kubernetes.io/component":  pulumi.String("keycloak"),
				},
			},
			Type: pulumi.String("Opaque"),
			StringData: pulumi.StringMap{
				"admin-password": keycloakAdminPassword,
			},
		}, pulumi.DependsOn([]pulumi.Resource{ns}))
		if err != nil {
			return fmt.Errorf("creating keycloak admin secret: %w", err)
		}

		// ── TLS Certificate (self-signed, generated in Go) ───────────────────
		// NOTE: In production, replace with cert-manager + Let's Encrypt or
		// organizational PKI. Self-signed certs are acceptable for local dev only.
		certPEM, keyPEM, err := generateSelfSignedCert(hostname)
		if err != nil {
			return fmt.Errorf("generating TLS cert: %w", err)
		}

		tlsSecret, err := corev1.NewSecret(ctx, "keycloak-tls", &corev1.SecretArgs{
			Metadata: &metav1.ObjectMetaArgs{
				Name:      pulumi.String("keycloak-tls"),
				Namespace: ns.Metadata.Name().Elem(),
				Labels: pulumi.StringMap{
					"app.kubernetes.io/managed-by": pulumi.String("pulumi"),
					"app.kubernetes.io/component":  pulumi.String("tls"),
				},
			},
			Type: pulumi.String("kubernetes.io/tls"),
			StringData: pulumi.StringMap{
				"tls.crt": pulumi.String(certPEM),
				"tls.key": pulumi.String(keyPEM),
			},
		}, pulumi.DependsOn([]pulumi.Resource{ns}))
		if err != nil {
			return fmt.Errorf("creating TLS secret: %w", err)
		}

		// ── PostgreSQL Helm Release (Bitnami) ─────────────────────────────────
		// Pinned chart version for reproducibility.
		// ClusterIP-only — PostgreSQL is never exposed outside the cluster.
		pgRelease, err := helmv3.NewRelease(ctx, "postgresql", &helmv3.ReleaseArgs{
			Name:      pulumi.String("postgresql"),
			Namespace: ns.Metadata.Name().Elem(),
			Chart:     pulumi.String("postgresql"),
			Version:   pulumi.String("15.5.38"),
			RepositoryOpts: &helmv3.RepositoryOptsArgs{
				Repo: pulumi.String("https://charts.bitnami.com/bitnami"),
			},
			Values: pulumi.Map{
				"global": pulumi.Map{
					"postgresql": pulumi.Map{
						"auth": pulumi.Map{
							// Reference our pre-created secret so passwords are not in chart values.
							"existingSecret": pulumi.String("postgres-credentials"),
							"database":       pulumi.String("keycloak"),
							"username":       pulumi.String("keycloak"),
						},
					},
				},
				"primary": pulumi.Map{
					"persistence": pulumi.Map{
						"enabled": pulumi.Bool(true),
						"size":    pulumi.String("2Gi"),
					},
					"resources": pulumi.Map{
						"requests": pulumi.Map{
							"cpu":    pulumi.String("100m"),
							"memory": pulumi.String("256Mi"),
						},
						"limits": pulumi.Map{
							"cpu":    pulumi.String("500m"),
							"memory": pulumi.String("512Mi"),
						},
					},
					// Non-root container — Bitnami images default to uid 1001.
					"podSecurityContext": pulumi.Map{
						"enabled":   pulumi.Bool(true),
						"runAsUser": pulumi.Int(1001),
						"fsGroup":   pulumi.Int(1001),
					},
					"containerSecurityContext": pulumi.Map{
						"enabled":                  pulumi.Bool(true),
						"runAsNonRoot":             pulumi.Bool(true),
						"allowPrivilegeEscalation": pulumi.Bool(false),
						"capabilities": pulumi.Map{
							"drop": pulumi.StringArray{pulumi.String("ALL")},
						},
					},
				},
				// No external service — ClusterIP only.
				"service": pulumi.Map{
					"type": pulumi.String("ClusterIP"),
					"port": pulumi.Int(5432),
				},
				"networkPolicy": pulumi.Map{
					"enabled": pulumi.Bool(false), // We manage NetworkPolicy ourselves below.
				},
			},
		}, pulumi.DependsOn([]pulumi.Resource{ns, pgSecret}))
		if err != nil {
			return fmt.Errorf("creating postgresql release: %w", err)
		}

		// ── Keycloak Helm Release (Bitnami) ───────────────────────────────────
		// Using Bitnami's Keycloak chart which bundles a well-tested Keycloak image.
		// Chart version 22.x ships Keycloak 26.x.
		kcRelease, err := helmv3.NewRelease(ctx, "keycloak", &helmv3.ReleaseArgs{
			Name:      pulumi.String("keycloak"),
			Namespace: ns.Metadata.Name().Elem(),
			Chart:     pulumi.String("keycloak"),
			Version:   pulumi.String("22.2.7"),
			RepositoryOpts: &helmv3.RepositoryOptsArgs{
				Repo: pulumi.String("https://charts.bitnami.com/bitnami"),
			},
			Values: pulumi.Map{
				"auth": pulumi.Map{
					"adminUser":         pulumi.String("admin"),
					"existingSecret":    pulumi.String("keycloak-admin-credentials"),
					"passwordSecretKey": pulumi.String("admin-password"),
				},
				// Connect to our PostgreSQL deployment.
				"externalDatabase": pulumi.Map{
					"host":                      pulumi.String("postgresql"),
					"port":                      pulumi.Int(5432),
					"database":                  pulumi.String("keycloak"),
					"user":                      pulumi.String("keycloak"),
					"existingSecret":            pulumi.String("postgres-credentials"),
					"existingSecretPasswordKey": pulumi.String("password"),
				},
				// Disable bundled PostgreSQL — we deployed it ourselves.
				"postgresql": pulumi.Map{
					"enabled": pulumi.Bool(false),
				},
				"production": pulumi.Bool(false), // local dev
				"proxy":      pulumi.String("edge"),
				// Ingress configuration.
				"ingress": pulumi.Map{
					"enabled":          pulumi.Bool(true),
					"ingressClassName": pulumi.String("traefik"),
					"hostname":         pulumi.String(hostname),
					"tls":              pulumi.Bool(true),
					"extraTls": pulumi.MapArray{
						pulumi.Map{
							"hosts":      pulumi.StringArray{pulumi.String(hostname)},
							"secretName": pulumi.String("keycloak-tls"),
						},
					},
					"annotations": pulumi.StringMap{
						"traefik.ingress.kubernetes.io/router.entrypoints": pulumi.String("websecure"),
						"traefik.ingress.kubernetes.io/router.tls":         pulumi.String("true"),
					},
				},
				// Expose Keycloak as ClusterIP only; ingress handles external traffic.
				"service": pulumi.Map{
					"type": pulumi.String("ClusterIP"),
					"ports": pulumi.Map{
						"http": pulumi.Int(80),
					},
				},
				"replicaCount": pulumi.Int(1),
				"resources": pulumi.Map{
					"requests": pulumi.Map{
						"cpu":    pulumi.String("250m"),
						"memory": pulumi.String("512Mi"),
					},
					"limits": pulumi.Map{
						"cpu":    pulumi.String("1000m"),
						"memory": pulumi.String("1024Mi"),
					},
				},
				// Security context — non-root, no privilege escalation.
				"podSecurityContext": pulumi.Map{
					"enabled":   pulumi.Bool(true),
					"runAsUser": pulumi.Int(1001),
					"fsGroup":   pulumi.Int(1001),
				},
				"containerSecurityContext": pulumi.Map{
					"enabled":                  pulumi.Bool(true),
					"runAsNonRoot":             pulumi.Bool(true),
					"allowPrivilegeEscalation": pulumi.Bool(false),
					"capabilities": pulumi.Map{
						"drop": pulumi.StringArray{pulumi.String("ALL")},
					},
				},
				// Readiness and liveness probes are enabled by default in the chart.
				// Keycloak health endpoints: /health/ready and /health/live.
				"livenessProbe": pulumi.Map{
					"enabled":             pulumi.Bool(true),
					"initialDelaySeconds": pulumi.Int(300),
					"periodSeconds":       pulumi.Int(20),
					"failureThreshold":    pulumi.Int(6),
					"timeoutSeconds":      pulumi.Int(5),
				},
				"readinessProbe": pulumi.Map{
					"enabled":             pulumi.Bool(true),
					"initialDelaySeconds": pulumi.Int(30),
					"periodSeconds":       pulumi.Int(10),
					"failureThreshold":    pulumi.Int(6),
					"timeoutSeconds":      pulumi.Int(5),
				},
				"startupProbe": pulumi.Map{
					"enabled":             pulumi.Bool(true),
					"initialDelaySeconds": pulumi.Int(30),
					"periodSeconds":       pulumi.Int(10),
					"failureThreshold":    pulumi.Int(60),
					"timeoutSeconds":      pulumi.Int(5),
				},
			},
		}, pulumi.DependsOn([]pulumi.Resource{ns, pgRelease, kcAdminSecret, tlsSecret}))
		if err != nil {
			return fmt.Errorf("creating keycloak release: %w", err)
		}

		// ── NetworkPolicy: PostgreSQL ─────────────────────────────────────────
		// Only allow inbound connections from pods with the keycloak app label.
		_, err = networkingv1.NewNetworkPolicy(ctx, "postgres-netpol", &networkingv1.NetworkPolicyArgs{
			Metadata: &metav1.ObjectMetaArgs{
				Name:      pulumi.String("postgres-allow-keycloak"),
				Namespace: ns.Metadata.Name().Elem(),
				Labels: pulumi.StringMap{
					"app.kubernetes.io/managed-by": pulumi.String("pulumi"),
				},
			},
			Spec: &networkingv1.NetworkPolicySpecArgs{
				PodSelector: &metav1.LabelSelectorArgs{
					MatchLabels: pulumi.StringMap{
						"app.kubernetes.io/name": pulumi.String("postgresql"),
					},
				},
				PolicyTypes: pulumi.StringArray{pulumi.String("Ingress"), pulumi.String("Egress")},
				Ingress: networkingv1.NetworkPolicyIngressRuleArray{
					&networkingv1.NetworkPolicyIngressRuleArgs{
						From: networkingv1.NetworkPolicyPeerArray{
							&networkingv1.NetworkPolicyPeerArgs{
								PodSelector: &metav1.LabelSelectorArgs{
									MatchLabels: pulumi.StringMap{
										"app.kubernetes.io/name": pulumi.String("keycloak"),
									},
								},
							},
						},
						Ports: networkingv1.NetworkPolicyPortArray{
							&networkingv1.NetworkPolicyPortArgs{
								Port:     pulumi.Int(5432),
								Protocol: pulumi.String("TCP"),
							},
						},
					},
				},
				Egress: networkingv1.NetworkPolicyEgressRuleArray{
					// Allow DNS resolution (kube-dns on port 53).
					&networkingv1.NetworkPolicyEgressRuleArgs{
						Ports: networkingv1.NetworkPolicyPortArray{
							&networkingv1.NetworkPolicyPortArgs{
								Port:     pulumi.Int(53),
								Protocol: pulumi.String("UDP"),
							},
						},
					},
				},
			},
		}, pulumi.DependsOn([]pulumi.Resource{ns, pgRelease}))
		if err != nil {
			return fmt.Errorf("creating postgres network policy: %w", err)
		}

		// ── NetworkPolicy: Keycloak ───────────────────────────────────────────
		// Allow inbound from ingress controller namespace only.
		// Allow outbound to PostgreSQL and DNS only.
		_, err = networkingv1.NewNetworkPolicy(ctx, "keycloak-netpol", &networkingv1.NetworkPolicyArgs{
			Metadata: &metav1.ObjectMetaArgs{
				Name:      pulumi.String("keycloak-network-policy"),
				Namespace: ns.Metadata.Name().Elem(),
				Labels: pulumi.StringMap{
					"app.kubernetes.io/managed-by": pulumi.String("pulumi"),
				},
			},
			Spec: &networkingv1.NetworkPolicySpecArgs{
				PodSelector: &metav1.LabelSelectorArgs{
					MatchLabels: pulumi.StringMap{
						"app.kubernetes.io/name": pulumi.String("keycloak"),
					},
				},
				PolicyTypes: pulumi.StringArray{pulumi.String("Ingress"), pulumi.String("Egress")},
				Ingress: networkingv1.NetworkPolicyIngressRuleArray{
					// Allow traffic from kube-system (Traefik ingress controller lives there in k3d).
					&networkingv1.NetworkPolicyIngressRuleArgs{
						From: networkingv1.NetworkPolicyPeerArray{
							&networkingv1.NetworkPolicyPeerArgs{
								NamespaceSelector: &metav1.LabelSelectorArgs{
									MatchLabels: pulumi.StringMap{
										"kubernetes.io/metadata.name": pulumi.String("kube-system"),
									},
								},
							},
						},
					},
				},
				Egress: networkingv1.NetworkPolicyEgressRuleArray{
					// Allow PostgreSQL egress.
					&networkingv1.NetworkPolicyEgressRuleArgs{
						To: networkingv1.NetworkPolicyPeerArray{
							&networkingv1.NetworkPolicyPeerArgs{
								PodSelector: &metav1.LabelSelectorArgs{
									MatchLabels: pulumi.StringMap{
										"app.kubernetes.io/name": pulumi.String("postgresql"),
									},
								},
							},
						},
						Ports: networkingv1.NetworkPolicyPortArray{
							&networkingv1.NetworkPolicyPortArgs{
								Port:     pulumi.Int(5432),
								Protocol: pulumi.String("TCP"),
							},
						},
					},
					// Allow DNS.
					&networkingv1.NetworkPolicyEgressRuleArgs{
						Ports: networkingv1.NetworkPolicyPortArray{
							&networkingv1.NetworkPolicyPortArgs{
								Port:     pulumi.Int(53),
								Protocol: pulumi.String("UDP"),
							},
						},
					},
					// Allow HTTPS egress (for OIDC well-known, token endpoints, etc).
					&networkingv1.NetworkPolicyEgressRuleArgs{
						Ports: networkingv1.NetworkPolicyPortArray{
							&networkingv1.NetworkPolicyPortArgs{
								Port:     pulumi.Int(443),
								Protocol: pulumi.String("TCP"),
							},
							&networkingv1.NetworkPolicyPortArgs{
								Port:     pulumi.Int(80),
								Protocol: pulumi.String("TCP"),
							},
						},
					},
				},
			},
		}, pulumi.DependsOn([]pulumi.Resource{ns, kcRelease}))
		if err != nil {
			return fmt.Errorf("creating keycloak network policy: %w", err)
		}

		// ── Stack Outputs ─────────────────────────────────────────────────────
		ctx.Export("keycloakUrl", pulumi.Sprintf("https://%s", hostname))
		ctx.Export("keycloakAdminUser", pulumi.String("admin"))
		ctx.Export("namespace", pulumi.String(namespace))
		ctx.Export("tlsNote", pulumi.String("Self-signed cert: use -k with curl or accept browser warning"))

		return nil
	})
}
