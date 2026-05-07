#!/bin/sh
# entrypoint.sh — Подмена переменных окружения при запуске контейнера
# По умолчанию используем пустой homeserverUrl — Matrix SDK
# автоматически определит текущий хост и будет ходить через тот же домен
# (app.xemooll.ru/_matrix/ → nginx proxy → xemooll.ru/_matrix/)

echo "[ENTRYPOINT] Configuring homeserver for same-origin proxy mode"

cat > /usr/share/nginx/html/config.js <<EOF
// Auto-generated configuration
// homeserverUrl пустой = Matrix SDK использует текущий хост (same-origin)
// Это нужно чтобы API запросы шли через nginx proxy, минуя Cloudflare
window.__APP_CONFIG = {
  homeserverUrl: "",
  serverName: "xemooll.ru"
};
EOF

echo "[ENTRYPOINT] Starting nginx..."
exec "$@"
