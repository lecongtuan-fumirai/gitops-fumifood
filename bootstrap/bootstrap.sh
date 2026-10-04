#!/usr/bin/env bash
# One-off Argo CD bootstrap. Everything after this is reconciled from Git.
#
# Prereqs:
#   - k3s running (ansible-playbook ansible/site.yml)
#   - age private key at $SOPS_AGE_KEY_FILE (default /root/.config/sops/age/keys.txt)
#   - read-only deploy key for git@github.com:lecongtuan-fumirai/gitops-fumifood.git at $DEPLOY_KEY
#
# Idempotent: safe to re-run.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-/root/.config/sops/age/keys.txt}
DEPLOY_KEY=${DEPLOY_KEY:-/root/.ssh/argocd_platform_gitops}
REPO_URL=git@github.com:lecongtuan-fumirai/gitops-fumifood.git
ARGOCD_CHART_VERSION=$(yq '.spec.sources[0].targetRevision' "$ROOT/clusters/prod/platform/argocd.yaml")

log() { printf '\n\033[1;34m>> %s\033[0m\n' "$*"; }

log "Preflight"
kubectl get nodes
test -s "$SOPS_AGE_KEY_FILE" || { echo "missing age key $SOPS_AGE_KEY_FILE"; exit 1; }
test -s "$DEPLOY_KEY" || { echo "missing deploy key $DEPLOY_KEY"; exit 1; }

log "PriorityClasses (Argo CD pods reference platform-critical)"
kubectl apply --server-side --force-conflicts -f "$ROOT/platform/namespaces/priority-classes.yaml"

log "argocd namespace + SOPS age key"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt="$SOPS_AGE_KEY_FILE" --dry-run=client -o yaml | kubectl apply -f -

log "Repository credentials (read-only deploy key)"
kubectl -n argocd create secret generic repo-platform-gitops \
  --from-literal=type=git --from-literal=url="$REPO_URL" \
  --from-file=sshPrivateKey="$DEPLOY_KEY" --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f -

log "Install Argo CD chart $ARGOCD_CHART_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd \
  --version "$ARGOCD_CHART_VERSION" -f "$ROOT/platform/argocd/values.yaml" \
  --wait --timeout 10m

log "Root application"
kubectl apply -f "$ROOT/bootstrap/root-app.yaml"

log "Done. Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "Store it in the password manager, then: kubectl -n argocd delete secret argocd-initial-admin-secret"
