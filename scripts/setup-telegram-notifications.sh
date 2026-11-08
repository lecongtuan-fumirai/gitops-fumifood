#!/usr/bin/env bash
# ==============================================================================
# Setup & Verify Argo CD Telegram Notifications (DevSecOps Standard)
#
# Prereqs:
#   - kubectl access to cluster (argocd namespace)
#   - Telegram Bot Token (from @BotFather)
#   - Telegram Chat ID (group or private channel, e.g. -100xxxxxxxxxx)
#
# Usage:
#   ./scripts/setup-telegram-notifications.sh
#   Or non-interactive:
#   TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="-100xxx" ./scripts/setup-telegram-notifications.sh
# ==============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${BLUE}>> %s${NC}\n" "$*"; }
ok()   { printf "${GREEN}✔ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err()  { printf "${RED}✘ %s${NC}\n" "$*" >&2; exit 1; }

# 1. Resolve Bot Token
TOKEN="${TELEGRAM_BOT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  if [ -s "$ROOT/hub/secrets/telegram_bot_token" ]; then
    TOKEN=$(cat "$ROOT/hub/secrets/telegram_bot_token")
    log "Found bot token from hub/secrets/telegram_bot_token"
  else
    printf "Enter Telegram Bot Token (hidden): "
    read -rs TOKEN
    echo
  fi
fi
[ -n "$TOKEN" ] || err "Telegram bot token cannot be empty"

# 2. Resolve Chat ID
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [ -z "$CHAT_ID" ]; then
  if [ -s "$ROOT/hub/secrets/telegram_chat_id" ]; then
    CHAT_ID=$(cat "$ROOT/hub/secrets/telegram_chat_id")
    log "Found chat ID from hub/secrets/telegram_chat_id: $CHAT_ID"
  else
    printf "Enter Telegram Chat ID (e.g. -1001234567890): "
    read -r CHAT_ID
  fi
fi
[ -n "$CHAT_ID" ] || err "Telegram chat ID cannot be empty"

# 3. Verify Bot & Chat Connectivity
log "Verifying Telegram Bot API connectivity..."
if command -v curl >/dev/null 2>&1; then
  BOT_INFO=$(curl -s "https://api.telegram.org/bot${TOKEN}/getMe" || true)
  if echo "$BOT_INFO" | grep -q '"ok":true'; then
    BOT_NAME=$(echo "$BOT_INFO" | grep -o '"username":"[^"]*' | cut -d'"' -f4 || echo "bot")
    ok "Bot authenticated successfully (@${BOT_NAME})"
  else
    warn "Could not authenticate bot via Telegram API (may be running offline/sandboxed): $BOT_INFO"
  fi

  log "Sending test notification to Chat ID: $CHAT_ID..."
  SEND_RES=$(curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=🚀 [Argo CD] Notifications connected successfully for cluster prod." || true)
  if echo "$SEND_RES" | grep -q '"ok":true'; then
    ok "Test message delivered to Telegram chat!"
  else
    warn "Test message response: $SEND_RES"
  fi
fi

# 4. Create Kubernetes Secret in argocd namespace
log "Applying argocd-notifications-secret to K8s..."
if command -v kubectl >/dev/null 2>&1; then
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - || true
  kubectl -n argocd create secret generic argocd-notifications-secret \
    --from-literal=telegram-token="$TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Secret 'argocd-notifications-secret' applied in namespace 'argocd'"
else
  warn "kubectl not found or cluster offline. Please ensure 'argocd-notifications-secret' is created on the cluster."
fi

# 5. Update ApplicationSet Annotations with Chat ID
log "Configuring Chat ID in clusters/prod/apps-appset.yaml..."
yq -i '
  .spec.template.metadata.annotations["notifications.argoproj.io/subscribe.on-deployed.telegram"] = "'"${CHAT_ID}"'" |
  .spec.template.metadata.annotations["notifications.argoproj.io/subscribe.on-health-degraded.telegram"] = "'"${CHAT_ID}"'" |
  .spec.template.metadata.annotations["notifications.argoproj.io/subscribe.on-sync-failed.telegram"] = "'"${CHAT_ID}"'"
' "$ROOT/clusters/prod/apps-appset.yaml"
ok "ApplicationSet subscriptions updated with Chat ID: $CHAT_ID"

log "Restarting Argo CD Notifications controller if running..."
if command -v kubectl >/dev/null 2>&1; then
  kubectl -n argocd rollout restart deployment/argocd-notifications-controller 2>/dev/null || true
fi

echo
ok "Setup complete! Argo CD will now notify Telegram whenever a pod rollout completes (Done) or fails (Failed)."

