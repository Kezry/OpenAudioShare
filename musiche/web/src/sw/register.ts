let swRegistration: ServiceWorkerRegistration | null = null;
export function getServiceWorkerRegistration(): ServiceWorkerRegistration | null {
  return swRegistration;
}
export async function registerServiceWorker() {
  // Vendored build: the player is served by the phone itself over LAN, so a
  // cache-first service worker only causes harm - it keeps serving the old UI
  // after an APK upgrade and stale proxied API responses, and its cache
  // ('musiche-cache') is never invalidated upstream. The embedded WebView
  // never supported service workers anyway. Unregister anything left behind
  // by older builds and drop that cache.
  if ('serviceWorker' in navigator) {
    try {
      const registrations = await navigator.serviceWorker.getRegistrations();
      for (let registration of registrations) {
        await registration.unregister();
      }
      if (typeof caches !== 'undefined') {
        await caches.delete('musiche-cache');
      }
    } catch (error) {
      console.error('service worker cleanup failed:', error);
    }
  }
}
