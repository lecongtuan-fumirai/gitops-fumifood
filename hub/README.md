# Monitoring hub: miniappify (VPS Việt Nam)

Hướng dẫn dựng hub monitoring cho cụm K3s `vn1-01` (EU). Làm lần lượt từng bước,
**không nhảy cóc**. Mỗi bước đều có lệnh kiểm tra và cách rollback.

## 0. Kiến trúc

```
 vn1-01 (EU, K3s prod)                                   miniappify (VN, Docker)
 ┌────────────────────────────┐                           ┌──────────────────────────────────┐
 │ node-exporter  ─┐          │                           │ VictoriaMetrics :8428 (30d)      │
 │ kube-state-m.  ─┼─ vmagent ├── WireGuard (wg-hub) ────►│   ▲            │                 │
 │ kubelet/cAdv.  ─┤  2Gi     │  10.66.66.10 → 10.66.66.1 │   │ scrape     ▼                 │
 │ traefik/argo.. ─┘  buffer  │  remote_write + basicAuth │ node-exp, cAdvisor, blackbox     │
 └────────────────────────────┘                           │ vmalert ─► Alertmanager ─► Telegram
                                                          │                └─► healthchecks.io (Watchdog)
                                                          │ Grafana :3000 (127.0.0.1 / wg0)  │
                                                          └──────────────────────────────────┘
```

| Quyết định | Lý do |
|---|---|
| **Push** (vmagent → remote_write), không pull | RTT EU↔VN ~250 ms và có packet loss. Pull qua WAN dễ timeout và mất điểm dữ liệu. Push scrape tại chỗ, có **buffer đĩa 1.5 GB** (~vài ngày), tự gửi bù khi tunnel sống lại. |
| VictoriaMetrics single, không dùng Prometheus | RAM ~3-5 lần ít hơn, nén tốt hơn (~0.4 byte/sample), dedup sẵn. Hợp với VPS ít RAM/đĩa. |
| vmalert + Alertmanager, không dùng Grafana alerting | Alert dạng code trong Git, review được qua PR, có inhibit để không bị spam. |
| Watchdog → healthchecks.io | Phát hiện **chính hệ thống monitoring chết** (hub sập, Telegram lỗi…). Không có cái này thì "im lặng" sẽ bị hiểu nhầm là "ổn". |
| Blackbox từ VN | Đo đúng trải nghiệm người dùng VN (DNS, TLS, Cloudflare, latency). |
| Không có log stack | Đĩa VN chỉ còn ~13 GB. Khi cần thì thêm VictoriaLogs (rất nhẹ). |

**Ngân sách tài nguyên trên miniappify** (hard limit, không vượt được):
RAM ≈ 1.2 GiB (VM 512m, Grafana 256m, cAdvisor 160m, các phần còn lại ≤ 64m).
Đĩa ≈ 2-4 GB với retention 30 ngày (VM tự chuyển sang read-only khi đĩa còn < 2 GB).

**Port binding** (không có port nào mở `0.0.0.0`):

| Dịch vụ | Bind | Ai truy cập |
|---|---|---|
| VictoriaMetrics | `10.66.66.1:8428`, `127.0.0.1:8428` | vmagent qua WG (basicAuth), admin local |
| Grafana | `127.0.0.1:3000`, `10.66.66.1:3000` | SSH tunnel / client WG của admin |
| Alertmanager | `127.0.0.1:9093` | chỉ local |
| node-exporter | `172.30.0.1:9100` | chỉ bridge `br-monitoring` |

---

## 1. Kiểm tra trước (trên miniappify)

```bash
free -m; df -h /var/lib/docker; docker compose version
ip -4 addr show wg0            # phải có 10.66.66.1/24
wg show wg0                    # xem các peer hiện có
wg show wg0 allowed-ips        # 10.66.66.10 PHẢI chưa bị dùng
systemctl is-enabled wg-quick@wg0   # biết wg0 do wg-quick quản lý hay không
grep -i SaveConfig /etc/wireguard/wg0.conf
ufw status verbose
```

> [!IMPORTANT]
> Nếu `10.66.66.10` đã bị peer khác dùng thì chọn IP khác. Sau đó sửa `wg_hub_address`
> trong `ansible/group_vars/all.yml` và `WG_GUARD_PEER` (bước 3) cho khớp.

## 2. Lấy mã nguồn về `/opt/platform-gitops`

Chỉ cần thư mục `hub/`. Nên dùng **deploy key read-only riêng cho miniappify**,
đừng copy key của vn1-01:

