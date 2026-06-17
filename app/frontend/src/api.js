// Centralised fetch layer. Every call to the Rust backend goes through here so the
// base path (/api) and error handling live in one place. Nginx reverse-proxies
// /api/ to the backend on port 8080; in dev, Vite proxies it (see vite.config.js).

const BASE = '/api';

async function getJSON(path) {
  const res = await fetch(`${BASE}${path}`);
  if (!res.ok) {
    throw new Error(`Request failed: ${res.status} ${res.statusText}`);
  }
  return res.json();
}

// GET /api/products → [{ id, name, price, image_url, stock }]
export function getProducts() {
  return getJSON('/products');
}

// GET /api/products/:id → { id, name, price, description, stock, image_url }
export function getProduct(id) {
  return getJSON(`/products/${encodeURIComponent(id)}`);
}

// GET /api/orders → [{ id, product_id, qty, total }]
export function getOrders() {
  return getJSON('/orders');
}
