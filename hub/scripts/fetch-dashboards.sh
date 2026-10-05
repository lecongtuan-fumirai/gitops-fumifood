#!/usr/bin/env bash
# Download community dashboards from grafana.com and bind them to the
# provisioned datasource (uid "victoriametrics"). Re-run to update; commit the
# resulting JSON so the hub is reproducible from Git.
#
# Usage: ./scripts/fetch-dashboards.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=grafana/dashboards
DS_UID=victoriametrics

# folder|grafana.com id|file name
DASHBOARDS=(
  "Hosts|1860|node-exporter-full"
  "Kubernetes|15757|k8s-views-global"
  "Kubernetes|15758|k8s-views-namespaces"
  "Kubernetes|15759|k8s-views-nodes"
  "Kubernetes|15760|k8s-views-pods"
  "Platform|17346|traefik"
  "Platform|14584|argocd"
  "Platform|11001|cert-manager"
  "Monitoring|10229|victoriametrics-single"
  "Monitoring|12683|vmagent"
  "Monitoring|14950|vmalert"
  "Monitoring|13659|blackbox-http"
  "Hosts|15798|docker-cadvisor"
)

for entry in "${DASHBOARDS[@]}"; do
  IFS='|' read -r folder id name <<<"$entry"
  mkdir -p "$OUT/$folder"
  dest="$OUT/$folder/$name.json"
  echo "-> $folder/$name (grafana.com #$id)"
  if ! curl -fsSL --retry 3 "https://grafana.com/api/dashboards/$id/revisions/latest/download" -o "$dest.tmp"; then
    echo "   !! download failed for #$id, skipping" >&2; rm -f "$dest.tmp"; continue
  fi
  # Replace every datasource input variable (${DS_PROMETHEUS}, ${DS_VICTORIAMETRICS}, ...)
  # with our fixed uid, and drop __inputs so Grafana does not ask for them.
  python3 - "$dest.tmp" "$dest" "$DS_UID" <<'PY'
import json, re, sys
src, dst, uid = sys.argv[1:4]
raw = open(src).read()
raw = re.sub(r'\$\{DS_[A-Za-z0-9_-]+\}', uid, raw)
d = json.loads(raw)
d.pop("__inputs", None); d.pop("__requires", None)
d["id"] = None
open(dst, "w").write(json.dumps(d, indent=2))
PY
  rm -f "$dest.tmp"
done
echo "Done. Grafana picks up changes within 60s."