```bash
ssh-keygen -t ed25519 -N '' -C miniappify-gitops-ro -f /root/.ssh/gitops_ro
cat /root/.ssh/gitops_ro.pub   # GitHub → repo → Settings → Deploy keys → Add (KHÔNG tick write)

GIT_SSH_COMMAND='ssh -i /root/.ssh/gitops_ro -o IdentitiesOnly=yes' \
  git clone --filter=blob:none --sparse git@github.com:lecongtuan-fumirai/gitops-fumifood.git /opt/platform-gitops
cd /opt/platform-gitops
git config core.sshCommand 'ssh -i /root/.ssh/gitops_ro -o IdentitiesOnly=yes'
git sparse-checkout set hub
cd hub && chmod +x scripts/*.sh
```

> Trước khi PR `feat/monitoring-agent` được merge, thêm `-b feat/monitoring-agent` vào lệnh clone.

## 3. WireGuard: thêm peer vn1-01

**Public key của vn1-01** (không phải bí mật):

```
gKEgW9Byx94AikUlS73LikYDWYl0vMDFC8CCy1FvODo=
```

### 3.1 Thêm peer, không làm rớt các peer khác

```bash
wg set wg0 peer gKEgW9Byx94AikUlS73LikYDWYl0vMDFC8CCy1FvODo= allowed-ips 10.66.66.10/32
```

Lưu cấu hình lại để không mất khi reboot:

- Nếu `SaveConfig = true`: chạy `wg-quick save wg0`. **Đừng** sửa tay file khi interface đang chạy,
  vì lúc down nó sẽ ghi đè lên chỉnh sửa của bạn.
- Nếu không có SaveConfig: thêm đoạn sau vào `/etc/wireguard/wg0.conf`:

```ini
[Peer]
# vn1-01 (K3s prod, EU): monitoring push only
PublicKey = gKEgW9Byx94AikUlS73LikYDWYl0vMDFC8CCy1FvODo=
AllowedIPs = 10.66.66.10/32
```

> [!NOTE]
> Không cần `Endpoint` hay `PersistentKeepalive` ở phía hub: vn1-01 chủ động kết nối
> và giữ keepalive 25s. `AllowedIPs = /32` để hub chỉ nhận đúng IP này từ peer, chống spoofing.

### 3.2 Gửi public key của hub về để cấu hình vn1-01

```bash
wg show wg0 public-key
```

Trên **vn1-01**, tạo PR sửa `ansible/group_vars/all.yml` → `wg_hub_public_key: "<key ở trên>"`.
Sau khi merge thì chạy:

```bash
cd /home/platform-gitops/ansible && ansible-playbook site.yml --tags wireguard
```

> [!CAUTION]
> Luôn chạy với `--tags wireguard`. **Không** chạy `site.yml` không có tag: role k3s_server
> sẽ ghi đè config k3s và restart cluster (xem phần "Phát hiện" ở cuối).

Kiểm tra từ cả hai phía:

```bash
# miniappify
wg show wg0 | grep -A4 gKEgW9      # "latest handshake" < 2 phút
ping -c3 10.66.66.10
# vn1-01
wg show wg-hub; ping -c3 10.66.66.1
```

Nếu ping ổn mà HTTP bị treo thì gần như chắc chắn là lỗi MTU. Thử
`ping -M do -s 1352 10.66.66.1` trên vn1-01. Nếu fail thì giảm `wg_hub_mtu` (1380 → 1340).

### 3.3 Least privilege cho peer vn1-01

Nếu vn1-01 bị chiếm quyền, kẻ tấn công **không được** đi tiếp sang các peer VPN khác,
SSH hay n8n trên miniappify. Chỉ cho phép đúng `:8428`:

```bash
cp /opt/platform-gitops/hub/systemd/docker-after-wg0.conf /etc/systemd/system/docker.service.d/10-after-wg0.conf 2>/dev/null \
  || { mkdir -p /etc/systemd/system/docker.service.d && cp /opt/platform-gitops/hub/systemd/docker-after-wg0.conf /etc/systemd/system/docker.service.d/10-after-wg0.conf; }
cp /opt/platform-gitops/hub/systemd/monitoring-wg-guard.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now monitoring-wg-guard.service
/opt/platform-gitops/hub/scripts/wg-guard.sh status
```

