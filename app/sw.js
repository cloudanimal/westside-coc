// Westside Members — minimal service worker
// Goal: make the app installable + give an offline fallback for the shell.
// Strategy: network-first for the app's own pages; never intercept Supabase,
// fonts, tiles, or other cross-origin/API traffic.
const CACHE = "westside-app-v1";
const SHELL = ["./", "./index.html", "./help.html", "./privacy.html"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  // Only handle our own same-origin app pages; let everything else (Supabase,
  // fonts, Leaflet CDN, map tiles) go straight to the network untouched.
  if (url.origin !== self.location.origin || !url.pathname.startsWith("/app/")) return;

  e.respondWith(
    fetch(req)
      .then((res) => {
        // Update the cached copy of shell pages when online.
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(req).then((hit) => hit || caches.match("./index.html")))
  );
});
