#!/bin/bash

set +e

HOME_DIR="/config"
LOG_DIR="$HOME_DIR/logs"

unset LD_PRELOAD
unset NPM_CONFIG_PREFIX

ABC_UID=$(id -u abc 2>/dev/null || echo "")
ABC_GID=$(id -g abc 2>/dev/null || echo "")

PUID="${ABC_UID:-${PUID:-1000}}"
PGID="${ABC_GID:-${PGID:-1000}}"

sudo chown -R "$PUID:$PGID" "/config" 2>/dev/null || true

sudo chmod -R u+rwX,g+rX,o-rwx "/config" 2>/dev/null || true

if [ ! -w "/config" ]; then
  sudo chmod 755 "/config" 2>/dev/null || true
fi

sudo rm -rf "$LOG_DIR" 2>/dev/null || true
sudo mkdir -p "$LOG_DIR" 2>/dev/null || true
if [ -d "$LOG_DIR" ]; then
  sudo chmod 755 "$LOG_DIR" 2>/dev/null || true
  sudo chown "$PUID:$PGID" "$LOG_DIR" 2>/dev/null || true
fi

sudo mkdir -p "$HOME_DIR/tmp" 2>/dev/null || true
if [ -d "$HOME_DIR/tmp" ]; then
  sudo chmod 1777 "$HOME_DIR/tmp" 2>/dev/null || true
  sudo chown "$PUID:$PGID" "$HOME_DIR/tmp" 2>/dev/null || true
fi
export TMPDIR="$HOME_DIR/tmp"

log() {
  local msg="[gmweb-startup] $(date '+%Y-%m-%d %H:%M:%S') $@"
  echo "$msg"
  echo "$msg" >> "$LOG_DIR/startup.log"
  sync "$LOG_DIR/startup.log" 2>/dev/null || true
}

log "===== GMWEB STARTUP (NGINX-FIRST BLOCKING ARCHITECTURE) ====="

mkdir -p /tmp/gmweb-wrappers
cat > /tmp/gmweb-wrappers/npm-as-abc.sh << 'NPM_WRAPPER_EOF'
#!/bin/bash
export NVM_DIR=/config/nvm
export HOME=/config
export GMWEB_DIR=/config/.gmweb
unset NPM_CONFIG_PREFIX
unset npm_config_prefix
export npm_config_cache=/config/.gmweb/npm-cache
export npm_config_prefix=/config/.gmweb/npm-global
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/config/.gmweb/npm-global/bin:$PATH"
if ! command -v npm &>/dev/null; then
  echo "ERROR: npm not available after NVM source" >&2
  echo "DEBUG: PATH=$PATH NVM_DIR=$NVM_DIR" >&2
  exit 1
fi
exec "$@"
NPM_WRAPPER_EOF
chmod +x /tmp/gmweb-wrappers/npm-as-abc.sh

log "Initial /config ownership and permissions fixed"

log "Phase 0.1: Enabling s6-rc services (removing down markers)"
sudo rm -f /run/service/svc-*/down 2>/dev/null || true
log "✓ s6-rc services enabled for auto-start"

log "Phase 0.5: Comprehensive home directory permission setup (PUID=$PUID, PGID=$PGID)"

CRITICAL_PATHS=(
  "$HOME_DIR"
  "$HOME_DIR/.config"
  "$HOME_DIR/.local"
  "$HOME_DIR/.local/bin"
  "$HOME_DIR/.local/share"
  "$HOME_DIR/.cache"
  "$HOME_DIR/.gmweb"
  "$HOME_DIR/.gmweb/tools"
  "$HOME_DIR/.gmweb/cache"
  "$HOME_DIR/.gmweb/npm-cache"
  "$HOME_DIR/.gmweb/npm-global"
  "$HOME_DIR/.gmweb/npm-global/bin"
  "$HOME_DIR/.gmweb/npm-global/lib"
  "$HOME_DIR/.tmp"
  "$HOME_DIR/logs"
  "$HOME_DIR/workspace"
  "$HOME_DIR/.nvm"
  "/run/user/$PUID"
)

