# Kiến trúc & Cẩm nang Vận hành Hệ thống Monitoring Hub (Production Grade)

Tài liệu này giải thích chi tiết, toàn diện và dễ hiểu về toàn bộ hệ thống giám sát phân tán đa vùng (Cross-Region Hybrid Monitoring) giữa cụm **K3s Production tại Đức (EU)** và **Monitoring Hub tại Việt Nam (VN)**.

---

## 1. Bức tranh tổng thể: Tại sao lại thiết kế như thế này?

```
┌────────────────────────────────────────────────────────┐         ┌──────────────────────────────────────────────────────────┐
│             CỤM PRODUCTION K3S (Đức - EU)              │         │             MONITORING HUB (Việt Nam - VN)               │
│                    Host: vn1-01                        │         │                    Host: miniappify                      │
│                                                        │         │                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │         │  ┌────────────────────────────────────────────────────┐  │
│  │ node-exporter│  │kube-state-m. │  │ Kubelet/cAdv │  │         │  │                 VictoriaMetrics                    │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │         │  │                (TSDB lưu trữ 30d)                  │  │
│         │                 │                 │          │         │  └────────────────────────▲───────────────────────────┘  │
│         └───────────┬─────┴─────────────────┘          │         │                           │                              │
│                     ▼                                  │         │               Remote Write (TCP :8428)                   │
│               ┌───────────┐                            │         │                           │                              │
│               │  vmagent  │                            │         │                           │                              │
│               │ (Scrape & │                            │         │                           │                              │
│               │ 2GB Buffer)                            │         │                           │                              │
│               └─────┬─────┘                            │         │                           │                              │
│                     │                                  │         │                           │                              │
│                     │  Flannel Masquerade              │         │                           │                              │
│                     ▼                                  │         │                           │                              │
│              ┌─────────────┐                           │         │                     ┌───────────┐                        │
│              │   wg-hub    │==================== WIREGUARD VPN ========================│    wg0    │                        │
│              │ 10.66.66.10 │   (Mã hóa đường hầm xuyên lục địa RTT ~250ms)             │10.66.66.1 │                        │
│              └─────────────┘                                     │                     └─────┬─────┘                        │
│                                                                  │                           │                              │
└──────────────────────────────────────────────────────────────────┘                           │ wg-guard (Chặn tất cả,       │
                                                                                               │  chỉ mở duy nhất :8428)      │
                                                                                               ▼                              │
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐  │
│  CÁC THÀNH PHẦN GIÁM SÁT & CẢNH BÁO TẠI HUB:                                                                             │  │
│                                                                                                                          │  │
│    ┌──────────────┐           ┌────────────────┐         ┌─────────────────┐                                             │  │
│    │   vmalert    │ ────────► │  Alertmanager  │ ──────► │ Nhóm Telegram   │                                             │  │
│    │ (Quét Rules) │           │(Lọc & Gửi tin) │         │ (Cảnh báo sự cố)│                                             │  │
│    └──────────────┘           └───────┬────────┘         └─────────────────┘                                             │  │
│                                       │ Watchdog Ping                                                                    │  │
│                                       ▼                                                                                  │  │
│                               ┌────────────────┐                                                                         │  │
│                               │ healthchecks.io│ (Dead Man's Switch: Báo động nếu Hub mất điện/chết mạng)                │  │
│                               └────────────────┘                                                                         │  │
│                                                                                                                          │  │
│    ┌──────────────┐           ┌────────────────┐         ┌─────────────────┐         ┌──────────────────────────────┐    │  │
│    │   Grafana    │ ◄──────── │    Traefik     │ ◄────── │   Cloudflare    │ ◄────── │         Người dùng           │    │  │
│    │  (Port 3000) │  Nội bộ   │    (Port 80)   │  HTTP   │  (SSL/TLS Term) │  HTTPS  │(https://grafana.tuanstark...│    │  │
│    └──────────────┘           └────────────────┘         └─────────────────┘         └──────────────────────────────┘    │  │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘  │
```

### Câu hỏi 1: Tại sao không cài thẳng Prometheus + Grafana trên K3s (EU)?
* **Nguy cơ tràn RAM (OOM Crash)**: Cụm K3s sản xuất có giới hạn RAM. Prometheus tiêu thụ rất nhiều RAM khi tải cao. Nếu Prometheus bị OOM, nó có thể kéo theo các dịch vụ nghiệp vụ (Fumirai Lunch, Floci) bị ảnh hưởng.
* **Nguyên tắc "Độc lập quan sát" (Out-of-band Monitoring)**: Khi server Production bị sập nguồn hoặc đứt mạng, toàn bộ hệ thống giám sát cài trên nó cũng sẽ chết theo. Bạn sẽ không nhận được bất kỳ tin nhắn cảnh báo nào. Do đó, Hub giám sát bắt buộc phải nằm trên một máy chủ độc lập ở vị trí địa lý khác.

