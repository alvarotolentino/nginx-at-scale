import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import viteCompression from 'vite-plugin-compression';

// Production build outputs directly into nginx/static so Nginx serves the SPA
// from /srv/static with no extra copy. Paths are relative to app/frontend/.
export default defineConfig({
  plugins: [
    react(),
    // Precompress every emitted asset so Nginx can serve .gz / .br directly
    // (gzip_static / brotli_static) — no per-request compression CPU at runtime.
    viteCompression({ algorithm: 'gzip', ext: '.gz', threshold: 1024 }),
    viteCompression({ algorithm: 'brotliCompress', ext: '.br', threshold: 1024 }),
  ],
  base: '/',
  // Strip dev-only noise from the production bundle.
  esbuild: {
    drop: ['console', 'debugger'],
    legalComments: 'none',
  },
  build: {
    outDir: '../../nginx/static',
    assetsDir: 'assets',
    emptyOutDir: true,
    // Target modern evergreen browsers — smaller output, no legacy transpile.
    target: 'es2020',
    minify: 'esbuild', // fastest minifier; comparable size to terser for this app
    cssMinify: true,
    cssCodeSplit: true,
    sourcemap: false, // never ship maps to prod
    reportCompressedSize: false, // skip the gzip-size pass → faster builds
    chunkSizeWarningLimit: 1000,
    rollupOptions: {
      output: {
        // Keep React in its own long-cached chunk, split from app code.
        manualChunks: {
          vendor: ['react', 'react-dom'],
        },
      },
    },
  },
  server: {
    // Dev-only proxy: the Rust backend listens on 8080. In production Nginx does this.
    proxy: {
      '/api': 'http://localhost:8080',
    },
  },
});
