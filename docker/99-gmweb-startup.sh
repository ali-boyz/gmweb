#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[gmweb-init] GMWeb initialization starting at $(date)"

STARTUP_SCRIPT=""
for location in \
  "$SCRIPT_DIR/custom_startup.sh" \
  /tmp/custom_startup.sh \
  /opt/custom_startup.sh \
  /root/custom_startup.sh \
  /usr/local/bin/custom_startup.sh; do
  if [ -f "$location" ]; then
    STARTUP_SCRIPT="$location"
    break
  fi
done

if [ -z "$STARTUP_SCRIPT" ]; then
  echo "[gmweb-init] ERROR: custom_startup.sh not found in any location"
  echo "[gmweb-init] Searched: $SCRIPT_DIR, /tmp, /opt, /root, /usr/local/bin"
  exit 1
fi

echo "[gmweb-init] Found custom_startup.sh at $STARTUP_SCRIPT, executing..."
exec bash "$STARTUP_SCRIPT"
