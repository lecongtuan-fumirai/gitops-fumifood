# platform-gitops

GitOps source of truth for the Fumirai K3s platform (cluster `prod`, node `vn1-01`).

| Layer | Managed by | Path |
|---|---|---|
| Node (OS hardening, swap, k3s, backups) | Ansible | `ansible/` |
| Argo CD bootstrap (one-off) | `bootstrap/bootstrap.sh` | `bootstrap/` |
| Cluster wiring (projects, platform apps, ApplicationSet) | Argo CD root app | `clusters/prod/` |
| Shared platform components | Argo CD (project `platform`) | `platform/` |
| Workloads | Argo CD ApplicationSet (project `apps`) | `apps/<app>/overlays/<env>` |

## Golden rules
1. Nothing is applied by hand except `bootstrap/`. Everything else goes through a PR.
2. Images are pinned by tag + digest. `latest` is forbidden.
3. Secrets are committed **only** SOPS-encrypted (`*.enc.yaml`). `scripts/validate.sh` fails otherwise.
4. Every container declares requests/limits (also enforced by LimitRange).
5. Production overlays change only via reviewed PR; CI bot may push to `overlays/staging/**` only.

## Adding a new service
```
apps/<name>/base/            # Deployment, Service, Ingress, NetworkPolicy
apps/<name>/overlays/<env>/  # kustomization.yaml (namespace <name>-<env|prod>), secrets.enc.yaml
platform/namespaces/<name>.yaml
```
The `apps` ApplicationSet picks it up automatically as `<name>-<env>`.

## Day-2 commands
```bash
# kubectl from a laptop (API is never exposed publicly)
ssh -N -L 6443:127.0.0.1:6443 root@13.140.183.90
# Argo CD UI
ssh -N -L 8081:127.0.0.1:8081 root@13.140.183.90   # then on server: kubectl -n argocd port-forward svc/argocd-server 8081:80
# Edit a secret
sops apps/fumirai-lunch/overlays/production/secrets.enc.yaml
# Validate everything locally
./scripts/validate.sh
```

## Troubleshooting & Debugging

### 1. Workload & Pod Issues (CrashLoopBackOff, Pending, Restarts)
```bash
# List all pods with status and node placement
kubectl get pods -A -o wide

# Filter pods that are not Running or Completed
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Inspect pod events, exit codes, and failure reasons (OOMKilled, probe failures)
kubectl describe pod <pod-name> -n <namespace>

# Stream live container logs
kubectl logs -f <pod-name> -n <namespace> [-c <container-name>]

# Check logs of previous crashed container instance
kubectl logs --previous <pod-name> -n <namespace>

# Restart a deployment (e.g. reload Secret or ConfigMap updates)
kubectl rollout restart deployment/<deploy-name> -n <namespace>
kubectl rollout status deployment/<deploy-name> -n <namespace>

# Shell into a running container
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh
```

### 2. Node & Cluster Health (OOM, High Resource Usage)
```bash
# Check node status and conditions
kubectl get nodes -o wide
kubectl describe node vn1-01

# Inspect CPU & Memory usage across cluster
kubectl top nodes
kubectl top pods -A --sort-by=memory
kubectl top pods -A --sort-by=cpu

# Cluster-wide events sorted chronologically (warnings, scheduling, evictions)
kubectl get events -A --sort-by='.metadata.creationTimestamp'

# K3s system service logs on the host server
journalctl -u k3s -f --no-tail
```

### 3. Ingress, Networking & TLS Certificates
```bash
# Check Services and target Endpoints
kubectl get svc,ep -n <namespace>

# Inspect Ingress definitions and hosts
kubectl get ingress -A
kubectl describe ingress <ingress-name> -n <namespace>

# Traefik ingress controller logs (traffic routing, SSL handshakes)
kubectl logs -n traefik -l app.kubernetes.io/name=traefik -f --tail=100

# Check cert-manager SSL certificates, orders, and challenges
kubectl get certificate,certificaterequest,order,challenge -A
kubectl describe certificate <cert-name> -n <namespace>
```

### 4. Argo CD & GitOps Sync Failures
```bash
# View all applications sync and health status
kubectl get applications -n argocd

# Inspect sync error or diff details
kubectl describe application <app-name> -n argocd

# Argo CD repo-server logs (KSOPS decrypt, kustomize render issues)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -f --tail=100

# Trigger a manual sync on an application
kubectl patch application <app-name> -n argocd --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

### 5. Secrets & KSOPS Decryption Verification
```bash
# Verify decrypted secret contents inside cluster
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.<KEY>}' | base64 -d; echo

# Local SOPS decrypt check
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d apps/<app>/overlays/<env>/secrets.enc.yaml
```

## Documentation & Runbooks
- [docs/k3s-cluster-architecture.md](docs/k3s-cluster-architecture.md): **Core K3s Cluster Architecture & System Design**
- [docs/security-hardening-and-ddos-runbook.md](docs/security-hardening-and-ddos-runbook.md): **Security Hardening, Anti-DDoS Architecture & Incident Runbook**
- [docs/monitoring-hub-architecture-and-runbook.md](docs/monitoring-hub-architecture-and-runbook.md): Cross-Region Monitoring Hub Architecture & Operations
- [docs/runbook-cutover.md](docs/runbook-cutover.md): Zero-downtime migration and ingress cutover
- [docs/runbook-dr.md](docs/runbook-dr.md): Disaster recovery runbook
