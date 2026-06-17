// k6 scenario: add-to-cart flow.
// Constant 500 VUs for 5 minutes.
//
// NOTE: the backend does NOT yet implement cart endpoints. This script documents
// the intended flow; the cart POST/GET/DELETE calls are marked TODO and currently
// the script only exercises GET /api/products. Wire the cart endpoints in a future
// backend iteration, then un-TODO the calls below.

import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost';

export const options = {
  scenarios: {
    cart: {
      executor: 'constant-vus',
      vus: 500,
      duration: '5m',
    },
  },
  thresholds: {
    'http_req_duration{type:api-list}': ['p(95)<150'],
  },
};

export default function () {
  // Currently exercised: list products.
  const res = http.get(`${BASE}/api/products`, { tags: { type: 'api-list' } });
  check(res, { 'list 200': (r) => r.status === 200 });

  let products = [];
  try {
    products = res.json();
  } catch (_) {
    products = [];
  }
  const productId = products.length > 0 ? products[0].id : 'prod-001';

  // ---- TODO: cart endpoints (not yet implemented in the backend) ------------
  // const add = http.post(`${BASE}/api/cart`, JSON.stringify({ product_id: productId, qty: 1 }),
  //   { headers: { 'Content-Type': 'application/json' }, tags: { type: 'cart-add' } });
  // check(add, { 'cart add 200': (r) => r.status === 200 });
  //
  // const cart = http.get(`${BASE}/api/cart`, { tags: { type: 'cart-get' } });
  // check(cart, { 'cart get 200': (r) => r.status === 200 });
  //
  // const del = http.del(`${BASE}/api/cart/${productId}`, null, { tags: { type: 'cart-del' } });
  // check(del, { 'cart del 200': (r) => r.status === 200 });
  // ---------------------------------------------------------------------------
  void productId; // silence unused until cart endpoints land
}
