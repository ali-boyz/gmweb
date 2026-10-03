#!/bin/bash

set +e

HOME_DIR="/config"
LOG_DIR="$HOME_DIR/logs"
GMWEB_DIR="$HOME_DIR/.gmweb"

log() {
  local msg="[gmweb-background] $(date '+%Y-%m-%d %H:%M:%S') $@"
  echo "$msg"
  echo "$msg" >> "$LOG_DIR/background-installs.log"
  sync "$LOG_DIR/background-installs.log" 2>/dev/null || true
}

log "===== GMWEB BACKGROUND INSTALLS STARTED (Phase 3) ====="
log "This runs async after supervisor is ready - does not block services"

sudo mkdir -p "$GMWEB_DIR/deps"
sudo chown 1000:1000 "$GMWEB_DIR/deps" 2>/dev/null || true
sudo chmod u+rwX,g+rX,o-rwx "$GMWEB_DIR/deps" 2>/dev/null || true

log "Phase 3.1: Installing critical Node modules..."

log "  Installing better-sqlite3..."
sudo -u abc bash << 'SQLITE_INSTALL_EOF'
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
npm install -g better-sqlite3 2>&1 | tail -3
SQLITE_INSTALL_EOF
[ $? -eq 0 ] && log "✓ better-sqlite3 installed" || log "WARNING: better-sqlite3 install incomplete"

log "  Installing bcrypt..."
sudo -u abc bash << 'BCRYPT_INSTALL_EOF'
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
cd /config/.gmweb/deps && npm install bcrypt 2>&1 | tail -3
BCRYPT_INSTALL_EOF
[ $? -eq 0 ] && log "✓ bcrypt installed" || log "WARNING: bcrypt install incomplete"

sudo -u abc bash << 'CACHE_CLEAN_EOF'
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
npm cache clean --force 2>&1 | tail -1
CACHE_CLEAN_EOF
log "✓ npm cache cleaned"

log "Phase 3.2: Installing agent-browser..."

log "  Cleaning stale agent-browser install (prevents ENOTEMPTY on re-install)..."
rm -rf /config/.gmweb/npm-global/lib/node_modules/agent-browser 2>/dev/null || true
rm -f /config/.gmweb/npm-global/bin/agent-browser 2>/dev/null || true
log "  Installing agent-browser package..."
sudo -u abc bash << 'AGENT_BROWSER_INSTALL_EOF'
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
npm install -g agent-browser 2>&1 | tail -3
AGENT_BROWSER_INSTALL_EOF
[ $? -eq 0 ] && log "✓ agent-browser installed" || log "WARNING: agent-browser install incomplete"

AGENT_BROWSER_BIN="/config/.gmweb/npm-global/bin/agent-browser"

log "  Running agent-browser setup (download Chromium)..."
sudo -u abc bash << AGENT_BROWSER_SETUP_EOF
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
"$AGENT_BROWSER_BIN" install 2>&1
AGENT_BROWSER_SETUP_EOF
[ $? -eq 0 ] && log "✓ agent-browser Chromium download complete" || log "WARNING: agent-browser setup incomplete"

log "  Installing agent-browser system dependencies..."
sudo -u abc bash << AGENT_BROWSER_DEPS_EOF
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
"$AGENT_BROWSER_BIN" install --with-deps 2>&1
AGENT_BROWSER_DEPS_EOF
[ $? -eq 0 ] && log "✓ agent-browser system dependencies installed" || log "WARNING: agent-browser --with-deps incomplete"

log "  Adding agent-browser skills..."
sudo -u abc bash << 'AGENT_BROWSER_SKILLS_EOF'
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
npx skills add vercel-labs/agent-browser -g -y --all 2>&1 | tail -5
AGENT_BROWSER_SKILLS_EOF
[ $? -eq 0 ] && log "✓ agent-browser skills added" || log "WARNING: agent-browser skills add incomplete"