- `docker-after-wg0.conf`: docker khởi động sau wg0. Nếu không có, lúc reboot việc bind `10.66.66.1:8428`
  có thể fail và VM sẽ không lên. Dùng `Wants=` để nếu wg0 lỗi thì n8n/postgres vẫn chạy bình thường.
  **Không cần restart docker**: thay đổi có hiệu lực từ lần boot sau.
- `wg-guard`: rule nằm trong chain `DOCKER-USER`, không nằm trong `FORWARD`, vì port publish của Docker
  đi qua DNAT → FORWARD. Chặn ở FORWARD sẽ chặn luôn ingest.

## 4. Firewall (UFW) cho node-exporter của hub

node-exporter chạy `network_mode: host` và chỉ listen trên `172.30.0.1:9100`. Nếu UFW đang
active, container VM sẽ đi vào INPUT và bị chặn. Thêm rule sau:

```bash
ufw allow in on br-monitoring from 172.30.0.0/24 to 172.30.0.1 port 9100 proto tcp comment 'vm -> node-exporter'
```

(Bridge `br-monitoring` chỉ xuất hiện sau `docker compose up` lần đầu. Thêm rule trước vẫn được.)

> Không cần mở thêm port public nào. Không động tới `/etc/docker/daemon.json`, vì restart dockerd
> sẽ restart n8n/postgres/redis.

## 5. Secrets

Telegram:

1. Chat với `@BotFather` → `/newbot` → nhận **token**.
2. Tạo group "Fumirai Alerts", add bot vào group rồi gửi 1 tin nhắn bất kỳ.
3. Lấy chat id (group id là số âm, thường bắt đầu bằng `-100`):

```bash
read -rsp 'token: ' T; echo
curl -s "https://api.telegram.org/bot$T/getUpdates" | grep -o '"chat":{"id":-\?[0-9]*' | sort -u
unset T
```

healthchecks.io: tạo check **Period 1 phút, Grace 5 phút**, cấu hình kênh thông báo
(email + Telegram) rồi copy **Ping URL**.

`vm_password` phải **trùng** với password vmagent trên vn1-01. Lấy bằng lệnh sau
(chạy trên vn1-01, đọc trực tiếp, không lưu ra file):

```bash
cd /home/platform-gitops
SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt sops -d --extract '["stringData"]["password"]' \
  platform/monitoring/config/vmagent-remote-write.enc.yaml; echo
```

Trên miniappify:

```bash
cd /opt/platform-gitops/hub && ./scripts/init-secrets.sh
```

Script hỏi lần lượt các giá trị (nhập ẩn) rồi ghi vào `secrets/`. Thư mục này có quyền 0700 và
đã được git-ignore. Mật khẩu Grafana admin được sinh ngẫu nhiên. Đọc 1 lần bằng
`cat secrets/grafana_admin_password` rồi cất vào password manager.

## 6. (Tuỳ chọn) Khai báo URL dịch vụ trên hub

Trong `victoriametrics/scrape.yml`, bỏ comment target n8n và điền URL thật để blackbox
probe nó. Nên làm qua PR rồi `git pull` trên hub.

## 7. Preflight → khởi động

```bash
cd /opt/platform-gitops/hub
./scripts/preflight.sh          # phải ra PREFLIGHT OK (WARN thì đọc kỹ)
docker compose pull
docker compose up -d
docker compose ps               # tất cả "running"/"healthy"
docker stats --no-stream $(docker compose ps -q)
```

## 8. Nghiệm thu (bắt buộc làm đủ)

```bash
P=$(cat secrets/vm_password)
q() { curl -s -u vmagent:$P http://127.0.0.1:8428/api/v1/query --data-urlencode "query=$1" | python3 -m json.tool | head -40; }

q 'up == 0'                               # rỗng = mọi target đều UP
q 'count by (cluster, job) (up)'          # có cả cluster="hub" và cluster="prod"
q 'max(vm_rows_inserted_total)'           # đang tăng
q 'probe_success'                         # = 1 cho các URL
curl -s http://127.0.0.1:9093/api/v2/alerts | python3 -m json.tool | grep alertname   # chỉ có Watchdog
unset P
```

