# Layer 6 — Async File I/O: kernel AIO + directio

> **Scope note.** Nginx mainline does **not** use io_uring for its networking event
> loop — epoll remains the networking path as of Nginx 1.26. This layer targets
> **file I/O only**: serving large static assets more efficiently. It is applied by
> [apply-layer-6.sh](../../scripts/apply-layer-6.sh), which installs
> [layer-06-aio.conf](../../nginx/sections/layer-06-aio.conf) — the Layer 5 TLS config
> plus `aio`/`directio` on the static location.
>
> **Two ways to do async file I/O — and why this config uses threads.** Nginx offers
> `aio on` (Linux **native** AIO via libaio) and `aio threads` (a **thread pool**). Native
> AIO needs nginx built `--with-file-aio` *and* forces `O_DIRECT`; on a binary without that
> flag it hard-fails config test with `"aio on" is unsupported on this platform`. The
> config therefore uses **`aio threads`**, which needs only `--with-threads` (present in
> virtually every build), works with buffered *or* directio reads, and offloads the blocking
> read to a pool thread so the event loop never stalls. [apply-layer-6.sh](../../scripts/apply-layer-6.sh)
> checks for `--with-threads` up front. To use native AIO instead, rebuild nginx
> `--with-file-aio` and set `aio on;` (directio then becomes mandatory).

## What `aio on` does

By default Nginx reads files synchronously inside the worker: a blocking `read()`
parks the worker until the disk responds, and during that time the worker cannot
service other connections on that event-loop pass. `aio on` delegates file reads to
the **kernel asynchronous I/O** interface — on Linux this is `io_submit` /
`io_getevents` via **libaio** (not io_uring yet). The worker submits the read, keeps
processing other connections, and is notified when the data is ready. This keeps the
event loop non-blocking under disk-bound static workloads.

## What `directio` does

`directio` opens files above a size threshold with `O_DIRECT`, which **bypasses the
page cache**. For large assets this avoids *double buffering* — copying the file into
the page cache and then into the application/socket buffer. The data moves disk →
user buffer → socket once, freeing page-cache RAM for more useful work.

## When NOT to use directio

Small files (≲ 512 KB) are **faster through the page cache**: they are likely already
cached, and `O_DIRECT` forces an actual disk round-trip plus alignment overhead. That
is why we set `directio 512k` — only files larger than 512 KB bypass the cache; small
SPA assets keep their fast cached path.

## Current io_uring status in Nginx

io_uring is the modern Linux async I/O interface and supersedes libaio, but mainline
Nginx does **not** yet use it for networking, and `aio` does not yet target io_uring
for file reads. This is tracked upstream and is **forward-looking** — today, `aio on`
means libaio.

There is an open (unmerged) upstream PR adding io_uring for **file-cache reads**:
[nginx/nginx#1303](https://github.com/nginx/nginx/pull/1303). We reviewed it as a
potential alternative to this layer — spoiler: it only touches the `proxy_cache` read
path, not static-file serving, so it would not have changed the T1 result. Full review,
build recipe, and test plan: [Layer 6 (alternative) — io_uring](08-layer-06-io-uring.md).

## Expected impact

- Lower CPU idle/iowait time on **disk-bound, large-file** workloads (workers don't block on reads).
- Page-cache RAM freed by `directio` on large assets, available for other uses.

> **Measured on T1 (2026-07-04) — it REGRESSED, so the block is OPT-IN / off by default.**
> On the T1 SPA workload (small assets, entirely page-cached, served over TLS), enabling
> `aio threads; directio 512k;` made throughput **worse**:
>
> | Test | Layer 5 | Layer 6 (aio on) | Δ |
> |---|---|---|---|
> | wrk static (H1.1+TLS) | 290,200 | 228,904 | **-21 %** |
> | h2load (warm H2+TLS)  | 347,732 | 268,286 | **-23 %** |
> | wrk UI | 159,354 | 158,896 | flat (NIC-bound) |
>
> - **Why it hurt:** over HTTPS nginx **cannot use `sendfile`** (the kernel can't encrypt),
>   so every file is read into a userspace buffer to be encrypted. Those reads are **cache
>   hits — they never block.** Routing them through the thread pool adds a dispatch
>   (context-switch + queue) per request for zero benefit; the monitor showed nginx CPU
>   *dropping* (1195 %→1165 %) while throughput dropped too — workers idling on the handoff.
> - **When it helps:** only when reads **genuinely block on disk** — large media (video, big
>   images) or a working set larger than RAM. That is a T2/T3 / different-content scenario,
>   not this SPA.
> - **`aio on` vs `aio threads` matters here:** native `aio on` is gated to files ≥ the
>   `directio` size, so small cached files keep the fast path (likely a no-op, not a
>   regression). Thread-pool `aio threads` applies to **all** reads, so on a small-file
>   workload it regresses. This binary lacks `--with-file-aio`, so thread-pool is the only
>   option → the block is left **commented out** in the config; uncomment it only for a
>   large-media workload (and prefer a `--with-file-aio` build for `aio on`).
> - **Takeaway:** tuning is **not** universally additive. A layer can cost throughput on the
>   wrong workload; measure, don't assume.

## How to verify

Confirm the config loaded and shows the thread-pool aio:

```bash
nginx -T 2>/dev/null | grep -E 'aio|directio'          # aio threads; directio 512k;
```

With **`aio threads`** (this config) the reads happen on pool threads, not via
`io_submit`, so trace the worker's threads doing `pread` instead:

```bash
strace -f -e pread64 -p $(pidof nginx | awk '{print $1}') 2>&1 | head
```

If you switched to native **`aio on`**, then the libaio syscalls are what to look for:

```bash
strace -e io_submit,io_getevents -p $(pidof nginx | awk '{print $1}')
```

Next: [Layer 7 — NUMA & CPU Affinity](09-layer-07-numa.md).