### Câu hỏi 2: Tại sao dùng cơ chế PUSH (`vmagent`) thay vì PULL (Prometheus cào metric)?
* Khoảng cách địa lý từ Việt Nam sang Đức có độ trễ mạng (**RTT ~250ms**) và thường xuyên bị jitter, đứt cáp quang biển.
* Nếu Hub ở VN chủ động kết nối sang Đức để cào dữ liệu (Pull) mỗi 15-30 giây, các request HTTP sẽ liên tục bị timeout, mất gói tin, làm biểu đồ Grafana bị răng cưa, đứt đoạn.
* **Giải pháp Push**: Ta đặt một agent siêu nhẹ là `vmagent` ngay trong K3s. `vmagent` cào metric nội bộ với tốc độ microsecond, sau đó nén lại và chủ động đẩy (Push) về Hub qua VPN.

---

## 2. Chi tiết từng tầng công nghệ & Cách hoạt động

### 2.1. Tầng tác nhân tại cụm K3s (`vn1-01` - Đức)

1. **`node-exporter`**: Thu thập thông số phần cứng của máy chủ Linux (CPU, RAM, Đĩa cứng, Network bandwidth, IOPS).
2. **`kube-state-metrics`**: Thu thập trạng thái các tài nguyên Kubernetes (Pod nào đang CrashLoopBackOff, Deployment nào thiếu replica, PVC nào sắp đầy...).
3. **`cAdvisor` (tích hợp trong Kubelet)**: Thu thập mức tiêu thụ CPU/RAM của từng container cụ thể.
4. **`vmagent` (Trái tim của cụm thu thập)**:
   * **Cơ chế Buffer đĩa 2GB**: Đây là tính năng quan trọng nhất. Khi đường truyền mạng quốc tế bị đứt, hoặc khi Hub VN khởi động lại/nâng cấp, `vmagent` sẽ tự động ghi toàn bộ metrics vào ổ đĩa PVC cục bộ (tối đa 1.5GB - 2GB).
   * **Buffer Replay (Gửi bù dữ liệu)**: Ngay khi đường hầm VPN thông suốt trở lại, `vmagent` sẽ xả dữ liệu từ quá khứ đến hiện tại sang VictoriaMetrics với đúng timestamp ban đầu. Biểu đồ trên Grafana sẽ tự động được lấp đầy liền mạch, **không bao giờ bị mất dữ liệu lịch sử**.

---

### 2.2. Tầng mạng bảo mật: Đường hầm WireGuard VPN

Hai máy chủ được nối với nhau qua một mạng riêng ảo bảo mật:
* **Hub VN (`miniappify`)**: Interface `wg0`, IP `10.66.66.1/24`, Port UDP `51820`.
* **K3s EU (`vn1-01`)**: Interface `wg-hub`, IP `10.66.66.10/32`.

#### Bí ẩn SRE: Tại sao `ping 10.66.66.1` từ K3s lại báo `100% packet loss` mà dữ liệu vẫn chạy ầm ầm?
Trong thiết kế bảo mật chuẩn **Zero-Trust & Least-Privilege**:
* Hub VN cài đặt service `monitoring-wg-guard.service` áp dụng quy tắc iptables:
  ```bash
  # Chặn toàn bộ mọi kết nối từ IP 10.66.66.10 (K3s) vào hệ điều hành Hub (kể cả lệnh Ping ICMP)
  -A INPUT -s 10.66.66.10/32 -i wg0 -j DROP

  # CHỈ CHO PHÉP DUY NHẤT gói tin TCP đi vào cổng 8428 (VictoriaMetrics Ingestion)
  -A DOCKER-USER -s 10.66.66.10/32 -i wg0 -p tcp --ctorigdstport 8428 -j RETURN
  -A DOCKER-USER -s 10.66.66.10/32 -i wg0 -j DROP
  ```
* **Mục đích sinh tử**: K3s là cụm chạy ứng dụng ra Internet, nguy cơ bị tấn công cao hơn. Nếu K3s bị chiếm quyền, hacker dù chui qua VPN cũng **không thể ping, không thể scan port, không thể tấn công SSH (22), Postgres (5432), n8n (5678) hay Redis (6379)** trên Hub VN.