| # | Test | Cách làm | Kết quả mong đợi |
|---|---|---|---|
| 1 | Telegram | `docker compose exec alertmanager amtool alert add Test severity=warning cluster=hub --alertmanager.url=http://127.0.0.1:9093` | Nhận tin Telegram trong ~30s |
| 2 | Dead man's switch | `docker compose stop alertmanager`, chờ ~6 phút | healthchecks.io báo DOWN. Sau đó `start` lại |
| 3 | Mất tunnel + gửi bù | Trên vn1-01: `systemctl stop wg-quick@wg-hub` trong 10 phút rồi start lại | Alert `ProdMetricsAbsent`. Sau khi start lại, đồ thị **liền mạch** (dữ liệu buffer được gửi bù) |
| 4 | Reboot hub | `reboot` trong khung giờ thấp điểm | Mọi container tự lên, VM bind được 10.66.66.1 |
| 5 | Grafana | `ssh -L 3000:127.0.0.1:3000 root@103.140.249.167` → http://localhost:3000 | 13 dashboard trong 4 folder đều có dữ liệu |

## 9. Truy cập Grafana

- **Mặc định (khuyến nghị):** SSH tunnel như test #5, hoặc dùng client WireGuard của admin
  qua `http://10.66.66.1:3000`.
- Nếu muốn có domain: đặt sau reverse proxy + **Cloudflare Access** (Zero Trust, free ≤ 50 user),
  rồi set `GRAFANA_ROOT_URL=https://grafana.<domain>` và `GRAFANA_COOKIE_SECURE=true` trong `.env`.
  **Không** publish 3000 ra `0.0.0.0`.

## 10. Vận hành

| Việc | Lệnh / ngưỡng |
|---|---|
| Đổi rule/alert | PR → `git pull` → `docker compose restart vmalert` (hoặc `curl -X POST 127.0.0.1:8880/-/reload` trong network) |
| Đổi scrape | PR → `git pull` → `curl -u vmagent:$(cat secrets/vm_password) -X POST http://127.0.0.1:8428/-/reload` |
| Đổi alertmanager | PR → `git pull` → `docker compose restart alertmanager` |
| Nâng version | PR đổi tag **và** digest → `docker compose pull && docker compose up -d` |
| Dung lượng TSDB | Sau 7 ngày: `du -sh /var/lib/docker/volumes/monitoring_vm-data`. Nhân 30/7 để ước lượng. Nếu > 5 GB thì giảm retention hoặc drop bớt metric ở vmagent |
| Silence khi bảo trì | `docker compose exec alertmanager amtool silence add cluster=prod --duration=1h --comment=maint --alertmanager.url=http://127.0.0.1:9093` |
| Backup | Dashboards/rules nằm trong Git. Grafana DB chỉ chứa user/preferences. Dữ liệu metric có thể chấp nhận mất. Nếu cần thì dùng `vmbackup` để đẩy lên S3 |

## 11. Rollback

```bash
cd /opt/platform-gitops/hub
docker compose down                 # giữ volume (dữ liệu)
# docker compose down -v            # xoá hẳn dữ liệu
systemctl disable --now monitoring-wg-guard.service
rm /etc/systemd/system/monitoring-wg-guard.service /etc/systemd/system/docker.service.d/10-after-wg0.conf
systemctl daemon-reload
wg set wg0 peer gKEgW9Byx94AikUlS73LikYDWYl0vMDFC8CCy1FvODo= remove   # + xoá [Peer] trong wg0.conf
ufw delete allow in on br-monitoring from 172.30.0.0/24 to 172.30.0.1 port 9100 proto tcp
```

Ở phía vn1-01: revert PR monitoring (Argo sẽ prune) và chạy `systemctl disable --now wg-quick@wg-hub`.
Trong lúc hub chết, production **không bị ảnh hưởng**: vmagent chỉ buffer (tối đa 1.5 GB) rồi
bỏ dữ liệu cũ nhất, không bao giờ làm đầy đĩa node.

## 12. Troubleshooting nhanh

| Triệu chứng | Kiểm tra |
|---|---|
| Không có dữ liệu `cluster="prod"` | `wg show` (handshake?), trên vn1-01: `kubectl -n monitoring logs sts/vmagent... \| grep -i remote` |
| vmagent báo 401 | `vm_password` không khớp. Chạy lại bước 5 rồi `docker compose up -d --force-recreate victoriametrics vmalert grafana` |
| VM không lên sau reboot (`cannot assign requested address`) | Thiếu drop-in ở bước 3.3, hoặc wg0 không lên |
| Ping qua tunnel OK nhưng HTTP treo | Lỗi MTU, xem bước 3.2 |
| `HubTSDBDiskLow` | `df -h`. Dọn `docker system prune` (cẩn thận với n8n) hoặc giảm retention |
| Spam alert | Silence tạm thời, rồi sửa ngưỡng qua PR. Không tắt Watchdog |
