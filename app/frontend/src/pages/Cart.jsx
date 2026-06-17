import { useState } from 'react';
import styles from './Cart.module.css';

function formatPrice(p) {
  return `$${Number(p).toFixed(2)}`;
}

function readCart() {
  try {
    return JSON.parse(localStorage.getItem('cart') || '[]');
  } catch {
    return [];
  }
}

function navigate(href) {
  window.history.pushState({}, '', href);
  window.dispatchEvent(new PopStateEvent('popstate'));
}

export default function Cart() {
  const [items, setItems] = useState(readCart);
  const [placed, setPlaced] = useState(false);

  const total = items.reduce((sum, i) => sum + i.price * i.qty, 0);

  function remove(id) {
    const next = items.filter((i) => i.id !== id);
    setItems(next);
    localStorage.setItem('cart', JSON.stringify(next));
    window.dispatchEvent(new Event('cart-changed'));
  }

  function checkout() {
    localStorage.setItem('cart', '[]');
    setItems([]);
    setPlaced(true);
    window.dispatchEvent(new Event('cart-changed'));
  }

  if (placed) {
    return (
      <div className="page">
        <h1>Order placed! 🎉</h1>
        <p>Thanks for shopping with 1B Shop.</p>
        <a
          href="/"
          onClick={(e) => {
            e.preventDefault();
            navigate('/');
          }}
        >
          Continue Shopping
        </a>
      </div>
    );
  }

  return (
    <div className="page">
      <h1>Cart</h1>
      {items.length === 0 ? (
        <p>
          Your cart is empty.{' '}
          <a
            href="/"
            onClick={(e) => {
              e.preventDefault();
              navigate('/');
            }}
          >
            Continue Shopping
          </a>
        </p>
      ) : (
        <>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Item</th>
                <th>Qty</th>
                <th>Unit</th>
                <th>Subtotal</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {items.map((i) => (
                <tr key={i.id}>
                  <td>{i.name}</td>
                  <td>{i.qty}</td>
                  <td>{formatPrice(i.price)}</td>
                  <td>{formatPrice(i.price * i.qty)}</td>
                  <td>
                    <button className={styles.remove} onClick={() => remove(i.id)}>
                      Remove
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className={styles.total}>Total: {formatPrice(total)}</div>
          <div className={styles.actions}>
            <a
              href="/"
              onClick={(e) => {
                e.preventDefault();
                navigate('/');
              }}
            >
              Continue Shopping
            </a>
            <button className={styles.checkout} onClick={checkout}>
              Checkout
            </button>
          </div>
        </>
      )}
    </div>
  );
}
