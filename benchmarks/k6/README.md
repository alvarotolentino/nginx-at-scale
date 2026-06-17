# k6 Benchmark Scenarios

Three scripted load scenarios for the 1B Shop stack.

| Script | Purpose | Profile |
|--------|---------|---------|
| `browse-products.js` | Realistic browse journey | 10→5000 VUs, ~19 min |
| `cart-checkout.js` | Add-to-cart flow (cart endpoints TODO) | 500 VUs constant, 5 min |
| `concurrency-ramp.js` | Find the connection ceiling | 1k→100k VUs, ~9 min |

## Prerequisites

Install k6 (Debian/Ubuntu via the Grafana apt repo):

```bash
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install -y k6
# macOS: brew install k6
```

## Running

Each script reads the target from `BASE_URL` (default `http://localhost`):

```bash
# Browse journey, save full metrics to JSON
k6 run --out json=results/tier-1/k6-browse.json benchmarks/k6/browse-products.js

# Against a TLS host (Layer 5+)
BASE_URL=https://localhost k6 run benchmarks/k6/browse-products.js

# Concurrency ceiling stress test
k6 run --out json=results/tier-1/k6-ramp.json benchmarks/k6/concurrency-ramp.js
```

> High-VU runs (`concurrency-ramp.js`) need raised fd limits on the **load
> generator** too: `ulimit -n 1048576` before launching k6.

## Interpreting the summary

k6 prints a summary at the end of each run:

- **`http_req_duration`** — request latency. Watch `p(95)` and `p(99)`; the threshold
  lines show ✓/✗ against the targets defined in each script's `options.thresholds`.
- **`http_req_failed`** — error rate. For `concurrency-ramp.js`, the custom
  `ceiling_errors` metric crossing **1%** marks the concurrency ceiling for that stage.
- **`iterations` / `vus`** — completed journeys and the live VU count per stage.
- **`data_received` / `data_sent`** — throughput, useful for NIC-saturation checks.

## Comparing across optimization layers

1. Apply a layer (`sudo scripts/apply-layer-N.sh`).
2. Re-run the same script with `--out json=results/tier-1/k6-<layer>.json`.
3. Diff the `p(95)` / `http_req_failed` / max-VU-before-1%-error across runs.

The expectation: as layers stack, p95 stays flat to higher VU counts and the
`concurrency-ramp.js` ceiling moves up.
