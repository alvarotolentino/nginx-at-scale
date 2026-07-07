# Layer 5 — TLS Hardening & Session Resumption

> **Goal of this stage.** Add TLS on `:443` **without** giving back the throughput the
> earlier layers won. The lever is **handshake economy**: a full TLS handshake is the
> single most expensive thing in an HTTPS request, so the whole design is about doing it
> as rarely as possible (session resumption) and as cheaply as possible (AEAD ciphers,
> OCSP stapling, HTTP/2 reuse). Also targets an SSL Labs **A+** rating.

The complete config is
[nginx/sections/layer-05-tls.conf](../../nginx/sections/layer-05-tls.conf) — it extends
the Layer 3 worker/event model and adds the TLS server.

## Why TLS is a performance problem, not just a security one

A full TLS handshake costs a round-trip *and* an asymmetric-crypto operation (the
expensive part). At high connection-arrival rates, naive TLS can erase the gains from
Layers 1–3 because every new connection pays that cost. The mitigations below attack each
piece of that cost.

## Protocol & cipher selection

```nginx
ssl_protocols TLSv1.2 TLSv1.3;             # drop TLS 1.0/1.1 (A+ requirement)
ssl_ciphers ECDHE-...-GCM-...:...-CHACHA20-POLY1305:...;   # AEAD only, forward-secret
ssl_prefer_server_ciphers off;             # TLS 1.3 ignores this; AEAD-only 1.2 is safe with client order
```

- **TLS 1.3** cuts the handshake to **one round-trip** (1-RTT) versus 1.2's two, and
  removes legacy/insecure options by design. Dropping 1.0/1.1 is required for A+.
- **AEAD ciphers only** (AES-GCM, ChaCha20-Poly1305) — authenticated encryption, all
  **ECDHE** for forward secrecy. AES-GCM wins on CPUs with AES-NI; ChaCha20 wins on
  hardware without it (and is listed so clients can choose).

## Session resumption — the throughput lever

```nginx
ssl_session_cache shared:SSL:50m;   # ~200k sessions shared across all workers
ssl_session_timeout 1d;             # resume within a day → skip the full handshake
ssl_session_tickets off;            # off for forward secrecy (see below)
```

**Session resumption is what keeps HTTPS fast at scale.** A returning client resumes from
the cached session and **skips the expensive asymmetric handshake** entirely — an abbreviated
handshake instead of a full one. The `shared:SSL:50m` cache (~200k sessions) is shared
across workers, so any worker can resume any client.

**Why `ssl_session_tickets off`?** Tickets also enable resumption, but the ticket-encryption
key is a **long-lived secret** — if it leaks, past sessions lose forward secrecy, and
rotating it across a fleet is operationally fragile. Cache-based resumption keeps the
secret server-side only, so we prefer the cache and disable tickets. (On a multi-node
fleet you'd revisit this with a rotating ticket-key distribution; for this single target
the cache is strictly safer.)

## OCSP stapling — remove a client round-trip

```nginx
ssl_stapling on;
ssl_stapling_verify on;
```

The server fetches the CA's OCSP revocation response and **staples** it into the
handshake, so the client doesn't make its own round-trip to the CA to check the cert.
Faster handshake, and it doesn't leak the client's browsing to the CA. (With the
self-signed lab cert there's no real OCSP responder — these directives are how it's done
with a real CA-issued cert, and are left in for fidelity.)

## HTTP/2 + HSTS + redirect

```nginx
server { listen 80 ... ; return 301 https://$host$request_uri; }   # force TLS
server {
    listen 443 ssl backlog=65535 reuseport;
    http2 on;                                                       # multiplex over one conn
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    ...
}
```

- **HTTP/2** multiplexes many requests over **one** TLS connection — so the expensive
  handshake is amortized across far more requests. Big win for the static asset bundle.
- **HSTS with `preload`** forces HTTPS for two years and is required for A+. The `:80`
  server only 301-redirects to `:443`.
- `reuseport` + `backlog=65535` carry over from Layer 3 onto the TLS listener.

## Apply it

```bash
# TARGET
sudo scripts/apply-layer-5.sh
#   → ensures libaio-dev (for the optional Layer 6 AIO combo), generates a self-signed
#     cert if none exists, installs certs to /etc/nginx/certs (key chmod 600),
#     cp layer-05-tls.conf → nginx.conf, reload, snapshot --label layer-5

# TESTER  (wrk accepts the self-signed lab cert transparently)
scripts/load-test.sh --target https://<target-ip> --label layer-5 --tier <n>
```

