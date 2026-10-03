#!/bin/bash

set +e

SELKIES_RUN="/etc/s6-overlay/s6-rc.d/svc-selkies/run"

if [ ! -f "$SELKIES_RUN" ]; then
  echo "[patch-selkies] ERROR: Selkies s6-rc service not found at $SELKIES_RUN"
  exit 1
fi

cp "$SELKIES_RUN" "$SELKIES_RUN.backup" 2>/dev/null || true

sed -i 's/--mode="webrtc"/--mode="websockets"/g' "$SELKIES_RUN"

if grep -q 'mode="websockets"' "$SELKIES_RUN"; then
  echo "[patch-selkies] Selkies confirmed in WebSocket mode"
  exit 0
else
  echo "[patch-selkies] ERROR: Failed to confirm Selkies WebSocket mode"
  exit 1
fi