---

### 2.3. Tầng lưu trữ & Cảnh báo tại Hub (`miniappify` - VN)

1. **VictoriaMetrics (Single-node TSDB)**:
   * Lưu trữ chuỗi thời gian (time-series).
   * Nén dữ liệu cực kỳ tối ưu (~0.4 byte/sample), retention 30 ngày chỉ tốn khoảng 2-4GB disk.
   * Cổng `:8428` chỉ bind vào `10.66.66.1` (WireGuard) và `127.0.0.1` (local), tuyệt đối không mở `0.0.0.0` ra Internet.
2. **`vmalert`**:
   * Cứ mỗi 30 giây, `vmalert` quét các biểu thức PromQL (Alert Rules) trên VictoriaMetrics.
   * Nếu phát hiện lỗi (ví dụ: Node hết RAM, Pod restart liên tục, SSL sắp hết hạn), nó tạo cảnh báo gửi sang Alertmanager.
3. **`Alertmanager`**:
   * Nhận cảnh báo từ `vmalert`.
   * **Inhibition rules (Chống bão thông báo)**: Nếu cả server bị mất mạng (`HostUnreachable`), nó sẽ ngắt toàn bộ cảnh báo của các Pod bên trong để tránh bắn hàng trăm thông báo rác cùng lúc.
   * **Gửi tin về Telegram**: Định dạng tin nhắn HTML rõ ràng, gửi thẳng về nhóm Telegram.
4. **Dead Man's Switch (`Watchdog` -> `healthchecks.io`)**:
   * `vmalert` có một alert đặc biệt tên là `Watchdog` - alert này **luôn luôn kích hoạt 24/7**.
   * Alertmanager nhận `Watchdog` và định kỳ 60 giây gửi webhook ping tới `healthchecks.io`.
   * **Nếu Hub VN sập nguồn, cháy ổ cứng hoặc mất mạng**: Webhook sẽ ngừng gửi. Sau 5 phút không thấy ping, `healthchecks.io` sẽ lập tức báo động cho bạn qua Email/Telegram khẩn cấp.

---

### 2.4. Tầng hiển thị: Truy cập Grafana qua Domain HTTPS

Luồng đi của một request từ trình duyệt người dùng đến Grafana:

```
[Trình duyệt] 
      │ HTTPS (Port 443)
      ▼
[Cloudflare Edge] (SSL/TLS Encryption Mode: Flexible)
      │ HTTP (Port 80)
      ▼
[Traefik Reverse Proxy trên VPS] (Lắng nghe 0.0.0.0:80)
      │ Định tuyến theo domain: Host(`grafana.tuanstark.id.vn`)
      ▼
[Grafana Container] (Lắng nghe tại 10.66.66.1:3000 & 127.0.0.1:3000)
```

#### Xử lý lỗi kinh điển: "Cloudflare Error 521 (Web server is down)"
* **Bản chất**: Trên VPS, Traefik được cấu hình theo triết lý "Cloudflare đã xử lý chứng chỉ SSL, Traefik bên trong chỉ cần nhận HTTP cổng 80".
* Nếu trên Cloudflare bạn để chế độ SSL là **Full** hoặc **Full (strict)**, Cloudflare sẽ cố kết nối vào cổng 443 của VPS -> Cổng 443 không mở -> Báo lỗi 521.
* **Khắc phục**: Chuyển chế độ SSL trên Cloudflare sang **Flexible**, Cloudflare sẽ nói chuyện với cổng 80 của Traefik và mọi thứ hoạt động trơn tru.

---

## 3. Các sự cố hạ tầng thực tế đã được giải quyết (Troubleshooting Case Studies)

### Sự cố 1: Lỗi xung đột dải mạng Docker (`Pool overlaps with other one`)
* **Hiện tượng**: Khi chạy `docker compose up` stack monitoring, Docker báo lỗi không tạo được mạng `monitoring`.
* **Nguyên nhân**: File cấu hình ban đầu yêu cầu dải `172.30.0.0/24`, nhưng mạng của `n8n/traefik` hiện hữu trên VPS đã chiếm toàn bộ `172.30.0.0/16`.
* **Xử lý chuẩn SRE**: Chuyển dải mạng monitoring sang **`172.28.0.0/24`** (Gateway `172.28.0.1`). Cập nhật đồng bộ các file `docker-compose.yml`, `scrape.yml`, `preflight.sh` và UFW rule. Hệ thống n8n không bị gián đoạn dù chỉ 1 giây.

