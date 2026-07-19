# Layer 6 (alternative path) — io_uring file I/O: nginx PR #1303

> **Status: EXPERIMENTAL / PARKED — not part of the regular layer chain.** This is an
> alternative to [Layer 6 — kernel AIO + directio](08-layer-06-aio.md), based on the
> **open, unmerged** upstream PR [nginx/nginx#1303](https://github.com/nginx/nginx/pull/1303)
> ("io_uring support for file cache reads", opened 2026-04-29, labeled *needs-analysis* /
> *backlog* as of 2026-07-09). It requires building nginx from source with the PR applied.
> We document it because Layer 6's libaio/thread-pool approach **regressed T1 by 21–23 %**,
> and io_uring is the natural "what about the modern interface?" question. Short answer
> after reviewing the patch: **it would not have changed our Layer 6 result at all** — see
> the scope analysis below.

## What the PR actually does

Reading the [full diff](https://github.com/nginx/nginx/pull/1303/changes/0011afdb5d3a49d006678b87beb46bd2d90191a6)
(15 files, ~1,050 added lines), the design is:

- **New build option `--with-io_uring`**, mutually exclusive with `--with-file-aio`
  (`auto/unix` hard-fails if both are set). Requires **liburing** headers + library at
  build time and links `-luring`.
- **New runtime directive `io_uring on|off`** (http/server/location scope, **default
  off**), parallel to the existing `aio` directive.
- **One io_uring ring per worker**, initialized inside the epoll module
  (`ngx_epoll_io_uring_init`). Queue depth comes from the existing
  `worker_aio_requests` setting (default 32). Completions are delivered via an
  **eventfd registered on the ring and added to epoll** — so the event loop wakes up on
  CQE arrival exactly like the libaio path does today.
- **Reads are submitted as `IORING_OP_READ`** (buffered read — no `O_DIRECT`, no
  registered buffers, no SQPOLL, no fixed files). One SQE + one `io_uring_submit()`
  syscall per read; there is no batching of submissions.
- **Graceful degradation**: if the SQ is full, or submit returns `EAGAIN`, it falls back
  to a synchronous `ngx_read_file()`. On `ENOSYS`/`EINVAL`/`EOPNOTSUPP` it disables
  io_uring **globally for the rest of the worker's life** and goes synchronous.
- **Cancellation machinery**: a hard-coded 60 s timer per in-flight read; on timeout the
  worker submits `IORING_OP_ASYNC_CANCEL` and then **blocks in `io_uring_wait_cqe()`**
  until that specific completion arrives. Worker shutdown drains/cancels all in-flight
  requests (with an `IORING_ASYNC_CANCEL_ANY|ALL` fast path, falling back to per-event
  cancel on kernels that return `-EINVAL` for the flags).

## The critical scope caveat: file cache only

The only call site of the new `ngx_file_io_uring_read()` is
**`ngx_http_file_cache.c`** — the code that reads **proxy/FastCGI/uwsgi/SCGI cache
entries** (`proxy_cache` and friends) off disk. Specifically it replaces the read of the
cache header + start of body (`c->body_start` bytes) when a cached response is served.

What the PR does **not** touch:

- **`ngx_output_chain.c`** — the copy path that reads **static files** into userspace
  buffers (the path our TLS-encrypted SPA assets take, since HTTPS can't `sendfile`).
- The static module, `sendfile`, temp-file writes, log writes — all unchanged.

So on the T1 workload (static SPA assets over TLS, no `proxy_cache` in the hot path),
**this patch is a literal no-op**: `io_uring on` would load, initialize a ring, and never
submit a single read. Our Layer 6 regression measured the *static-file* read path, which
this PR leaves on the synchronous/thread-pool code it already uses.

## Would it help even where it does apply?

Reviewing the submit path raises the same red flag that sank `aio threads` on T1:

- After a successful submit the function **always returns `NGX_AGAIN`** and parks the
  request until the eventfd→epoll→posted-event round trip completes — even if the data
  was page-cache-hot and the kernel completed the read inline. A hot cache read costs
  *submit syscall + eventfd read + epoll dispatch + posted event* where a plain `pread()`
  costs one cheap syscall. That is **more** per-request overhead on a hot working set,
  which is exactly the T1 situation.
- One `io_uring_submit()` per read means no syscall amortization — the headline io_uring
  win (batched/zero-syscall submission via SQPOLL) is not implemented.
- The author's own benchmarks (Linux 6.8, 4 vCPUs, cache-serving workload) show modest
  gains only at the small end and a **loss** at the large end:

  | Cached object size | sync read (RPS) | io_uring (RPS) | Δ |
  |---|---|---|---|
  | 4 KiB | 71,761 | 77,631 | **+8 %** |
  | ~medium | ~56 k | ~56 k | flat |
  | 1 MiB | 7,643 | 7,268 | **-5 %** |

- Reviewers flagged real correctness concerns that are still open: io_uring buffer
  lifetime rules (the kernel owns the destination buffer until the CQE arrives — if the
  request pool is freed while a read is in flight, the kernel writes into freed memory;
  the 60 s timer + blocking cancel is a mitigation, not a guarantee), and the blocking
  `io_uring_wait_cqe()` inside the cancel path stalls the whole event loop.
- On first `EINVAL` from any read, io_uring is disabled for the worker's remaining
  lifetime — a transient error permanently degrades to sync reads with no log-visible
  recovery.

## Requirements, if we test it

| Requirement | Detail |
|---|---|
| Kernel | ≥ 5.6 for `IORING_OP_READ`; ≥ 5.19 for `IORING_ASYNC_CANCEL_ALL/ANY` (older kernels take the per-event-cancel fallback). Ubuntu 24.04's 6.8+ is fine. |
| liburing | `apt-get install liburing-dev` (build) — the binary links `liburing.so` (runtime). |
| Build | From source with the PR applied; **cannot** combine with `--with-file-aio`, so the native-AIO comparison binary must be a separate build. |
| Environment | Bare metal is fine. Note: default Docker/containerd **seccomp profiles block io_uring syscalls** — irrelevant for T1's metal target, but it would silently fall back (`ENOSYS` → sync) in containers. |

### Build recipe

```bash
apt-get install -y liburing-dev mercurial build-essential libpcre2-dev zlib1g-dev libssl-dev

git clone https://github.com/nginx/nginx.git && cd nginx
git fetch origin pull/1303/head:io-uring && git checkout io-uring

# Mirror the flags of the installed package (nginx -V), swapping the file-aio flag:
auto/configure \
  --prefix=/usr/local/nginx-iouring \
  --with-io_uring \
  --with-threads \
  --with-http_ssl_module --with-http_v2_module \
  $(nginx -V 2>&1 | tr ' ' '\n' | grep '^--with' | grep -v file-aio | tr '\n' ' ')
make -j"$(nproc)"
```

### Config to exercise it

`io_uring on` only fires on `proxy_cache` reads, so the test config must cache backend
responses to disk and serve from that cache:

```nginx
proxy_cache_path /var/cache/nginx/iouring levels=1:2 keys_zone=iou:64m
                 max_size=20g inactive=60m;

location /api/ {
    proxy_pass http://127.0.0.1:3000;
    proxy_cache iou;
    proxy_cache_valid 200 10m;
    io_uring on;            # replaces `aio threads` for the cache read
}
```

## Test plan (when/if we run it)

1. **Workload must be disk-bound cache reads**, or the test measures nothing: either a
   cache working set larger than RAM, or a cold cache with `max_size` in the tens of GB
   and enough distinct keys that page-cache hit rate stays low. The T1 SPA traffic
   (small, fully page-cached) cannot distinguish the implementations — that is the
   Layer 6 lesson repeated.
2. Three binaries / configs, A/B/C on identical traffic:
   sync reads (baseline), `aio threads` (current Layer 6 opt-in), `io_uring on` (PR build).
3. Usual three-leg measurement (snapshot / monitor / load-test); watch iowait and
   per-worker CPU, restart nginx between runs.
4. Success criterion: io_uring beats `aio threads` on RPS/core at equal p99 on the
   disk-bound workload. On a page-cached workload, expect it to lose or tie — if it
   *wins* there, suspect the harness.

## Verdict

**Parked, not adopted.** Three reasons:

1. **Unmerged and drifting** — open since April 2026, *backlog*-labeled, unresolved
   buffer-lifetime review comments, and nginx upstream has rejected io_uring patches
   before (the 2020 series never landed). Building a course layer on an unmerged patch
   means re-validating on every rebase.
2. **Wrong code path for T1** — it accelerates `proxy_cache` disk reads only; T1's
   regression was on the static-file read path, which the PR does not modify.
3. **Same architectural cost that made Layer 6 regress** — per-read submit syscall plus
   a full event-loop round trip, paid even on page-cache hits. The author's own numbers
   (+8 % small / -5 % large, cache workload, 4 vCPUs) do not clear the bar that would
   justify a source-built, patched binary.

**Revisit when** any of: the PR merges (or nginx ships official io_uring file I/O), the
workload gains a genuinely disk-bound `proxy_cache` tier (T2/T3 large-media scenario), or
the patch grows `ngx_output_chain` coverage so static reads use it too.

Back to the regular chain: [Layer 6 — kernel AIO + directio](08-layer-06-aio.md) ·
Next: [Layer 7 — NUMA & CPU Affinity](09-layer-07-numa.md).
