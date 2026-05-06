# ============================================
# Stage 1: Build Flutter web
# ============================================
FROM ubuntu:22.04 AS builder

# Устанавливаем зависимости
RUN apt-get update && apt-get install -y \
    curl git unzip xz-utils zip \
    && rm -rf /var/lib/apt/lists/*

# Устанавливаем Flutter 3.24.5 (Dart 3.5+ — соответствует SDK >=3.2.0)
ENV FLUTTER_VERSION=3.24.5
RUN git clone https://github.com/flutter/flutter.git -b ${FLUTTER_VERSION} --depth 1 /sdks/flutter
ENV PATH="/sdks/flutter/bin:/sdks/flutter/bin/cache/dart-sdk/bin:${PATH}"

# Преднастраиваем Flutter (принимаем лицензии, скачиваем SDK)
RUN flutter config --no-analytics \
    && flutter precache --web \
    && flutter doctor

WORKDIR /app

# Кэшируем зависимости
COPY pubspec.yaml ./
RUN flutter pub get

# Если pubspec.lock существует — копируем для детерминистичной сборки
# Если нет — используем свежеразрешённые зависимости (ок для dev)
COPY pubspec.lock* ./
RUN flutter pub get 2>/dev/null || true

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
