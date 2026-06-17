// k6 stress test: find the concurrency ceiling.
// Ramps 1k → 10k → 50k → 100k VUs (2 minutes per stage). Each VU issues the
// lowest-overhead request (GET /, static) so the test isolates connection handling
// rather than backend/JSON cost. Records the stage where error rate exceeds 1%.
//
// Thresholds are intentionally lax so the test runs to completion past saturation
// (we want to OBSERVE the ceiling, not abort at it).

import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost';
const errorRate = new Rate('ceiling_errors');

export const options = {
  stages: [
    { duration: '2m', target: 1000 },
    { duration: '2m', target: 10000 },
    { duration: '2m', target: 50000 },
    { duration: '2m', target: 100000 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    // Lax: abort only at total collapse, so we can see where 1% is crossed.
    http_req_failed: ['rate<0.95'],
  },
};

export default function () {
  const res = http.get(`${BASE}/`, { tags: { type: 'static' } });
  const ok = check(res, { 'static 200': (r) => r.status === 200 });
  errorRate.add(!ok);
}

// After the run, inspect the per-stage `ceiling_errors` rate in the k6 summary /
// JSON output: the first VU stage where it exceeds 0.01 (1%) is your ceiling.
