# Runbook: Zero-downtime migration from host nginx/compose to K3s

State machine per domain: `compose` → `k3s-via-nginx` (Phase 4) → `k3s-direct` (Phase 5).
Rollback at any point = restore the backed-up vhost and `nginx -s reload` (seconds).

## Phase 4 – route one vhost through Traefik (TLS still on host nginx)

Pre-checks
```bash
kubectl -n argocd get applications                     # all Synced/Healthy
VIA=127.0.0.1:8080 SCHEME=http scripts/smoke-test.sh  # Traefik answers for both hosts
```

1. Backup: `cp /etc/nginx/sites-available/<host>.conf /root/nginx-backup/<host>.conf.$(date +%s)`
2. In the **:80 server**, let ACME challenges fall through to Traefik (cert-manager) while keeping certbot working:
   ```nginx
   location /.well-known/acme-challenge/ {
       root /var/www/html;
       try_files $uri @k3s_acme;
   }
   location @k3s_acme {
       proxy_pass http://127.0.0.1:8080;
       proxy_set_header Host $host;
   }
   ```
3. In the **:443 server**, replace every `location` block with:
   ```nginx
   location / {
       proxy_pass http://127.0.0.1:8080;
       proxy_http_version 1.1;
       proxy_set_header Upgrade $http_upgrade;
       proxy_set_header Connection $connection_upgrade;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto https;
       proxy_buffering off;
       proxy_request_buffering off;
       proxy_read_timeout 86400s;
       proxy_send_timeout 600s;
   }
   ```
   Keep the existing `client_max_body_size` (50M fumifood, 5000M chungkhoanai).
4. `nginx -t && nginx -s reload`, then `scripts/smoke-test.sh` (public DNS).
5. Watch `kubectl get certificate -A` until `READY=True` (cert-manager issued via the ACME fallthrough).
6. Stop the old containers for that domain only after 24h of clean metrics:
   - fumifood: `cd /opt/fumirai-lunch && docker compose down` (or the compose dir in use)
   - chungkhoanai: `systemctl disable --now floci` (floci data already copied into the PVC)

Order: fumifood.dpdns.org first (stateless), chungkhoanai.dpdns.org second (needs PVC data copy
right before switch: `docker compose stop floci` → copy `/home/floci/data` → switch vhost).

## Phase 5 – Traefik takes :80/:443 directly

Both domains must have `READY=True` certificates in the cluster.
1. PR in platform-gitops `platform/traefik/values.yaml`: `exposedPort` 80/443 + enable web→websecure redirect.
2. Merge, then immediately on the host: `systemctl disable --now nginx` (svclb binds the ports within seconds).
3. `scripts/smoke-test.sh`. Gap is limited to the port handover (~5–10 s), no TLS gap.
4. Rollback: `systemctl start nginx` after reverting the PR (Traefik back on 8080/8443).
