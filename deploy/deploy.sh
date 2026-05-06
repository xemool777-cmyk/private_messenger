#!/bin/bash
# ============================================
# Деплой Private Messenger на удалённый сервер
# Использование: ./deploy/deploy.sh [server_ip_or_domain]
# ============================================

set -e

SERVER="${1:-xemooll.ru}"
SSH_USER="${2:-root}"
REMOTE_DIR="/opt/private_messenger"

echo "============================================"
echo "  Private Messenger — Деплой на $SERVER"
echo "============================================"

# 1. Пушим в GitHub
echo ""
echo "[1/4] Pushing to GitHub..."
git -C "$(dirname "$0")/.." push origin main

# 2. SSH на сервер — клонируем/обновляем
echo ""
echo "[2/4] Updating repository on server..."
ssh "$SSH_USER@$SERVER" << 'REMOTE_SCRIPT'
set -e

if [ -d /opt/private_messenger ]; then
  echo "  Updating existing repo..."
  cd /opt/private_messenger
  git pull origin main
else
  echo "  Cloning repository..."
  git clone https://github.com/xemool777-cmyk/private_messenger.git /opt/private_messenger
  cd /opt/private_messenger
fi

# 3. Собираем и запускаем Docker
echo ""
echo "[3/4] Building Docker image..."
cd /opt/private_messenger
docker compose build --no-cache messenger-web

echo ""
echo "[4/4] Starting containers..."
docker compose up -d messenger-web

echo ""
echo "============================================"
echo "  Деплой завершён!"
echo "  Веб-клиент: http://$SERVER:8080"
echo "============================================"

# Показать статус
docker compose ps
docker compose logs --tail=20 messenger-web

REMOTE_SCRIPT

echo ""
echo "Готово! Проверьте http://$SERVER:8080"