for path in "${CRITICAL_PATHS[@]}"; do
  if [ ! -d "$path" ]; then
    sudo mkdir -p "$path" 2>/dev/null || true
  fi
  sudo chown "$PUID:$PGID" "$path" 2>/dev/null || true
  if [[ "$path" =~ (.cache|.tmp|.config|workspace) ]]; then
    sudo chmod 750 "$path" 2>/dev/null || true
  else
    sudo chmod 755 "$path" 2>/dev/null || true
  fi
done

sudo chown "$PUID:$PGID" "$HOME_DIR/.gitconfig" 2>/dev/null || true
sudo chown -R "$PUID:$PGID" "$HOME_DIR/.claude" 2>/dev/null || true
sudo chown "$PUID:$PGID" "$HOME_DIR/.git-credentials" 2>/dev/null || true
sudo chown -R "$PUID:$PGID" "$HOME_DIR/.config" 2>/dev/null || true
sudo chown -R "$PUID:$PGID" "$HOME_DIR/.gmweb" 2>/dev/null || true
sudo chown -R "$PUID:$PGID" "$HOME_DIR/nvm" 2>/dev/null || true

log "✓ Comprehensive permission setup complete"

BOOT_ID="$(date '+%s')-$$"
log "Boot ID: $BOOT_ID"

log "✓ Phase 0: Permissions and environment ready (BLOCKING)"
log "NOTE: All APT packages (unzip, jq, ttyd, gcloud, gh) install async in rest-of-startup.sh"
log "      Nothing blocks nginx startup"

log "Cleaning up legacy installations and ensuring clean state..."

mkdir -p /config/.gmweb/{npm-cache,npm-global,tools,deps,cache}
chown -R "$PUID:$PGID" /config/.gmweb 2>/dev/null || true
chmod -R u+rwX,g+rX,o-rwx /config/.gmweb 2>/dev/null || true

sudo rm -rf /config/usr /config/.gmweb-deps /config/.gmweb-bashrc-setup /config/.gmweb-bashrc-setup-v2 /config/.gmweb-migrated-v2 2>/dev/null || true

for node_dir in /config/nvm/versions/node/v*; do
  if [ -d "$node_dir" ] && [[ ! "$node_dir" =~ v24\. ]]; then
    rm -rf "$node_dir" 2>/dev/null || true
  fi
done

log "✓ Cleanup complete"

log "Compiling close_range shim..."
sudo mkdir -p /opt/lib

if [ ! -f /opt/lib/libshim_close_range.so ]; then
  cat > /tmp/shim_close_range.c << 'SHIMEOF'
#define _GNU_SOURCE
#include <errno.h>

int close_range(unsigned int first, unsigned int last, int flags) {
    errno = 38;
    return -1;
}
SHIMEOF
  gcc -fPIC -shared /tmp/shim_close_range.c -o /tmp/libshim_close_range.so 2>&1 | grep -v "^$" || true
  rm -f /tmp/shim_close_range.c

  if [ -f /tmp/libshim_close_range.so ]; then
    sudo mv /tmp/libshim_close_range.so /opt/lib/libshim_close_range.so
    sudo chmod 755 /opt/lib/libshim_close_range.so
    log "✓ Shim compiled to /opt/lib/libshim_close_range.so"
  fi
else
  log "✓ Shim already exists at /opt/lib/libshim_close_range.so"
fi

ABC_UID=$(id -u abc 2>/dev/null || echo 1000)
ABC_GID=$(id -g abc 2>/dev/null || echo 1000)
RUNTIME_DIR="/run/user/$ABC_UID"

if [ ! -d "$RUNTIME_DIR" ]; then
  sudo mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
  sudo chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
  sudo chown "$ABC_UID:$ABC_GID" "$RUNTIME_DIR" 2>/dev/null || true
fi

