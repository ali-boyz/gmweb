#!/bin/bash

set +e

unset NPM_CONFIG_PREFIX
unset npm_config_prefix

HOME_DIR="/config"
LOG_DIR="$HOME_DIR/logs"
STARTUP_SOURCE_URL="https://github.com/AnEntrypoint/gmweb.git"
STARTUP_COMMIT="1b183446751c633b4c52cd703022482bd5a5be9c"

log() {
  local msg="[rest-of-startup] $(date '+%Y-%m-%d %H:%M:%S') $@"
  echo "$msg"
  echo "$msg" >> "$LOG_DIR/startup.log" 2>/dev/null || echo "$msg"
  sync "$LOG_DIR/startup.log" 2>/dev/null || true
}

log "===== REST OF STARTUP PHASES (NON-BLOCKING) ====="
log "This runs async while nginx and s6-rc proceed independently"

if [ "$GMWEB_HEADLESS" = "1" ]; then
  log "Running in HEADLESS mode - desktop features disabled"
  IS_HEADLESS=true
else
  IS_HEADLESS=false
fi

ABC_UID=$(id -u abc 2>/dev/null || echo 1000)
RUNTIME_DIR="/run/user/$ABC_UID"

mkdir -p "$RUNTIME_DIR"
chown abc:abc "$RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
if [ ! -S "$RUNTIME_DIR/bus" ]; then
  log "Starting D-Bus session bus at $RUNTIME_DIR/bus..."
  rm -f "$RUNTIME_DIR/bus"
  sudo -u abc XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    dbus-daemon --session --address="unix:path=$RUNTIME_DIR/bus" --nofork >/dev/null 2>&1 &
  for i in $(seq 1 10); do
    [ -S "$RUNTIME_DIR/bus" ] && { log "✓ D-Bus session bus ready (attempt $i/10)"; break; }
    sleep 0.5
  done
  [ -S "$RUNTIME_DIR/bus" ] || log "WARNING: D-Bus session bus socket did not appear after 10 attempts - headed Chromium/XFCE will hang"
else
  log "D-Bus session bus already present at $RUNTIME_DIR/bus"
fi

log "Phase 0: Installing system packages (APT) - async after nginx"
apt-get update -qq 2>/dev/null || true
log "  Installing: unzip jq ttyd chromium git-lfs"
apt-get install -y --no-install-recommends unzip jq ttyd chromium git-lfs 2>&1 | tail -2
[ $? -eq 0 ] && log "✓ System packages installed" || log "WARNING: System package install incomplete"
git lfs install 2>/dev/null || true

log "  Wrapping chromium-browser to always force --no-sandbox..."
CHROMIUM_REAL_BIN=$(readlink -f /usr/bin/chromium-browser 2>/dev/null || readlink -f /usr/bin/chromium 2>/dev/null)
if [ -n "$CHROMIUM_REAL_BIN" ] && [ -x "$CHROMIUM_REAL_BIN" ]; then
  if [ ! -x "${CHROMIUM_REAL_BIN}.real" ]; then
    cp "$CHROMIUM_REAL_BIN" "${CHROMIUM_REAL_BIN}.real" 2>/dev/null
  fi
  cat > "$CHROMIUM_REAL_BIN" <<CHROMIUM_WRAPPER_EOF
#!/bin/bash
exec "${CHROMIUM_REAL_BIN}.real" --no-sandbox --disable-setuid-sandbox "\$@"
CHROMIUM_WRAPPER_EOF
  chmod 755 "$CHROMIUM_REAL_BIN"
  for alias_path in /usr/bin/chromium-browser /usr/bin/chromium /usr/bin/google-chrome /usr/bin/google-chrome-stable; do
    if [ "$alias_path" != "$CHROMIUM_REAL_BIN" ] && [ ! -e "$alias_path" ]; then
      ln -sf "$CHROMIUM_REAL_BIN" "$alias_path" 2>/dev/null
    fi
  done
  log "  ✓ chromium wrapper installed (real binary at ${CHROMIUM_REAL_BIN}.real)"
