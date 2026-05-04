# ============================================
# Stage 1: Build Flutter web
# ============================================
FROM cirrusci/flutter:stable AS builder

WORKDIR /app

# Кэшируем зависимости
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# Копируем исходники
COPY . .

# Собираем веб-версию
# HOMESERVER_URL можно передать через --build-arg
ARG HOMESERVER_URL=https://xemooll.ru
RUN flutter build web \
    --dart-define=HOMESERVER_URL=$HOMESERVER_URL \
    --release \
    --no-tree-shake-icons

# ============================================
# Stage 2: Nginx для раздачи статики
# ============================================
FROM nginx:alpine

# Удаляем дефолтный конфиг
RUN rm /etc/nginx/conf.d/default.conf

# Копируем свой конфиг nginx
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf

# Копируем собранный билд из Stage 1
COPY --from=builder /app/build/web /usr/share/nginx/html

# Копируем скрипт подмены env-переменных при запуске
COPY deploy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
