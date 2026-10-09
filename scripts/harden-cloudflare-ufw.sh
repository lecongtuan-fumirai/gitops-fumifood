#!/usr/bin/env bash
# ==============================================================================
# Harden UFW Firewall: Restrict HTTP (80) & HTTPS (443) to Cloudflare & VPN only
# Prevents direct-to-origin DDoS attacks bypassing Cloudflare proxy.
# ==============================================================================

set -euo pipefail

echo "===> [1/4] Fetching latest Cloudflare IP ranges..."
CF_IPV4=$(curl -sSL https://www.cloudflare.com/ips-v4)
CF_IPV6=$(curl -sSL https://www.cloudflare.com/ips-v6)

echo "===> [2/4] Allowing Local, Cluster, and VPN traffic to ports 80/443..."
# Localhost & Host
ufw allow from 127.0.0.1 to any port 80 proto tcp comment 'Localhost HTTP' || true
ufw allow from 127.0.0.1 to any port 443 proto tcp comment 'Localhost HTTPS' || true
ufw allow from 13.140.183.90 to any port 80 proto tcp comment 'Host IP HTTP' || true
ufw allow from 13.140.183.90 to any port 443 proto tcp comment 'Host IP HTTPS' || true

# Kubernetes pod & service CIDRs
ufw allow from 10.42.0.0/16 to any port 80 proto tcp comment 'K3s Pods HTTP' || true
ufw allow from 10.42.0.0/16 to any port 443 proto tcp comment 'K3s Pods HTTPS' || true
ufw allow from 10.43.0.0/16 to any port 80 proto tcp comment 'K3s Services HTTP' || true
ufw allow from 10.43.0.0/16 to any port 443 proto tcp comment 'K3s Services HTTPS' || true

# WireGuard VPN Hub
ufw allow from 10.66.66.0/24 to any port 80 proto tcp comment 'WireGuard Hub HTTP' || true
ufw allow from 10.66.66.0/24 to any port 443 proto tcp comment 'WireGuard Hub HTTPS' || true

echo "===> [3/4] Adding Cloudflare IP rules..."
for ip in $CF_IPV4; do
  ufw allow from "$ip" to any port 80 proto tcp comment 'Cloudflare IPv4 HTTP'
  ufw allow from "$ip" to any port 443 proto tcp comment 'Cloudflare IPv4 HTTPS'
done

for ip in $CF_IPV6; do
  ufw allow from "$ip" to any port 80 proto tcp comment 'Cloudflare IPv6 HTTP'
  ufw allow from "$ip" to any port 443 proto tcp comment 'Cloudflare IPv6 HTTPS'
done

echo "===> [4/4] Removing global open rules for 80 and 443..."
ufw delete allow 80/tcp || true
ufw delete allow 443/tcp || true
ufw delete allow 80 || true
ufw delete allow 443 || true

echo "===> Reloading UFW..."
ufw reload

echo "===> Done! UFW status:"
ufw status verbose