else
  log "  WARNING: chromium binary not found, cannot install --no-sandbox wrapper"
fi

log "  Installing Bun runtime..."
if [ ! -x /usr/local/bin/bun ]; then
  curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash 2>&1 | tail -2
  ln -sf /usr/local/bin/bun /usr/local/bin/bunx 2>/dev/null || true
fi
if [ -x /usr/local/bin/bun ]; then
  log "  ✓ Bun installed: $(/usr/local/bin/bun --version)"
else
  log "  WARNING: Bun installation failed - services will fall back to npx"
fi

log "  Configuring git HTTPS URL rewriting for GitHub..."
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" 2>/dev/null || true
git config --global url."https://github.com/".insteadOf "git@github.com:" 2>/dev/null || true
sudo chown abc:abc "$HOME_DIR/.gitconfig" 2>/dev/null || true
sudo chown abc:abc "$HOME_DIR/.git-credentials" 2>/dev/null || true
log "  ✓ Git URL rewriting configured"

log "Phase 1: Fetching startup revision ${STARTUP_COMMIT}"

sudo rm -rf /tmp/gmweb /opt/gmweb-startup/node_modules /opt/gmweb-startup/lib \
       /opt/gmweb-startup/services /opt/gmweb-startup/package* \
       /opt/gmweb-startup/*.js /opt/gmweb-startup/*.json /opt/gmweb-startup/*.sh \
       /opt/gmweb-startup/.git 2>/dev/null || true

sudo mkdir -p /opt/gmweb-startup

log "  Verifying network connectivity..."
if timeout 10 curl -fsSL --connect-timeout 5 https://api.github.com/users/AnEntrypoint >/dev/null 2>&1; then
  log "  ✓ Network verified"
else
  log "  WARNING: Network check failed, attempting clone anyway (may timeout)"
fi

rm -rf /tmp/gmweb 2>/dev/null || true
if ! timeout 120 git init --quiet /tmp/gmweb || \
   ! timeout 120 git -C /tmp/gmweb remote add origin "$STARTUP_SOURCE_URL" || \
   ! timeout 120 git -C /tmp/gmweb fetch --depth 1 --filter=blob:none origin "$STARTUP_COMMIT" || \
   ! timeout 120 git -C /tmp/gmweb checkout --detach --quiet FETCH_HEAD || \
   [ "$(git -C /tmp/gmweb rev-parse HEAD)" != "$STARTUP_COMMIT" ]; then
  log "ERROR: Startup revision fetch or integrity verification failed"
  exit 1
fi

if [ ! -d /tmp/gmweb/startup ]; then
  log "ERROR: Git clone completed but startup directory missing"
  exit 1
fi

log "✓ Startup revision verified: $(git -C /tmp/gmweb rev-parse HEAD)"

cp -r /tmp/gmweb/startup/* /opt/gmweb-startup/
cp /tmp/gmweb/docker/nginx-sites-enabled-default /opt/gmweb-startup/
log "✓ Startup files copied to /opt/gmweb-startup"

if [ ! -f /config/crontab ] && [ -f /opt/gmweb-startup/crontab.default ]; then
  log "Phase 1.0-cron: Creating /config/crontab from default template..."
  cp /opt/gmweb-startup/crontab.default /config/crontab
  chmod 644 /config/crontab
  chown abc:abc /config/crontab 2>/dev/null || true
  crontab -u abc /config/crontab 2>/dev/null || true
  log "✓ Default crontab installed and loaded for user abc"
elif [ -f /config/crontab ]; then
  log "Phase 1.0-cron: /config/crontab already exists, loading..."
  crontab -u abc /config/crontab 2>/dev/null || true
  log "✓ Existing crontab loaded for user abc"
fi

log "Phase 1.0a: Setting up beforestart and beforeend hooks..."
cp /tmp/gmweb/startup/beforestart /config/beforestart
cp /tmp/gmweb/startup/beforeend /config/beforeend
chmod +x /config/beforestart /config/beforeend
chown abc:abc /config/beforestart /config/beforeend
log "✓ beforestart and beforeend hooks installed to /config/"

log "Phase 1.0b: Generating perfect .bashrc file..."
cat > /config/.bashrc << 'BASHRC_EOF'
#!/bin/bash

if [ -f "${HOME}/.beforestart" ] || [ -f "${HOME}/beforestart" ]; then
  BEFORESTART_HOOK="${HOME}/beforestart"
  [ ! -f "$BEFORESTART_HOOK" ] && BEFORESTART_HOOK="${HOME}/.beforestart"
  if [ -f "$BEFORESTART_HOOK" ]; then
    . "$BEFORESTART_HOOK"
  fi
fi

if [ -z "$PS1" ]; then
  return
fi

export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoredups:ignorespace

shopt -s histappend 2>/dev/null || true
shopt -s checkwinsize 2>/dev/null || true

export PS1="\u@\h:\w\$ "
BASHRC_EOF
chmod 644 /config/.bashrc
log "✓ Perfect .bashrc created"

log "Phase 1.0c: Generating perfect .profile file..."
cat > /config/.profile << 'PROFILE_EOF'
#!/bin/bash

if [ -f "${HOME}/.beforestart" ] || [ -f "${HOME}/beforestart" ]; then
  BEFORESTART_HOOK="${HOME}/beforestart"
  [ ! -f "$BEFORESTART_HOOK" ] && BEFORESTART_HOOK="${HOME}/.beforestart"
  if [ -f "$BEFORESTART_HOOK" ]; then
    . "$BEFORESTART_HOOK"
  fi
fi
PROFILE_EOF
chmod 644 /config/.profile
log "✓ Perfect .profile created"

GMWEB_DIR="/config/.gmweb"
sudo mkdir -p "$GMWEB_DIR" && sudo chown -R abc:abc "$GMWEB_DIR" 2>/dev/null || true

log "Phase 1 complete - environment ready (using beforestart hook)"

log "Verifying persistent path structure..."
sudo mkdir -p /config/nvm /config/.tmp /config/logs /config/.local /config/.local/bin
sudo chown 1000:1000 /config/nvm /config/.tmp /config/logs /config/.local /config/.local/bin 2>/dev/null || true
sudo chmod 755 /config/nvm /config/.tmp /config/logs /config/.local /config/.local/bin 2>/dev/null || true

cp /tmp/gmweb/startup/.nvm_compat.sh /config/.nvm_compat.sh
cp /tmp/gmweb/startup/.nvm_restore.sh /config/.nvm_restore.sh
chmod +x /config/.nvm_compat.sh /config/.nvm_restore.sh

NVM_DIR=/config/nvm
export NVM_DIR
log "Persistent paths ready: NVM_DIR=$NVM_DIR"

log "Phase 1: Sourcing beforestart hook for environment setup..."
if [ -f /config/beforestart ]; then
  . /config/beforestart
else
  log "ERROR: beforestart hook not found at /config/beforestart"
  exit 1
fi

mkdir -p "$NVM_DIR"

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  log "Installing NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash 2>&1 | tail -3
  . /config/beforestart
fi

NODE_DIR="$NVM_DIR/versions/node"
LATEST_NODE=$(ls -1 "$NODE_DIR" 2>/dev/null | sort -V | tail -1)

if [ -z "$LATEST_NODE" ]; then
  log "No Node.js found, installing Node 24..."
  nvm install 24 2>&1 | tail -5
else
  NPM_MODULE="$NODE_DIR/$LATEST_NODE/lib/node_modules/npm"
  if [ ! -d "$NPM_MODULE" ]; then
    log "npm missing from $LATEST_NODE, reinstalling Node 24..."
    chown -R abc:abc "$NODE_DIR/$LATEST_NODE" 2>/dev/null || true
    nvm deactivate 2>/dev/null || true
    rm -rf "$NODE_DIR/$LATEST_NODE"
    nvm install 24 2>&1 | tail -5
  else
    log "Node $LATEST_NODE with npm verified"
  fi
fi

nvm use 24 2>&1 | tail -2
nvm alias default 24 2>&1 | tail -2

ACTIVE_NODE=$(nvm which current 2>/dev/null | sed 's|/bin/node||')
[ -d "$ACTIVE_NODE" ] && sudo chown -R abc:abc "$ACTIVE_NODE" 2>/dev/null || true

if ! command -v npm &>/dev/null; then
  log "ERROR: npm not available after nvm setup"
  log "DEBUG: PATH=$PATH"
  log "DEBUG: node=$(which node 2>&1)"
  exit 1
fi

NODE_VERSION=$(node -v | tr -d 'v')
NPM_VERSION=$(npm -v)
log "Node.js $NODE_VERSION, npm $NPM_VERSION (NVM_DIR=$NVM_DIR)"

log "CRITICAL: Fixing npm cache permissions (root-owned files from previous boots)..."
if [ -d "$GMWEB_DIR/npm-cache" ]; then
  sudo rm -rf "$GMWEB_DIR/npm-cache" 2>/dev/null || true
  mkdir -p "$GMWEB_DIR/npm-cache"
  chmod 777 "$GMWEB_DIR/npm-cache"
  log "  ✓ npm cache cleaned and recreated with proper permissions"
fi

if [ -d "$GMWEB_DIR/npm-global" ]; then
  sudo chown -R abc:abc "$GMWEB_DIR/npm-global" 2>/dev/null || true
  sudo chmod -R u+rwX,g+rX,o-rwx "$GMWEB_DIR/npm-global" 2>/dev/null || true
  log "  ✓ npm-global permissions fixed"
fi

if [ ! -f /tmp/gmweb-wrappers/npm-as-abc.sh ]; then
  mkdir -p /tmp/gmweb-wrappers
  cat > /tmp/gmweb-wrappers/npm-as-abc.sh << 'NPM_WRAPPER_EOF'
#!/bin/bash
export NVM_DIR=/config/nvm
export HOME=/config
export GMWEB_DIR=/config/.gmweb
export npm_config_cache=/config/.gmweb/npm-cache
unset npm_config_prefix
unset NPM_CONFIG_PREFIX
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export npm_config_prefix=/config/.gmweb/npm-global
export PATH="/config/.gmweb/npm-global/bin:$PATH"
if ! command -v npm &>/dev/null; then
  echo "ERROR: npm not available after NVM source" >&2
  echo "DEBUG: NVM_DIR=$NVM_DIR" >&2
  echo "DEBUG: PATH=$PATH" >&2
  exit 1
fi
exec "$@"
NPM_WRAPPER_EOF
  chmod +x /tmp/gmweb-wrappers/npm-as-abc.sh
fi

sudo -u abc /tmp/gmweb-wrappers/npm-as-abc.sh npm cache clean --force 2>&1 | tail -1 || true
log "✓ npm cache cleaned and fixed"

log "Setting up supervisor..."
rm -rf /tmp/gmweb /tmp/_keep_docker_scripts 2>/dev/null || true

log "Final npm cache verification before supervisor install..."
sudo -u abc /tmp/gmweb-wrappers/npm-as-abc.sh npm cache clean --force 2>&1 | tail -1 || true

log "Installing supervisor dependencies as abc user..."
cd /opt/gmweb-startup && \
  sudo -u abc /tmp/gmweb-wrappers/npm-as-abc.sh npm install --production --omit=dev 2>&1 | tail -3 && \
  chmod +x install.sh start.sh index.js && \
  chmod -R go+rx . && \
  chown -R root:root . && \
  chmod 755 .

sudo nginx -t 2>&1 && sudo nginx -s reload || log "✗ Nginx reload failed before supervisor start"
log "Supervisor ready (fresh from git)"

cat > /tmp/launch_xfce_components.sh << 'XFCE_LAUNCHER_EOF'
#!/bin/bash

export DISPLAY=:1
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
export XDG_RUNTIME_DIR="/run/user/1000"
export HOME=/config

log() {
  echo "[xfce-launcher] $(date '+%Y-%m-%d %H:%M:%S') $@"
}

sleep 15

if ! pgrep -u abc xfce4-session >/dev/null 2>&1; then
  log "NOTE: XFCE session manager not running (desktop components skipped)"
  exit 0
fi

log "XFCE session detected, launching components..."
sleep 2

log "Launching XFCE desktop components..."

if ! pgrep -u abc xfce4-panel >/dev/null 2>&1; then
  sudo -u abc HOME=/config DISPLAY=:1 DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" LD_PRELOAD=/opt/lib/libshim_close_range.so \
    xfce4-panel >/dev/null 2>&1
  log "xfce4-panel completed"
fi

if ! pgrep -u abc xfdesktop >/dev/null 2>&1; then
  sudo -u abc HOME=/config DISPLAY=:1 DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" LD_PRELOAD=/opt/lib/libshim_close_range.so \
    xfdesktop >/dev/null 2>&1
  log "xfdesktop completed"
fi

if ! pgrep -u abc xfwm4 >/dev/null 2>&1; then
  sudo -u abc HOME=/config DISPLAY=:1 DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" LD_PRELOAD=/opt/lib/libshim_close_range.so \
    xfwm4 >/dev/null 2>&1
  log "xfwm4 completed"
fi

log "XFCE component launcher complete"
XFCE_LAUNCHER_EOF

chmod +x /tmp/launch_xfce_components.sh
log "XFCE launcher script prepared"

if [ -f /custom-cont-init.d/background-installs.sh ]; then
  log "Phase 6: Spawning background installs async (non-blocking)..."
  nohup bash /custom-cont-init.d/background-installs.sh > "$LOG_DIR/background-installs.log" 2>&1 &
  log "✓ Background install process spawned (PID: $!)"
else
  log "WARNING: background-installs.sh not found at /custom-cont-init.d/"
fi

log "Phase 5: Starting supervisor (background installs run async)..."

unset NPM_CONFIG_PREFIX

if [ -f /opt/gmweb-startup/start.sh ]; then
  NVM_DIR=/config/nvm \
  HOME=/config \
  GMWEB_DIR="$GMWEB_DIR" \
  PATH="/config/.gmweb/cache/.bun/bin:/config/.gmweb/npm-global/bin:$PATH" \
  NODE_OPTIONS="--no-warnings" \
  TMPDIR="/config/.tmp" \
  TMP="/config/.tmp" \
  TEMP="/config/.tmp" \
  XDG_RUNTIME_DIR="$RUNTIME_DIR" \
  XDG_CACHE_HOME="/config/.gmweb/cache" \
  XDG_CONFIG_HOME="/config/.gmweb/cache/.config" \
  XDG_DATA_HOME="/config/.gmweb/cache/.local/share" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
  DOCKER_CONFIG="/config/.gmweb/cache/.docker" \
  BUN_INSTALL="/config/.gmweb/cache/.bun" \
  PUPPETEER_EXECUTABLE_PATH="/usr/bin/chromium-browser" \
  CHROME_PATH="/usr/bin/chromium-browser" \
  CHROMIUM_PATH="/usr/bin/chromium-browser" \
  PUPPETEER_SKIP_DOWNLOAD="true" \
  PUPPETEER_CACHE_DIR="/config/.cache/puppeteer" \
  PASSWORD="$PASSWORD" \
  sudo -E -u abc bash /opt/gmweb-startup/start.sh 2>&1 | tee -a "$LOG_DIR/startup.log"
  log "Supervisor process completed"
else
  log "ERROR: start.sh not found at /opt/gmweb-startup/start.sh"
fi

if [ "$IS_HEADLESS" = "true" ]; then
  log "Skipping XFCE launcher (headless mode)"
else
  bash /tmp/launch_xfce_components.sh >> "$LOG_DIR/startup.log" 2>&1
  log "XFCE component launcher completed"
fi

log "===== REST OF STARTUP COMPLETE ====="
log "All blocking phases complete (supervisor running)"
log "Background installs continue async in background (/config/logs/background-installs.log)"
log "nginx ready, supervisor active, services and components launched"
log "s6-rc services are now active (/desk/ endpoint available)"

exit 0
