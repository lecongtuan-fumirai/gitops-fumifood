# Kiến trúc Hệ thống & Cụm K3s Production (Comprehensive Architecture Guide)

Tài liệu này cung cấp cái nhìn toàn cảnh, chi tiết và có hệ thống về toàn bộ kiến trúc cụm **Kubernetes (K3s)** đang vận hành trên máy chủ Production (`vmi3371043`). Tài liệu giúp các kỹ sư DevOps / SRE / Platform nắm vững các quyết định thiết kế (Design Decisions), cấu hình chi tiết, luồng dữ liệu, cơ chế bảo vệ tài nguyên và cách thức vận hành hệ thống.

---

## MỤC LỤC
1. [Bức tranh Tổng thể Hệ thống (System Topology)](#1-bức-tranh-tổng-thể-hệ-thống-system-topology)
2. [Thiết kế Lõi Cụm K3s (K3s Control Plane & Core Decisions)](#2-thiết-kế-lõi-cụm-k3s-k3s-control-plane--core-decisions)
   * [Tại sao chọn SQLite (Kine) thay vì etcd?](#tại-sao-chọn-sqlite-kine-thay-vì-etcd)
   * [Mã hóa Secrets at-rest (Data Encryption)](#mã-hóa-secrets-at-rest-data-encryption)
   * [Tách biệt Ingress Traefik khỏi vòng đời K3s](#tách-biệt-ingress-traefik-khỏi-vòng-đời-k3s)
3. [Kiến trúc Mạng & Ingress (Networking & Traffic Flow)](#3-kiến-trúc-mạng--ingress-networking--traffic-flow)
   * [Flannel CNI với backend WireGuard-native](#flannel-cni-với-backend-wireguard-native)
   * [Bộ điều khiển Ingress Traefik v3.7](#bộ-điều-khiển-ingress-traefik-v37)
   * [Đường hầm Giám sát Cross-Region (`wg-hub`)](#đường-hầm-giám-sát-cross-region-wg-hub)
4. [Quản trị Bộ nhớ, Eviction & Priority Classes](#4-quản-trị-bộ-nhớ-eviction--priority-classes)
   * [Bảo lưu tài nguyên hệ thống (System & Kube Reserved)](#bảo-lưu-tài-nguyên-hệ-thống-system--kube-reserved)
   * [Ngưỡng tự động trục xuất Pod (Kubelet Eviction Thresholds)](#ngưỡng-tự-động-trục-xuất-pod-kubelet-eviction-thresholds)
   * [Phân cấp ưu tiên Pod (Priority Classes)](#phân-cấp-ưu-tiên-pod-priority-classes)
   * [Cơ chế Swap Safety Net](#cơ-chế-swap-safety-net)
5. [Kiến trúc Lưu trữ (Persistent Storage)](#5-kiến-trúc-lưu-trữ-persistent-storage)
6. [Mô hình Quản trị GitOps (ArgoCD & App Topology)](#6-mô-hình-quản-trị-gitops-argocd--app-topology)
   * [Mô hình App of Apps](#mô-hình-app-of-apps)
   * [ApplicationSet cho các Microservices](#applicationset-cho-các-microservices)
   * [Quản lý Bí mật với SOPS & Age](#quản-lý-bí-mật-với-sops--age)
7. [Cơ chế Sao lưu & Phục hồi Thảm họa (Backup & DR)](#7-cơ-chế-sao-lưu--phục-hồi-thảm-họa-backup--dr)
8. [Tự động Nâng cấp Cụm (System Upgrade Controller)](#8-tự-động-nâng-cấp-cụm-system-upgrade-controller)
9. [Bảng Tra cứu Nhanh cho Kỹ sư Vận hành (SRE Cheat Sheet)](#9-bảng-tra-cứu-nhanh-cho-kỹ-sư-vận-hành-sre-cheat-sheet)

---

## 1. Bức tranh Tổng thể Hệ thống (System Topology)

### Hạ tầng Vật lý / VPS
* **Nhà cung cấp**: Contabo VPS (Vùng Đức - EU).
* **Hostname**: `vmi3371043` (tên node trên k3s: `vmi3371043`, alias: `vn1-01`).
* **IP Public**: `13.140.183.90`.
* **Cấu hình phần cứng**: 2 vCPU, 3.8 GiB RAM, 291 GiB SSD, 4 GiB Swap.
* **Hệ điều hành**: Ubuntu 22.04 LTS (Jammy Jellyfish), Linux Kernel 5.15.
* **Phiên bản K3s**: `v1.36.5+k3s1`.

### Sơ đồ Kiến trúc Phân tầng (Architecture Diagram)

```
                     [ INTERNET CLIENTS ]
                              │
                    ┌─────────▼─────────┐
                    │  Cloudflare Edge  │ (WAF, DDoS Shield, SSL Term)
                    └─────────┬─────────┘
                              │ HTTPS / 443 (CF-Connecting-IP)
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│ MÁY CHỦ PRODUCTION VPS (Host: vmi3371043 - 13.140.183.90)              │
│                                                                        │
│ ┌────────────────────────────────────────────────────────────────────┐ │
│ │ TƯỜNG LỬA HOST & KERNEL HARDENING                                   │ │
│ │ - UFW: Whitelist Cloudflare IPs, VPN WireGuard, Port 22 (Fail2ban) │ │
│ │ - Kernel: SYN backlog 8192, somaxconn 8192, Strict rp_filter=1     │ │
│ └─────────────────────────────────┬──────────────────────────────────┘ │
│                                   │                                    │
│ ┌─────────────────────────────────▼──────────────────────────────────┐ │
│ │ K3S CONTROL PLANE & RUNTIME                                         │ │
│ │ - SQLite (Kine) Datastore [AES-CBC Encrypted Secrets]              │ │
│ │ - Flannel CNI (wireguard-native: Pods 10.42.0.0/16, Svcs 10.43/16) │ │
│ │ - Kubelet (System-reserved: 400Mi, Kube-reserved: 500Mi)           │ │
│ └─────────────────────────────────┬──────────────────────────────────┘ │
│                                   │                                    │
│ ┌─────────────────────────────────▼──────────────────────────────────┐ │
│ │ INGRESS LAYER (Namespace: traefik)                                  │ │
│ │ Traefik v3.7 IngressController (priority: platform-critical)       │ │
│ │ ├─ EntryPoint :80  (HTTP)  ───► Redirect to :443 (HTTPS)           │ │
│ │ ├─ EntryPoint :443 (HTTPS) ───► TLS Term / RateLimit per Client IP │ │
│ │ └─ Middlewares: security-headers, rate-limit (CF-Connecting-IP)    │ │
│ └───────┬─────────────────────────┬───────────────────────────┬──────┘ │
│         │                         │                           │        │
│         ▼                         ▼                           ▼        │
│ ┌───────────────┐       ┌───────────────────┐       ┌────────────────┐ │
│ │ APPS WORKLOAD │       │ PLATFORM CORE     │       │ MONITORING     │ │
│ │ (Restricted)  │       │ (Platform-Crit.)  │       │ (Standard)     │ │
│ │               │       │                   │       │                │ │
│ │ fumirai-lunch │       │ ArgoCD Stack      │       │ vmagent        │ │
│ │ ├─ Frontend   │       │ Cert-Manager      │       │ node-exporter  │ │
│ │ └─ Backend    │       │ System-Upgrade    │       │ kube-state-m.  │ │
│ │               │       │ Local-Path Storage│       │ metrics-server │ │
│ │ floci (AWS em)│       │                   │       │                │ │
│ └───────────────┘       └───────────────────┘       └───────┬────────┘ │
│                                                             │          │
│                                                             ▼          │
│                                                 ┌────────────────────┐ │
│                                                 │ wg-hub WireGuard   │ │
│                                                 │ Interface (10.66)  │ │
└─────────────────────────────────────────────────┴───────────┬────────┘ │
                                                              │          │
                                   ┌──────────────────────────┘          │
                                   │ Remote Write Metrics (Encrypted)    │
                                   ▼                                     │
┌────────────────────────────────────────────────────────────────────────┐
│ MONITORING HUB ĐỘC LẬP TẠI VIỆT NAM (Host: miniappify - 10.66.66.1)    │
│ VictoriaMetrics (TSDB) ──► Alertmanager ──► Telegram Alert Bot         │
│ Grafana Dashboard (Quản trị & Giám sát hiệu năng)                      │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Thiết kế Lõi Cụm K3s (K3s Control Plane & Core Decisions)

Cấu hình máy chủ K3s được định nghĩa tại template Ansible [ansible/roles/k3s_server/templates/config.yaml.j2](file:///home/platform-gitops/ansible/roles/k3s_server/templates/config.yaml.j2) và render ra file `/etc/rancher/k3s/config.yaml`.

### Tại sao chọn SQLite (Kine) thay vì etcd?
* **Bối cảnh kỹ thuật**: etcd là hệ thống đồng thuận phân tán (Raft consensus) yêu cầu khắt khe về tốc độ ghi đĩa fsync (thường phải < 10ms, lý tưởng < 2ms). Trên các dòng VPS ảo hóa chia sẻ tài nguyên như Contabo, tốc độ fsync đĩa đo được dao động quanh ngưỡng **~12ms - 15ms**.
* **Hậu quả nếu dùng etcd**: Trễ ghi đĩa cao dẫn đến hiện tượng trượt nhịp bầu chọn leader (leader election timeout), drop gói tin heartbeat giữa các nút và làm tắc nghẽn Kube-apiserver.
* **Giải pháp**: K3s hỗ trợ **Kine (Kine is not etcd)** để chuyển tiếp các câu truy vấn etcd v3 API thành SQL chuẩn. Với cụm đơn nút (single-node), **SQLite** mang lại:
  1. Tốc độ thực thi cực nhanh trên một tiến trình cục bộ, loại bỏ hoàn toàn hiện tượng timeout của Raft.
  2. Tiết kiệm tài nguyên vượt trội: Chỉ tiêu tốn khoảng **15 - 30 MiB RAM** (so với 300 - 500 MiB của etcd).
  3. Dễ dàng sao lưu: Chỉ cần gọi lệnh `sqlite3 .backup` là có một bản snapshot hoàn chỉnh, nhất quán mà không cần dừng cụm.

### Mã hóa Secrets at-rest (Data Encryption)
Trong file cấu hình K3s:
```yaml
secrets-encryption: true
```
* Khi bật cờ này, toàn bộ tài nguyên `Secret` lưu trong SQLite đều được K3s tự động mã hóa bằng thuật toán đối mã AES-CBC (hoặc AES-GCM tùy phiên bản K3s) với key ngẫu nhiên sinh ra tại `/var/lib/rancher/k3s/server/cred/encryption-config.json`.
* Ngay cả khi file SQLite database bị rò rỉ, kẻ tấn công cũng không thể đọc được nội dung mật khẩu, token, private key.

### Tách biệt Ingress Traefik khỏi vòng đời K3s
K3s mặc định tự động cài đặt Traefik v1/v2 thông qua cơ chế `HelmController` chạy bằng các Job tạm.
Chúng tôi cấu hình:
```yaml
disable:
  - traefik
```
* **Lý do**: Việc để K3s tự cài Traefik sẽ làm mất tính nhất quán của GitOps, khó kiểm soát phiên bản chart và khó cấu hình nâng cao. Traefik được đưa ra ngoài để quản trị tập trung bởi ArgoCD tại [platform/traefik/](file:///home/platform-gitops/platform/traefik/) với chart chính thức `41.6.1` (Traefik v3.7).

### API Server Auditing
Chính sách kiểm toán API được kích hoạt thông qua file `/etc/rancher/k3s/audit-policy.yaml`:
* Ghi log metadata của mọi thao tác thay đổi `secrets` và `configmaps`.
* Bỏ qua các lệnh đọc `get`, `list`, `watch` liên tục từ kube-proxy và kubelet để tránh phình dung lượng log đĩa.
* Log được lưu tại `/var/lib/rancher/k3s/server/logs/audit.log` và tự động xoay vòng (tối đa 3 file x 50MB, lưu tối đa 7 ngày).

---

## 3. Kiến trúc Mạng & Ingress (Networking & Traffic Flow)

### Flannel CNI với backend WireGuard-native
```yaml
flannel-backend: wireguard-native
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
```
* **Flannel wireguard-native**: Khởi tạo giao diện mạng ảo `flannel-wg` trên cổng UDP `51820`. Toàn bộ gói tin giao tiếp giữa các Pod đều được mã hóa bằng giao thức WireGuard ngay tại tầng Linux Kernel space.
* **Hiệu năng**: Tốc độ xử lý gói tin nhanh hơn IPsec gấp 3-4 lần và tiêu tốn rất ít CPU so với VXLAN bọc gói.

### Bộ điều khiển Ingress Traefik v3.7
* **Dịch vụ mạng (Service)**: Chạy dưới dạng `type: LoadBalancer` kết hợp với K3s Klipper Service Load Balancer (`svclb-traefik`), gắn trực tiếp vào port 80 và 443 của host IP `13.140.183.90`.
* **Bảo toàn IP nguồn**:
  ```yaml
  service:
    spec:
      externalTrafficPolicy: Local
  ```
  Ngăn cản Kube-proxy thực hiện SNAT, đảm bảo giữ nguyên IP nguồn của client khi gói tin chạm vào Ingress pod.
* **Cơ chế chuyển tiếp HTTPS**: Cổng 80 tự động chuyển hướng thường trực (HTTP 301 Permanent Redirect) sang cổng 443.
* **Cấp chứng chỉ SSL tự động**: Tích hợp với **Cert-Manager** thông qua ClusterIssuer `letsencrypt-prod` (giao thức ACME HTTP-01 challenge).

### Đường hầm Giám sát Cross-Region (`wg-hub`)
* Để đẩy metric về Hub giám sát tại Việt Nam mà không mở bất kỳ cổng quản trị nào ra Internet, host thiết lập giao diện WireGuard thứ hai: `wg-hub`.
* Địa chỉ IP: `10.66.66.10/32` kết nối trực tiếp tới Hub `10.66.66.1:51820`.
* Agent giám sát `vmagent` cào metric từ nội bộ cụm (Kubelet, Node-exporter) và đẩy qua đường hầm này bằng giao thức Prometheus Remote-Write (TCP `10.66.66.1:8428`).

---

## 4. Quản trị Bộ nhớ, Eviction & Priority Classes

Hệ thống hoạt động trên VPS có **3.8 GiB RAM**, trong khi phải gánh toàn bộ Control Plane K3s, ArgoCD, Ingress, Monitoring và các ứng dụng nghiệp vụ. Cơ chế bảo vệ bộ nhớ được tính toán chi tiết như sau:

### Bảo lưu tài nguyên hệ thống (System & Kube Reserved)
Trong cấu hình Kubelet (`/etc/rancher/k3s/config.yaml`):
```yaml
kubelet-arg:
  - "system-reserved=cpu=250m,memory=400Mi"
  - "kube-reserved=cpu=250m,memory=500Mi"
```
* **Bảo lưu cho hệ điều hành (`system-reserved`)**: Dành riêng 400 MiB RAM và 0.25 vCPU cho Linux Kernel, SSH daemon, UFW, Journald và Fail2ban. K8s cam kết không bao giờ xếp lịch (schedule) pod lấn chiếm vào vùng nhớ này.
* **Bảo lưu cho K8s engine (`kube-reserved`)**: Dành riêng 500 MiB RAM và 0.25 vCPU cho K3s server process, Containerd runtime và Kubelet daemon.
* **Ý nghĩa**: Ngay cả khi toàn bộ các Pod ứng dụng ăn cạn RAM, hệ điều hành và K3s vẫn còn nguyên gần **1 GiB RAM** để hoạt động, không bao giờ bị đơ (freeze) máy chủ.

### Ngưỡng tự động trục xuất Pod (Kubelet Eviction Thresholds)
```yaml
kubelet-arg:
  - "eviction-hard=memory.available<300Mi,nodefs.available<10%,imagefs.available<10%"
  - "eviction-soft=memory.available<500Mi"
  - "eviction-soft-grace-period=memory.available=1m"
```
* Khi bộ nhớ khả dụng của máy giảm xuống dưới **500 MiB** kéo dài quá 1 phút: Kubelet kích hoạt cảnh báo Soft Eviction.
* Khi bộ nhớ khả dụng chạm mốc nguy hiểm **< 300 MiB**: Kubelet lập tức kích hoạt Hard Eviction, chủ động tắt các Pod không thiết yếu để cứu vãn sự ổn định của node, ngăn chặn Linux Kernel kích hoạt OOM Killer mù quáng.

### Phân cấp ưu tiên Pod (Priority Classes)
Được khai báo tại [platform/namespaces/priority-classes.yaml](file:///home/platform-gitops/platform/namespaces/priority-classes.yaml):

| Tên PriorityClass | Trọng số (Value) | Đối tượng áp dụng | Hành vi khi thiếu RAM |
| :--- | :--- | :--- | :--- |
| **`platform-critical`** | `1000000` | Traefik, Cert-Manager, ArgoCD | **Bất tử**: Kubelet không bao giờ trục xuất các pod này |
| **`workload-prod`** | `100000` | `fumirai-lunch` (backend + frontend) | **Ưu tiên cao**: Chỉ bị tắt nếu hạ tầng platform cạn kiệt |
| **`workload-standard`** | `1000` *(Default)* | Môi trường Staging, tool test, CronJob | **Trục xuất đầu tiên**: Kubelet sẽ kill các pod này để nhường RAM |

### Cơ chế Swap Safety Net
* Kubelet được cấu hình `fail-swap-on=false`.
* VPS tạo file swap 4 GiB (`/swapfile`) với `vm.swappiness = 10`.
* **Quy tắc**: Pods chạy trên K3s không được cấp phát swap (bị khóa bởi cgroups memory limits). Swap chỉ đóng vai trò là "phao cứu sinh" đệm lưng cho các tiến trình hệ điều hành (k3s, containerd, journald) khi có các đợt tải đột biến bất ngờ.

---

## 5. Kiến trúc Lưu trữ (Persistent Storage)

* **Storage Provider**: Sử dụng **Rancher Local Path Provisioner** tích hợp sẵn của K3s (`local-path`).
* **Đường dẫn trên Host**: `/var/lib/rancher/k3s/storage/`.
* **Phân loại ứng dụng**:
  1. **Ứng dụng phi trạng thái (Stateless - `fumirai-lunch`)**:
     * Không sử dụng PersistentVolume.
     * Sử dụng cơ sở dữ liệu PostgreSQL từ xa (Neon DB serverless).
     * Dữ liệu tải lên tạm thời (ảnh menu, sao kê) được chứa trong ổ đĩa ảo tạm thời `emptyDir: { sizeLimit: 256Mi }`. Khi Pod restart, dữ liệu tạm này tự động giải phóng.
  2. **Ứng dụng có trạng thái (Stateful - `floci`)**:
     * Gắn PersistentVolumeClaim (PVC) dung lượng 5GiB lưu trữ dữ liệu giả lập AWS cục bộ trên đĩa cứng host.

---

## 6. Mô hình Quản trị GitOps (ArgoCD & App Topology)

Toàn bộ tài nguyên trên cụm K3s được quản trị 100% bằng mã (Infrastructure as Code) thông qua **ArgoCD** theo mô hình khai báo khai nguyên:

```
repository: gitops-fumifood
│
├── bootstrap/root-app.yaml           # App of Apps (ArgoCD Root Application)
│
├── clusters/prod/
│   ├── projects.yaml                 # Phân quyền 2 Projects: "platform" và "apps"
│   ├── apps-appset.yaml              # ApplicationSet tự động quét thư mục apps/
│   └── platform/                     # Khai báo các core components
│       ├── traefik.yaml
│       ├── cert-manager.yaml
│       ├── monitoring.yaml
│       ├── namespaces.yaml
│       └── system-upgrade-controller.yaml
│
├── platform/                         # Manifest chi tiết của platform (Kustomize/Helm)
│   ├── traefik/
│   ├── cert-manager/
│   └── namespaces/
│
└── apps/                             # Chứa các workloads ứng dụng
    └── fumirai-lunch/
        ├── base/                     # Deployment, Service, Ingress, NetPol dùng chung
        └── overlays/
            ├── production/           # Cấu hình riêng cho Prod (Secrets, Image digest)
            └── staging/              # Cấu hình riêng cho Staging
```

### Quy tắc Vàng của GitOps (Golden Rules)
1. **Tuyệt đối không can thiệp thủ công bằng `kubectl apply`**: Bất kỳ thay đổi nào làm bằng tay trên cụm đều sẽ bị tính năng `selfHeal: true` của ArgoCD tự động đè lại trạng thái trong Git.
2. **Khóa cứng phiên bản Image (Immutable Tags)**: Nghiêm cấm dùng tag `latest`. Mọi image chạy trên Production bắt buộc phải ghim kèm SHA-256 Digest:
   ```yaml
   images:
     - name: fumirai-lunch-backend
       newName: docker.io/lecongtuan/fumirai-lunch-backend
       digest: sha256:3909593290b97be18eafd3c9df54be0d1990e494abb5c5d39086a0f0ea78a403
   ```
3. **Mã hóa Secrets với SOPS & Age**:
   * File bí mật trong git đều có định dạng `secrets.enc.yaml`.
   * Khóa công khai Age được khai báo tại [.sops.yaml](file:///home/platform-gitops/.sops.yaml).
   * Script kiểm tra an toàn `./scripts/validate.sh` sẽ chặn đứng mọi commit nếu phát hiện có secret dạng plaintext.

---

## 7. Cơ chế Sao lưu & Phục hồi Thảm họa (Backup & DR)

Hệ thống được sao lưu tự động thông qua Ansible role `backup` với cơ chế Systemd Timer:

* **Lịch trình (`backup_schedule`)**: Chạy định kỳ mỗi 6 giờ (`00/6:15:00`).
* **Tiến trình thực hiện**:
  1. Gọi SQLite Online Backup API sao lưu nhất quán file `/var/lib/rancher/k3s/server/db/state.db`.
  2. Gom cụm các file chứng chỉ, token và private keys tại `/var/lib/rancher/k3s/server/cred`.
  3. Sao lưu toàn bộ thư mục dữ liệu PVC của local-path storage.
  4. Nén toàn bộ bằng thuật toán **zstd** tốc độ cao và mã hóa bằng **Age**.
  5. Tẩy rửa dữ liệu cục bộ, chỉ giữ lại các bản backup trong 3 ngày gần nhất.
  6. Đồng bộ bản mã hóa lên dịch vụ Cloud Storage thông qua `rclone`.

*Tài liệu hướng dẫn khôi phục toàn diện khi chết server được ghi tại [docs/runbook-dr.md](file:///home/platform-gitops/docs/runbook-dr.md).*

---

## 8. Tự động Nâng cấp Cụm (System Upgrade Controller)

Hệ thống tích hợp **Rancher System Upgrade Controller (SUC)** để nâng cấp phiên bản K3s mà không gây gián đoạn:
* SUC giám sát CRD `Plan`.
* Khi phiên bản K3s trong GitOps được nâng lên, SUC tạo một Pod đặc quyền chạy ngầm, gọi script nâng cấp K3s nhị phân, khởi động lại K3s server mà không làm rớt các container đang chạy của người dùng.

---

## 9. Bảng Tra cứu Nhanh cho Kỹ sư Vận hành (SRE Cheat Sheet)

```bash
# ==============================================================================
# 1. KIỂM TRA TRẠNG THÁI CỤM VÀ TÀI NGUYÊN
# ==============================================================================
# Xem trạng thái Node, phiên bản và tình trạng Ready
k3s kubectl get nodes -o wide

# Xem mức tiêu thụ CPU / RAM thực tế của Node
k3s kubectl top nodes

# Xem mức tiêu thụ CPU / RAM của từng Pod (sắp xếp theo RAM)
k3s kubectl top pods -A --sort-by=memory

# Kiểm tra xem có Pod nào đang bị OOM hoặc Restart không
k3s kubectl get pods -A | grep -v "Running"

# ==============================================================================
# 2. KIỂM TRA INGRESS VÀ TRAFFIC
# ==============================================================================
# Xem log của Traefik theo thời gian thực
k3s kubectl logs -n traefik deployment/traefik -f --tail=50

# Xem các quy tắc định tuyến Ingress đang hoạt động
k3s kubectl get ingress -A

# Kiểm tra trạng thái cấp phát chứng chỉ SSL Let's Encrypt
k3s kubectl get certificate,certificaterequest -A

# ==============================================================================
# 3. KIỂM TRA ĐỒNG BỘ GITOPS (ARGOCD)
# ==============================================================================
# Kiểm tra toàn bộ các Applications của cụm
k3s kubectl get applications -n argocd

# Buộc ArgoCD đồng bộ cưỡng bức một Application ngay lập tức
k3s kubectl annotate application <APP_NAME> -n argocd argocd.argoproj.io/refresh=hard --overwrite

# ==============================================================================
# 4. KẾT NỐI VÀ DEBUG TỪ LAPTOP (KHÔNG CẦN MỞ PORT PUBLIC)
# ==============================================================================
# Tạo SSH Tunnel kết nối an toàn vào Kube-apiserver trên port 6443
ssh -N -L 6443:127.0.0.1:6443 ubuntu@13.140.183.90

# Tạo SSH Tunnel mở giao diện Web ArgoCD Server
ssh -N -L 8080:127.0.0.1:8080 ubuntu@13.140.183.90
# (Sau đó trên server chạy: k3s kubectl port-forward svc/argocd-server -n argocd 8080:80)
```

---

*Tài liệu được lưu trữ chính thức trong GitOps repository tại [docs/k3s-cluster-architecture.md](file:///home/platform-gitops/docs/k3s-cluster-architecture.md).*
