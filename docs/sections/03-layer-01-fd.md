# Layer 1 — File Descriptors & Socket Buffers

> **Goal of this stage.** Remove the first hard wall: the file-descriptor ceiling and the
> socket accept queues. Until these are raised, every later optimization is pointless —
> the box simply cannot *hold* enough connections to benefit from them.

## The wall you hit at baseline

Every TCP connection is a **file descriptor**. The stock per-process and per-user FD
limits are low (often 1024 soft), so a high-concurrency test produces `Too many open
files` in `error.log` and socket errors at the load generator — exactly the symptom
called out in [Section 02](02-baseline.md). This layer lifts every FD ceiling in the
chain *and* widens the kernel queues where new connections wait to be accepted.

## Three ceilings, all of which must move together

The trap is that these limits are layered, and raising one without the others does
nothing — the lowest cap wins.

| Ceiling | Where | Set by this layer |
|---------|-------|-------------------|
| Kernel system-wide FD max | `fs.file-max` | 2,097,152 |
| Kernel per-process FD max | `fs.nr_open` | 2,097,152 |
| Per-user soft/hard `nofile` | `/etc/security/limits.d/nginx.conf` | 2,097,152 |
| systemd service FD limit | `nginx.service.d/limits.conf` `LimitNOFILE` | 2,097,152 |
| Nginx worker FD limit | `worker_rlimit_nofile` (Layer 3 config) | 2,097,152 |

`fs.nr_open` must be **≥** the per-user `nofile` or the ulimit can't take effect.
Critically, **systemd ignores `/etc/security/limits.*`** for services — nginx run under
systemd needs its own `LimitNOFILE` drop-in, which is why
[apply-layer-1.sh](../../scripts/apply-layer-1.sh) writes both.

## Kernel parameters

From [kernel/sysctl/layer-01-fd-limits.conf](../../kernel/sysctl/layer-01-fd-limits.conf):

```ini
fs.file-max                  = 2097152   # system-wide FD ceiling (~2M concurrent conns)
fs.nr_open                   = 2097152   # per-process FD ceiling; must be >= user nofile
net.core.somaxconn           = 65535     # completed-connection (accept) queue per listener
net.core.netdev_max_backlog  = 65535     # NIC ingress packet queue before drops
net.ipv4.tcp_max_syn_backlog = 65535     # half-open (SYN_RECV) queue — SYN-flood headroom
net.ipv4.tcp_fin_timeout     = 15        # frees ephemeral ports faster under churn
net.ipv4.tcp_tw_reuse        = 1         # reuse TIME_WAIT sockets for new outbound conns
```

Two categories here:

- **FD ceilings** (`file-max`, `nr_open`) — how many connections the host can *hold*.
- **Accept/queue depth** (`somaxconn`, `netdev_max_backlog`, `tcp_max_syn_backlog`) — how
  many *pending* connections can wait without being dropped during a burst. Nginx's
  `listen ... backlog=` can never exceed `somaxconn`, so it's raised here first.

`tcp_tw_reuse` + the lower `tcp_fin_timeout` matter because nginx-as-a-proxy opens many
short-lived upstream connections; without them you exhaust ephemeral ports under load.

## Apply it

```bash
# TARGET
sudo scripts/apply-layer-1.sh
#   → installs the sysctl file as /etc/sysctl.d/99-nginx-perf.conf (the cumulative file
#     every later layer appends to), writes the limits.d + systemd LimitNOFILE drop-ins,
#     sets the CPU governor to performance (base host tuning — see below),
#     daemon-reload, nginx reload, then snapshot --label layer-1
```

## Base host tuning applied here: CPU governor = performance

Layer 1 is the **host** layer, so it's also where the first piece of the *base tuning*
(inherited by every later layer) is set: `set_cpu_governor_performance` in
[_lib.sh](../../scripts/_lib.sh) forces every core's cpufreq governor to `performance` and
persists it via a `nginx-cpu-governor.service` oneshot (sysfs governor resets on boot).

This matters more than it looks. The original layer sweep ran on a *demand* governor with
the cores downclocked, so every "100 % CPU" figure was 100 % of a **throttled** clock —
pinning the governor to max frequency was a large share of the measured ~2× throughput
gain. Setting it at Layer 1 means every layer below is measured at full clock. (Reverted
to `ondemand` by [reset-baseline.sh](../../scripts/reset-baseline.sh).)

```bash
# TESTER
scripts/load-test.sh --target https://<target-ip> --label layer-1 --tier <n>
```

## Verify

```bash
sysctl fs.file-max fs.nr_open net.core.somaxconn   # show the raised values
cat /proc/$(pidof nginx | awk '{print $1}')/limits | grep "Max open files"   # worker sees 2097152
```

The snapshot captures `socket-stats.txt` and `kernel-params.txt` under
`results/tier-N/layer-1/snapshot/` for the report.

## Expected impact

- The `Too many open files` errors from baseline **disappear**.
- Connection count ceiling jumps from ~1k/worker toward the new FD limit — though RPS may
  barely move yet: this layer unblocks *capacity*, not per-connection throughput. The
  buffer/behavior tuning that lifts throughput is **Layer 2**.

Next: [Layer 2 — Linux TCP/IP Kernel Tuning](04-layer-02-tcp.md).
