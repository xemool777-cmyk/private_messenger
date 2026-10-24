// Service worker PWA для private_messenger.
// Flutter >= 3.41 генерирует flutter_service_worker.js, который при активации сам себя
// отменяет (unregister) — поэтому оболочка приложения кэшируется здесь.
//
// Стратегия:
//  - установка: precache оболочки (index, bootstrap, main.dart.js, manifest, иконки)
//  - навигация: network-first с фолбэком на кэшированный index.html (офлайн-старт)
//  - статика (assets/, canvaskit/, иконки): cache-first с фоновым обновлением

const VERSION = 'v2';
const SHELL_CACHE = `shell-${VERSION}`;
const RUNTIME_CACHE = `runtime-${VERSION}`;

const SHELL_ASSETS = [
  './',
  './index.html',
  './manifest.json',
  './flutter_bootstrap.js',
  './main.dart.js',
  './icons/Icon-192.png',
  './icons/Icon-512.png',
];

// Точка входа НИКОГДА не отдаётся из кэша первой: после пересборки имя main.dart.js
// не меняется, и cache-first показал бы старую сборку поверх нового index.html
// (пустой экран). Эти пути всегда берутся из сети с фолбэком на кэш.
const NETWORK_FIRST = ['./', './index.html', './main.dart.js', './flutter_bootstrap.js', './version.json'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(SHELL_CACHE);
      // каждый файл кладём отдельно: отсутствие одного не рушит установку
      await Promise.all(
        SHELL_ASSETS.map(async (url) => {
          try {
            await cache.add(new Request(url, { cache: 'reload' }));
          } catch (e) {
            console.warn('[sw] не удалось закэшировать', url, e);
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((k) => k !== SHELL_CACHE && k !== RUNTIME_CACHE)
          .map((k) => caches.delete(k)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Навигация: сеть, при отсутствии — оболочка из кэша (офлайн)
  if (req.mode === 'navigate') {
    event.respondWith(
      (async () => {
        try {
          const fresh = await fetch(req);
          const cache = await caches.open(SHELL_CACHE);
          cache.put('./index.html', fresh.clone());
          return fresh;
        } catch (e) {
          const cache = await caches.open(SHELL_CACHE);
          return (
            (await cache.match('./index.html')) ||
            (await cache.match('./')) ||
            new Response('Офлайн: оболочка PWA не закэширована', {
              status: 503,
              headers: { 'Content-Type': 'text/plain; charset=utf-8' },
            })
          );
        }
      })(),
    );
    return;
  }

  // Точка входа (index, bootstrap, main.dart.js): сеть, при неудаче — кэш
  const rel = './' + url.pathname.replace(/^\/+/, '');
  if (url.pathname === '/' || NETWORK_FIRST.includes(rel)) {
    event.respondWith(
      (async () => {
        try {
          const fresh = await fetch(req);
          if (fresh && fresh.ok) {
            const cache = await caches.open(SHELL_CACHE);
            cache.put(req, fresh.clone());
          }
          return fresh;
        } catch (e) {
          return (
            (await caches.match(req)) ||
            (await caches.match('./index.html')) ||
            new Response('Офлайн', { status: 504 })
          );
        }
      })(),
    );
    return;
  }

  // Статика: кэш, затем сеть (и кладём в runtime-кэш)
  event.respondWith(
    (async () => {
      const cached = await caches.match(req);
      if (cached) {
        // фоновое обновление, не блокируя ответ
        fetch(req)
          .then(async (fresh) => {
            if (fresh && fresh.ok) {
              const cache = await caches.open(RUNTIME_CACHE);
              cache.put(req, fresh.clone());
            }
          })
          .catch(() => {});
        return cached;
      }
      try {
        const fresh = await fetch(req);
        if (fresh && fresh.ok) {
          const cache = await caches.open(RUNTIME_CACHE);
          cache.put(req, fresh.clone());
        }
        return fresh;
      } catch (e) {
        return new Response('', { status: 504 });
      }
    })(),
  );
});
