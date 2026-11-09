#!/usr/bin/env bash
# ==============================================================================
# VPS Clean Slate Script (Factory Reset to Fresh OS State)
#
# Dọn dẹp sạch sẽ toàn bộ tàn dư của K3s, GitOps, WireGuard, CNI iptables,
# timers và cache để trả VPS về trạng thái sạch sẽ như lúc mới thuê.
#
# ĐẢM BẢO AN TOÀN: Giữ nguyên quyền SSH truy cập vào VPS (/root/.ssh/authorized_keys)
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { printf "${BLUE}>> %s${NC}\n" "$*"; }
ok()   { printf "${GREEN}✔ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err()  { printf "${RED}✘ %s${NC}\n" "$*" >&2; exit 1; }

echo -e "${RED}${BOLD}=================================================================="
echo -e "       CẢNH BÁO: BẠN ĐANG CHUẨN BỊ RESET VPS VỀ TRẠNG THÁI SẠCH   "
echo -e "==================================================================${NC}"
echo "Thao tác này sẽ xoá:"
echo "  1. Toàn bộ tàn dư K3s, Rancher, Kubelet, CNI"
echo "  2. Toàn bộ cấu hình VPN WireGuard cũ"
echo "  3. Toàn bộ Timers & Backup services (k3s-backup)"
echo "  4. Các công cụ devops/cli cũ (sops, kustomize, kubeconform, crictl, etc.)"
echo "  5. Cấu hình .kube, .config/sops, .config/helm, .config/rclone"
echo "  6. Dọn sạch iptables CNI và log rác hệ thống"
echo
read -rp "Bạn có chắc chắn muốn dọn sạch VPS? (gõ 'clean' để xác nhận): " confirm
if [ "$confirm" != "clean" ]; then
  echo "Đã huỷ thao tác."
  exit 0
fi

log "1. Dừng và xoá triệt để các dịch vụ K3s & Backup..."
systemctl stop k3s 2>/dev/null || true
systemctl disable k3s 2>/dev/null || true
systemctl stop k3s-backup.timer 2>/dev/null || true
systemctl disable k3s-backup.timer 2>/dev/null || true
systemctl stop k3s-backup.service 2>/dev/null || true
systemctl disable k3s-backup.service 2>/dev/null || true
rm -f /etc/systemd/system/k3s-backup.service /etc/systemd/system/k3s-backup.timer /etc/systemd/system/k3s.service
systemctl daemon-reload 2>/dev/null || true
ok "Đã dọn sạch systemd services & timers"

log "2. Dừng và dọn sạch VPN WireGuard..."
systemctl stop wg-quick@wg-hub 2>/dev/null || true
systemctl disable wg-quick@wg-hub 2>/dev/null || true
systemctl stop wg-quick@wg0 2>/dev/null || true
systemctl disable wg-quick@wg0 2>/dev/null || true
rm -rf /etc/wireguard
ok "Đã gỡ sạch WireGuard"

log "3. Xoá toàn bộ tàn dư thư mục dữ liệu K3s & CNI..."
rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /var/lib/cni /etc/cni
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ok "Đã xoá sạch /var/lib/rancher, /etc/rancher, /var/lib/kubelet và card mạng CNI"

log "4. Xoá các binary K3s và Devops tools cũ..."
rm -f /usr/local/bin/k3s /usr/local/bin/k3s-* /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr
rm -f /usr/local/bin/kustomize /usr/local/bin/kubeconform /usr/local/bin/sops /usr/local/bin/yq /usr/local/bin/k6 /usr/local/bin/age*
ok "Đã dọn sạch /usr/local/bin"

log "5. Xoá cấu hình ẩn và credentials cũ của root (BẢO VỆ .ssh/authorized_keys)..."
rm -rf /root/.kube
rm -rf /root/.config/sops
rm -rf /root/.config/helm
rm -rf /root/.config/rclone
rm -rf /root/.cache/*
ok "Đã xoá sạch .kube, .config/sops, .config/helm, .config/rclone (authorized_keys được giữ nguyên)"

log "6. Reset iptables về mặc định (chỉ giữ kết nối SSH)..."
if command -v iptables >/dev/null 2>&1; then
  # Flush all Kube / CNI chains
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  iptables -t raw -F
  iptables -t raw -X
  ok "Đã reset iptables"
fi

log "7. Dọn dẹp bộ nhớ đệm hệ thống (APT cache, /tmp)..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get autoremove -y >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
fi
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
ok "Đã dọn sạch APT cache và /tmp"

echo
ok "=================================================================="
ok "       VPS ĐÃ ĐƯỢC RESET HOÀN TOÀN VỀ TRẠNG THÁI NHƯ MỚI THUÊ!    "
ok "=================================================================="
echo "Hệ điều hành đã sạch 100%, sẵn sàng để bạn clone repo mới và triển khai."

