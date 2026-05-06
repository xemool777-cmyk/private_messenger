#!/bin/sh
# entrypoint.sh — Подмена переменных окружения при запуске контейнера
# Позволяет задавать HOMESERVER_URL через docker-compose без пересборки

if [ -n "$HOMESERVER_URL" ]; then
  echo "[ENTRYPOINT] Setting HOMESERVER_URL=$HOMESERVER_URL"

  # Создаём config.js который читается приложением
  cat > /usr/share/nginx/html/config.js <<EOF
// Auto-generated configuration
window.__APP_CONFIG = {
  homeserverUrl: "$HOMESERVER_URL",
  serverName: "$(echo $HOMESERVER_URL | sed 's|https\?://||' | sed 's|/.*||')"
};
EOF
else
  echo "[ENTRYPOINT] HOMESERVER_URL not set, using default: https://xemooll.ru"
  cat > /usr/share/nginx/html/config.js <<EOF
// Auto-generated configuration (defaults)
window.__APP_CONFIG = {
  homeserverUrl: "https://xemooll.ru",
  serverName: "xemooll.ru"
};
EOF
fi

echo "[ENTRYPOINT] Starting nginx..."
exec "$@"
