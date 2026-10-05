#!/usr/bin/env bash
# Pre-flight checks on miniappify before `docker compose up -d`.
# Read-only: changes nothing. Exit code != 0 if a blocking check fails.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }

echo "== Resources"
avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
[ "$avail_mb" -ge 1500 ] && ok "MemAvailable ${avail_mb}MiB (stack caps ~1.2GiB)" || bad "MemAvailable ${avail_mb}MiB < 1500MiB"
free_gb=$(df -BG --output=avail /var/lib/docker | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 8 ] && ok "Disk free for /var/lib/docker: ${free_gb}G" || bad "Disk free ${free_gb}G < 8G (VM needs ~3G + 2G safety margin)"

echo "== Docker"
docker compose version >/dev/null 2>&1 && ok "$(docker compose version | head -1)" || bad "docker compose v2 missing"
docker compose config -q 2>/dev/null && ok "compose file valid" || bad "docker compose config failed"

echo "== WireGuard"
if ip -4 addr show wg0 2>/dev/null | grep -q '10.66.66.1/'; then ok "wg0 has 10.66.66.1"; else bad "wg0 with 10.66.66.1 not found"; fi
if wg show wg0 allowed-ips 2>/dev/null | grep -q '10.66.66.10/32'; then ok "peer vn1-01 (10.66.66.10/32) configured"; else warn "peer 10.66.66.10/32 not yet on wg0 (step 2 of README)"; fi
hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '$2>0{print $2}' | sort -n | tail -1)
if grep -q '^SaveConfig *= *true' /etc/wireguard/wg0.conf 2>/dev/null; then warn "wg0.conf has SaveConfig=true: edit with 'wg set' + 'wg-quick save', not by hand"; fi
if systemctl cat docker 2>/dev/null | grep -q 'wg-quick@wg0'; then ok "docker starts after wg-quick@wg0"; else warn "docker has no After=wg-quick@wg0 drop-in (VM bind to 10.66.66.1 can fail at boot)"; fi

echo "== Ports"
for p in 10.66.66.1:8428 127.0.0.1:8428 127.0.0.1:3000 10.66.66.1:3000 127.0.0.1:9093 172.30.0.1:9100; do
  if ss -ltnH "( sport = :${p##*:} )" | awk '{print $4}' | grep -qE "^(\*|0\.0\.0\.0|\[::\]|${p%:*}):${p##*:}$"; then
    docker ps --format '{{.Names}}' | grep -q '^monitoring-' && ok "$p in use (by this stack)" || bad "$p already in use by something else"
  else ok "$p free"; fi
done

echo "== Firewall"
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  ok "ufw active"
  ufw status | grep -q '172.30.0.0/24' && ok "ufw allows monitoring bridge -> node-exporter" || warn "add: ufw allow in on br-monitoring from 172.30.0.0/24 to 172.30.0.1 port 9100 proto tcp"
else
  warn "ufw inactive: published ports are still private (bound to 127.0.0.1 / 10.66.66.1 / 172.30.0.1)"
fi

echo "== Secrets"
for s in vm_password telegram_bot_token telegram_chat_id healthchecks_url grafana_admin_password; do
  [ -s "secrets/$s" ] && ok "secrets/$s" || bad "secrets/$s missing (run scripts/init-secrets.sh)"
done
[ "$(stat -c %a secrets 2>/dev/null)" = "700" ] && ok "secrets/ is 0700" || bad "chmod 700 secrets"
grep -qE '^-?[0-9]+$' secrets/telegram_chat_id 2>/dev/null && ok "telegram chat id is numeric" || bad "secrets/telegram_chat_id must be a number"
docker compose run --rm --no-deps --entrypoint amtool alertmanager check-config /etc/alertmanager/alertmanager.yml >/dev/null 2>&1 \
  && ok "alertmanager config valid (amtool)" || bad "amtool check-config failed: docker compose run --rm --no-deps --entrypoint amtool alertmanager check-config /etc/alertmanager/alertmanager.yml"

echo
[ "$FAIL" -eq 0 ] && echo "PREFLIGHT OK" || { echo "PREFLIGHT FAILED"; exit 1; }