### Sự cố 2: Lỗi DNS không trỏ đúng máy chủ phân giải (Authoritative NS)
* **Hiện tượng**: Đã thêm bản ghi A trên trang nhà đăng ký tên miền nhưng ra ngoài mạng không phân giải được.
* **Nguyên nhân**: Tên miền `.id.vn` đã được chuyển giao NameServer sang Cloudflare (`julio` / `stevie`). Mọi bản ghi khai báo ở nhà đăng ký cũ đều bị vô hiệu hóa.
* **Xử lý**: Khai báo bản ghi `A` với tên `grafana` trỏ về `103.140.249.167` ngay trên giao diện Cloudflare DNS.

---

## 4. Cẩm nang vận hành hàng ngày (Operator Cheat Sheet)

### 4.1. Thông tin đăng nhập & Địa chỉ quan trọng
* **Grafana URL**: [https://grafana.tuanstark.id.vn](https://grafana.tuanstark.id.vn)
* **Tài khoản**: `admin`
* **Mật khẩu**: Được lưu an toàn tại file [`/opt/platform-gitops/hub/secrets/grafana_admin_password`](file:///opt/platform-gitops/hub/secrets/grafana_admin_password).
* **Đường dẫn Dashboards chính**:
  * [Kubernetes Global View](https://grafana.tuanstark.id.vn/d/k8s_views_global/kubernetes-views-global)
  * [K3s Node Resources (vmi3371043)](https://grafana.tuanstark.id.vn/d/rYdddlPWk/node-exporter-full)
  * [VictoriaMetrics Ingestion Engine](https://grafana.tuanstark.id.vn/d/wNf0q_kZk/victoriametrics-single-node)
  * [Traefik Official Dashboard](https://grafana.tuanstark.id.vn/d/n5bu_kv45/traefik-official-standalone-dashboard)

---

### 4.2. Các lệnh kiểm tra sức khỏe hệ thống nhanh (Health Check)

#### Trên VPS Hub (`miniappify`):
```bash
# 1. Kiểm tra trạng thái các container monitoring
cd /opt/platform-gitops/hub && docker compose ps

# 2. Xem tài nguyên tiêu thụ thực tế
docker stats --no-stream $(docker compose ps -q)

# 3. Kiểm tra kết nối WireGuard với K3s EU
wg show wg0

# 4. Kiểm tra số lượng metrics đang ghi nhận vào VictoriaMetrics
P=$(cat /opt/platform-gitops/hub/secrets/vm_password)
curl -s -u vmagent:$P http://127.0.0.1:8428/api/v1/query --data-urlencode 'query=count by (cluster, job) (up)' | python3 -m json.tool

# 5. Kiểm tra danh sách cảnh báo đang kích hoạt
curl -s http://127.0.0.1:9093/api/v2/alerts | python3 -m json.tool
```

#### Trên máy chủ K3s EU (`vn1-01`):
```bash
# 1. Kiểm tra kết nối tunnel WireGuard tới Hub
wg show wg-hub

# 2. Kiểm tra log của vmagent xem có đẩy metric thành công không
kubectl -n monitoring logs sts/vmagent -c vmagent --tail 30

# 3. Kiểm tra 3 pod agent giám sát
kubectl -n monitoring get pods
```

---

### 4.3. Quy trình xử lý sự cố (Runbook)

| Triệu chứng | Nguyên nhân có thể | Cách xử lý |
|---|---|---|
| **Grafana báo "No data" cho cụm prod** | Mất kết nối WireGuard giữa 2 server | Chạy `wg show wg-hub` trên `vn1-01`. Nếu handshake > 3 phút: chạy `systemctl restart wg-quick@wg-hub`. |
| **Nhận cảnh báo Telegram liên tục** | Ngưỡng cảnh báo quá nhạy hoặc dịch vụ lỗi | Vào Grafana kiểm tra pod/node tương ứng. Muốn tắt tạm thời (silence 1h): dùng lệnh `amtool silence add`. |
| ** healthchecks.io báo DOWN** | VPS Hub VN mất điện, rớt mạng hoặc Alertmanager chết | SSH vào Hub kiểm tra `docker compose ps`. Nếu Alertmanager stopped, chạy `docker compose up -d alertmanager`. |
| **Đĩa cứng Hub VN bị đầy (>80%)** | Dữ liệu metric vượt dung lượng dự tính | VictoriaMetrics tự chuyển sang read-only khi đĩa còn <2GB. Chạy `docker system prune` hoặc giảm `retentionPeriod` từ 30d xuống 14d trong `docker-compose.yml`. |
