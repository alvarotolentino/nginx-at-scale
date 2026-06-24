// k6 static UI mix — equivalent of benchmarks/wrk/browse-ui.lua for testers without wrk.
// Every request is served by nginx directly (SPA routes + hashed asset bundles).
// No backend involvement — this stresses nginx + kernel, not Axum/lux.
//
// Env vars (all optional):
//   BASE_URL     target origin          (default: http://localhost)
//   UI_PATHS     comma-separated path@weight entries discovered at runtime by
//                load-test-bombardier.sh (e.g. "/@8,/cart@8,/assets/vendor.js@1")
//   K6_VUS       concurrent VUs         (default: 400)
//   K6_DURATION  test duration string   (default: 30s)

import http from 'k6/http';
import { check } from 'k6';

const BASE     = __ENV.BASE_URL    || 'http://localhost';
const VUS      = parseInt(__ENV.K6_VUS      || '400', 10);
const DURATION = __ENV.K6_DURATION || '30s';

// Build weighted pool from UI_PATHS — same @weight syntax as browse-ui.lua.
// SPA routes weighted 8x over asset bundles so we measure connection concurrency,
// not bandwidth (a 140 KB vendor bundle every 6th req turns this into a BW test).
function buildPool() {
  const raw = __ENV.UI_PATHS || '/@8,/cart@8';
  const pool = [];
  for (const entry of raw.split(',')) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const m = trimmed.match(/^(.+)@(\d+)$/);
    const path   = m ? m[1] : trimmed;
    const weight = m ? parseInt(m[2], 10) : 1;
    for (let i = 0; i < weight; i++) pool.push(path);
  }
  return pool.length ? pool : ['/'];
}

const pool = buildPool();

export const options = {
  vus:      VUS,
  duration: DURATION,
  insecureSkipTLSVerify: true,
  thresholds: {
    http_req_duration: ['p(99)<500'],
    http_req_failed:   ['rate<0.01'],
  },
};

let _idx = 0;   // per-VU counter — k6 VU contexts are isolated, so no race
export default function () {
  const path = pool[_idx++ % pool.length];
  const res  = http.get(`${BASE}${path}`, { tags: { type: 'static' } });
  check(res, { '2xx': (r) => r.status >= 200 && r.status < 300 });
}
