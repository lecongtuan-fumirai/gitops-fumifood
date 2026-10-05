#!/usr/bin/env bash
# Create the hub's secret files interactively. Values are never echoed and
# never written anywhere except hub/secrets/ (git-ignored).
#
# Usage: ./scripts/init-secrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets
chmod 700 secrets

write_secret() { # name value
  printf '%s' "$2" > "secrets/$1"
  # 0444 inside a 0700 dir: containers running as non-root (alertmanager=nobody,
  # grafana=472) can read the bind-mounted file, other host users cannot reach it.
  chmod 444 "secrets/$1"
  echo "  wrote secrets/$1"
}

ask() { # prompt -> stdin hidden
  local v; read -rsp "$1: " v; echo >&2; printf '%s' "$v"
}

echo "== vm_password (MUST match vmagent's password on vn1-01)"
echo "   On vn1-01 run:"
echo "   sops -d --extract '[\"stringData\"][\"password\"]' platform/monitoring/config/vmagent-remote-write.enc.yaml"
[ -s secrets/vm_password ] && echo "   exists, keeping" || write_secret vm_password "$(ask 'paste vm_password')"

echo "== telegram_bot_token (from @BotFather)"
[ -s secrets/telegram_bot_token ] && echo "   exists, keeping" || write_secret telegram_bot_token "$(ask 'paste bot token')"

echo "== telegram_chat_id (group id is negative, e.g. -100123...)"
if [ -s secrets/telegram_chat_id ]; then
  echo "   exists, keeping"
else
  read -rp "chat id: " cid
  [[ "$cid" =~ ^-?[0-9]+$ ]] || { echo "   not a number" >&2; exit 1; }
  write_secret telegram_chat_id "$cid"
fi

echo "== healthchecks_url (https://hc-ping.com/<uuid>, period 1m, grace 5m)"
[ -s secrets/healthchecks_url ] && echo "   exists, keeping" || write_secret healthchecks_url "$(ask 'paste ping URL')"

echo "== grafana_admin_password (generated)"
if [ -s secrets/grafana_admin_password ]; then
  echo "   exists, keeping"
else
  write_secret grafana_admin_password "$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  echo "   read it once with: cat secrets/grafana_admin_password  (then store it in your password manager)"
fi
echo "Done."
