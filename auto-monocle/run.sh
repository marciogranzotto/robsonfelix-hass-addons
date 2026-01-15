#!/bin/bash
set -e

echo "========================================"
echo "  Auto-Monocle Add-on Starting"
echo "========================================"

CONFIG_PATH="/data/options.json"
MONOCLE_CONFIG="/etc/monocle/monocle.json"

# Read configuration
MONOCLE_TOKEN=$(jq -r '.monocle_token // ""' "$CONFIG_PATH")
AUTO_DISCOVER=$(jq -r '.auto_discover // true' "$CONFIG_PATH")
REFRESH_INTERVAL=$(jq -r '.refresh_interval // 300' "$CONFIG_PATH")

if [ -z "$MONOCLE_TOKEN" ] || [ "$MONOCLE_TOKEN" = "null" ]; then
    echo "[ERROR] Monocle token not configured!"
    echo "[ERROR] Get your token from https://monoclecam.com and add it to the add-on configuration."
    exit 1
fi

# Run camera discovery
echo "[INFO] Running camera discovery..."
python3 /opt/monocle/discover_cameras.py

if [ ! -f "$MONOCLE_CONFIG" ]; then
    echo "[ERROR] Monocle configuration not generated!"
    exit 1
fi

echo "[INFO] Monocle configuration:"
cat "$MONOCLE_CONFIG"
echo ""

# Start camera refresh in background
if [ "$AUTO_DISCOVER" = "true" ]; then
    (
        while true; do
            sleep "$REFRESH_INTERVAL"
            echo "[INFO] Refreshing camera list..."
            python3 /opt/monocle/discover_cameras.py
        done
    ) &
fi

echo "[INFO] Starting Monocle Gateway..."
echo "[INFO] Make sure port 443 is forwarded to this add-on"

# Start Monocle Gateway
cd /opt/monocle
exec ./monocle-gateway
