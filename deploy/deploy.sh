#!/bin/bash
# Deploy script for Private Messenger Push Gateway
# Run this on the server (91.84.127.122) as root

set -e

SERVER_DIR="/opt/messenger-server"
PUSH_DIR="$SERVER_DIR/push-gateway"

echo "=== Deploying Push Gateway ==="

# 1. Ensure directories exist
mkdir -p "$PUSH_DIR"

# 2. Copy push gateway files
if [ -d "./push-gateway" ]; then
  cp -r ./push-gateway/* "$PUSH_DIR/"
  echo "[OK] Push gateway files copied"
else
  echo "[ERROR] push-gateway directory not found"
  exit 1
fi

# 3. Copy docker-compose and Caddyfile
cp ./docker-compose.yml "$SERVER_DIR/docker-compose.yml"
cp ./Caddyfile "$SERVER_DIR/Caddyfile"
echo "[OK] Configs copied"

# 4. Rebuild and restart services
cd "$SERVER_DIR"
docker compose build push-gateway
docker compose up -d push-gateway
echo "[OK] Push Gateway started"

# 5. Reload Caddy if running
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || \
  docker compose restart caddy
echo "[OK] Caddy reloaded"

echo "=== Deploy Complete ==="
echo "Push Gateway: https://app.xemooll.ru/gw/health"
