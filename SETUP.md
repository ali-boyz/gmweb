# Deployment Guide: gmweb on Oracle VPS

This guide covers deploying gmweb on an Oracle Cloud VPS with self-signed SSL certificates.

## Overview

gmweb is a Docker-based web development environment that provides:
- **Remote desktop** (XFCE via Selkies)
- **Web terminal** (webssh2/ttyd)
- **File manager** (web-based)
- **AionUI** - IDE/workspace interface
- **nginx** reverse proxy with HTTP Basic Auth

Recommended specs: 4 cores, 24GB RAM (Oracle Cloud free tier A1 shape works well).

---

## Step 1: Install Docker Compose

```bash
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

sudo chmod +x /usr/local/bin/docker-compose

docker-compose --version
```

---

## Step 2: Configure Oracle Cloud Firewall

Oracle Cloud has **two firewalls** - both need to be configured.

### A. Oracle Cloud Console (Security List)

1. Go to Oracle Cloud Console → Networking → Virtual Cloud Networks
2. Click your VCN → Click your Subnet → Click the Security List
3. Add **Ingress Rules**:

| Source CIDR | Protocol | Dest Port | Description |
|-------------|----------|-----------|-------------|
| 0.0.0.0/0 | TCP | 80 | HTTP |
| 0.0.0.0/0 | TCP | 443 | HTTPS |

### B. iptables on the VPS

```bash
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT

sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save

```

---

## Step 3: Clone and Configure

```bash
git clone https://github.com/AnEntrypoint/gmweb.git
cd gmweb

cat > .env << 'EOF'
PASSWORD=your-secure-password-here
TZ=America/New_York
PUID=1000
PGID=1000
EOF
```

**Change `PASSWORD`** to something secure - this protects all web endpoints.

---

## Step 4: Update docker-compose for Direct Port Access

Edit `docker-compose.yaml` to expose ports 80 and 443:

```yaml
services:
  gmweb:
    ports:
      - "80:80"
      - "443:443"
```

---

## Step 5: Build and Start (First Boot)

```bash
docker-compose up -d --build
```

**Startup timeline:**
- 0-30s: nginx starts, git clone
- 30-60s: Node.js/NVM installation (first boot only)
- 60-120s: Services initialize
- 120s+: Background installs (non-blocking)

---

## Step 6: Generate Self-Signed SSL Certificate

The nginx config expects certs at `/config/ssl/`. Generate them after the container initializes:

```bash
docker-compose exec gmweb bash -c '
  mkdir -p /config/ssl
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /config/ssl/cert.key \
    -out /config/ssl/cert.pem \
    -subj "/CN=gmweb/O=Self-Signed"
  chmod 600 /config/ssl/cert.key
  chmod 644 /config/ssl/cert.pem
'

docker-compose exec gmweb nginx -s reload
```

---

## Step 7: Access the Services

Once running, access via your VPS IP:

| URL | Service | Description |
|-----|---------|-------------|
| `https://YOUR-IP/` | AionUI | Main workspace interface |
| `https://YOUR-IP/desk` | Desktop | XFCE remote desktop |
| `https://YOUR-IP/ssh` | Terminal | Web-based SSH terminal |
| `https://YOUR-IP/files` | File Manager | Web file browser |

**Login credentials:**
- Username: `abc`
- Password: (value you set in `.env`)

**Note:** Your browser will warn about the self-signed certificate. Click "Advanced" → "Proceed anyway" to accept it.

---

## Monitoring & Troubleshooting

### View Logs
```bash
docker-compose logs -f gmweb

docker-compose exec gmweb cat /config/logs/startup.log

docker-compose exec gmweb tail -f /config/logs/supervisor.log
```

### Check if Ports are Open
```bash
sudo ss -tlnp | grep -E ':80|:443'

nc -zv YOUR-VPS-IP 80
nc -zv YOUR-VPS-IP 443
```

### Restart Services
```bash
docker-compose restart gmweb
```

### Full Reset
```bash
docker-compose down -v
docker-compose up -d --build
```

---

## Verification Checklist

After deployment:
- [ ] Port 80/443 accessible from outside (`nc -zv YOUR-IP 443`)
- [ ] `https://YOUR-IP/` shows login prompt (accept cert warning)
- [ ] Can log in with `abc` / your password
- [ ] Desktop loads at `/desk`
- [ ] Terminal works at `/ssh`
- [ ] File manager works at `/files`

---

## Files Modified/Created

| File | Action | Purpose |
|------|--------|---------|
| `docker-compose.yaml` | Edit | Add port 80 and 443 mappings |
| `.env` | Create | Set PASSWORD and TZ |
| `/config/ssl/cert.key` | Generated in container | SSL private key |
| `/config/ssl/cert.pem` | Generated in container | SSL certificate |

---

## Notes

- The container automatically handles Oracle kernel's missing `close_range()` syscall
- Everything installs fresh at container startup (prevents stale code issues)
- First boot takes 2-3 minutes; subsequent boots are faster
- See `CLAUDE.md` for detailed architecture documentation
