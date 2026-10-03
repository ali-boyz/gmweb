#!/bin/bash
set -e

HOME_DIR="/config"
LOG_DIR="$HOME_DIR/logs"

rm -rf "$LOG_DIR" 2>/dev/null || true
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
chown abc:abc "$LOG_DIR" 2>/dev/null || true

log() {
  echo "[gmweb] $(date '+%Y-%m-%d %H:%M:%S') $@" | tee -a "$LOG_DIR/startup.log"
}

BOOT_ID="$(date '+%s')-$$"
log "===== GMWEB UNIFIED STARTUP (boot: $BOOT_ID) ====="

ABC_UID=$(id -u abc 2>/dev/null || echo 1000)
ABC_GID=$(id -g abc 2>/dev/null || echo 1000)
RUNTIME_DIR="/run/user/$ABC_UID"

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
chown "$ABC_UID:$ABC_GID" "$RUNTIME_DIR"

log "Phase 1: Dockerfile setup (directories, symlinks, shim)"

mkdir -p /config/usr/local/lib /config/usr/local/bin /config/nvm /config/.tmp /config/logs /config/.gmweb-deps
chmod 755 /config /config/usr/local /config/usr/local/lib /config/usr/local/bin /config/nvm /config/.tmp /config/logs /config/.gmweb-deps 2>/dev/null || true

rm -rf /usr/local/local 2>/dev/null || true
rm -rf /usr/local 2>/dev/null || true
ln -s /config/usr/local /usr/local

echo 'prefix = /config/usr/local' > /etc/npmrc
grep -q 'NVM_DIR=/config/nvm' /etc/environment || echo 'NVM_DIR=/config/nvm' >> /etc/environment
grep -q 'NPM_CONFIG_PREFIX' /etc/environment || echo 'NPM_CONFIG_PREFIX=/config/usr/local' >> /etc/environment

if [ ! -f /opt/lib/libshim_close_range.so ]; then
  log "Compiling close_range shim..."
  mkdir -p /opt/lib
  cat > /tmp/shim_close_range.c << 'SHIMEOF'
#define _GNU_SOURCE
#include <errno.h>

int close_range(unsigned int first, unsigned int last, int flags) {
    errno = 38;
    return -1;
}
SHIMEOF
  gcc -fPIC -shared /tmp/shim_close_range.c -o /opt/lib/libshim_close_range.so 2>&1 | tail -2
  rm /tmp/shim_close_range.c
  log "✓ Shim compiled"
fi

export LD_PRELOAD=/opt/lib/libshim_close_range.so
grep -q 'LD_PRELOAD=/opt/lib/libshim_close_range.so' /etc/environment || echo 'LD_PRELOAD=/opt/lib/libshim_close_range.so' >> /etc/environment

log "Phase 2: nginx HTTP Basic Auth + routing (CRITICAL - FIRST)"

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

if [ -z "${PASSWORD}" ]; then
  PASSWORD="password"
  log "Using default PASSWORD"
else
  log "Using PASSWORD from environment"
fi

printf '%s' "$PASSWORD" | openssl passwd -apr1 -stdin 2>/dev/null | { read hash; printf 'abc:%s\n' "$hash" > /etc/nginx/.htpasswd; }
chmod 644 /etc/nginx/.htpasswd

log "Downloading nginx config from GitHub..."
curl -fsSL https://raw.githubusercontent.com/AnEntrypoint/gmweb/main/docker/nginx-sites-enabled-default -o /etc/nginx/sites-available/default 2>/dev/null || {
  log "Failed to download nginx config, using fallback"
  cat > /etc/nginx/sites-available/default << 'NGINX_EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  auth_basic "GMWeb";
  auth_basic_user_file /etc/nginx/.htpasswd;

  location /desk {
    auth_basic "GMWeb";
    auth_basic_user_file /etc/nginx/.htpasswd;
    alias /usr/share/selkies/web/;
    index index.html index.htm;
    try_files $uri $uri/ =404;
  }

  location ~ /desk/websockets? {
    auth_basic "GMWeb";
    auth_basic_user_file /etc/nginx/.htpasswd;
    rewrite ^/desk/(.*) /$1 break;
    proxy_pass http://127.0.0.1:8082;
  }

  location /ssh {
    proxy_pass http://127.0.0.1:9999;
  }

  location /files {
    proxy_pass http://127.0.0.1:9998/;
  }

  location /devmode {
    proxy_pass http://127.0.0.1:5173;
  }

  location = / {
    return 301 /gm/;
  }

  location / {
    proxy_pass http://127.0.0.1:9897;
  }
}
NGINX_EOF
}

