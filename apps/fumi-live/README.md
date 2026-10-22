# fumi-live (Fumi Live Gateway)

Backend gateway cho Browser Extension phiên dịch thời gian thực (Real-time Speech-to-Text & Translation) sử dụng WebSocket (NestJS, Deepgram, Groq, Claude, Gemini).

---

## 1. Thông tin Triển khai & Định tuyến

- **Namespace:** `fumi-live-prod`
- **Domain:** `fumifood.dpdns.org` (dùng chung domain qua Traefik Ingress)
- **Image:** `ghcr.io/fumirai-ltd/fumi-live-gateway:sha-02f3950@sha256:5beaae1fbff2d2929f75b53db14c4565fd8aac2d92f05b178752f00ccefacd57`
- **Cơ chế xác thực pull image:** Secret `ghcr-pull` (GitHub PAT với quyền `read:packages`).

### Endpoints
| Giao thức | Đường dẫn | Mục đích |
|---|---|---|
| `WSS` | `wss://fumifood.dpdns.org/ws` | Kênh WebSocket truyền nhận audio & subtitles của Extension |
| `HTTPS` | `https://fumifood.dpdns.org/healthz` | Health check endpoint (`200 OK`) |
| `HTTPS` | `https://fumifood.dpdns.org/projects` | REST API quản lý Projects/Glossary |
| `HTTPS` | `https://fumifood.dpdns.org/auth` | REST API xác thực Google SSO |

---

## 2. Quản lý Biến Môi trường & API Keys (Local .env)

File `.env` được lưu cục bộ trên máy chủ (đã được cấu hình trong `.gitignore` để không bao giờ bị đẩy lên Git).

### Bước 1: Mở và chỉnh sửa file `.env`
```bash
nano /home/platform-gitops/.env
```
Các biến mẫu:
```properties
PORT=8080
AUTH_TOKEN=your_extension_secret_token
MAX_SESSIONS=20
MAX_CLIENTS_PER_MEETING=50

# Speech-to-Text
STT_PROVIDER=deepgram
DEEPGRAM_API_KEY=your_deepgram_api_key

# Translation LLM
TRANSLATE_PROVIDERS=groq
GROQ_API_KEY=your_groq_api_key
GROQ_MODEL=qwen/qwen3.8-27b
CLAUDE_MODEL=claude-haiku-4-5-20251001
ANTHROPIC_API_KEY=your_anthropic_api_key
GEMINI_API_KEY=your_gemini_api_key

# Storage & Database
PERSIST_TRANSCRIPTS=false
DATABASE_URL=
```

### Bước 2: Nạp file `.env` vào Kubernetes Secret
```bash
kubectl create secret generic fumi-live-secrets \
  --from-env-file=/home/platform-gitops/.env \
  --namespace=fumi-live-prod \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Bước 3: Khởi động lại Pod để nhận cấu hình mới
```bash
kubectl rollout restart deployment/fumi-live-gateway -n fumi-live-prod
```

---

## 3. Các lệnh Vận hành Thường dùng (Day-2 Operations)

### Xem log trực tiếp của Pod
```bash
kubectl logs -f deployment/fumi-live-gateway -n fumi-live-prod
```

### Xem trạng thái Pod & Ingress
```bash
kubectl get pods,ingress,svc -n fumi-live-prod
```

### Tạo lại Secret pull image GHCR (nếu cần đổi PAT token)
```bash
kubectl create secret docker-registry ghcr-pull \
  --namespace=fumi-live-prod \
  --docker-server=ghcr.io \
  --docker-username=lecongtuan-fumirai \
  --docker-password=<token-ghp_...> \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Test nhanh kết nối WebSocket qua Ingress
```bash
python3 -c "
import ssl, socket
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = socket.create_connection(('10.43.187.227', 443))
ss = ctx.wrap_socket(s, server_hostname='fumifood.dpdns.org')
req = 'GET /ws HTTP/1.1\r\nHost: fumifood.dpdns.org\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'
ss.sendall(req.encode())
print(ss.recv(1024).decode())
"
# Phản hồi 'HTTP/1.1 101 Switching Protocols' là thành công.
```
