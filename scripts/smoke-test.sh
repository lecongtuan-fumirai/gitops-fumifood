#!/usr/bin/env bash
# External smoke test for production endpoints. Usage:
#   scripts/smoke-test.sh                      # via public DNS
#   VIA=127.0.0.1:8080 SCHEME=http scripts/smoke-test.sh   # hit Traefik directly (transition)
set -uo pipefail
SCHEME=${SCHEME:-https}
VIA=${VIA:-}
FAIL=0

req() { # host path expected_code
  local host=$1 path=$2 want=$3 url resolve=() code
  if [ -n "$VIA" ]; then
    url="$SCHEME://$host:${VIA##*:}$path"; resolve=(--resolve "$host:${VIA##*:}:${VIA%%:*}")
  else
    url="$SCHEME://$host$path"
  fi
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${resolve[@]}" -H "X-Forwarded-Proto: https" "$url")
  if [ "$code" = "$want" ]; then printf '  \033[32mPASS\033[0m %-28s %-22s %s\n' "$host" "$path" "$code"
  else printf '  \033[31mFAIL\033[0m %-28s %-22s %s (want %s)\n' "$host" "$path" "$code" "$want"; FAIL=1; fi
}

echo "fumirai-lunch"
req fumifood.dpdns.org /health 200
req fumifood.dpdns.org / 200
req fumifood.dpdns.org "/socket.io/?EIO=4&transport=polling" 200
echo "floci"
req chungkhoanai.dpdns.org /_floci/health 200
req chungkhoanai.dpdns.org /_floci/ui 302
req chungkhoanai.dpdns.org /api/clouds 200
req chungkhoanai.dpdns.org /console/aws 200

[ "$FAIL" -eq 0 ] && echo "SMOKE OK" || { echo "SMOKE FAILED"; exit 1; }
