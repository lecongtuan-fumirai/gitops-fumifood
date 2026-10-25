# Sổ Tay Vận Hành & Chuẩn Hóa VPS K3s Production (Enterprise SRE Runbook)

> **Mục đích tài liệu:**  
> Ghi lại toàn bộ quy trình thiết lập, giải thích chi tiết **Cách làm (How)**, **Tại sao phải làm (Why)**, **Những lưu ý sống còn (Gotchas)** và **Cách khôi phục khi có sự cố (Rollback)** cho từng giai đoạn chuẩn hóa máy chủ VPS `vmi3371043` (`13.140.183.90`).  
> Tài liệu này đảm bảo bất kỳ kỹ sư nào khi nhìn lại đều hiểu bản chất kiến trúc và không bao giờ phải "tự mò lại" từ đầu.

---

## MỤC LỤC
1. [Giai đoạn 1: Bảo mật Tầng Biên & Quyền Truy Cập (Zero-Trust Perimeter)](#giai-đoạn-1-bảo-mật-tầng-biên--quyền-truy-cập-zero-trust-perimeter)
   * [1.1. Chuẩn hóa Quản trị SSH (User riêng, Khóa Root, Tắt Mật khẩu)](#11-chuẩn-hóa-quản-trị-ssh)
   * [1.2. Khóa Cổng Kubernetes API (`6443/tcp`)](#12-khóa-cổng-kubernetes-api-6443tcp)
   * [1.3. Khóa Cổng Web (80/443) Chỉ Cho Phép Cloudflare Edge IP](#13-khóa-cổng-web-80443-chỉ-cho-phép-cloudflare-edge-ip)
2. [Giai đoạn 2: Chuẩn Hóa Hệ Điều Hành Host (CIS Linux Hardening)](#giai-đoạn-2-chuẩn-hóa-hệ-điều-hành-host-cis-linux-hardening)
   * [2.1. Tối ưu Hóa Kernel Sysctl (Chống SYN Flood, Socket Leak, Swap Tuning)](#21-tối-ưu-hóa-kernel-sysctl)
   * [2.2. Cài đặt & Cấu hình Fail2ban Chống Dò Quét](#22-cài-đặt--cấu-hình-fail2ban)
   * [2.3. Tự Động Cập Nhật Bản Vá Bảo Mật (`unattended-upgrades`)](#23-tự-động-cập-nhật-bản-vá-bảo-mật)
3. [Giai đoạn 3: Phân Vùng Tài Nguyên & Ổn Định K3s (SRE Resource Isolation)](#giai-đoạn-3-phân-vùng-tài-nguyên--ổn-định-k3s-sre-resource-isolation)
   * [3.1. Thiết lập Budget Bảo vệ OS (`system-reserved` & `kube-reserved`)](#31-thiết-lập-budget-bảo-vệ-os)
   * [3.2. Cấu hình Ngưỡng Tự Thu Hồi Pods Tránh Treo Máy (`eviction-hard`)](#32-cấu-hình-ngưỡng-tự-thu-hồi-pods)
   * [3.3. Tự Động Dọn Rác Container Image Tránh Đầy Ổ Đĩa](#33-tự-động-dọn-rác-container-image)
4. [Giai đoạn 4: Tự Động Hóa Sao Lưu 3-2-1 Sang Cloudflare R2](#giai-đoạn-4-tự-động-hóa-sao-lưu-3-2-1-sang-cloudflare-r2)
   * [4.1. Cơ Chế Snapshot Online K3s SQLite (Zero Downtime)](#41-cơ-chế-snapshot-online-k3s-sqlite)
   * [4.2. Cấu hình K3s Backup Service & Timer](#42-cấu-hình-k3s-backup-service--timer)
   * [4.3. Kịch Bản Khôi Phục Thảm Họa (DR Scenario)](#43-kịch-bản-khôi-phục-thảm-họa)
5. [Giai đoạn 5: Giám Sát Toàn Diện (Observability & SRE Hub)](#giai-đoạn-5-giám-sát-toàn-diện-observability--sre-hub)
   * [5.1. Kiến Trúc Giám Sát Tập Trung Qua WireGuard Tunnel](#51-kiến-trúc-giám-sát-tập-trung)
   * [5.2. Giải Thích: Tại Sao Không Cài Grafana Trực Tiếp Lên VPS Này?](#52-giải-thích-tại-sao-không-cài-grafana-trực-tiếp)

---

# Giai đoạn 1: Bảo mật Tầng Biên & Quyền Truy Cập (Zero-Trust Perimeter)

---

## 1.1. Chuẩn hóa Quản trị SSH

### 📌 Tại sao phải làm vậy? (Rationale)
1. **Nguyên tắc trách nhiệm (Accountability):** Tại các công ty lớn, không ai được phép SSH trực tiếp bằng `root`. Nếu nhiều người cùng dùng `root`, khi có lỗi hoặc lệnh phá hoại (như `rm -rf`), audit log hệ thống sẽ không thể truy vết ai là người thực hiện. Dùng tài khoản cá nhân có `sudo` giúp lưu lại lịch sử trong `/var/log/auth.log`.
2. **Chống Brute-force tự động:** Mọi botnet trên Internet đều quét cổng 22 với username mặc định là `root`. Tắt `PermitRootLogin` sẽ vô hiệu hóa 99.9% các đợt tấn công dò mật khẩu tự động này.
3. **Cấm Password Authentication:** Mật khẩu dù phức tạp đến đâu vẫn có rủi ro bị lộ (keylogger, brute force). SSH Key chuẩn `ed25519` sử dụng mật mã đường cong elip (elliptic-curve cryptography), độ dài ngắn, tốc độ nhanh và không thể bị giải mã ngược.

### 🛠️ Cách làm từng bước (How-to)

```bash
# Bước 1: Tạo user quản trị riêng (ví dụ: devops)
sudo adduser devops

# Bước 2: Thêm devops vào nhóm sudo để có quyền thực thi lệnh quản trị
sudo usermod -aG sudo devops

# Bước 3: Thiết lập thư mục SSH với quyền hạn cực kỳ nghiêm ngặt
sudo mkdir -p /home/devops/.ssh
sudo chmod 700 /home/devops/.ssh

# Bước 4: Copy authorized_keys hiện tại sang (hoặc dán public key ed25519 mới)
sudo cp /root/.ssh/authorized_keys /home/devops/.ssh/authorized_keys
sudo chown -R devops:devops /home/devops/.ssh
sudo chmod 600 /home/devops/.ssh/authorized_keys
```

**Cấu hình SSH Daemon an toàn:**
Tạo file cấu hình riêng tại `/etc/ssh/sshd_config.d/99-hardening.conf` (không sửa file `/etc/ssh/sshd_config` gốc để tránh bị ghi đè khi nâng cấp gói `openssh-server`):

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Vô hiệu hóa login bằng root từ xa
PermitRootLogin no

# Bắt buộc xác thực qua SSH Key, cấm dùng password qua mạng
PasswordAuthentication no
PubkeyAuthentication yes

# Bảo vệ session
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# Kiểm tra cú pháp cấu hình (BẮT BUỘC TRƯỚC KHI RELOAD)
sudo sshd -t

# Nếu lệnh trên không báo lỗi gì, tiến hành reload sshd
sudo systemctl reload sshd
```

### ⚠️ Lưu ý sống còn & Gotchas
* **QUY TẮC SỐ 1:** Sau khi reload `sshd`, **TUYỆT ĐỐI KHÔNG ĐƯỢC TẮT CỬA SỔ TERMINAL HIỆN TẠI**.
* Mở một cửa sổ Terminal mới trên máy tính cá nhân của bạn để test thử:
  ```bash
  ssh devops@13.140.183.90
  sudo whoami  # Nhập pass devops, phải in ra 'root'
  ```
* Chỉ khi nào terminal mới đăng nhập và `sudo` thành công mới được tắt session cũ.
* **Cách cứu hộ nếu lỡ bị khóa:** Đăng nhập vào trang quản trị Contabo $\rightarrow$ Mở tính năng **VNC Web Console** (Console ảo tương đương cắm màn hình/bàn phím trực tiếp vào máy chủ vật lý) để đăng nhập và sửa lại file cấu hình.

---

## 1.2. Khóa Cổng Kubernetes API (`6443/tcp`)

### 📌 Tại sao phải làm vậy? (Rationale)
1. **Kubernetes API là "trái tim" của hệ thống:** Ai nắm được quyền điều khiển cổng 6443 coi như nắm toàn bộ máy chủ.
2. **Tránh bị khai thác lỗ hổng Zero-day / CVE:** Mặc dù Kubernetes có xác thực chứng chỉ TLS (mTLS), việc phơi cổng 6443 ra toàn thế giới (`0.0.0.0/0`) khiến máy chủ liên tục bị hàng nghìn botnet gửi gói tin dò quét các lỗ hổng bypass xác thực (như các lỗ hổng nổi tiếng CVE-2018-1002105, CVE-2023-3893).
3. **Tiết kiệm tài nguyên CPU/RAM:** K3s server phải thực hiện hàng ngàn phép tính mã hóa bắt tay TLS (TLS Handshake) cho các kết nối rác từ Internet, gây hao tốn CPU của VPS.

### 🛠️ Cách làm từng bước (How-to)

```bash
# Xóa quy tắc cho phép cổng 6443 từ mọi nơi trên UFW
sudo ufw delete allow 6443/tcp
sudo ufw delete allow 6443/tcp comment "" 2>/dev/null || true
```

* **Nếu muốn quản trị từ xa từ máy tính cá nhân:**
  Lấy IP mạng nhà/công ty (`curl ifconfig.me`) rồi chỉ cho phép duy nhất IP đó:
  ```bash
  sudo ufw allow from <IP_CỦA_BẠN> to any port 6443 proto tcp comment "Admin remote Kube API"
  ```
* **Hoặc quản trị an toàn nhất:** Kết nối thông qua VPN WireGuard (`51820/udp`) nội bộ.

### ⚠️ Lưu ý sống còn & Gotchas
* Sau khi xóa rule `6443/tcp`, các lệnh `kubectl` gõ trực tiếp trên VPS **HOÀN TOÀN KHÔNG BỊ ẢNH HƯỞNG**. Vì trên VPS, `kubectl` giao tiếp qua loopback nội bộ `127.0.0.1:6443`, không đi qua tường lửa ngoài của card mạng `eth0`.
* Traefik Ingress và các Pods bên trong K3s giao tiếp qua mạng nội bộ CNI Flannel (`10.42.0.0/16`), hoàn toàn không bị ảnh hưởng.

---

## 1.3. Khóa Cổng Web (80/443) Chỉ Cho Phép Cloudflare Edge IP

### 📌 Tại sao phải làm vậy? (Rationale)
1. **Chống Bypass CDN (Origin IP Bypass Attack):**
   * Bạn cấu hình domain trỏ qua Cloudflare để dùng CDN, WAF, Rate-limiting và chống DDoS.
   * Nhưng nếu cổng 80/443 trên VPS mở `Anywhere`, kẻ tấn công chỉ cần quét cổng hoặc tìm thấy IP thật `13.140.183.90` (qua DNS history hoặc chứng chỉ SSL), chúng sẽ bắn thẳng traffic vào IP này. Toàn bộ lớp bảo vệ của Cloudflare sẽ bị vô hiệu hóa!
2. **Đảm bảo 100% Traffic đều được kiểm duyệt:** Khi UFW chỉ mở cho dải IP của Cloudflare, bất kỳ ai cố tình truy cập thẳng `http://13.140.183.90` sẽ bị Firewall Drop gói tin ngay tại tầng Network của nhân Linux (Kernel space), không tốn một chút RAM hay CPU nào của Traefik/K3s.

### 🛠️ Cách làm từng bước (How-to)

Chạy script tự động đã được lập trình sẵn trong repo [scripts/harden-cloudflare-ufw.sh](file:///home/platform-gitops/scripts/harden-cloudflare-ufw.sh):

```bash
sudo bash /home/platform-gitops/scripts/harden-cloudflare-ufw.sh
```

**Bản chất hoạt động của script:**
1. Script gửi request tới API chính thức của Cloudflare:
   * IPv4: `https://www.cloudflare.com/ips-v4`
   * IPv6: `https://www.cloudflare.com/ips-v6`
2. Tạo các rule UFW cho phép cổng `80` và `443` cho từng dải mạng (CIDR) này.
3. Xóa bỏ hoàn toàn rule mở tự do (`ufw delete allow 80`, `ufw delete allow 443`).

### ⚠️ Lưu ý sống còn & Gotchas
* **Điều kiện bắt buộc:** Trên Cloudflare Dashboard, DNS record của bạn (`fumifood.dpdns.org`) phải được **bật đám mây màu cam (Proxied = ON)**. Nếu để DNS-only (Grey cloud), người dùng sẽ không vào được trang web vì IP của họ bị UFW chặn.
* **Chứng chỉ Let's Encrypt:** Cert-Manager vẫn tự động gia hạn SSL qua HTTP-01 challenge bình thường, vì bot của Let's Encrypt truy cập domain qua Cloudflare Proxy.
* **Cập nhật định kỳ:** Cloudflare rất hiếm khi đổi dải IP, nhưng nên đặt một cronjob chạy script này mỗi tháng 1 lần để cập nhật.

---

# Giai đoạn 2: Chuẩn Hóa Hệ Điều Hành Host (CIS Linux Hardening)

---

## 2.1. Tối ưu Hóa Kernel Sysctl

### 📌 Tại sao phải làm vậy? (Rationale)
* Cấu hình mặc định của Linux Ubuntu được thiết kế cho các tác vụ tổng quát hoặc máy tính văn phòng, **không tối ưu cho máy chủ chạy Container & Kubernetes**.
* Khi bị flood request hoặc traffic tăng đột biến:
  * Hàng đợi kết nối TCP (`somaxconn`, `tcp_max_syn_backlog`) mặc định quá nhỏ (thường chỉ 128 hoặc 1024), dẫn đến việc từ chối kết nối ngay cả khi CPU còn rảnh rỗi.
  * Tham số `vm.swappiness` mặc định trên Ubuntu là 60 khiến kernel vội vã đẩy dữ liệu ra ổ cứng SSD swap, gây nghẽn I/O Disk trên VPS Contabo. Giảm xuống `10` buộc kernel ưu tiên dùng RAM thật trước.
  * Bật `tcp_syncookies` để ngăn chặn hoàn toàn kiểu tấn công cổ điển nhưng nguy hiểm: **TCP SYN Flood**.

### 🛠️ Cách làm từng bước (How-to)

Tạo file `/etc/sysctl.d/99-kubernetes-enterprise.conf`:

```bash
sudo tee /etc/sysctl.d/99-kubernetes-enterprise.conf << 'EOF'
# ============================================================================
# 1. BẢO MẬT & CHỐNG TẤN CÔNG MẠNG (ANTI-DDOS & SYN FLOOD)
# ============================================================================
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Chống IP Spoofing (Giả mạo địa chỉ IP nguồn)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Bỏ qua ICMP Redirects (Chống tấn công Man-In-The-Middle định tuyến)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# ============================================================================
# 2. HIỆU NĂNG MẠNG & DUNG LƯỢNG KẾT NỐI (HIGH CONCURRENCY)
# ============================================================================
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535

# Tối ưu bộ đệm TCP socket
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# ============================================================================
# 3. BẢO VỆ BỘ NHỚ RAM & TỐI ƯU SWAP (CHO VPS 4GB RAM)
# ============================================================================
# Chỉ dùng Swap khi RAM thực sự cạn kiệt (< 10%)
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# Cần thiết cho K8s và Elastic/VictoriaMetrics
vm.max_map_count = 262144
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
EOF

# Nạp cấu hình vào nhân Kernel ngay lập tức mà không cần khởi động lại máy
sudo sysctl --system
```

---

## 2.2. Cài đặt & Cấu hình Fail2ban

### 📌 Tại sao phải làm vậy? (Rationale)
* Cho dù đã tắt đăng nhập mật khẩu, các bot dò quét vẫn liên tục gửi yêu cầu SSH handshake vào cổng 22. 
* `Fail2ban` đọc file log `/var/log/auth.log` theo thời gian thực. Nếu một IP cố tình gửi thông tin sai 3 lần, Fail2ban sẽ tự động thêm rule vào Firewall để khóa (ban) IP đó trong vòng 24 giờ. Điều này giải phóng hoàn toàn tiến trình `sshd` khỏi việc phải phản hồi các botnet.

### 🛠️ Cách làm từng bước (How-to)

```bash
# 1. Cài đặt fail2ban
sudo apt-get update && sudo apt-get install -y fail2ban

# 2. Tạo cấu hình cục bộ (jail.local)
sudo tee /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 3
ignoreip = 127.0.0.1/8 ::1 10.42.0.0/16 10.43.0.0/16 10.66.66.0/24

[sshd]
enabled = true
port    = 22
mode    = aggressive
backend = systemd
EOF

# 3. Kích hoạt và khởi động dịch vụ
sudo systemctl enable --now fail2ban

# 4. Kiểm tra trạng thái hoạt động
sudo fail2ban-client status sshd
```

---

## 2.3. Tự Động Cập Nhật Bản Vá Bảo Mật (`unattended-upgrades`)

### 📌 Tại sao phải làm vậy? (Rationale)
* Các lỗ hổng nhân Linux và thư viện hệ thống (OpenSSL, glibc, systemd) xuất hiện liên tục. Thay vì phải vào gõ `apt update && apt upgrade` thủ công, các công ty lớn cấu hình cho OS tự động tải và cài các bản vá bảo mật quan trọng (`security updates`) vào ban đêm, giúp hệ thống luôn an toàn trước các lỗ hổng zero-day đã có bản vá.

### 🛠️ Cách làm từng bước (How-to)

```bash
sudo apt-get install -y unattended-upgrades update-notifier-common

sudo tee /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {
    # Không tự nâng cấp k3s hoặc kernel nếu chưa test
    "k3s*";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# Kích hoạt lịch chạy tự động hàng ngày
sudo tee /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

---

# Giai đoạn 3: Phân Vùng Tài Nguyên & Ổn Định K3s (SRE Resource Isolation)

---

## 3.1. Thiết lập Budget Bảo vệ OS (`system-reserved` & `kube-reserved`)

### 📌 Tại sao phải làm vậy? (Rationale)
* **Giải mã hiện tượng `top nodes` báo 108%:**
  * K3s mặc định cho rằng toàn bộ RAM của máy chủ đều có thể dùng để lập lịch chạy Pods.
  * Nếu các Pod tiêu thụ hết RAM, nhân Linux sẽ kích hoạt cơ chế sinh tồn: **Linux Kernel OOM Killer**.
  * Kernel OOM Killer sẽ tìm các tiến trình tiêu tốn nhiều RAM để "bắn hạ" (kill). Rất nhiều trường hợp nó bắn nhầm `containerd`, `k3s-server`, hoặc làm tê liệt tiến trình `sshd`, dẫn đến máy chủ bị treo cứng (hang), không thể SSH vào được nữa và buộc phải Hard Reboot trên Contabo.
* **Giải pháp:** Cấu hình **Reservation Budget**:
  * Trừ sẵn **400 MiB RAM + 250m CPU** cho riêng Hệ điều hành (`system-reserved`).
  * Trừ sẵn **500 MiB RAM + 250m CPU** cho Kubelet & Containerd (`kube-reserved`).
  * K3s Scheduler sẽ chỉ phân bổ phần còn lại cho các Pods, đảm bảo OS không bao giờ bị nghẽn thở.

### 🛠️ Cách làm từng bước (How-to)

File cấu hình chính của K3s server nằm tại `/etc/rancher/k3s/config.yaml`. Bạn chỉnh sửa hoặc bổ sung các dòng sau:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee -a /etc/rancher/k3s/config.yaml << 'EOF'

# --- SRE RESOURCE RESERVATION & STABILITY ---
kubelet-arg:
  - "system-reserved=cpu=250m,memory=400Mi"
  - "kube-reserved=cpu=250m,memory=500Mi"
  - "eviction-hard=memory.available<300Mi,nodefs.available<10%,imagefs.available<10%"
  - "eviction-soft=memory.available<500Mi"
  - "eviction-soft-grace-period=memory.available=1m"
  - "image-gc-high-threshold=80"
  - "image-gc-low-threshold=70"
EOF

# Restart K3s để nạp tham số kubelet mới
sudo systemctl restart k3s
```

> **Kiểm tra (Verification):**  
> Chạy lệnh: `kubectl describe node vmi3371043 | grep -A 8 "Allocatable:"`  
> Bạn sẽ thấy giá trị bộ nhớ `Allocatable` được tính toán lại một cách chuẩn mực, thấp hơn tổng dung lượng vật lý (Capacity) đúng bằng phần đã reserve.

---

## 3.2. Cấu hình Ngưỡng Tự Thu Hồi Pods Tránh Treo Máy (`eviction-hard`)

### 📌 Tại sao phải làm vậy? (Rationale)
* Khi một ứng dụng bị lỗi tràn bộ nhớ (Memory Leak), thay vì để nó ăn sạch RAM và làm sập cả VPS, Kubernetes Kubelet sẽ tự động can thiệp theo 2 bước:
  1. **Soft Eviction (`memory.available < 500Mi` trong 1 phút):** Kubelet gửi tín hiệu cảnh báo và chuẩn bị khởi động lại pod gây lỗi.
  2. **Hard Eviction (`memory.available < 300Mi`):** Kubelet lập tức thu hồi và khởi động lại pod ngốn RAM nhất, giải phóng bộ nhớ ngay lập tức để bảo vệ VPS không bao giờ bị crash.

---

## 3.3. Tự Động Dọn Rác Container Image Tránh Đầy Ổ Đĩa

* `image-gc-high-threshold=80`: Khi ổ cứng chứa container images chạm mốc **80%**, Kubelet tự động kích hoạt trình dọn dẹp các Docker/Container image cũ không còn sử dụng.
* `image-gc-low-threshold=70`: Nó sẽ dọn dẹp liên tục cho đến khi dung lượng đĩa giảm xuống dưới **70%** thì dừng. Bạn không bao giờ phải lo việc nửa đêm ổ cứng bị đầy 100% làm chết cụm.

---

# Giai đoạn 4: Tự Động Hóa Sao Lưu 3-2-1 Sang Cloudflare R2

---

## 4.1. Cơ Chế Snapshot Online K3s SQLite (Zero Downtime)

### 📌 Tại sao phải làm vậy? (Rationale)
* K3s lưu toàn bộ trạng thái cụm (Secrets, ConfigMaps, Deployments, CRDs) trong file SQLite tại `/var/lib/rancher/k3s/server/db/state.db`.
* Nếu chỉ dùng lệnh `cp` copy file này khi K3s đang chạy, bạn sẽ thu được một file database bị hỏng (corrupted) do SQLite đang có giao dịch ghi dở dang (WAL mode).
* Script backup của chúng ta sử dụng API chuẩn của SQLite:
  ```bash
  sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '/tmp/state.db'"
  sqlite3 /tmp/state.db "PRAGMA integrity_check;"
  ```
  Lệnh này khóa logic an toàn ở mức SQLite page, đảm bảo bản snapshot toàn vẹn 100% mà **không cần dừng dịch vụ K3s một giây nào (Zero Downtime)**.

---

## 4.2. Cấu hình K3s Backup Service & Timer

Toàn bộ logic này đã được viết thành Ansible Role trong [ansible/roles/backup](file:///home/platform-gitops/ansible/roles/backup). Để kích hoạt:

```bash
# Bước 1: Tạo file biến môi trường chứa thông tin Cloudflare R2
sudo install -m 600 /dev/null /etc/k3s-backup.env
sudo tee /etc/k3s-backup.env << 'EOF'
R2_ACCOUNT_ID="<id-cloudflare-cua-ban>"
R2_ACCESS_KEY_ID="<key-id-r2>"
R2_SECRET_ACCESS_KEY="<secret-key-r2>"
R2_BUCKET="platform-backups"

# Khóa công khai Age (dùng để mã hóa file trước khi gửi lên đám mây)
BACKUP_AGE_RECIPIENT="age1..."
EOF

# Bước 2: Chạy Ansible tag backup để cài rclone, tạo script và enable systemd timer
cd /home/platform-gitops/ansible
ansible-playbook site.yml --tags backup

# Bước 3: Kiểm tra lịch chạy
systemctl list-timers | grep k3s-backup
```
* **Lịch trình:** Tự động chạy mỗi 6 tiếng một lần (`00:15`, `06:15`, `12:15`, `18:15 UTC`).
* **Chuẩn 3-2-1:**
  * Bản copy 1: Đang chạy trên K3s.
  * Bản copy 2: Lưu tại local `/var/backups/k3s` (lưu trữ xoay vòng 3 ngày).
  * Bản copy 3: Mã hóa bằng `age` và đẩy lên Cloudflare R2 (Offsite Cloud).

---

# Giai đoạn 5: Giám Sát Toàn Diện (Observability & SRE Hub)

---

## 5.1. Kiến Trúc Giám Sát Tập Trung Qua WireGuard Tunnel

```
[ VPS Production: vmi3371043 ]                      [ Monitoring Hub VPS (Miniappify) ]
┌───────────────────────────────┐                  ┌─────────────────────────────────┐
│ • VictoriaMetrics Agent       │                  │ • VictoriaMetrics TSDB Cluster  │
│   (vmagent nhẹ, ít tốn RAM)   │                  │ • VictoriaLogs Storage          │
│ • Node Exporter (Metrics OS)  │ === WireGuard == │ • Grafana Dashboards            │
│ • Kube-State-Metrics (K8s)    │    Tunnel VPN    │ • Alertmanager (Telegram/Slack) │
│ • Fluent Bit (Gom Log)        │                  │                                 │
└───────────────────────────────┘                  └─────────────────────────────────┘
```

* Trên VPS Production, chúng ta **chỉ cài các Agent siêu nhẹ** (`vmagent`, `fluent-bit`, `node-exporter`). Chúng chỉ tốn khoảng ~50-80MB RAM.
* Các Agent này gom toàn bộ số liệu và log, sau đó đẩy an toàn qua đường hầm **WireGuard Tunnel (`10.66.66.1:8428`)** về máy chủ Monitoring Hub trung tâm.

---

## 5.2. Giải Thích: Tại Sao Không Cài Grafana Trực Tiếp Lên VPS Này?

Khi bạn kiểm tra `kubectl get pods -A | grep -i grafana` và không thấy Grafana chạy, đây là **MỘT QUYẾT ĐỊNH THIẾT KẾ CỐ TÌNH (INTENTIONAL SRE ARCHITECTURE)**:

1. **Bảo tồn RAM quý giá cho ứng dụng kinh doanh:**
   * VPS này có 3.8 GiB RAM và đang gánh toàn bộ môi trường Production (`fumirai-lunch`, `fumi-live`, ArgoCD).
   * Grafana + Prometheus Server đầy đủ ngốn ít nhất 800MB - 1.5GB RAM và tốn nhiều I/O đĩa cứng để vẽ biểu đồ. Cài Grafana lên đây sẽ làm cụm bị thiếu RAM trầm trọng.
2. **Nguyên tắc "Không để người quan sát chết chung với bệnh nhân":**
   * Nếu VPS Production gặp sự cố sập nguồn hoặc bị DDoS nghẽn mạng, nếu Grafana nằm ngay trên VPS đó thì bạn sẽ mất luôn khả năng giám sát và không nhận được cảnh báo.
   * Để Grafana và Alertmanager ở một máy chủ độc lập (Monitoring Hub) giúp bạn vẫn theo dõi và nhận thông báo Telegram bình thường ngay cả khi VPS Production gặp sự cố.
