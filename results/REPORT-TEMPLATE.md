# Results — Qualitative Observations

Hand-filled companion to the auto-generated `tier-N/REPORT.md`. The automated report
captures the numbers (RPS, p99); this captures the *story* — what you expected, what
actually happened, and what surprised you. One row per optimization layer.

| Layer | What changed | Expected impact | Actual impact | Surprise findings |
|-------|--------------|-----------------|---------------|-------------------|
| Baseline | Stock Nginx, no tuning | Reference point | _fill in_ | _fill in_ |
| 1 — FD & Socket Buffers | `fs.file-max`/`nr_open` → 2M, somaxconn/backlogs → 65535, ulimits | Removes "too many open files" wall; higher max connections | _fill in_ | _fill in_ |
| 2 — TCP/IP Kernel | BBR + fq, 16MB socket buffers, keepalive economy | Higher goodput, better p99 on high-BDP links | _fill in_ | _fill in_ |
| 3 — Nginx Workers/Events | epoll, multi_accept, accept_mutex off, keepalive 10k, reuseport | Higher RPS, lower per-worker overhead | _fill in_ | _fill in_ |
| 4 — jemalloc | LD_PRELOAD jemalloc | Lower p99, flatter RSS over time | _fill in_ | _fill in_ |
| 5 — TLS Hardening | TLS 1.2/1.3, session cache, OCSP, HSTS | A+ rating; handshake amortized via resumption | _fill in_ | _fill in_ |
| 6 — Async File I/O | `aio on`, `directio 512k` | Lower CPU iowait on static; freed page cache | _fill in_ | _fill in_ |
| 7 — NUMA & Affinity | `worker_processes $(nproc)`, `worker_cpu_affinity auto` | Higher cache hit rate, less cross-socket latency | _fill in_ | _fill in_ |
| 8 — DPDK env | Hugepages, vfio-pci, NIC ceiling test | Establishes raw NIC ceiling vs kernel path | _fill in_ | _fill in_ |

## Notes per tier

### Tier 1 (cloud VM)
- Realistic ceiling: _fill in_
- Bottleneck hit first: _fill in_

### Tier 2 (32-core bare metal)
- Realistic ceiling: _fill in_
- Bottleneck hit first: _fill in_

### Tier 3 (128-core bare metal)
- Realistic ceiling: _fill in_
- Bottleneck hit first: _fill in_