## Verify

```bash
curl -kI https://localhost/                                  # 200 + HSTS header
openssl s_client -connect localhost:443 -tls1_3 </dev/null   # negotiated TLS 1.3
# resumption working: second handshake shows "Reused"
openssl s_client -connect localhost:443 -reconnect </dev/null 2>&1 | grep -i reused
```

> The lab uses a **self-signed** cert (`generate-certs.sh`). A real deployment swaps in a
> CA-issued cert; the OCSP-stapling and HSTS-preload directives only fully apply there.

## Expected impact

- TLS adds handshake cost, but with resumption + HTTP/2 the **steady-state RPS stays close
  to the plaintext Layer 3 number** — the whole point of the layer. Expect a dip on
  *cold* connections, near-parity on warm/resumed ones.
- A+ on SSL Labs (with a real cert): TLS 1.2/1.3 only, AEAD + ECDHE, HSTS preload, stapling.

> **Measured on T1 over a sub-ms LAN (2026-07-04) — protocol matters, and you must test
> HTTP/2 to see it.** Same `/` response as Layers 3–4.
>
> | Test | Protocol | RPS | vs plaintext (Layer 4 = 388,867) |
> |---|---|---|---|
> | wrk static | HTTP/1.1 + TLS, keepalive | 290,120 | **-25.4 %** |
> | h2load static | **HTTP/2 + TLS, warm** | **348,787** | **-10.3 %** |
>
> - **Warm HTTP/2 recovers ~60 % of the TLS penalty** (gap shrinks -99k → -40k vs
>   plaintext). The "near-parity" claim is **directionally right, not literal** — HTTP/2
>   claws most of it back but a residual remains.
> - **wrk cannot show this — it is HTTP/1.1 only.** The wrk static number (290k) is the
>   *worst case*: TLS over many HTTP/1.1 connections. To measure the layer's actual thesis
>   you need a warm HTTP/2 client — here `h2load` (`load-test.sh --h2`).
> - **Why H2 wins** (from h2load's traffic counters): **HPACK header compression** reports
>   `space savings 25.50 %` — the ~370-byte security-header block (added in Layer 3) repeats
>   every response, and HPACK compresses it across requests, so there are **fewer bytes to
>   AES-encrypt per response.** Same bandwidth as wrk (~421 vs ~411 MB/s) but more requests
>   packed into it. Plus **400 warm connections vs wrk's 4000** = 10× fewer handshakes and
>   far less per-connection TLS state; multiplexing amortizes the handshake to nil.
> - **The residual -10 % is symmetric AES-GCM body encryption** — H2 removes handshake and
>   header-byte overhead, but every response body is still encrypted. That floor is
>   irreducible; resumption cannot touch it (it only cheapens handshakes, already amortized
>   here by keepalive/multiplexing).
> - **Confirmed server-CPU-bound (re-run with the H2 phase monitored).** With h2load
>   reordered to run between the wrk stages and the sampler at `--duration 110`, the H2
>   window is captured: at ~400 connections the target sat at **~99–100 % CPU, nginx on all
>   12 threads**. So **347,732 req/s is the server's ceiling** for warm H2 on this box — not
>   a tester limit. All three rows above are therefore CPU-bound at 100 %, making this a
>   clean same-hardware, same-CPU protocol comparison.
> - **Tooling note:** `h2load`'s timing-based `--duration` mode reported `0 req/s` on this
>   build despite traffic flowing, so `load-test.sh --h2` uses **count-based `-n`**, which
>   reports correctly.
> - **nginx RSS climbs under TLS:** peak **7.7 GB**, rising monotonically through the run and
>   not reclaimed within it (vs ~2 GB plaintext at Layer 4). The 50 MB session cache doesn't
>   explain it — it's per-connection TLS + request buffers retained by the allocator under
>   churn. Watch whether it plateaus across Layers 6–8 rather than growing unbounded.
> - **UI mix** (159k RPS, tx 9.8 Gbps) unchanged — NIC-bound, a wall TLS/H2 cannot move.

Next: [Layer 6 — Async File I/O](layer-06-aio.md).
