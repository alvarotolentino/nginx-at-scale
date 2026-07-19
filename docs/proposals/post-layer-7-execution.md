# Post-Layer-7 Tuning — Execution Runbook (P1/P2)

> Target is already at **Layer 7**. Every item below applies **on top of** that end-state,
> one change at a time, each snapshot + load-tested in isolation — same discipline as the
> layer sweep. K5 (`mitigations=off`) is deliberately excluded for now.
> Reference numbers: [`results/latest_v1/tier-1/REPORT.md`](../../results/latest_v1/tier-1/REPORT.md).

## The two walls this attacks

- **Wall A — static/h2 CPU**: all 12 threads at 100 %, nginx ~1200 %. Levers: K1, K4, K6, K7.
- **Wall B — UI at 10 GbE line rate + 43–97k retrans/s**: NIC-bound, CPU idle in this phase.
  Levers: N1 (fewer bytes), N2 (more wire), K3 (stop the loss). K3's payoff here is
  **wire/latency, not CPU** — the retrans is in the NIC-bound phase where cores idle.

## Per-item tracking loop

For each item, on the two nodes:

```bash
# TARGET — apply ONE item, then snapshot
sudo scripts/tune-network-irq.sh --rings          # (example item)
sudo scripts/monitor.sh --label l7-k3-rings --tier 1 --duration 110 &

# TESTER — run the standard trio with the SAME label
scripts/load-test.sh --target https://<target-ip> --label l7-k3-rings --tier 1 \
  --profile highconn --h2 --api

# TARGET — copy tester load/ back, then
scripts/generate-report.sh --tier 1 --cost 0.41
```

Keep the item only if it clears its gate; else `--revert`. Label convention: `l7-<item>`.

## Sequence (ordered by expected payoff)

| # | Item | Apply (target) | Tester | Expected signal | Gate |
|---|---|---|---|---|---|
| 0 | **K3 diagnose** | `ethtool -S <if> \| grep -iE 'drop\|miss\|err'`; `tc -s qdisc show dev <if>`; `nstat -az \| grep -i retrans` **during the UI window** | run trio, watch | attribute the 43–97k/s loss (ring? qdisc? switch?) | measurement only |
| 1 | **N1 brotli** | `sudo scripts/build-brotli-module.sh` then `sudo scripts/apply-tune-nginx.sh --brotli` | add `--brotli` | UI RPS ↑ ~text-asset byte savings; 0 runtime CPU | keep if UI ≥ +3 % |
| 2 | **K3 rings + pause** | `sudo scripts/tune-network-irq.sh --rings --pause` | trio | UI-phase retrans ↓ order of magnitude | keep if retrans drops |
| 3 | **K4 coalescing** | `sudo scripts/tune-network-irq.sh --coalesce` | trio | softirq ↓ 2–5 pts; µs p50 rise OK | keep if softirq drops, RPS not worse |
| 4 | **K6 jumbo** | `sudo scripts/tune-network-irq.sh --jumbo` **(+ same MTU on tester + switch)** | trio | UI +3–4 %, softirq ↓ in UI | keep if UI ↑ and no PMTU stalls |
| 5 | **K1 notrack** | `sudo scripts/tune-network-irq.sh --notrack` | trio | softirq ↓, static/h2 ↑ single digit | keep if static/h2 ≥ +2 % |
| 6 | **K7 budget** | `sudo scripts/tune-network-irq.sh --budget` (only if softnet_stat time_squeeze climbing) | trio | smoother tail under peak pps | keep if p99 improves |
| 7 | **N2 second 10 GbE port** | manual: 2nd port own subnet/IP, nginx listen both, `tune-network-rps.sh` on both NICs | two tester procs, one per IP, sum RPS | UI ceiling → ~2× until CPU bites | effort; do after 1–4 banked |
| 8 | **K2 IRQ affinity** | `sudo scripts/tune-network-irq.sh --irq-affinity` | trio | flatten per-core skew | **weak premise** — static was balanced; check UI-phase `cpu_max_core` vs `cpu_avg` first |
| 9 | **N3 tickets** | `sudo scripts/apply-tune-nginx.sh --tickets` | `--profile churn` | faster cold handshakes | keep if churn RPS ↑; warm unchanged |
| 10 | **N4 ssl_buffer** | `sudo scripts/apply-tune-nginx.sh --ssl-buffer 4k` | trio | small; maybe static p99 | cheap experiment; keep the winner |

Priorities: **P1** = 1,2,5,7,8 (attack a measured wall). **P2** = 3,4,6,9,10.
N1 is first despite being "N": it's the highest-value, lowest-risk win (the `.br` files
already exist; zero runtime CPU) and the only lever that moves Wall B without new hardware.

## Scripts added

- [`scripts/tune-network-irq.sh`](../../scripts/tune-network-irq.sh) — K1/K2/K3/K4/K6/K7,
  per-flag, idempotent, boot-persistent, `--revert`.
- [`scripts/build-brotli-module.sh`](../../scripts/build-brotli-module.sh) — builds the
  ngx_brotli dynamic module for the installed nginx (N1 prerequisite).
- [`scripts/apply-tune-nginx.sh`](../../scripts/apply-tune-nginx.sh) — N1/N3/N4 toggles on
  the live L7 config, validate + reload + backup, `--revert`.
- [`scripts/load-test.sh`](../../scripts/load-test.sh) — new `--brotli` flag
  (`Accept-Encoding: br` on wrk + h2load) to measure N1.

**Caveat:** re-running `apply-layer-7.sh` reinstalls the stock L7 nginx config and drops
N1/N3/N4 — re-apply `apply-tune-nginx.sh` afterwards. The `tune-network-irq.sh` items are
independent of nginx and survive.
