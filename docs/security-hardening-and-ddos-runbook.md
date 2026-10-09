# Kiến trúc Bảo mật & Cẩm nang Phòng chống DDoS, Bảo vệ VPS / K3s Production

Tài liệu này được biên soạn cho các kỹ sư DevOps / SRE / SecOps nhằm hiểu rõ toàn bộ kiến trúc an ninh nhiều lớp (Defense-in-Depth), các quyết định kỹ thuật, quy trình vận hành (Runbook), bảo trì và xử lý sự cố khi vận hành ứng dụng `fumirai-lunch` và cụm Kubernetes K3s trên VPS production (`vmi3371043`).

---

## MỤC LỤC
1. [Bối cảnh & Mô hình Đe dọa (Threat Model)](#1-bối-cảnh--mô-hình-đe-dọa-threat-model)
2. [Kiến trúc An ninh Đa tầng (Defense-in-Depth Architecture)](#2-kiến-trúc-an-ninh-đa-tầng-defense-in-depth-architecture)
3. [Chi tiết các Tầng Bảo vệ Đã Triển khai](#3-chi-tiết-các-tầng-bảo-vệ-đã-triển-khai)
   * [Tầng 1: Edge & DNS (Cloudflare Proxy)](#tầng-1-edge--dns-cloudflare-proxy)
   * [Tầng 2: Firewall Host (UFW & IPTables)](#tầng-2-firewall-host-ufw--iptables)
   * [Tầng 3: Ingress Controller (Traefik v3.7 Hardening)](#tầng-3-ingress-controller-traefik-v37-hardening)
   * [Tầng 4: Kubernetes Workload & Namespace Isolation](#tầng-4-kubernetes-workload--namespace-isolation)
   * [Tầng 5: Linux Kernel Tuning (Anti-DDoS & Socket Recovery)](#tầng-5-linux-kernel-tuning-anti-ddos--socket-recovery)
   * [Tầng 6: Quản trị SSH & Chống Chiếm quyền Root](#tầng-6-quản-trị-ssh--chống-chiếm-quyền-root)
4. [Cẩm nang Vận hành & Bảo trì (Day-2 Operations)](#4-cẩm-nang-vận-hành--bảo-trì-day-2-operations)
   * [Checklist kiểm tra an ninh định kỳ](#checklist-kiểm-tra-an-ninh-định-kỳ)
   * [Cách cập nhật dải IP Cloudflare](#cách-cập-nhật-dải-ip-cloudflare)
   * [Quy trình đóng hoàn toàn cổng 80/443 trên UFW](#quy-trình-đóng-hoàn-toàn-cổng-80443-trên-ufw)
   * [Quy trình chuyển đổi SSH sang user `ubuntu`](#quy-trình-chuyển-đổi-ssh-sang-user-ubuntu)
5. [Quy trình Xử lý Sự cố (Troubleshooting & Incident Response)](#5-quy-trình-xử-lý-sự-cố-troubleshooting--incident-response)
   * [Sự cố 1: Bị tấn công DDoS / Spike Load](#sự-cố-1-bị-tấn-công-ddos--spike-load)
   * [Sự cố 2: Người dùng thật bị lỗi HTTP 429 (Too Many Requests)](#sự-cố-2-người-dùng-thật-bị-lỗi-http-429-too-many-requests)
   * [Sự cố 3: K3s Pod bị OOMKilled hoặc Node áp lực bộ nhớ](#sự-cố-3-k3s-pod-bị-oomkilled-hoặc-node-áp-lực-bộ-nhớ)
6. [Quy trình Rollback Khẩn cấp (Disaster Recovery)](#6-quy-trình-rollback-khẩn-cấp-disaster-recovery)

---

## 1. Bối cảnh & Mô hình Đe dọa (Threat Model)

### Đặc thù hạ tầng:
* **Host VPS**: 2 vCPU, 3.8 GiB RAM (Contabo VPS `vmi3371043`).
* **Workloads trên cụm**:
  * Nền tảng: K3s server, Containerd, ArgoCD stack, Traefik Ingress, Cert-Manager, VictoriaMetrics agent (`vmagent`), Node-exporter.
  * Ứng dụng: `fumirai-lunch` (NestJS backend + Vite SPA frontend), `floci` (Local AWS emulator).
* **Thách thức cốt lõi**:
  Tài nguyên VPS có giới hạn (2 vCPU / 4GB RAM với mức RAM sử dụng nền ~95%). Một đợt tấn công dù ở quy mô nhỏ (vài nghìn request/giây hoặc SYN flood nhẹ) nếu lọt qua tầng biên sẽ lập tức làm cạn kiệt CPU/RAM, gây OOM-killer làm sập các dịch vụ trọng yếu của hệ thống.

### Các vector tấn công tiềm tàng:
1. **Volumetric DDoS & HTTP Flood**: Bắn hàng loạt request vào endpoint ứng dụng để làm nghẽn CPU và RAM Node.js backend.
2. **Origin IP Bypass**: Dò quét tìm ra IP gốc của VPS (`13.140.183.90`) qua các subdomain không bật proxy, sau đó tấn công trực tiếp vào IP này nhằm vô hiệu hóa lớp bảo vệ Cloudflare.
3. **Slowloris / Slow-POST DoS**: Mở hàng nghìn kết nối HTTP/TCP giữ kết nối cực chậm, chiếm dụng toàn bộ connection slot và file descriptors của Traefik.
4. **SYN Flood Attack**: Gửi ồ ạt gói tin TCP SYN giả mạo IP nguồn làm đầy hàng đợi `tcp_max_syn_backlog`, khiến server từ chối phục vụ mọi kết nối mới.
5. **Container Escape & Privilege Escalation**: Khai thác lỗi ứng dụng để lấy cắp ServiceAccount token của Kubernetes, từ đó tấn công vào Kube-apiserver hoặc leo quyền chiếm quyền root của host.

---

## 2. Kiến trúc An ninh Đa tầng (Defense-in-Depth Architecture)

Hệ thống được thiết kế theo mô hình phòng thủ theo chiều sâu (Defense-in-Depth) với 6 tầng độc lập:

```
[ NGƯỜI DÙNG & INTERNET ]
            │
            ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TẦNG 1: CLOUDFLARE EDGE (Tầng Biên)                                    │
│ - WAF, DDoS Layer 3/4/7 Mitigation, Bot Fight Mode                      │
│ - Ẩn giấu IP gốc, gắn header CF-Connecting-IP                          │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Traffic đã lọc sạch)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TẦNG 2: LINUX FIREWALL (UFW & IPTables)                                 │
│ - Port 80 & 443: Chỉ cho phép Cloudflare IPs & VPN Hub WireGuard       │
│ - Port 22: Giám sát bởi Fail2ban, cấm password                         │
│ - Port 6443, 10250, 9100: Đóng chặt với Internet (chỉ listen localhost)│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TẦNG 3: INGRESS CONTROLLER (Traefik v3.7 Hardening)                     │
│ - trustedIPs: Đầy đủ 22 dải IPv4 & IPv6 của Cloudflare                  │
│ - sourceCriterion: requestHeaderName = "CF-Connecting-IP"              │
│ - Rate-Limit: 100 req/s, burst 50 ĐỘC LẬP THEO TỪNG CLIENT IP          │
│ - Timeouts: readTimeout=60s, writeTimeout=60s, idleTimeout=180s        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TẦNG 4: KUBERNETES WORKLOAD ISOLATION                                  │
│ - PSA Level: restricted (bắt buộc toàn bộ Pod)                         │
│ - Pod Security: runAsNonRoot=true, readOnlyRootFilesystem=true,        │
│   capabilities drop=[ALL], allowPrivilegeEscalation=false              │
│ - ServiceAccount: automountServiceAccountToken=false (Prod & Staging)  │
│ - NetworkPolicy: baseline Ingress chỉ cho phép từ Traefik              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TẦNG 5 & 6: LINUX KERNEL & SYSTEM ACCESS                               │
│ - sysctl: tcp_max_syn_backlog=8192, somaxconn=8192, rp_filter=1        │
│ - Socket cleanup: tcp_fin_timeout=20, tcp_tw_reuse=1                   │
│ - SSH: Đồng bộ SSH Key sang user ubuntu (NOPASSWD sudo)                │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Chi tiết các Tầng Bảo vệ Đã Triển khai

### Tầng 1: Edge & DNS (Cloudflare Proxy)
* **Cấu hình Domain**: Domain [fumifood.dpdns.org](https://fumifood.dpdns.org) được ủy quyền qua Cloudflare Proxy (đám mây cam `Proxied`).
* **Chức năng**:
  * Hấp thụ toàn bộ các cuộc tấn công DDoS volumetric (Layer 3/4 SYN flood, UDP flood, amplification attack) tại các trung tâm dữ liệu toàn cầu của Cloudflare.
  * Tự động lọc các loại bot độc hại qua tính năng *Bot Fight Mode*.
  * Chuyển tiếp request về máy chủ gốc kèm theo header định danh IP thực tế của client: `CF-Connecting-IP`.

---

### Tầng 2: Firewall Host (UFW & IPTables)
* **Vấn đề đã khắc phục**: Trước đây, UFW mở cổng 80 & 443 cho `Anywhere`. Nếu kẻ tấn công phát hiện IP gốc `13.140.183.90`, họ có thể tấn công thẳng vào IP này, bypass toàn bộ Cloudflare.
* **Cơ chế triển khai**:
  * Script [scripts/harden-cloudflare-ufw.sh](file:///home/platform-gitops/scripts/harden-cloudflare-ufw.sh) tự động tải danh sách dải IP chính thức của Cloudflare và áp dụng vào UFW:
    * Cho phép HTTP/HTTPS từ dải Cloudflare IPv4 (15 dải) và IPv6 (7 dải).
    * Cho phép HTTP/HTTPS từ nội bộ Host, cụm K3s (`10.42.0.0/16`, `10.43.0.0/16`) và dải VPN WireGuard (`10.66.66.0/24`).
    * Xóa bỏ quy tắc mở cổng 80 & 443 ra toàn thế giới (`0.0.0.0/0`).
  * Các cổng quản trị nội bộ (`6443` K3s API, `10250` Kubelet, `9100` Node-exporter) được cấu hình `DROP` từ ngoài Internet, chỉ cho phép truy cập qua SSH tunnel hoặc localhost.

---

### Tầng 3: Ingress Controller (Traefik v3.7 Hardening)
Được cấu hình trong [platform/traefik/values.yaml](file:///home/platform-gitops/platform/traefik/values.yaml) và [platform/traefik/config/middlewares.yaml](file:///home/platform-gitops/platform/traefik/config/middlewares.yaml).

#### 1. Khai báo Cloudflare Trusted IPs trên cả 2 Entrypoint
Trước đây, cổng `websecure` (443) không cấu hình `trustedIPs`, khiến Traefik không tin cậy header chuyển tiếp và coi tất cả người dùng đều có IP là server của Cloudflare.
Đã bổ sung danh sách đầy đủ 22 dải IP Cloudflare vào cả `web` và `websecure`:
```yaml
ports:
  web:
    forwardedHeaders:
      trustedIPs:
        - "127.0.0.1/32"
        - "10.42.0.0/16"
        - "13.140.183.90/32"
        # Cloudflare IPv4 (15 ranges)
        - "173.245.48.0/20"
        - "103.21.244.0/22"
        # ...
        # Cloudflare IPv6 (7 ranges)
        - "2400:cb00::/32"
        # ...
  websecure:
    forwardedHeaders:
      trustedIPs:
        - "127.0.0.1/32"
        # ... (đầy đủ các dải như trên)
```

#### 2. Kích hoạt Timeout chống Slowloris DoS
Traefik mặc định đặt timeout = 0 (vô hạn). Đã giới hạn lại để ngăn chặn việc kẻ tấn công mở hàng nghìn kết nối treo:
```yaml
transport:
  respondingTimeouts:
    readTimeout: 60s      # Giới hạn thời gian đọc toàn bộ request
    writeTimeout: 60s     # Giới hạn thời gian ghi response
    idleTimeout: 180s     # Thu hồi kết nối idle sau 3 phút
```

#### 3. Phân lập Rate Limit chính xác theo từng Client IP
Trong [platform/traefik/config/middlewares.yaml](file:///home/platform-gitops/platform/traefik/config/middlewares.yaml):
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: traefik
spec:
  rateLimit:
    average: 100
    burst: 50
    period: 1s
    sourceCriterion:
      requestHeaderName: CF-Connecting-IP
```
* **Lợi ích**: Khi kẻ tấn công spam request, Traefik sẽ căn cứ vào header `CF-Connecting-IP` được Cloudflare xác thực để đếm quota. Chỉ duy nhất IP của kẻ tấn công bị chặn (HTTP 429), trong khi toàn bộ người dùng hợp lệ khác vẫn truy cập bình thường.

---

### Tầng 4: Kubernetes Workload & Namespace Isolation
Được cấu hình trong [apps/fumirai-lunch/base/](file:///home/platform-gitops/apps/fumirai-lunch/base/) và [platform/namespaces/fumirai-lunch.yaml](file:///home/platform-gitops/platform/namespaces/fumirai-lunch.yaml).

#### 1. Khóa ServiceAccount Token (Chống leo quyền vào Kube-apiserver)
* Tại cấp độ Pod: Cả `backend` và `frontend` đều khai báo `automountServiceAccountToken: false`.
* Tại cấp độ Namespace (Chuẩn CIS Benchmark): Cấu hình ServiceAccount `default` trong cả hai namespace `fumirai-lunch-prod` và `fumirai-lunch-staging` với `automountServiceAccountToken: false`.
* **Kết quả kiểm tra**: Container hoàn toàn không tồn tại thư mục `/var/run/secrets/kubernetes.io/serviceaccount`. Kẻ tấn công nếu có khai thác được code app cũng không thể gọi vào API của cluster.

#### 2. Container Hardening chuẩn PSA "restricted"
* `runAsNonRoot: true`, `runAsUser: 1001` (backend) / `101` (frontend).
* `readOnlyRootFilesystem: true`: Toàn bộ filesystem của container là read-only; các vùng ghi tạm chỉ cho phép trong `emptyDir` có giới hạn dung lượng (`/tmp: 256Mi`).
* `capabilities: drop: [ALL]`: Tước bỏ toàn bộ đặc quyền Linux capabilities của container.
* `allowPrivilegeEscalation: false`: Không cho phép tiến trình con chiếm quyền cao hơn tiến trình cha.

#### 3. NetworkPolicy
* Áp dụng NetworkPolicy `baseline` cho namespace: Chỉ chấp nhận traffic Ingress từ Pod thuộc namespace `traefik` và nội bộ namespace. Mọi traffic ngang hàng từ các namespace khác đều bị chặn lại.

---

### Tầng 5: Linux Kernel Tuning (Anti-DDoS & Socket Recovery)
Được cấu hình tại `/etc/sysctl.d/99-security.conf` và lưu vết trong [ansible/roles/hardening/tasks/main.yml](file:///home/platform-gitops/ansible/roles/hardening/tasks/main.yml).

| Tham số | Giá trị trước | Giá trị sau | Mục đích |
| :--- | :--- | :--- | :--- |
| `net.ipv4.tcp_max_syn_backlog` | 256 | **8192** | Tăng hàng đợi kết nối SYN lên 32 lần, chống tràn khi bị SYN Flood |
| `net.core.somaxconn` | 4096 | **8192** | Tăng số lượng kết nối đang chờ tiếp nhận ở tầng socket |
| `net.core.netdev_max_backlog` | 1000 | **16384** | Tăng dung lượng hàng đợi gói tin ở card mạng trước khi chuyển lên kernel |
| `net.ipv4.tcp_syncookies` | 1 | **1** | Bật SYN Cookies khi hàng đợi bị đầy |
| `net.ipv4.conf.all.rp_filter` | 2 | **1** | Strict Reverse Path: Tự động drop gói tin giả mạo IP nguồn |
| `net.ipv4.tcp_fin_timeout` | 60 | **20** | Thu hồi socket ở trạng thái FIN_WAIT_2 sau 20s thay vì 60s |
| `net.ipv4.tcp_tw_reuse` | 0 | **1** | Tái sử dụng socket TIME_WAIT an toàn cho kết nối đi |
| `net.ipv4.tcp_max_tw_buckets` | 262144 | **1440000** | Tăng số lượng socket TIME_WAIT tối đa tránh drop kết nối |
| `fs.file-max` | 388126 | **2097152** | Nâng giới hạn file descriptors của toàn hệ điều hành lên 2 triệu |

---

### Tầng 6: Quản trị SSH & Chống Chiếm quyền Root
1. **Đã tắt mật khẩu**: `PasswordAuthentication no`, vô hiệu hóa 100% tấn công dò mật khẩu SSH.
2. **Fail2ban giám sát Port 22**: Tự động block IP sau 5 lần gõ sai key/thất bại trong 10 phút.
3. **Đồng bộ Key cho user `ubuntu`**:
   * Đã sao chép 3 SSH keys từ `/root/.ssh/authorized_keys` sang `/home/ubuntu/.ssh/authorized_keys` (`chmod 600`, `chown ubuntu:ubuntu`).
   * User `ubuntu` đã được cấp quyền `sudo` toàn quyền (`NOPASSWD:ALL`).
   * **Nguyên tắc**: Khuyến nghị quản trị viên SSH bằng tài khoản `ubuntu@<IP>` và dùng `sudo su` khi cần, hạn chế SSH trực tiếp bằng `root`.

---

## 4. Cẩm nang Vận hành & Bảo trì (Day-2 Operations)

### Checklist kiểm tra an ninh định kỳ

Chạy cụm lệnh sau để kiểm tra nhanh "sức khỏe" an ninh của VPS:
```bash
# 1. Kiểm tra tải CPU, RAM và số người đang đăng nhập
uptime && free -h

# 2. Kiểm tra các port đang LISTEN mở ra ngoài (chỉ nên thấy 22, 80, 443, 51820)
ss -tlpn | grep LISTEN

# 3. Kiểm tra trạng thái Firewall UFW
ufw status verbose

# 4. Kiểm tra trạng thái Fail2ban bảo vệ SSH
fail2ban-client status sshd

# 5. Kiểm tra các tham số chống DDoS của Kernel
sysctl net.ipv4.tcp_max_syn_backlog net.core.somaxconn net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter

# 6. Kiểm tra trạng thái đồng bộ GitOps trên ArgoCD
k3s kubectl get application traefik traefik-config namespaces fumirai-lunch-production -n argocd
```

---

### Cách cập nhật dải IP Cloudflare
Cloudflare hiếm khi thay đổi dải IP, nhưng theo khuyến nghị định kỳ 6 tháng một lần:
1. Chạy script tự động cập nhật:
   ```bash
   /home/platform-gitops/scripts/harden-cloudflare-ufw.sh
   ```
2. Nếu Cloudflare có thêm dải IP mới, hãy cập nhật vào [platform/traefik/values.yaml](file:///home/platform-gitops/platform/traefik/values.yaml) ở mục `forwardedHeaders.trustedIPs` cho cả `web` và `websecure`, sau đó commit và push lên Git.

---

### Quy trình đóng hoàn toàn cổng 80/443 trên UFW
Khi domain `chungkhoanai.dpdns.org` đã được chuyển qua Cloudflare (hoặc chỉ dùng qua VPN):
1. Chạy script khóa UFW:
   ```bash
   /home/platform-gitops/scripts/harden-cloudflare-ufw.sh
   ```
2. Kiểm tra lại trạng thái UFW:
   ```bash
   ufw status numbered
   ```
   *Đảm bảo không còn dòng `80/tcp ALLOW IN Anywhere` hay `443/tcp ALLOW IN Anywhere`.*

---

### Quy trình chuyển đổi SSH sang user `ubuntu`
Khi đã kiểm tra đăng nhập bằng user `ubuntu` thành công từ máy cá nhân:
```bash
# Test thử từ laptop cá nhân:
ssh ubuntu@13.140.183.90
sudo -i  # Phải vào được root không cần password
```
Sau đó có thể khóa hẳn SSH trực tiếp user `root` trên server:
1. Mở file `/etc/ssh/sshd_config`:
   ```bash
   sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
   sudo systemctl restart sshd
   ```
*(Lưu ý: Luôn giữ một cửa sổ SSH đang mở trong khi test cửa sổ SSH mới để phòng sự cố).*

---

## 5. Quy trình Xử lý Sự cố (Troubleshooting & Incident Response)

### Sự cố 1: Bị tấn công DDoS / Spike Load
**Hiện tượng**: `uptime` báo load average tăng vọt (> 6.0), trang web phản hồi chậm hoặc timeout.

**Quy trình xử lý**:
1. **Tìm tiến trình đang chiếm CPU / RAM**:
   ```bash
   ps aux --sort=-%cpu | head -n 15
   ps aux --sort=-%mem | head -n 15
   ```
2. **Kiểm tra số lượng kết nối mạng vào cổng 80 & 443**:
   ```bash
   ss -tan state established '( dport = :80 or dport = :443 )' | wc -l
   ```
3. **Xem các IP đang mở nhiều kết nối nhất**:
   ```bash
   ss -nt state established '( dport = :80 or dport = :443 )' | awk '{print $4}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -n 20
   ```
4. **Nếu phát hiện IP lạ không phải của Cloudflare đang kết nối trực tiếp vào port 80/443**:
   * Chạy ngay script khóa UFW:
     ```bash
     /home/platform-gitops/scripts/harden-cloudflare-ufw.sh
     ```
   * Hoặc chặn ngay lập tức IP đó bằng UFW:
     ```bash
     ufw insert 1 deny from <IP_KẺ_TẤN_CÔNG>
     ```
5. **Kích hoạt chế độ "Under Attack Mode" trên Cloudflare**:
   * Truy cập Cloudflare Dashboard -> chọn Domain `fumifood.dpdns.org` -> Bật **Under Attack Mode** để Cloudflare tự động hiển thị JavaScript Challenge (Turnstile) chặn 100% botnet trước khi chạm tới VPS.

---

### Sự cố 2: Người dùng thật bị lỗi HTTP 429 (Too Many Requests)
**Hiện tượng**: Người dùng báo bị chặn hoặc nhận thông báo Rate Limit vượt quá mức.

**Quy trình xử lý**:
1. **Kiểm tra log của Traefik**:
   ```bash
   k3s kubectl logs -n traefik deployment/traefik --tail=100 | grep "429"
   ```
2. **Kiểm tra lại cấu hình Middleware**:
   * Đảm bảo `sourceCriterion.requestHeaderName` là `CF-Connecting-IP`.
   * Nếu nghiệp vụ của ứng dụng có tính chất polling hoặc load nhiều asset đồng thời khiến người dùng hợp lệ chạm trần 100 req/s, tăng `average` và `burst` trong [platform/traefik/config/middlewares.yaml](file:///home/platform-gitops/platform/traefik/config/middlewares.yaml):
     ```yaml
     spec:
       rateLimit:
         average: 150
         burst: 80
         period: 1s
     ```
   * Commit và push lên Git để ArgoCD tự động áp dụng.

---

### Sự cố 3: K3s Pod bị OOMKilled hoặc Node áp lực bộ nhớ
**Hiện tượng**: Pod backend hoặc Traefik bị restart, `kubectl describe pod` thấy `OOMKilled`.

**Quy trình xử lý**:
1. **Kiểm tra pod nào vừa bị restart**:
   ```bash
   k3s kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount'
   ```
2. **Kiểm tra log OOM của Kernel**:
   ```bash
   dmesg -T | grep -i "oom" | tail -n 20
   ```
3. **Kiểm tra bộ nhớ Swap**:
   ```bash
   swapon --show
   free -h
   ```
   *Nếu Swap bị đầy, chạy `swapoff -a && swapon -a` để giải phóng (chỉ thực hiện khi RAM còn trống).*

---

## 6. Quy trình Rollback Khẩn cấp (Disaster Recovery)

Nếu bất kỳ cấu hình nào mới triển khai gây lỗi ngoài ý muốn, thực hiện rollback theo các bước chuẩn sau:

### 1. Rollback Traefik Ingress:
Revert commit trên Git:
```bash
cd /home/platform-gitops
git revert HEAD -m "revert: rollback traefik security changes"
git push origin main
# Buộc ArgoCD sync ngay:
k3s kubectl annotate application traefik traefik-config -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### 2. Rollback Kernel Sysctl:
Khôi phục file sysctl mặc định và nạp lại:
```bash
rm -f /etc/sysctl.d/99-security.conf
sysctl --system
```

### 3. Rollback UFW Firewall:
Nếu lỡ khóa nhầm UFW làm mất truy cập web:
```bash
ufw allow 80/tcp
ufw allow 443/tcp
ufw reload
```

---

*Tài liệu được khởi tạo và lưu trữ chính thức trong GitOps repository tại [docs/security-hardening-and-ddos-runbook.md](file:///home/platform-gitops/docs/security-hardening-and-ddos-runbook.md).*