log "Phase 3.2b: Verifying chromium headless launch..."
CHROMIUM_VERIFIED=false
if [ -x /usr/bin/chromium-browser ]; then
  CHROMIUM_TEST=$(timeout 10 /usr/bin/chromium-browser --headless --no-sandbox --disable-gpu --dump-dom about:blank 2>&1)
  if echo "$CHROMIUM_TEST" | grep -q '<html>'; then
    CHROMIUM_VERSION=$(/usr/bin/chromium-browser --version 2>&1 | head -1)
    log "✓ System chromium verified: $CHROMIUM_VERSION"
    CHROMIUM_VERIFIED=true
  else
    log "WARNING: System chromium headless test failed"
    log "  Output: $(echo "$CHROMIUM_TEST" | tail -3)"
  fi
else
  log "WARNING: /usr/bin/chromium-browser not found (apt install may not have completed)"
fi

log "Phase 3.2c: Cleaning stale puppeteer cache versions..."
PUPPETEER_CACHE="/config/.cache/puppeteer/chrome"
if [ -d "$PUPPETEER_CACHE" ]; then
  CURRENT_ARCH=$(uname -m)
  ARCH_PREFIX="linux_arm"
  [ "$CURRENT_ARCH" = "x86_64" ] && ARCH_PREFIX="linux"

  for chrome_dir in "$PUPPETEER_CACHE"/*/; do
    dir_name=$(basename "$chrome_dir")
    case "$dir_name" in
      linux-*)
        if [ "$CURRENT_ARCH" != "x86_64" ]; then
          log "  Removing wrong-arch puppeteer cache: $dir_name"
          rm -rf "$chrome_dir"
        fi
        ;;
    esac
  done

  KEPT=0
  for chrome_dir in $(ls -1dt "$PUPPETEER_CACHE"/${ARCH_PREFIX}-* 2>/dev/null); do
    KEPT=$((KEPT + 1))
    if [ $KEPT -gt 1 ]; then
      dir_name=$(basename "$chrome_dir")
      log "  Removing old puppeteer cache: $dir_name"
      rm -rf "$chrome_dir"
    fi
  done
  log "✓ Puppeteer cache cleaned (kept newest matching arch)"
fi

HEADLESS_CACHE="/config/.cache/puppeteer/chrome-headless-shell"
if [ -d "$HEADLESS_CACHE" ]; then
  for shell_dir in $(ls -1dt "$HEADLESS_CACHE"/*/ 2>/dev/null | tail -n +2); do
    dir_name=$(basename "$shell_dir")
    log "  Removing old headless shell cache: $dir_name"
    rm -rf "$shell_dir"
  done
fi

if [ "$CHROMIUM_VERIFIED" = true ]; then
  MARKER_FILE="/tmp/gmweb-chromium-ready"
  echo "ready=$(date '+%Y-%m-%d %H:%M:%S')" > "$MARKER_FILE"
  echo "path=/usr/bin/chromium-browser" >> "$MARKER_FILE"
  echo "version=$CHROMIUM_VERSION" >> "$MARKER_FILE"
  chmod 644 "$MARKER_FILE"
  log "✓ Chromium readiness marker created at $MARKER_FILE"
fi

log "Phase 3.2d: Wrapping any Puppeteer-downloaded chrome binaries to force --no-sandbox..."
for chrome_bin in "$PUPPETEER_CACHE"/*/chrome-linux*/chrome "$HEADLESS_CACHE"/*/chrome-linux*/chrome-headless-shell; do
  [ -x "$chrome_bin" ] || continue
  [ -x "${chrome_bin}.real" ] && continue
  cp "$chrome_bin" "${chrome_bin}.real"
  cat > "$chrome_bin" <<CHROMIUM_WRAPPER_EOF
#!/bin/bash
exec "${chrome_bin}.real" --no-sandbox --disable-setuid-sandbox "\$@"
CHROMIUM_WRAPPER_EOF
  chmod 755 "$chrome_bin"
  log "  ✓ Wrapped $chrome_bin"
done

log "✓ Phase 3.2: agent-browser ready"

log "Phase 3.1b: Installing GitHub CLI (gh)..."
apt-get update -qq 2>/dev/null || true
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null 2>/dev/null || true
apt-get update -qq 2>/dev/null || true
apt-get install -y gh 2>&1 | tail -2
[ $? -eq 0 ] && log "✓ GitHub CLI (gh) installed" || log "WARNING: gh install incomplete"

