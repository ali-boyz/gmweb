#!/bin/bash
set -o pipefail
HOME_DIR="${HOME:-/config}"
LOG_DIR="$HOME_DIR/logs"
if [ -f "$HOME_DIR/beforestart" ]; then
  . "$HOME_DIR/beforestart"
else
  echo "ERROR: beforestart hook not found at $HOME_DIR/beforestart"
  exit 1
fi

if [ -z "$(command -v node)" ]; then
  echo "ERROR: Node.js not found in PATH after sourcing gmweb environment"
  exit 1
fi

if ! command -v bunx &>/dev/null; then
  if ! command -v bun &>/dev/null; then
    echo "ERROR: bunx and bun not available in PATH"
    echo "ERROR: BUN_INSTALL=$BUN_INSTALL"
    echo "ERROR: PATH=$PATH"
    exit 1
  fi
  BUN_PATH=$(command -v bun)
  BUN_DIR=$(dirname "$BUN_PATH")
  ln -sf "$BUN_PATH" "$BUN_DIR/bunx" 2>/dev/null || true
fi

SUPERVISOR_LOG="$LOG_DIR/supervisor.log"
NODE_BIN="$(which node)"

if [ -z "$PASSWORD" ]; then
  echo "WARNING: PASSWORD not set, using fallback 'password'"
  export PASSWORD="password"
fi

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
if [ "$(id -u)" = "0" ]; then
  chown -R abc:abc "$LOG_DIR"
fi

BOOT_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[start.sh] === STARTUP DIAGNOSTICS (Boot: $BOOT_TIMESTAMP) ==="
echo "[start.sh] HOME_DIR=$HOME_DIR"
echo "[start.sh] LOG_DIR=$LOG_DIR"
echo "[start.sh] NODE_BIN=$NODE_BIN (exists: $([ -f "$NODE_BIN" ] && echo YES || echo NO))"
echo "[start.sh] supervisor index.js (exists: $([ -f /opt/gmweb-startup/index.js ] && echo YES || echo NO))"
echo "[start.sh] nginx status (running: $(pgrep -c nginx >/dev/null && echo YES || echo NO))"
echo "[start.sh] config.json (exists: $([ -f /opt/gmweb-startup/config.json ] && echo YES || echo NO))"

BUNX_PATH=$(command -v bunx 2>/dev/null || echo "NOT FOUND")
BUN_PATH=$(command -v bun 2>/dev/null || echo "NOT FOUND")
echo "[start.sh] bunx=$BUNX_PATH"
echo "[start.sh] bun=$BUN_PATH"
if [ "$BUNX_PATH" = "NOT FOUND" ] && [ "$BUN_PATH" = "NOT FOUND" ]; then
  echo "[start.sh] ERROR: bunx and bun are NOT available!"
  echo "[start.sh] BUN_INSTALL=$BUN_INSTALL"
  echo "[start.sh] PATH=$PATH"
else
  echo "[start.sh] ✓ bunx/bun available for services"
fi
echo "[start.sh] === STARTING SUPERVISOR ==="

export NODE_OPTIONS="--no-warnings"

start_supervisor() {
  if command -v stdbuf &> /dev/null; then
    stdbuf -oL -eL "$NODE_BIN" /opt/gmweb-startup/index.js >> "$SUPERVISOR_LOG" 2>&1 &
  else
    "$NODE_BIN" /opt/gmweb-startup/index.js >> "$SUPERVISOR_LOG" 2>&1 &
  fi
  echo $!
}

SUPERVISOR_PID=$(start_supervisor)

(
  WATCHDOG_PID_FILE="$LOG_DIR/.supervisor.pid"
  echo $SUPERVISOR_PID > "$WATCHDOG_PID_FILE"
  echo "[watchdog] Started, monitoring supervisor PID $SUPERVISOR_PID" >> "$SUPERVISOR_LOG"
  while true; do
    sleep 10
    CURRENT_PID=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
    if [ -n "$CURRENT_PID" ] && ! kill -0 "$CURRENT_PID" 2>/dev/null; then
      echo "[watchdog] [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Supervisor (PID $CURRENT_PID) died, restarting..." >> "$SUPERVISOR_LOG"
      NEW_PID=$(start_supervisor)
      echo $NEW_PID > "$WATCHDOG_PID_FILE"
      echo "[watchdog] [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Supervisor restarted with PID $NEW_PID" >> "$SUPERVISOR_LOG"
      sleep 15
    fi
  done
) &

echo "[start.sh] Supervisor PID: $SUPERVISOR_PID"
echo "[start.sh] Supervisor log: $SUPERVISOR_LOG"

sleep 3

if [ -f "$SUPERVISOR_LOG" ]; then
  TOTAL_LINES=$(wc -l < "$SUPERVISOR_LOG")
  echo "[start.sh] === SUPERVISOR LOG (last 50 lines of $TOTAL_LINES total) ==="
  tail -50 "$SUPERVISOR_LOG"
  echo "[start.sh] === END LOG ==="
else
  echo "[start.sh] WARNING: No supervisor log file found yet"
fi

sleep 5
if kill -0 $SUPERVISOR_PID 2>/dev/null; then
  echo "[start.sh] ✓ Supervisor is RUNNING (PID: $SUPERVISOR_PID)"

    sleep 8

    NGINX_CHECK_ATTEMPTS=0
    NGINX_LISTENING=false
    while [ $NGINX_CHECK_ATTEMPTS -lt 5 ]; do
      if command -v ss &> /dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":80.*LISTEN"; then
          echo "[start.sh] ✓ nginx is LISTENING on port 80"
          NGINX_LISTENING=true
          break
        fi
      fi
      NGINX_CHECK_ATTEMPTS=$((NGINX_CHECK_ATTEMPTS + 1))
      if [ $NGINX_CHECK_ATTEMPTS -lt 5 ]; then
        sleep 1
      fi
    done

    if [ "$NGINX_LISTENING" = false ]; then
      echo "[start.sh] ⚠ nginx NOT yet detected listening on port 80 (may still be initializing)"
    fi
else
  echo "[start.sh] ✗ Supervisor exited (check logs)"
  [ -f "$SUPERVISOR_LOG" ] && tail -50 "$SUPERVISOR_LOG"
fi

echo "[start.sh] === STARTUP COMPLETE ==="
exit 0
