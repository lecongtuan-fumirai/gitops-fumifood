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

See `docs/runbook-dr.md` for disaster recovery.