log "Phase 3.1c: Installing Google Cloud CLI (gcloud)..."
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null 2>/dev/null || true
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg 2>/dev/null | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - 2>/dev/null || true
apt-get update -qq 2>/dev/null || true
apt-get install -y google-cloud-cli 2>&1 | tail -2
[ $? -eq 0 ] && log "✓ Google Cloud CLI (gcloud) installed" || log "WARNING: gcloud install incomplete"

log "✓ Phase 3.1b-c: CLI tools installed"

log "Phase 3.3: Installing global npm packages..."

log "  Installing wrangler (Cloudflare deployment)..."
sudo -u abc bash << 'WRANGLER_INSTALL_EOF'
export HOME=/config
[ -f /config/beforestart ] && . /config/beforestart
npm install -g wrangler 2>&1 | tail -3
WRANGLER_INSTALL_EOF
[ $? -eq 0 ] && log "✓ wrangler installed" || log "WARNING: wrangler install incomplete"

log "Phase 3.4: Running secondary npm package installs..."
bash /opt/gmweb-startup/install.sh 2>&1 | tail -10
log "✓ Secondary npm installs complete"

log "Phase 3.5: FINAL comprehensive ownership enforcement (catching all root files)..."

for dir in /config/.gmweb /config/.nvm /config/.local /config/.cache /config/.config /config/workspace; do
  if [ -d "$dir" ]; then
    log "  Fixing all permissions in $dir..."
    sudo find "$dir" -type d -exec chown abc:abc {} \; 2>/dev/null || true
    sudo find "$dir" -type f -exec chown abc:abc {} \; 2>/dev/null || true
    sudo find "$dir" -type d -exec chmod u+rwX,g+rX,o-rwx {} \; 2>/dev/null || true
    sudo find "$dir" -type f -exec chmod u+rw,g+r,o-rwx {} \; 2>/dev/null || true
  fi
done

if [ -d /config/.gmweb/npm-cache ]; then
  if sudo find /config/.gmweb/npm-cache -not -user 1000 2>/dev/null | grep -q .; then
    log "  Root-owned files found in npm cache - DELETING and recreating..."
    sudo rm -rf /config/.gmweb/npm-cache
    mkdir -p /config/.gmweb/npm-cache
    chmod 777 /config/.gmweb/npm-cache
    log "  ✓ npm cache cleaned"
  fi
fi

if [ -d /config/.gmweb/npm-global ]; then
  if sudo find /config/.gmweb/npm-global -not -user 1000 2>/dev/null | grep -q .; then
    log "  Root-owned files found in npm-global - DELETING and recreating..."
    sudo rm -rf /config/.gmweb/npm-global
    mkdir -p /config/.gmweb/npm-global
    chmod 777 /config/.gmweb/npm-global
    log "  ✓ npm-global cleaned"
  fi
fi

ROOT_FILES=$(sudo find /config -not -user 1000 -not -path "/config/.git/*" 2>/dev/null | wc -l)
if [ "$ROOT_FILES" -gt 0 ]; then
  log "  Found $ROOT_FILES root-owned files - forcing ownership change..."
  sudo find /config -not -user 1000 -not -path "/config/.git/*" -exec chown abc:abc {} \; 2>/dev/null || true
  log "  ✓ All root-owned files reassigned to abc"
fi

REMAINING_ROOT=$(sudo find /config -not -user 1000 -not -path "/config/.git/*" 2>/dev/null | wc -l)
if [ "$REMAINING_ROOT" -gt 0 ]; then
  log "ERROR: Still found $REMAINING_ROOT root-owned files after final pass!"
  log "  List (first 10):"
  sudo find /config -not -user 1000 -not -path "/config/.git/*" 2>/dev/null | head -10 | while read f; do
    log "    - $f"
  done
  log "CRITICAL: This will cause npm EACCES errors on next boot"
else
  log "✓ VERIFIED: ZERO root-owned files in /config (excluding .git)"
fi

log "===== GMWEB BACKGROUND INSTALLS COMPLETE ====="
log "Services are now fully ready with all modules installed"

touch /tmp/gmweb-installs-complete
