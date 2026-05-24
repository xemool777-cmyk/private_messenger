// Service Worker for Private Messenger PWA
// Handles push notifications and caching

const CACHE_NAME = 'private-messenger-v2';

self.addEventListener('install', (event) => {
  console.log('[SW] Install');
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  console.log('[SW] Activate');
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.filter((name) => name !== CACHE_NAME).map((name) => caches.delete(name))
      );
    }).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  // Network-first strategy for API calls, cache-first for static assets
  const url = new URL(event.request.url);

  if (url.pathname.startsWith('/_matrix/')) {
    // API requests: network only (don't cache API)
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cachedResponse) => {
      if (cachedResponse) return cachedResponse;
      return fetch(event.request).then((response) => {
        if (response.ok && event.request.method === 'GET') {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => {
            cache.put(event.request, clone);
          });
        }
        return response;
      }).catch(() => {
        return new Response('Offline', { status: 503 });
      });
    })
  );
});

// Handle push notifications from Push Gateway
self.addEventListener('push', (event) => {
  console.log('[SW] Push received:', event);
  let data = { title: 'Новое сообщение', body: 'У вас новое сообщение в Private Messenger' };

  if (event.data) {
    try {
      data = event.data.json();
    } catch (e) {
      data.body = event.data.text();
    }
  }

  const notificationData = {
    body: data.body,
    icon: '/icons/Icon-192.png',
    badge: '/icons/Icon-192.png',
    tag: data.room_id || data.roomId || 'default',
    vibrate: [200, 100, 200],
    data: {
      room_id: data.room_id || data.roomId || '',
      event_id: data.event_id || '',
      unread: data.unread || 0,
    },
  };

  event.waitUntil(
    self.registration.showNotification(data.title, notificationData)
  );
});

// Handle notification click — open the room
self.addEventListener('notificationclick', (event) => {
  console.log('[SW] Notification click:', event);
  event.notification.close();

  const roomId = event.notification.data?.room_id || '';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes(self.location.origin) && 'focus' in client) {
          // Send room ID to the Flutter client if we have it
          if (roomId && client.postMessage) {
            client.postMessage({ type: 'open_room', room_id: roomId });
          }
          return client.focus();
        }
      }
      // Open new window with room parameter
      const url = roomId ? '/?room=' + encodeURIComponent(roomId) : '/';
      return self.clients.openWindow(url);
    })
  );
});