sleep 1
nginx -s reload 2>/dev/null || nginx &>/dev/null &
log "✓ nginx routing + HTTP Basic Auth configured (user: abc)"

export PASSWORD

log "Phase 3: System packages (from install.sh)"

apt-get update -qq 2>/dev/null || true
apt-get install -y --no-install-recommends curl bash git build-essential ca-certificates jq wget \
  software-properties-common apt-transport-https gnupg openssh-server openssh-client tmux lsof \
  scrot xclip \
  libgbm1 libgtk-3-0 libnss3 libxss1 libasound2t64 libatk-bridge2.0-0 \
  libdrm2 libxcomposite1 libxdamage1 libxrandr2 2>&1 | tail -5

echo "${ABC_UID}:${ABC_GID} ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers > /dev/null 2>&1 || true

sudo mkdir -p /run/sshd
sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
sudo sed -i 's/^UsePAM.*/UsePAM no/' /etc/ssh/sshd_config || true
sudo /usr/bin/ssh-keygen -A 2>/dev/null || true

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update -qq && apt-get install -y --no-install-recommends gh 2>&1 | tail -3

rm -rf /var/lib/apt/lists/*
log "✓ System packages installed"

log "Phase 4: Initialize D-Bus and environment"

sudo rm -rf /config/.npm 2>/dev/null || true
sudo rm -rf /config/node_modules/.bin/* 2>/dev/null || true
npm cache clean --force 2>/dev/null || true

mkdir -p /config/.npm
sudo chown -R abc:abc /config/.npm 2>/dev/null || true
sudo chmod -R 755 /config/.npm 2>/dev/null || true

cat > /tmp/npmrc << 'NPMRC_EOF'
cache=/config/.npm
prefix=/config/usr/local
NPMRC_EOF
sudo cp /tmp/npmrc /etc/npmrc 2>/dev/null || true
rm -f /tmp/npmrc

mkdir -p /config/usr/local/bin
cat > /config/usr/local/bin/npm-wrapper << 'WRAPPER_EOF'
#!/bin/bash
sudo chown -R abc:abc /config/.npm 2>/dev/null || true
exec /config/usr/local/bin/npm.real "$@"
WRAPPER_EOF
chmod +x /config/usr/local/bin/npm-wrapper

if [ -f /config/usr/local/bin/npm ] && [ ! -f /config/usr/local/bin/npm.real ]; then
  sudo mv /config/usr/local/bin/npm /config/usr/local/bin/npm.real 2>/dev/null || true
  sudo ln -sf /config/usr/local/bin/npm-wrapper /config/usr/local/bin/npm 2>/dev/null || true
fi

log "✓ npm configuration and wrapper set"

export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"

SAFE_TMPDIR="$HOME_DIR/.tmp"
mkdir -p "$SAFE_TMPDIR"
chmod 700 "$SAFE_TMPDIR"
chown abc:abc "$SAFE_TMPDIR"
export TMPDIR="$SAFE_TMPDIR"
export TMP="$SAFE_TMPDIR"
export TEMP="$SAFE_TMPDIR"

find "$SAFE_TMPDIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
find "$SAFE_TMPDIR" -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

rm -f "$RUNTIME_DIR/bus"
pkill -u abc dbus-daemon 2>/dev/null || true

sudo -u abc DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
  dbus-daemon --session --address=unix:path=$RUNTIME_DIR/bus --print-address 2>/dev/null &
DBUS_DAEMON_PID=$!

for i in {1..10}; do
  if [ -S "$RUNTIME_DIR/bus" ]; then
    log "D-Bus session ready (attempt $i/10)"
    break
  fi
  sleep 0.5
done

log "Phase 5: Node.js and supervisor setup"

sudo mkdir -p "$HOME_DIR/.npm" 2>/dev/null && sudo chown -R abc:abc "$HOME_DIR/.npm" 2>/dev/null || true

BASHRC_MARKER="$HOME_DIR/.gmweb-bashrc-setup"
if [ ! -f "$BASHRC_MARKER" ]; then
  cat >> "$HOME_DIR/.bashrc" << 'BASHRCEOF'
export NVM_DIR="/config/nvm"
export NPM_CONFIG_PREFIX="/config/usr/local"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="$(dirname "$(which node 2>/dev/null || echo /config/usr/local/bin/node)"):/config/usr/local/bin:$PATH"
BASHRCEOF
  touch "$BASHRC_MARKER"
fi

mkdir -p /config/usr/local/lib /config/usr/local/bin /config/nvm
chmod 755 /config/usr/local /config/usr/local/lib /config/usr/local/bin /config/nvm 2>/dev/null || true

if [ -d "/usr/local/local/nvm" ] && [ ! -e "/config/nvm/nvm.sh" ]; then
  log "Migrating NVM from /usr/local/local/nvm to /config/nvm"
  rm -rf /config/nvm && mv /usr/local/local/nvm /config/nvm 2>/dev/null || true
fi
rm -rf /usr/local/local 2>/dev/null || true

if [ ! -L /usr/local ] || [ "$(readlink /usr/local)" != "/config/usr/local" ]; then
  rm -f /usr/local && ln -s /config/usr/local /usr/local
fi

if ! command -v node &>/dev/null; then
  log "Installing Node.js via NVM..."
  mkdir -p "$NVM_DIR"

  if ! curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh 2>/dev/null | bash 2>&1 | tail -5; then
    log "ERROR: NVM installation failed"
    exit 1
  fi

  if [ ! -f "$NVM_DIR/nvm.sh" ]; then
    log "ERROR: NVM script not found after installation"
    exit 1
  fi

  . "$NVM_DIR/nvm.sh"

  if ! nvm install --lts 2>&1 | tail -5; then
    log "ERROR: Node.js LTS installation failed"
    exit 1
  fi

  nvm use default 2>&1 | tail -2
  log "✓ Node.js installed"
else
  log "✓ Node.js already available"
fi

if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
else
  log "ERROR: NVM script not available"
  exit 1
fi

export NPM_CONFIG_PREFIX=/config/usr/local

NODE_VERSION=$(node -v 2>/dev/null | tr -d 'v')
if [ -z "$NODE_VERSION" ]; then
  log "ERROR: Node.js not found after NVM setup"
  exit 1
fi

export PATH="$NVM_DIR/versions/node/v$NODE_VERSION/bin:/config/usr/local/bin:$PATH"
NODE_BIN_DIR="$NVM_DIR/versions/node/v$NODE_VERSION/bin"
log "✓ Node.js v$NODE_VERSION ready"

mkdir -p /config/usr/local/bin
for bin in node npm npx; do
  ln -sf "$NODE_BIN_DIR/$bin" /config/usr/local/bin/$bin
done
chmod 777 "$NODE_BIN_DIR" 2>/dev/null || true
chmod 777 "$NVM_DIR/versions/node/v$NODE_VERSION/lib/node_modules" 2>/dev/null || true
chmod 777 /config/usr/local/bin 2>/dev/null || true

log "Cloning supervisor from GitHub..."
rm -rf /tmp/gmweb /opt/gmweb-startup/node_modules /opt/gmweb-startup/lib \
       /opt/gmweb-startup/services /opt/gmweb-startup/package* \
       /opt/gmweb-startup/*.js /opt/gmweb-startup/*.json /opt/gmweb-startup/*.sh 2>/dev/null || true

mkdir -p /opt/gmweb-startup
git clone --depth 1 --single-branch --branch main https://github.com/AnEntrypoint/gmweb.git /tmp/gmweb 2>&1 | tail -3
cp -r /tmp/gmweb/startup/* /opt/gmweb-startup/

cd /opt/gmweb-startup && npm install --production --omit=dev 2>&1 | tail -3
chmod +x install.sh start.sh index.js 2>/dev/null || true
chmod -R go+rx . 2>/dev/null || true
chown -R root:root . 2>/dev/null || true
chmod 755 . 2>/dev/null || true

rm -rf /tmp/gmweb
log "✓ Supervisor ready"

log "Installing bcrypt and better-sqlite3..."
mkdir -p /config/.gmweb-deps
timeout 30 npm install -g better-sqlite3 2>&1 | tail -2
cd /config/.gmweb-deps && timeout 30 npm install bcrypt 2>&1 | tail -2
chown -R abc:abc /config/.gmweb-deps 2>/dev/null || true
log "✓ Critical modules installed"

log "Phase 6: Start supervisor (blocking)"

if [ -f /opt/gmweb-startup/start.sh ]; then
  sudo -u abc -H -E bash /opt/gmweb-startup/start.sh 2>&1 | tee -a "$LOG_DIR/startup.log" &
  SUPERVISOR_PID=$!
  sleep 2
  if kill -0 $SUPERVISOR_PID 2>/dev/null; then
    log "✓ Supervisor started (PID: $SUPERVISOR_PID)"
  else
    log "WARNING: Supervisor may have failed"
  fi
else
  log "ERROR: start.sh not found"
  exit 1
fi

log "Phase 7: Background tasks (non-blocking)"

{
  ARCH=$(uname -m)
  TTYD_ARCH=$([ "$ARCH" = "x86_64" ] && echo "x86_64" || echo "aarch64")
  TTYD_URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${TTYD_ARCH}"

  if [ ! -f /usr/bin/ttyd ]; then
    log "Downloading ttyd..."
    TTYD_RETRY=3
    while [ $TTYD_RETRY -gt 0 ]; do
      if timeout 60 curl -fL --max-redirs 5 -o /tmp/ttyd "$TTYD_URL" 2>/dev/null && [ -f /tmp/ttyd ] && [ -s /tmp/ttyd ]; then
        sudo mv /tmp/ttyd /usr/bin/ttyd
        sudo chmod +x /usr/bin/ttyd
        log "✓ ttyd installed"
        break
      else
        TTYD_RETRY=$((TTYD_RETRY - 1))
        [ $TTYD_RETRY -gt 0 ] && sleep 3
      fi
    done
    [ ! -f /usr/bin/ttyd ] && log "WARNING: ttyd install failed"
  fi

  log "Installing CLI tools (qwen-code, codex, cursor)..."
  npm install -g @qwen-code/qwen-code@latest 2>&1 | tail -2 && log "✓ qwen-code installed" || log "WARNING: qwen-code install failed"
  npm install -g @openai/codex 2>&1 | tail -2 && log "✓ codex installed" || log "WARNING: codex install failed"
  curl -fsSL https://cursor.com/install 2>/dev/null | bash 2>&1 | tail -3 && log "✓ cursor CLI installed" || log "WARNING: cursor CLI install failed"

  touch /tmp/gmweb-installs-complete
  log "Installation marker created"
} >> "$LOG_DIR/startup.log" 2>&1 &

log "Background tasks started"

[ -f "$HOME_DIR/startup.sh" ] && bash "$HOME_DIR/startup.sh" 2>&1 | tee -a "$LOG_DIR/startup.log"

chown -R abc:abc "$HOME_DIR" 2>/dev/null || true
log "===== GMWEB STARTUP COMPLETE ====="

exit 0
