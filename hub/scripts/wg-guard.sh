#!/usr/bin/env bash
# Least privilege for the vn1-01 WireGuard peer on miniappify.
#
# vn1-01 (10.66.66.10) may ONLY reach VictoriaMetrics ingest (10.66.66.1:8428).
# It must not reach other VPN peers, Grafana, SSH or any other host service.
#
# Why DOCKER-USER and not FORWARD: 10.66.66.1:8428 is a Docker-published port,
# so packets are DNAT'ed to the container and traverse FORWARD. A plain
# "FORWARD -s 10.66.66.10 -j DROP" would also kill ingestion. DOCKER-USER is
# evaluated before Docker's own rules and Docker never flushes it.
#
# Usage: wg-guard.sh up|down|status   (installed as monitoring-wg-guard.service)
set -euo pipefail
PEER="${WG_GUARD_PEER:-10.66.66.10/32}"
IFACE="${WG_GUARD_IFACE:-wg0}"
PORT="${WG_GUARD_PORT:-8428}"
TAG="monitoring-wg-guard"

FWD_ALLOW=(-i "$IFACE" -s "$PEER" -p tcp -m conntrack --ctorigdstport "$PORT" -m comment --comment "$TAG" -j RETURN)
FWD_DROP=(-i "$IFACE" -s "$PEER" -m comment --comment "$TAG" -j DROP)
# Host services (sshd, etc.) on the wg0 address. The WireGuard handshake itself
# arrives on the public interface, so this does not affect the tunnel.
IN_DROP=(-i "$IFACE" -s "$PEER" -m comment --comment "$TAG" -j DROP)

add() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
del() { while iptables -C "$@" 2>/dev/null; do iptables -D "$@"; done; }

case "${1:-}" in
  up)
    iptables -nL DOCKER-USER >/dev/null 2>&1 || { echo "DOCKER-USER chain missing (is docker running?)" >&2; exit 1; }
    # insert DROP first, then ALLOW above it => ALLOW is evaluated first
    add DOCKER-USER "${FWD_DROP[@]}"
    add DOCKER-USER "${FWD_ALLOW[@]}"
    add INPUT "${IN_DROP[@]}"
    ;;
  down)
    del DOCKER-USER "${FWD_ALLOW[@]}"
    del DOCKER-USER "${FWD_DROP[@]}"
    del INPUT "${IN_DROP[@]}"
    ;;
  status)
    iptables -S DOCKER-USER | grep -- "$TAG" || true
    iptables -S INPUT | grep -- "$TAG" || true
    ;;
  *) echo "usage: $0 up|down|status" >&2; exit 2 ;;
esac
