# Kiến trúc & Cẩm nang Vận hành Hệ thống Logging (VictoriaLogs & Fluent Bit)

Tài liệu này giải thích chi tiết về kiến trúc, cơ chế hoạt động và cẩm nang vận hành hệ thống thu thập, lưu trữ, tra cứu log tập trung chuẩn **SRE & Cloud-Native** cho nền tảng Fumifood (`fumirai-lunch`, `fumi-live`).

---

## 1. Bối cảnh & Lý do thiết kế

### 1.1. Tại sao không ghi file log trực tiếp trong Container?
* **Rủi ro mất mát dữ liệu (Ephemeral Layer)**: Container trong Kubernetes là bất biến và tạm thời. Khi Pod bị crash, restart hoặc rollout phiên bản mới, dữ liệu file log nằm trong container sẽ bị xóa sạch hoàn toàn.
* **Xung đột bảo mật K8s**: Toàn bộ workload production đều bật chuẩn bảo mật nghiêm ngặt `readOnlyRootFilesystem: true`. Container không được phép tự ý tạo/ghi file lên hệ thống tệp gốc.
* **Khó khăn khi điều tra sự cố (Troubleshooting)**: Nếu log được lưu thành các file nén `.gz` trên host, việc tìm kiếm lỗi giữa hàng trăm file bằng `zgrep`/`zcat` rất chậm, không có giao diện trực quan và không thể lọc theo `traceId` hay `userId`.

### 1.2. Giải pháp chuẩn Cloud-Native: Centralized Logging (Tương đương AWS CloudWatch)
* **Code Backend (NestJS)**: Chỉ in log ra màn hình console chuẩn (**`stdout`/`stderr`**).
* **Container Runtime (K3s/containerd)**: Tự động hứng toàn bộ luồng stdout và lưu tạm tại `/var/log/pods/`.
* **Fluent Bit (Shipper)**: Thu thập log, bóc tách cấu trúc Kubernetes Metadata (`pod_name`, `container_name`, `namespace_name`), rồi đẩy nhanh sang VictoriaLogs qua HTTP Stream.
* **VictoriaLogs (TSDB Engine)**: Lưu trữ, nén dữ liệu siêu nhỏ, cung cấp giao diện Web UI (VMUI) và tự động xóa bỏ vĩnh viễn log quá 7 ngày (**`-retentionPeriod=7d`**).

---

## 2. Bức tranh kiến trúc tổng thể

