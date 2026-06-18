# Section 15 — Security Hardening & Attack-Surface Reduction

Throughput is the headline, but a box answering a billion connections is also a billion-
connection attack surface. This section documents the hardening baked into the target so
"production-grade" isn't just a performance claim. It is **defense in depth**: firewall →
TLS → HTTP headers → least-privilege services → kernel sandboxing.

## 1. Network: nftables, default-drop

[`deploy/firewall/nftables.conf`](../../deploy/firewall/nftables.conf) sets `policy drop`
on input and opens exactly three ports: **22 (SSH), 80 (HTTP→HTTPS redirect), 443 (HTTPS)**.

The backend (`:8080`) and lux (`:6379`) bind to `127.0.0.1` and appear in **no** rule, so
they are unreachable from the network — only nginx, on the same host, can reach them. The
tester verifies this: `smoke-test.sh --target …` fails if `:8080` answers remotely.

> Lock SSH down further in production: restrict `tcp dport 22` to your admin source IP.

## 2. Transport: TLS 1.2/1.3, HSTS, OCSP

From Layer 5 on, nginx serves only TLS 1.2/1.3 with AEAD ciphers, session resumption via a
shared cache (tickets off for forward secrecy), OCSP stapling, and an HSTS preload header.
See [Layer 5 — TLS](07-layer-05-tls.md).

> **Lab caveat:** the cert is **self-signed** ([`generate-certs.sh`](../../scripts/generate-certs.sh)).
> HSTS preload and OCSP stapling are shipped and correct, but inert without a public CA
> chain. For a real deployment, swap in an ACME/Let's Encrypt cert and they become live.

## 3. HTTP response headers

Every tuned config sets a single security-header block (kept together because a child-
context `add_header` **replaces** all inherited ones in nginx):

| Header | Value | Purpose |
|--------|-------|---------|
| `Content-Security-Policy` | `default-src 'self'` + tight per-directive | Block injected/cross-origin scripts, frames, objects |
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` | Force HTTPS (TLS server only) |
| `X-Content-Type-Options` | `nosniff` | Stop MIME sniffing |
| `X-Frame-Options` | `DENY` | Anti-clickjacking (plus CSP `frame-ancestors 'none'`) |
| `Referrer-Policy` | `no-referrer` | Don't leak URLs |
| `Permissions-Policy` | deny geolocation/camera/mic/payment | Drop unused browser features |

Plus `server_tokens off` (hide the nginx version) and `client_max_body_size 1m` (this app
has no uploads).

The **CSP is strict** — `script-src 'self'`, `style-src 'self'` — because the Vite build
emits external JS/CSS chunks with no inline scripts (the only inline asset is the SVG
favicon, a `data:` URI, covered by `img-src 'self' data:`). If you add a library that
injects inline styles at runtime, widen `style-src` to include `'unsafe-inline'`; never
loosen `script-src`.

## 4. Rate limiting (opt-in, off for benchmarks)

`limit_req_zone` / `limit_conn_zone` are defined but **not applied** — enabling them on the
static `/` path would cap the throughput benchmark. The `/api/` location carries commented
`limit_req` / `limit_conn` lines you can switch on for non-benchmark, abuse-prone runs.

## 5. Least privilege: service users

| Service | User | Network bind | Notes |
|---------|------|--------------|-------|
| nginx | master root → workers `nginx` | `:80`/`:443` | root only to bind privileged ports + setuid workers |
| backend | `appsvc` (nologin, no home) | `127.0.0.1:8080` | stateless |
| lux | `luxsvc` (nologin, no home) | `127.0.0.1:6379` | data dir `/var/lib/lux` mode `0700` |

## 6. Kernel sandboxing: systemd

The unit files in [`deploy/systemd/`](../../deploy/systemd/) wrap each service in the
kernel's sandboxing primitives. backend + lux get the full set; nginx gets a reduced set
(its master legitimately needs `CAP_NET_BIND_SERVICE` + setuid).

| Directive | Effect |
|-----------|--------|
| `NoNewPrivileges` | No privilege escalation via setuid/caps |
| `ProtectSystem=strict` | Whole FS read-only except explicit `ReadWritePaths` |
| `ProtectHome`, `PrivateTmp`, `PrivateDevices` | No `/home`, private `/tmp`, no raw devices |
| `ProtectKernel{Tunables,Modules,Logs}` | Can't write sysctl, load modules, read kmsg |
| `RestrictAddressFamilies=AF_INET AF_INET6` | Only IP sockets (no AF_PACKET/raw) |
| `CapabilityBoundingSet=` (empty for backend/lux) | Drop *all* Linux capabilities |
| `MemoryDenyWriteExecute` | No W^X pages — blocks classic code injection |
| `SystemCallFilter=@system-service` | seccomp allowlist; deny `@privileged`/`@resources` |
| `LockPersonality`, `RestrictNamespaces`, `RestrictRealtime` | Shut common escape/abuse paths |

Audit the result on the target:

```bash
systemd-analyze security backend.service     # exposure score (lower = tighter)
systemd-analyze security lux.service
```

> **Tuning tension:** these protections cost essentially nothing at the syscall hot path
> nginx exercises. `MemoryDenyWriteExecute` can break a JIT, but neither the Rust backend
> nor lux JITs, so it's safe here. If a future component needs W^X, scope the relaxation to
> that one unit — don't drop it globally.

Next: [Section 13 — Results & Takeaways](13-results.md).
