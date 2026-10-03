#!/bin/bash
set -e

WEBTOP_USER="abc"

log() {
  echo "[gmweb-install] $@"
}

log "===== GMWEB INSTALL START $(date) ====="

log "Installing system packages..."

echo "${WEBTOP_USER} ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers > /dev/null
sudo apt --fix-broken install -y 2>/dev/null || true
sudo dpkg --configure -a 2>/dev/null || true
sudo apt update

sudo apt-get install -y --no-install-recommends \
  curl bash git build-essential ca-certificates jq wget \
  software-properties-common apt-transport-https gnupg openssh-server \
  openssh-client tmux lsof \
  scrot xclip \
  libgbm1 libgtk-3-0 libnss3 libxss1 libasound2t64 libatk-bridge2.0-0 \
  libdrm2 libxcomposite1 libxdamage1 libxrandr2

sudo rm -rf /var/lib/apt/lists/*
log "✓ System packages installed"

log "Configuring SSH..."

sudo mkdir -p /run/sshd

sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
if ! grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config; then
  sudo bash -c 'echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config'
fi

sudo sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true

sudo sed -i 's/^UsePAM yes/UsePAM no/' /etc/ssh/sshd_config || true
if ! grep -q '^UsePAM no' /etc/ssh/sshd_config; then
  sudo bash -c 'echo "UsePAM no" >> /etc/ssh/sshd_config'
fi

sudo /usr/bin/ssh-keygen -A

echo "${WEBTOP_USER}:abc" | sudo chpasswd

log "✓ SSH configured"

log "Installing GitHub CLI..."

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt-get install -y --no-install-recommends gh
sudo rm -rf /var/lib/apt/lists/*

log "✓ GitHub CLI installed"

log "Configuring tmux..."

sudo printf 'set -g history-limit 2000\nset -g terminal-overrides "xterm*:smcup@:rmcup@"\nset-option -g allow-rename off\nset-option -g set-titles on\n' | sudo tee /etc/tmux.conf > /dev/null

log "✓ Global tmux configured (user config at boot time)"

log "Downloading ProxyPilot..."

ARCH=$(uname -m)
TARGETARCH=$([ "$ARCH" = "x86_64" ] && echo "amd64" || echo "arm64")

DOWNLOAD_URL=$(curl -s https://api.github.com/repos/Finesssee/ProxyPilot/releases/latest | \
  jq -r ".assets[] | select(.name | contains(\"linux-${TARGETARCH}\")) | .browser_download_url" | head -1)

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
  log "GitHub API failed, trying direct download..."
  DOWNLOAD_URL="https://github.com/Finesssee/ProxyPilot/releases/latest/download/proxypilot-linux-${TARGETARCH}"
fi

log "Downloading from: $DOWNLOAD_URL"
if curl -fL -o /tmp/proxypilot "$DOWNLOAD_URL" 2>/dev/null; then
  sudo mv /tmp/proxypilot /usr/bin/proxypilot
  sudo chmod +x /usr/bin/proxypilot
  log "✓ ProxyPilot installed"
else
  log "WARNING: ProxyPilot download failed - service will be unavailable"
fi

log "ProxyPilot configuration will be set up at runtime"

log "Downloading ttyd (web terminal)..."

ARCH=$(uname -m)
TTYD_ARCH=$([ "$ARCH" = "x86_64" ] && echo "x86_64" || echo "aarch64")

TTYD_URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${TTYD_ARCH}"
log "Downloading ttyd from: $TTYD_URL"

TTYD_RETRY=3
TTYD_DOWNLOADED=0
while [ $TTYD_RETRY -gt 0 ] && [ $TTYD_DOWNLOADED -eq 0 ]; do
  if timeout 60 curl -fL --max-redirs 5 -o /tmp/ttyd "$TTYD_URL" 2>/dev/null && [ -f /tmp/ttyd ] && [ -s /tmp/ttyd ]; then
    TTYD_DOWNLOADED=1
  else
    TTYD_RETRY=$((TTYD_RETRY - 1))
    if [ $TTYD_RETRY -gt 0 ]; then
      log "ttyd download attempt failed, retrying ($TTYD_RETRY left)..."
      sleep 5
    fi
  fi
done

if [ $TTYD_DOWNLOADED -eq 1 ]; then
  sudo mv /tmp/ttyd /usr/bin/ttyd
  sudo chmod +x /usr/bin/ttyd
  log "✓ ttyd installed"
else
  log "WARNING: ttyd download failed after retries - webssh2 will be unavailable"
  rm -f /tmp/ttyd
fi

log "Permissions are set at boot time by custom_startup.sh"

log "NHFS will be run via npx at startup (no pre-build needed)"
log "✓ NHFS HTTP file server ready to launch"

log "===== GMWEB INSTALL COMPLETE $(date) ====="
exit 0
