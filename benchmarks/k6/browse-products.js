// k6 scenario: a user browsing the shop.
// Ramp 10 → 1000 → 5000 VUs over 5m, hold 5000 for 10m, ramp down.
// Each VU loads the SPA, fetches the product list, opens a random product, sleeps.

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE    = __ENV.BASE_URL    || 'http://localhost';
const MAX_VUS = parseInt(__ENV.K6_MAX_VUS || '5000', 10);

export const options = {
  stages: [
    { duration: '2m',  target: Math.min(1000, MAX_VUS) },
    { duration: '3m',  target: MAX_VUS },
    { duration: '10m', target: MAX_VUS },
    { duration: '2m',  target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<200'], // p95 latency under 200ms
    http_req_failed: ['rate<0.01'], // <1% errors
  },
};

export default function () {
  // 1. Load the SPA shell (static).
  let res = http.get(`${BASE}/`, { tags: { type: 'static' } });
  check(res, { 'static 200': (r) => r.status === 200 });

  // 2. Fetch the product list (dynamic).
  res = http.get(`${BASE}/api/products`, { tags: { type: 'api-list' } });
  check(res, { 'list 200': (r) => r.status === 200 });

  // 3. Open a random product from the list.
  let products = [];
  try {
    products = res.json();
  } catch (_) {
    products = [];
  }
  if (products.length > 0) {
    const id = products[Math.floor(Math.random() * products.length)].id;
    const detail = http.get(`${BASE}/api/products/${id}`, { tags: { type: 'api-detail' } });
    check(detail, { 'detail 200': (r) => r.status === 200 });
  }

  sleep(1); // think time
}
