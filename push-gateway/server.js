const express = require('express');
const webpush = require('web-push');

const app = express();
app.use(express.json());

// ─── VAPID ───
const VAPID_PUBLIC_KEY = process.env.VAPID_PUBLIC_KEY;
const VAPID_PRIVATE_KEY = process.env.VAPID_PRIVATE_KEY;
const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:admin@xemooll.ru';

if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) {
  console.error('FATAL: VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY must be set');
  process.exit(1);
}

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

// ─── Хранилище подписок (Map: pushkey → subscription) ───
const subscriptions = new Map();

// ─── VAPID Public Key endpoint (для клиента) ───
app.get('/vapid-public-key', (_req, res) => {
  res.json({ publicKey: VAPID_PUBLIC_KEY });
});

// ─── Регистрация подписки от Flutter ───
app.post('/register', (req, res) => {
  const { pushkey, subscription } = req.body;
  if (!pushkey || !subscription || !subscription.endpoint) {
    return res.status(400).json({ error: 'Missing pushkey or subscription' });
  }
  subscriptions.set(pushkey, subscription);
  console.log(`[REGISTER] pushkey=${pushkey.substring(0, 40)}... (total: ${subscriptions.size})`);
  res.json({ success: true });
});

// ─── Удаление подписки ───
app.post('/unregister', (req, res) => {
  const { pushkey } = req.body;
  if (pushkey) {
    subscriptions.delete(pushkey);
    console.log(`[UNREGISTER] removed (total: ${subscriptions.size})`);
  }
  res.json({ success: true });
});

// ─── Matrix Push Gateway API (вызывается Conduit) ───
app.post('/_matrix/push/v1/notify', async (req, res) => {
  const { notification } = req.body;
  if (!notification) {
    return res.status(400).json({ rejected: [] });
  }

  const pushkey = notification.devices?.[0]?.pushkey;
  if (!pushkey) {
    console.warn('[NOTIFY] No pushkey');
    return res.json({ rejected: [] });
  }

  const subscription = subscriptions.get(pushkey);
  if (!subscription) {
    console.warn(`[NOTIFY] Unknown pushkey: ${pushkey.substring(0, 40)}...`);
    return res.json({ rejected: [pushkey] });
  }

  // Формируем payload
  const sender = notification.sender_display_name ||
    (notification.sender ? notification.sender.split(':')[0].replace('@', '') : 'Кто-то');
  const roomName = notification.room_name || notification.room_alias || 'Чат';

  let body = '';
  if (notification.content?.body) {
    switch (notification.content.msgtype) {
      case 'm.image': body = '📷 Фото'; break;
      case 'm.file':  body = '📎 Файл'; break;
      case 'm.audio': body = '🎵 Аудио'; break;
      case 'm.video': body = '🎬 Видео'; break;
      default:        body = notification.content.body;
    }
  } else {
    body = 'Новое сообщение';
  }

  const payload = JSON.stringify({
    title: `${sender} • ${roomName}`,
    body: body,
    tag: notification.room_id || 'default',
    room_id: notification.room_id,
    event_id: notification.event_id,
    unread: notification.counts?.unread || 0,
  });

  try {
    await webpush.sendNotification(subscription, payload, {
      TTL: 86400,
      urgency: 'high',
    });
    console.log(`[PUSH] Sent to ${pushkey.substring(0, 40)}... room=${notification.room_id?.substring(0, 20)}...`);
    res.json({ rejected: [] });
  } catch (err) {
    console.error(`[PUSH] Error: ${err.statusCode} ${err.message}`);
    if (err.statusCode === 410) {
      subscriptions.delete(pushkey);
    }
    res.json({ rejected: [pushkey] });
  }
});

// ─── Health ───
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    subscriptions: subscriptions.size,
    vapidPublicKey: VAPID_PUBLIC_KEY,
  });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`[Push Gateway] Running on :${PORT}`);
  console.log(`[Push Gateway] VAPID public key: ${VAPID_PUBLIC_KEY}`);
});
