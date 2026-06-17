import { useEffect, useMemo, useState } from 'react';
import { getProducts } from '../api.js';
import productImage from '../assets/product.svg';
import styles from './ProductList.module.css';

const PAGE_SIZE = 12; // products per dashboard page

function formatPrice(p) {
  return `$${Number(p).toFixed(2)}`;
}

function addToCart(product) {
  let cart = [];
  try {
    cart = JSON.parse(localStorage.getItem('cart') || '[]');
  } catch {
    cart = [];
  }
  const existing = cart.find((i) => i.id === product.id);
  if (existing) {
    existing.qty += 1;
  } else {
    cart.push({ id: product.id, name: product.name, price: product.price, qty: 1 });
  }
  localStorage.setItem('cart', JSON.stringify(cart));
  window.dispatchEvent(new Event('cart-changed'));
}

export default function ProductList() {
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [page, setPage] = useState(1);

  useEffect(() => {
    let alive = true;
    getProducts()
      .then((data) => {
        if (alive) setProducts(Array.isArray(data) ? data : []);
      })
      .catch((err) => {
        if (alive) setError(err.message);
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, []);

  const totalPages = Math.max(1, Math.ceil(products.length / PAGE_SIZE));
  // Clamp page if the data shrinks beneath the current page.
  const safePage = Math.min(page, totalPages);
  const pageItems = useMemo(() => {
    const start = (safePage - 1) * PAGE_SIZE;
    return products.slice(start, start + PAGE_SIZE);
  }, [products, safePage]);

  function goto(p) {
    const next = Math.min(Math.max(1, p), totalPages);
    setPage(next);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  if (loading) return <div className="page">Loading products…</div>;
  if (error) return <div className="page">Failed to load products: {error}</div>;

  return (
    <div className="page">
      <h1>Shop</h1>
      <p className={styles.count}>
        {products.length} products · page {safePage} of {totalPages}
      </p>

      <div className={styles.grid}>
        {pageItems.map((p) => (
          <div
            key={p.id}
            className={styles.card}
            onClick={() => {
              window.history.pushState({}, '', `/product/${p.id}`);
              window.dispatchEvent(new PopStateEvent('popstate'));
            }}
          >
            {/* One shared image for every product. */}
            <img className={styles.image} src={productImage} alt={p.name} />
            <div className={styles.name}>{p.name}</div>
            <div className={styles.price}>{formatPrice(p.price)}</div>
            <button
              className={styles.button}
              onClick={(e) => {
                e.stopPropagation();
                addToCart(p);
              }}
            >
              Add to Cart
            </button>
          </div>
        ))}
      </div>

      {totalPages > 1 && (
        <nav className={styles.pagination} aria-label="Pagination">
          <button
            className={styles.pageBtn}
            onClick={() => goto(safePage - 1)}
            disabled={safePage <= 1}
          >
            ← Prev
          </button>

          {Array.from({ length: totalPages }, (_, i) => i + 1).map((p) => (
            <button
              key={p}
              className={`${styles.pageBtn} ${p === safePage ? styles.pageActive : ''}`}
              onClick={() => goto(p)}
              aria-current={p === safePage ? 'page' : undefined}
            >
              {p}
            </button>
          ))}

          <button
            className={styles.pageBtn}
            onClick={() => goto(safePage + 1)}
            disabled={safePage >= totalPages}
          >
            Next →
          </button>
        </nav>
      )}
    </div>
  );
}
