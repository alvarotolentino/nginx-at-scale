# Layer 4 — Memory Allocator (jemalloc)

## Why glibc malloc underperforms under high concurrency

glibc's `malloc` (ptmalloc2) was designed for general-purpose workloads, not for a
process fielding tens of thousands of concurrent connections. Three properties hurt
it at scale:

- **Arena lock contention.** ptmalloc2 shards the heap into a fixed number of arenas
  (typically `8 × ncpu`). When more threads than arenas allocate simultaneously, they
  serialize on the arena mutex. Under an Nginx worker servicing thousands of requests,
  this lock becomes a measurable tail-latency source.
- **Fragmentation.** Its best-fit/binning strategy leaves the heap pockmarked with
  unusable gaps as request buffers of varying sizes are allocated and freed. Over hours
  of load, resident memory (RSS) creeps upward and never fully returns to the OS.
- **Arena design.** Memory freed on one arena is not readily reused by another, so a
  bursty, multi-threaded allocation pattern wastes capacity.

## What jemalloc does differently

- **Thread-local caches (tcache).** Each thread satisfies most allocations from its own
  cache with no lock at all, eliminating the arena contention entirely on the hot path.
- **Size-class bins.** Allocations are rounded to a tight set of size classes, so freed
  blocks are far more likely to be reused exactly — dramatically lowering fragmentation.
- **Extent-based allocation.** Memory is managed in large extents that can be decayed
  back to the OS on a timer, keeping long-running RSS flat instead of monotonically rising.

The net effect for Nginx is lower and more stable p99 latency, and bounded RSS over
multi-hour load tests.

## Why LD_PRELOAD works without recompiling Nginx

`malloc`/`free` are ordinary dynamic symbols. `LD_PRELOAD` loads jemalloc's shared
object **before** libc, so its `malloc`/`free` win symbol resolution and transparently
replace glibc's for the whole process — no Nginx source change, no recompile. We inject
it through the Nginx systemd unit's `Environment="LD_PRELOAD=..."`.

## How to verify jemalloc is active

```bash
grep jemalloc /proc/$(pidof nginx | awk '{print $1}')/maps | head -1
```

A non-empty line means the jemalloc `.so` is mapped into the Nginx process.

## Expected impact

- Reduced p99 latency under sustained concurrency (no arena-lock stalls).
- Lower, flatter RSS over time (extent decay returns memory to the OS).

## Note on tcmalloc

tcmalloc is intentionally **excluded** from this guide. It leans on glibc internals and
does not support musl, and for this Debian/glibc Nginx stack jemalloc is the
battle-tested production choice. We standardize on jemalloc and do not benchmark tcmalloc.