log "Cleaning persistent volume artifacts..."
sudo rm -rf /config/.npm 2>/dev/null || true

GMWEB_DIR="/config/.gmweb"
sudo mkdir -p "$GMWEB_DIR"/{npm-cache,npm-global,tools}
sudo chown -R "$PUID:$PGID" "$GMWEB_DIR" 2>/dev/null || true
sudo chmod -R u+rwX,g+rX,o-rwx "$GMWEB_DIR" 2>/dev/null || true

cat > /tmp/npmrc << 'NPMRC_EOF'
cache=/config/.gmweb/npm-cache
prefix=/config/.gmweb/npm-global
NPMRC_EOF
sudo cp /tmp/npmrc /etc/npmrc 2>/dev/null || true

sudo cp /tmp/npmrc /config/.npmrc 2>/dev/null || true
sudo chown abc:abc /config/.npmrc 2>/dev/null || true
rm -f /tmp/npmrc

export PATH="/config/.gmweb/npm-global/bin:$PATH"
log "✓ Centralized gmweb directory configured"

log "Phase 0.75: Pre-clearing npm cache directories..."
if [ -d "$GMWEB_DIR/npm-cache" ]; then
  sudo rm -rf "$GMWEB_DIR/npm-cache" 2>/dev/null || true
  mkdir -p "$GMWEB_DIR/npm-cache"
  chmod 777 "$GMWEB_DIR/npm-cache"
  log "  ✓ npm-cache pre-cleared"
fi

if [ -d "$GMWEB_DIR/npm-global" ]; then
  sudo rm -rf "$GMWEB_DIR/npm-global" 2>/dev/null || true
  mkdir -p "$GMWEB_DIR/npm-global"
  chmod 777 "$GMWEB_DIR/npm-global"
  log "  ✓ npm-global pre-cleared"
fi

export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"

log "✓ Phase 0.5-0.75 complete - system ready for blocking nginx setup"

log "Phase 0: Calling nginx-setup.sh (BLOCKING - must complete before proceeding)"

if [ ! -f /custom-cont-init.d/nginx-setup.sh ]; then
  log "ERROR: nginx-setup.sh not found at /custom-cont-init.d/"
  exit 1
fi

if ! bash /custom-cont-init.d/nginx-setup.sh; then
  log "ERROR: nginx-setup.sh failed - cannot proceed"
  exit 1
fi

log "✓ nginx blocking phase complete - nginx ready on port 80"

log "Phase 1: Spawning rest-of-startup.sh (non-blocking - returns immediately)"

if [ ! -f /custom-cont-init.d/rest-of-startup.sh ]; then
  log "ERROR: rest-of-startup.sh not found at /custom-cont-init.d/"
  exit 1
fi

nohup bash /custom-cont-init.d/rest-of-startup.sh > "$LOG_DIR/rest-of-startup.log" 2>&1 &
REST_PID=$!
log "✓ rest-of-startup.sh spawned (PID: $REST_PID)"
log "  All subsequent startup phases run async in background"
log "  - Phase 2: Git clone, NVM setup"
log "  - Phase 3: Supervisor and services"
log "  - Phase 4: XFCE launcher"
log "  - Phase 5: Background module installs"

log "Phase 0: Ensuring Selkies WebSocket mode..."
if [ -f /custom-cont-init.d/patch-selkies-webrtc.sh ]; then
  bash /custom-cont-init.d/patch-selkies-webrtc.sh >> "$LOG_DIR/startup.log" 2>&1
  [ $? -eq 0 ] && log "Selkies WebSocket mode confirmed" || log "WARNING: Selkies mode patch may have failed"
else
  log "WARNING: patch-selkies-webrtc.sh not found"
fi

log "===== GMWEB BLOCKING STARTUP COMPLETE ====="
log "nginx ready and listening on port 80"
log "s6-rc services will proceed independently"
log "/desk/ endpoint available immediately"
log "Remaining startup phases running async (logs: /config/logs/rest-of-startup.log)"

export PASSWORD

exit 0
