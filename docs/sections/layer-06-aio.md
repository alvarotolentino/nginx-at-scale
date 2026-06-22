# Layer 6 — Async File I/O: kernel AIO + directio

> **Scope note.** Nginx mainline does **not** use io_uring for its networking event
> loop — epoll remains the networking path as of Nginx 1.26. This layer targets
> **file I/O only**: serving large static assets more efficiently. It is applied by
> [apply-layer-6.sh](../../scripts/apply-layer-6.sh), which installs
> [layer-06-aio.conf](../../nginx/sections/layer-06-aio.conf) — the Layer 5 TLS config
> plus `aio`/`directio` on the static location — and requires libaio on the host
> (`apply-layer-5.sh` already installs `libaio-dev`; the Layer 6 script guards for it too).

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

## Expected impact

- Lower CPU idle/iowait time on static-file-heavy workloads (workers don't block on reads).
- Page-cache RAM freed by `directio` on large assets, available for other uses.

## How to verify

```bash
strace -e io_getevents,io_submit -p $(pidof nginx | awk '{print $1}')
```

Seeing `io_submit` / `io_getevents` calls confirms kernel AIO is in use for reads.
