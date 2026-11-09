#!/usr/bin/env bash
# ==============================================================================
# Platform Teardown Script (Senior DevSecOps & SRE Standard)
#
# Allows controlled and clean teardown of the current platform to prepare
# for deploying a new repository/workload.
#
# Usage:
#   ./scripts/teardown.sh [apps | platform | full-k3s]
# ==============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
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

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo -e "${BOLD}Chọn phạm vi muốn down hệ thống:${NC}"
  echo "  1) apps      - Chỉ gỡ toàn bộ Applications (fumi-live, expense-tracker, fumirai-lunch)."
  echo "                 Giữ lại K3s + ArgoCD + Traefik + Cert-Manager để repo mới cắm vào chạy ngay."
  echo "  2) platform  - Gỡ sạch toàn bộ Applications VÀ Platform (ArgoCD, Traefik, Monitoring, Cert-Manager)."
  echo "                 Giữ lại cluster K3s trắng sẵn sàng cho bootstrap repo mới."
  echo "  3) full-k3s  - Gỡ triệt để K3s cluster trên VPS (/usr/local/bin/k3s-uninstall.sh)."
  echo "                 Đưa máy chủ VPS về trạng thái Ubuntu sạch ban đầu."
  echo
  read -rp "Nhập lựa chọn của bạn [1/2/3 hoặc tên]: " choice
  case "$choice" in
    1|apps) TARGET="apps" ;;
    2|platform) TARGET="platform" ;;
    3|full-k3s) TARGET="full-k3s" ;;
    *) err "Lựa chọn không hợp lệ. Huỷ thao tác." ;;
  esac
fi

echo -e "${RED}${BOLD}CẢNH BÁO: BẠN ĐANG CHUẨN BỊ TEARDOWN HỆ THỐNG: [${TARGET}]${NC}"
read -rp "Bạn có chắc chắn muốn thực hiện? (gõ 'yes' để xác nhận): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Đã huỷ thao tác."
  exit 0
fi

# Ensure kubeconfig
if [ -z "${KUBECONFIG:-}" ]; then
  if [ -f "$HOME/.kube/config" ]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi
fi

# ------------------------------------------------------------------------------
# 1. TEARDOWN APPS ONLY
# ------------------------------------------------------------------------------
teardown_apps() {
  log "Bước 1: Gỡ bỏ ApplicationSet 'apps' trong Argo CD..."
  if kubectl get applicationset apps -n argocd >/dev/null 2>&1; then
    kubectl delete applicationset apps -n argocd --cascade=foreground --timeout=2m || true
    ok "Đã gỡ ApplicationSet 'apps'"
  fi

  log "Bước 2: Xoá toàn bộ Application con của các ứng dụng..."
  APPS=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  for app in $APPS; do
    case "$app" in
      fumi-*|expense-*|fumirai-*)
        log "Đang xoá Application: $app"
        kubectl delete application "$app" -n argocd --cascade=foreground --timeout=2m || true
        ;;
    esac
  done

  log "Bước 3: Xoá triệt để các Namespace ứng dụng nghiệp vụ..."
  NAMESPACES=("fumi-live-prod" "fumi-live-staging" "fumi-portal-prod" "fumirai-lunch-prod" "fumirai-lunch-staging")
  for ns in "${NAMESPACES[@]}"; do
    if kubectl get ns "$ns" >/dev/null 2>&1; then
      log "Đang xoá namespace: $ns"
      kubectl delete ns "$ns" --timeout=3m || true
    fi
  done

  ok "Hoàn tất down toàn bộ Applications! Nền tảng K3s & Argo CD vẫn sẵn sàng cho repo mới."
}

# ------------------------------------------------------------------------------
# 2. TEARDOWN PLATFORM & GITOPS
# ------------------------------------------------------------------------------
teardown_platform() {
  teardown_apps

  log "Bước 4: Xoá Root Application và các Platform Applications trong Argo CD..."
  if kubectl get application root -n argocd >/dev/null 2>&1; then
    kubectl delete application root -n argocd --cascade=foreground --timeout=2m || true
  fi

  PLATFORM_APPS=("argocd" "traefik" "cert-manager" "monitoring" "logging" "system-upgrade-controller" "namespaces")
  for app in "${PLATFORM_APPS[@]}"; do
    if kubectl get application "$app" -n argocd >/dev/null 2>&1; then
      kubectl delete application "$app" -n argocd --cascade=foreground --timeout=2m || true
    fi
  done

  log "Bước 5: Gỡ cài đặt Argo CD Helm release..."
  if command -v helm >/dev/null 2>&1; then
    helm -n argocd uninstall argocd 2>/dev/null || true
  fi

  log "Bước 6: Xoá toàn bộ Platform Namespaces..."
  PLATFORM_NS=("argocd" "traefik" "cert-manager" "monitoring" "logging" "system-upgrade")
  for ns in "${PLATFORM_NS[@]}"; do
    if kubectl get ns "$ns" >/dev/null 2>&1; then
      kubectl delete ns "$ns" --timeout=3m || true
    fi
  done

  ok "Hoàn tất gỡ bỏ toàn bộ GitOps Platform! Cụm K3s hiện ở trạng thái trắng (bare cluster)."
}

# ------------------------------------------------------------------------------
# 3. FULL K3S UNINSTALL
# ------------------------------------------------------------------------------
teardown_k3s() {
  log "Đang gỡ cài đặt hoàn toàn K3s trên máy chủ..."
  if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh
    ok "Đã chạy /usr/local/bin/k3s-uninstall.sh thành công"
  else
    warn "Không tìm thấy /usr/local/bin/k3s-uninstall.sh. Kiểm tra lệnh 'which k3s-uninstall.sh'"
  fi

  log "Dọn dẹp tàn dư CNI và dữ liệu K3s..."
  rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet 2>/dev/null || true
  ip link delete cni0 2>/dev/null || true
  ip link delete flannel.1 2>/dev/null || true

  ok "Hoàn tất! Máy chủ đã được reset hoàn toàn về hệ điều hành gốc."
}

# Execute based on target
case "$TARGET" in
  apps)
    teardown_apps
    ;;
  platform)
    teardown_platform
    ;;
  full-k3s)
    teardown_k3s
    ;;
esac

