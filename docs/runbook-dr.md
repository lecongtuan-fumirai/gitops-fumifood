# Runbook: Disaster recovery (node lost)

**Targets:** RTO ~45 min · RPO cluster state 6h · floci data 6h (backup timer) · Neon DB handled by Neon/R2 dumps.

## What must exist outside the server
| Item | Where |
|---|---|
| This Git repo | GitHub `fumirai-ltd/platform-gitops` |
| age private key (`AGE-SECRET-KEY-...`) | Password manager + offline copy |
| Argo CD deploy key (private) | Password manager (or generate a new one and re-add to repo) |
| Backups `k3s-<host>-<ts>.tar.zst[.age]` | R2 `$R2_BUCKET/k3s/<host>/` |

## Path A (preferred): rebuild from Git
Apps are stateless except floci PVC; DB is Neon.
```bash
# 1. New Ubuntu 22.04/24.04 VPS, point DNS A records to the new IP
apt-get update && apt-get install -y git ansible
git clone git@github.com:lecongtuan-fumirai/gitops-fumifood.git /opt/platform-gitops && cd /opt/platform-gitops
# 2. Node + k3s (update ansible_host / tls_sans first if IP changed)
cd ansible && ansible-playbook site.yml && cd ..
# 3. Restore age key + deploy key, then bootstrap Argo CD
install -D -m600 /dev/stdin /root/.config/sops/age/keys.txt   # paste key, Ctrl-D
install -D -m600 /dev/stdin /root/.ssh/argocd_platform_gitops # paste key, Ctrl-D
./bootstrap/bootstrap.sh
# 4. Restore floci PVC data (after Argo CD created the PVC)
kubectl -n floci-prod scale deploy/floci --replicas=0
rclone copy r2:$R2_BUCKET/k3s/<host>/<latest> /tmp/ && age -d -i /root/.config/sops/age/keys.txt -o /tmp/b.tar.zst /tmp/<latest>
mkdir /tmp/b && tar -C /tmp/b -I zstd -xf /tmp/b.tar.zst && tar -C /tmp/b -xf /tmp/b/pvc-storage.tar
PV_DIR=$(ls -d /var/lib/rancher/k3s/storage/*floci-prod_floci-data*)
cp -a /tmp/b/storage/*floci-prod_floci-data*/. "$PV_DIR"/
kubectl -n floci-prod scale deploy/floci --replicas=1
# 5. Verify
kubectl -n argocd get applications && bash scripts/smoke-test.sh
```

## Path B: restore the datastore (same k3s version required)
```bash
systemctl stop k3s
tar -C /tmp/b -xf /tmp/b/k3s/server-tls-cred.tar -C /var/lib/rancher/k3s/server
cp /tmp/b/k3s/token /var/lib/rancher/k3s/server/token
cp /tmp/b/k3s/state.db /var/lib/rancher/k3s/server/db/state.db
rm -f /var/lib/rancher/k3s/server/db/state.db-{wal,shm}
systemctl start k3s
```

## Drill
Run Path A on a throw-away VM at least once per quarter; record duration here.

| Date | Path | Duration | Notes |
|---|---|---|---|
| | | | |
