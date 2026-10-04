#!/usr/bin/env bash
# Offline validation for platform-gitops. Runs locally and in CI (no cluster, no age key).
#  1. every *.enc.yaml is SOPS-encrypted; no plaintext Secret manifests anywhere else
#  2. every kustomization renders (KSOPS generators stripped: CI has no decryption key)
#  3. every Helm-based platform component renders with its pinned chart + values
#  4. everything passes kubeconform (core + CRD schemas)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0
SCHEMAS=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

echo "== 1. secrets hygiene"
while IFS= read -r f; do
  if ! grep -q '^sops:' "$f"; then red "NOT ENCRYPTED: $f"; FAIL=1; fi
done < <(find "$ROOT" -name '*.enc.yaml' -not -path '*/.git/*')
while IFS= read -r f; do
  red "PLAINTEXT Secret manifest: $f (must be *.enc.yaml)"; FAIL=1
done < <(grep -rlE '^kind:\s*Secret\s*$' "$ROOT/apps" "$ROOT/platform" "$ROOT/clusters" --include='*.yaml' | grep -v '\.enc\.yaml$' || true)

echo "== 2. kustomize build"
cp -a "$ROOT" "$WORK/repo"
find "$WORK/repo" -name kustomization.yaml -exec yq -i 'del(.generators)' {} \;
mkdir -p "$WORK/out"
while IFS= read -r k; do
  dir=$(dirname "$k"); rel=${dir#"$WORK/repo/"}
  out="$WORK/out/$(echo "$rel" | tr / _).yaml"
  if kustomize build "$dir" > "$out" 2> "$out.err"; then
    green "  ok  $rel"
  else
    red "  FAIL $rel"; sed 's/^/       /' "$out.err"; FAIL=1
  fi
done < <(find "$WORK/repo/apps" "$WORK/repo/platform" "$WORK/repo/clusters" -name kustomization.yaml | sort)

echo "== 3. helm template (pinned charts)"
render_chart() { # app-file
  local f=$1 repo chart ver vals name ns
  repo=$(yq 'select(.kind=="Application") | .spec.sources[0].repoURL' "$f" | sed -n 1p)
  chart=$(yq 'select(.kind=="Application") | .spec.sources[0].chart' "$f" | sed -n 1p)
  ver=$(yq 'select(.kind=="Application") | .spec.sources[0].targetRevision' "$f" | sed -n 1p)
  vals=$(yq 'select(.kind=="Application") | .spec.sources[0].helm.valueFiles[0]' "$f" | sed -n 1p | sed 's#\$values/##')
  name=$(yq 'select(.kind=="Application") | .spec.sources[0].helm.releaseName' "$f" | sed -n 1p)
  ns=$(yq 'select(.kind=="Application") | .spec.destination.namespace' "$f" | sed -n 1p)
  [ "$chart" = "null" ] && return 0
  if helm template "$name" "$chart" --repo "$repo" --version "$ver" -n "$ns" -f "$ROOT/$vals" \
       --kube-version 1.36.0 > "$WORK/out/helm_$name.yaml" 2> "$WORK/out/helm_$name.err"; then
    green "  ok  $chart@$ver"
  else
    red "  FAIL $chart@$ver"; sed 's/^/       /' "$WORK/out/helm_$name.err"; FAIL=1
  fi
}
for f in "$ROOT"/clusters/prod/platform/*.yaml; do render_chart "$f"; done

echo "== 4. kubeconform"
if ! kubeconform -strict -summary -ignore-missing-schemas "${SCHEMAS[@]}" "$WORK"/out/*.yaml; then
  FAIL=1
fi

[ "$FAIL" -eq 0 ] && green "ALL CHECKS PASSED" || { red "VALIDATION FAILED"; exit 1; }
