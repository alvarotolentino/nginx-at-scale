import { useEffect, useState } from 'react';
import ProductList from './pages/ProductList.jsx';
import ProductDetail from './pages/ProductDetail.jsx';
import Cart from './pages/Cart.jsx';

// Minimal client-side router: no react-router. We read window.location.pathname,
// render the matching page, and re-render on popstate (back/forward button).
function usePath() {
  const [path, setPath] = useState(window.location.pathname);
  useEffect(() => {
    const onPop = () => setPath(window.location.pathname);
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);
  return path;
}

// Live cart count read from localStorage. Re-checks on storage events and on the
// custom "cart-changed" event the pages dispatch after mutating the cart.
function useCartCount() {
  const read = () => {
    try {
      const cart = JSON.parse(localStorage.getItem('cart') || '[]');
      return cart.reduce((n, item) => n + (item.qty || 0), 0);
    } catch {
      return 0;
    }
  };
  const [count, setCount] = useState(read);
  useEffect(() => {
    const update = () => setCount(read());
    window.addEventListener('storage', update);
    window.addEventListener('cart-changed', update);
    return () => {
      window.removeEventListener('storage', update);
      window.removeEventListener('cart-changed', update);
    };
  }, []);
  return count;
}

function navigate(href) {
  window.history.pushState({}, '', href);
  window.dispatchEvent(new PopStateEvent('popstate'));
}

export default function App() {
  const path = usePath();
  const cartCount = useCartCount();

  let page;
  if (path === '/' || path === '') {
    page = <ProductList />;
  } else if (path.startsWith('/product/')) {
    page = <ProductDetail />;
  } else if (path === '/cart') {
    page = <Cart />;
  } else {
    page = <ProductList />;
  }

  return (
    <>
      <nav className="nav">
        <a
          className="nav-brand"
          href="/"
          onClick={(e) => {
            e.preventDefault();
            navigate('/');
          }}
        >
          1B Shop
        </a>
        <div className="nav-links">
          <a
            href="/"
            onClick={(e) => {
              e.preventDefault();
              navigate('/');
            }}
          >
            Shop
          </a>
          <a
            href="/cart"
            onClick={(e) => {
              e.preventDefault();
              navigate('/cart');
            }}
          >
            Cart 🛒 ({cartCount})
          </a>
        </div>
      </nav>
      {page}
    </>
  );
}
