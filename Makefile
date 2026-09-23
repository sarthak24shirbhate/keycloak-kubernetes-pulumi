# Makefile for keycloak-kubernetes-pulumi
# Uses pwsh (PowerShell 7+) on Windows. Compatible with GNU make.
#
# Usage:
#   make help         — show available targets
#   make bootstrap    — install deps, create cluster, configure context
#   make certs        — generate self-signed TLS certificate (standalone helper)
#   make deploy       — run pulumi up (deploy all resources)
#   make verify       — run PASS/FAIL verification suite
#   make credentials  — print Keycloak admin password
#   make status       — show cluster and pod status
#   make destroy      — tear down all resources

SHELL        := pwsh.exe
.SHELLFLAGS  := -NoProfile -NonInteractive -Command

REPO_ROOT    := $(shell (Get-Location).Path)
PULUMI_DIR   := $(REPO_ROOT)/pulumi
SCRIPTS_DIR  := $(REPO_ROOT)/scripts
PULUMI_STATE := file://$(REPO_ROOT)/.pulumi-state

.PHONY: help bootstrap cluster certs deploy verify credentials status destroy

help: ## Show available make targets
	@Write-Host ""
	@Write-Host "  Keycloak Kubernetes IaC — Available targets:" -ForegroundColor Cyan
	@Write-Host ""
	@Write-Host "  make bootstrap    Install deps, start Docker, create k3d cluster" -ForegroundColor White
	@Write-Host "  make cluster      Create k3d cluster only" -ForegroundColor White
	@Write-Host "  make certs        Generate standalone TLS certificate" -ForegroundColor White
	@Write-Host "  make deploy       Run pulumi up (deploy all Kubernetes resources)" -ForegroundColor White
	@Write-Host "  make verify       Run PASS/FAIL verification suite" -ForegroundColor White
	@Write-Host "  make credentials  Print the Keycloak admin password" -ForegroundColor White
	@Write-Host "  make status       Show cluster/pod/ingress status" -ForegroundColor White
	@Write-Host "  make destroy      Destroy all resources (prompts for cluster deletion)" -ForegroundColor White
	@Write-Host ""

bootstrap: ## Install deps, ensure Docker, create k3d cluster, configure Pulumi
	pwsh -NoProfile -File "$(SCRIPTS_DIR)/bootstrap.ps1"

cluster: ## Create k3d cluster only (Docker must be running)
	@k3d cluster create keycloak-cluster \
		--api-port 6443 \
		--port "8443:443@loadbalancer" \
		--port "8080:80@loadbalancer" \
		--k3s-arg "--disable=traefik@server:0" \
		--wait; \
	k3d kubeconfig merge keycloak-cluster --kubeconfig-switch-context

certs: ## Generate self-signed TLS certificate
	pwsh -NoProfile -File "$(SCRIPTS_DIR)/generate-certs.ps1"

deploy: ## Deploy all resources via Pulumi
	pwsh -NoProfile -File "$(SCRIPTS_DIR)/deploy.ps1"

verify: ## Run PASS/FAIL end-to-end verification
	pwsh -NoProfile -File "$(SCRIPTS_DIR)/verify.ps1"

credentials: ## Retrieve and print the Keycloak admin password
	@$$env:PULUMI_BACKEND_URL = "$(PULUMI_STATE)"; \
	Push-Location "$(PULUMI_DIR)"; \
	try { \
		Write-Host ""; \
		Write-Host "  Keycloak Admin Credentials:" -ForegroundColor Cyan; \
		Write-Host "  URL:      https://keycloak.local" -ForegroundColor White; \
		Write-Host "  Username: admin" -ForegroundColor White; \
		$$pass = pulumi config get keycloakAdminPassword 2>$$null; \
		if (-not $$pass) { \
			$$pass = kubectl get secret keycloak-admin-credentials -n keycloak \
				-o jsonpath='{.data.admin-password}' 2>$$null | \
				ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($$_)) }; \
		}; \
		Write-Host "  Password: $$pass" -ForegroundColor Green; \
		Write-Host "" \
	} finally { Pop-Location }

status: ## Show cluster and pod status
	@Write-Host "── Nodes ──" -ForegroundColor Cyan; \
	kubectl get nodes -o wide; \
	Write-Host ""; \
	Write-Host "── Pods (keycloak ns) ──" -ForegroundColor Cyan; \
	kubectl get pods -n keycloak -o wide; \
	Write-Host ""; \
	Write-Host "── Services ──" -ForegroundColor Cyan; \
	kubectl get svc -n keycloak; \
	Write-Host ""; \
	Write-Host "── Ingress ──" -ForegroundColor Cyan; \
	kubectl get ingress -n keycloak; \
	Write-Host ""; \
	Write-Host "── NetworkPolicies ──" -ForegroundColor Cyan; \
	kubectl get networkpolicy -n keycloak

destroy: ## Destroy all deployed resources
	pwsh -NoProfile -File "$(SCRIPTS_DIR)/destroy.ps1"