```
┌────────────────────────────────────────────────────────────────────────┐
│                        CỤM K3S PRODUCTION                              │
│                                                                        │
│   ┌──────────────────────────────┐    ┌─────────────────────────────┐  │
│   │ fumirai-lunch-prod (backend) │    │ fumi-live-prod (gateway)    │  │
│   └──────────────┬───────────────┘    └──────────────┬──────────────┘  │
│                  │                                   │                 │
│                  └─────────────────┬─────────────────┘                 │
│                                    │ stdout / stderr (JSON)            │
│                                    ▼                                   │
│                 ┌─────────────────────────────────────┐                │
│                 │ Container Runtime (containerd)      │                │
│                 │ Lưu file tại: /var/log/pods/        │                │
│                 └──────────────────┬──────────────────┘                │
│                                    │ hostPath: /var/log                │
│                                    ▼                                   │
│                 ┌─────────────────────────────────────┐                │
│                 │ Fluent Bit DaemonSet (logging ns)   │                │
│                 │ - Regex parser K8s CRI              │                │
│                 │ - Gắn nhãn namespace/pod/container  │                │
│                 │ - RAM tiêu thụ: ~15 MiB             │                │
│                 └──────────────────┬──────────────────┘                │
│                                    │ HTTP (/insert/jsonline)           │
│                                    ▼                                   │
│                 ┌─────────────────────────────────────┐                │
│                 │ VictoriaLogs Single (logging ns)    │                │
│                 │ - Thuật toán nén chuyên dụng        │                │
│                 │ - Cờ tự hủy: -retentionPeriod=7d    │                │
│                 │ - RAM tiêu thụ: ~7 MiB              │                │
│                 │ - Web UI tích hợp: :9428/select/vmui│                │
│                 └──────────────────┬──────────────────┘                │
│                                    │ Persistent Volume                 │
│                                    ▼                                   │
│                 ┌─────────────────────────────────────┐                │
│                 │ Local-path PVC (10Gi Storage)       │                │
│                 └─────────────────────────────────────┘                │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Cấu trúc GitOps & Thành phần Manifest

Hệ thống được quản lý 100% qua GitOps tại thư mục `platform/logging`:

### 3.1. Phân chia Namespace & ResourceQuota
* **File**: `platform/namespaces/platform-namespaces.yaml`
* **Namespace**: `logging`
* **ResourceQuota**:
  ```yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: quota
    namespace: logging
  spec:
    hard:
      requests.cpu: 100m
      requests.memory: 128Mi
      limits.memory: 384Mi
      pods: "6"
  ```
  > **Ý nghĩa SRE**: Đảm bảo toàn bộ stack logging (cả VictoriaLogs lẫn Fluent Bit) không bao giờ tiêu thụ vượt quá 384Mi RAM, tuyệt đối an toàn cho VPS 3.8GB.

### 3.2. VictoriaLogs Deployment & Storage
* **File**: `platform/logging/victoria-logs.yaml`
* **Image**: `victoriametrics/victoria-logs:v1.39.0@sha256:af75804afbd6009a56bd3590a68f82827a4764d28096f4729cc77ed1a502836f` (Ghim tag + digest).
* **Storage**: PVC `victoria-logs-data` dung lượng `10Gi` (storageClass `local-path`).
* **Tham số quan trọng**:
  * `-retentionPeriod=7d`: Tự động xoay vòng và xóa sạch dữ liệu cũ hơn 7 ngày.
  * `-storageDataPath=/storage`: Thư mục lưu trữ trên volume bền vững.
  * `-httpListenAddr=:9428`: Cổng nhận log và phục vụ Web UI.

### 3.3. Fluent Bit DaemonSet
* **File**: `platform/logging/fluent-bit.yaml`
* **Image**: `fluent/fluent-bit:3.2.4@sha256:a185ac0516e1f35568ff0662f12c4ada0ea38c4300ed223d0fde485599dff5b5`.
* **Cơ chế lọc**: Chỉ thu thập log từ `/var/log/pods/*fumirai*/*/*.log` và `/var/log/pods/*fumi-live*/*/*.log`.
* **Regex Parser**: Bóc tách chính xác tên namespace, pod name và container name theo định dạng CRI của containerd:
  ```ini
  [PARSER]
      Name        k8s-custom-tag
      Format      regex
      Regex       (?<namespace_name>[^_]+)_(?<pod_name>[^_]+)_(?<pod_id>[^.]+)\.(?<container_name>[^.]+)\.(?<num>[^.]+)\.log$
  ```

### 3.4. ArgoCD Application
* **File**: `clusters/prod/platform/logging.yaml`
* Tự động quản lý đồng bộ (Self-heal & Auto-prune) qua ArgoCD GitOps.

---

## 4. Benchmark Tài nguyên Thực tế

Kiểm tra trực tiếp trên cụm K3s Production (`kubectl top pods -n logging`):

| Thành phần | CPU trung bình | RAM tiêu thụ | Trạng thái |
| :--- | :--- | :--- | :--- |
| **`victoria-logs`** | ~10m (0.01 core) | **~7 MiB** | Running (Ready 1/1) |
| **`fluent-bit`** | ~5m (0.005 core) | **~15 MiB** | Running (Ready 1/1) |
| **Tổng cộng** | **~15m** | **~22 MiB** | **Tối ưu 100%** |

---

## 5. Cẩm nang Vận hành & Hướng dẫn Tra cứu (Runbook)

### 5.1. Mở giao diện Web UI (VMUI) như CloudWatch Log Insights
VictoriaLogs có sẵn giao diện trực quan cực nhanh. Để truy cập từ máy tính cá nhân:

```bash
# Tạo port-forward an toàn qua kubectl
kubectl port-forward svc/victoria-logs -n logging 9428:9428
```

Mở trình duyệt truy cập: **`http://localhost:9428/select/vmui/`**

* **Live Tail**: Bật chế độ tự động cuộn xem log thời gian thực.
* **Bar Chart**: Biểu đồ hiển thị mật độ log theo mốc thời gian.
* **Filtering**: Nhấp vào bất kỳ thuộc tính nào (`pod_name`, `stream`, ...) để lọc tức thì.

---

### 5.2. Các câu truy vấn LogsQL thường dùng

VictoriaLogs sử dụng cú pháp **LogsQL** đơn giản và mạnh mẽ:

#### 1. Xem tất cả log của Backend trong 30 phút qua:
```text
_time:30m AND kubernetes.container_name:backend
```

#### 2. Tìm tất cả lỗi (`ERROR`, `404`, `500`) trong ngày:
```text
_time:1d AND _msg:ERROR
```

#### 3. Điều tra lỗi liên quan đến một User ID hoặc Email cụ thể:
```text
_time:7d AND _msg:tuan.le.cong@fumirai.ltd
```

#### 4. Xem log cảnh báo bảo mật (Auth / Refresh Token):
```text
_time:24h AND _msg:"SECURITY ALERT"
```

#### 5. Truy vấn trực tiếp bằng CLI (curl):
```bash
# Query JSON output trên terminal
curl -s "http://victoria-logs.logging.svc:9428/select/logsql/query?query=_time:10m AND _msg:ERROR" | jq .
```

---

### 5.3. Kiểm tra sức khỏe & Troubleshooting

#### Kiểm tra pod log của VictoriaLogs:
```bash
kubectl logs -n logging deployment/victoria-logs --tail=50
```

#### Kiểm tra số lượng bản ghi đã thu thập (Hits count):
```bash
kubectl exec -n logging deployment/victoria-logs -- wget -qO- "http://127.0.0.1:9428/select/logsql/hits?query=*"
```

#### Kiểm tra dung lượng lưu trữ thực tế trên PVC:
```bash
kubectl exec -n logging deployment/victoria-logs -- df -h /storage
```
