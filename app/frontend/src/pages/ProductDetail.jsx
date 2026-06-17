import { useEffect, useState } from 'react';
import { getProduct } from '../api.js';
import productImage from '../assets/product.svg';
import styles from './ProductDetail.module.css';

function formatPrice(p) {
  return `$${Number(p).toFixed(2)}`;
}

function upsertCart(product) {
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

function navigate(href) {
  window.history.pushState({}, '', href);
  window.dispatchEvent(new PopStateEvent('popstate'));
}

export default function ProductDetail() {
  // /product/:id
  const id = window.location.pathname.split('/').pop();
  const [product, setProduct] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [added, setAdded] = useState(false);

  useEffect(() => {
    let alive = true;
    getProduct(id)
      .then((data) => {
        if (alive) setProduct(data);
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
  }, [id]);

  if (loading) return <div className="page">Loading product…</div>;
  if (error) return <div className="page">Failed to load product: {error}</div>;
  if (!product) return <div className="page">Product not found.</div>;

  return (
    <div className="page">
      <a
        href="/"
        onClick={(e) => {
          e.preventDefault();
          navigate('/');
        }}
      >
        ← Back to Shop
      </a>
      <div className={styles.detail}>
        {/* One shared image for every product. */}
        <img className={styles.image} src={productImage} alt={product.name} />
        <div className={styles.info}>
          <h1>{product.name}</h1>
          <div className={styles.price}>{formatPrice(product.price)}</div>
          <p className={styles.description}>{product.description}</p>
          <div className={styles.stock}>
            {product.stock > 0 ? `${product.stock} in stock` : 'Out of stock'}
          </div>
          <button
            className={styles.button}
            onClick={() => {
              upsertCart(product);
              setAdded(true);
            }}
          >
            Add to Cart
          </button>
          {added && <span className={styles.added}>Added ✓</span>}
        </div>
      </div>
    </div>
  );
}
