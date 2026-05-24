# Deploy Private Messenger v2 — Push Notifications

## Server: 91.84.127.122 (root)

## 1. Push Gateway

Скопировать на сервер и запустить:

```bash
# На сервере:
cd /opt/messenger-server

# Создать папку push-gateway
mkdir -p push-gateway

# Скопировать push-gateway.tar.gz, распаковать
cd push-gateway
tar -xzf ../push-gateway.tar.gz
npm install --omit=dev

# Обновить docker-compose.yml
# Добавить сервис push-gateway из deploy/docker-compose.yml

# Обновить Caddyfile
# Добавить route для /gw/* из deploy/Caddyfile

# Пересобрать и запустить
docker compose build push-gateway
docker compose up -d push-gateway
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## 2. Flutter Web App

```bash
# На сервере:
cd /opt/messenger-server

# Остановить nginx, скопировать сборку
docker compose stop nginx

# Распаковать private-messenger-web.tar.gz в папку сайта
tar -xzf private-messenger-web.tar.gz -C /path/to/web/root

# Запустить
docker compose start nginx
```

## 3. Проверка

- https://app.xemooll.ru/gw/health — должен вернуть JSON с VAPID ключом
- Открыть PWA на iPhone, перелогиниться
- Проверить что push уведомления приходят
