// Push Helper for Private Messenger
// Provides JS interop functions for Flutter to register/unregister push subscriptions

const PUSH_GATEWAY_URL = 'https://app.xemooll.ru/gw';

let _swRegistration = null;
let _pushSubscription = null;

// Safe JSON parse helper — logs raw response on failure
async function safeJsonParse(response, label) {
  const rawText = await response.text();
  try {
    return JSON.parse(rawText);
  } catch (e) {
    console.error(`[PushHelper] JSON parse FAILED for ${label}: ${e.message}`);
    console.error(`[PushHelper] Raw response (first 500 chars): ${rawText.substring(0, 500)}`);
    console.error(`[PushHelper] HTTP status: ${response.status} ${response.statusText}`);
    throw e; // re-throw so caller handles fallback
  }
}

// Get VAPID public key from gateway
async function getVapidPublicKey() {
  try {
    const resp = await fetch(PUSH_GATEWAY_URL + '/vapid-public-key');
    if (!resp.ok) {
      console.warn(`[PushHelper] VAPID key fetch failed: HTTP ${resp.status}`);
      return 'BDnWyvvZ6i61MywqMP-xcMnxh_NKz8HD8-DM3oUYBV4SH6xreLshnFGloOffDFtrARm9PaQzczb8_KNCT6znHrM';
    }
    const data = await safeJsonParse(resp, 'vapid-public-key');
    return data.publicKey;
  } catch (e) {
    console.warn('[PushHelper] Cannot fetch VAPID key from gateway, using fallback');
    return 'BDnWyvvZ6i61MywqMP-xcMnxh_NKz8HD8-DM3oUYBV4SH6xreLshnFGloOffDFtrARm9PaQzczb8_KNCT6znHrM';
  }
}

// URL-safe base64 to Uint8Array (for VAPID key)
function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding)
    .replace(/\-/g, '+')
    .replace(/_/g, '/');
  const rawData = atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

// Register push subscription
async function registerPush() {
  console.log('[PushHelper] registerPush called');

  // Check if push is supported
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
    console.warn('[PushHelper] Push not supported');
    return null;
  }

  // Register service worker
  _swRegistration = await navigator.serviceWorker.register('sw.dart.js');
  console.log('[PushHelper] SW registered, scope:', _swRegistration.scope);

  // Wait for service worker to be active
  if (!_swRegistration.active) {
    await new Promise((resolve) => {
      _swRegistration.addEventListener('updatefound', () => resolve());
    });
  }

  // Request notification permission
  if (Notification.permission !== 'granted') {
    const permission = await Notification.requestPermission();
    if (permission !== 'granted') {
      console.warn('[PushHelper] Notification permission denied:', permission);
      return null;
    }
  }

  // Get VAPID key
  const vapidKey = await getVapidPublicKey();
  console.log('[PushHelper] VAPID key obtained');

  // Check existing subscription
  _pushSubscription = await _swRegistration.pushManager.getSubscription();
  if (_pushSubscription) {
    console.log('[PushHelper] Already subscribed, unsubscribing first');
    await _pushSubscription.unsubscribe();
    _pushSubscription = null;
  }

  // Subscribe
  _pushSubscription = await _swRegistration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: urlBase64ToUint8Array(vapidKey),
  });
  console.log('[PushHelper] Subscribed, endpoint:', _pushSubscription.endpoint);

  return _pushSubscription.toJSON();
}

// Send subscription to push gateway
async function sendSubscriptionToGateway(subscriptionJson) {
  console.log('[PushHelper] sendSubscriptionToGateway');
  const pushkey = subscriptionJson.endpoint;

  try {
    const resp = await fetch(PUSH_GATEWAY_URL + '/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pushkey, subscription: subscriptionJson }),
    });
    if (!resp.ok) {
      console.warn(`[PushHelper] Gateway /register returned HTTP ${resp.status}`);
    }
    const data = await safeJsonParse(resp, 'gateway-register');
    console.log('[PushHelper] Gateway response:', data);
    return data.success === true;
  } catch (e) {
    console.error('[PushHelper] Gateway error:', e);
    return false;
  }
}

// Unregister push subscription
async function unregisterPush() {
  console.log('[PushHelper] unregisterPush');

  if (_pushSubscription) {
    const pushkey = _pushSubscription.endpoint;

    await _pushSubscription.unsubscribe();
    _pushSubscription = null;

    // Notify gateway
    try {
      await fetch(PUSH_GATEWAY_URL + '/unregister', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pushkey }),
      });
    } catch (e) {
      console.warn('[PushHelper] Unregister gateway error:', e);
    }
  }

  if (_swRegistration) {
    await _swRegistration.unregister();
    _swRegistration = null;
  }
}
