#!/usr/bin/env bash
# Sample the TARGET node's live utilization WHILE the tester generates load.
# This runs ON THE TARGET. It is the third leg of the measurement model:
#
#   snapshot.sh  (target)  — what state the box is in   (static, before load)
#   monitor.sh   (target)  — what the box is doing      (time series, DURING load)
#   load-test.sh (tester)  — how the box performed      (RPS / latency / errors)
#
# All three are correlated by --label. Without this file the report can only say
# "RPS went up" — with it, it can say *why* (CPU saturated? one core pegged on
# softirq? NIC at line rate? memory flat?) and compute efficiency (RPS/core).
#
# Zero dependencies: pure /proc + /sys (+ cgroup v2 for per-service CPU/RSS).
#
# Output: results/tier-<tier>/<label>/monitor/
#   timeseries.csv  one row per sample (interval default 2s)
#   summary.txt     parseable "key: value" aggregates merged by generate-report.sh
#
# Usage:
#   scripts/monitor.sh --label layer-3 --tier 1 --duration 45     # fixed window
#   scripts/monitor.sh --label layer-3 --tier 1 &                 # until SIGTERM/Ctrl-C
#   (apply-all-layers.sh starts/stops this automatically around each load pause)
#
# Metric notes:
#   cpu_pct           whole-machine busy % (0–100, all cores aggregated)
#   cpu_max_core_pct  busiest single core % — catches the "one core at 100%,
#                     rest idle" softirq/IRQ funnel that averages hide
#   softirq_pct       whole-machine %soft — the packet-steering signal
#   <svc>_cpu_pct     per-service CPU as % of ONE core (600% = 6 full cores),
#                     read from the service's cgroup so nginx workers are summed
#   rx/tx_mbps        NIC throughput — shows when the wire, not nginx, is the wall
#   tcp_inuse/tw      open TCP sockets / TIME-WAIT — the live concurrency view
#   retrans_ps        TCP retransmits/s — rising = network or buffer pressure
#   listen_drops_ps   accept-queue overflows/s — rising = backlog too small (Layer 1)
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
LABEL="run"
TIER="1"
DURATION="0"     # seconds; 0 = run until SIGTERM/SIGINT (finalizes on exit)
INTERVAL="2"
IFACE=""

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --label)    LABEL="$2"; shift 2 ;;
    --tier)     TIER="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --iface)    IFACE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$ROOT_DIR/results/tier-${TIER}/${LABEL}/monitor"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/timeseries.csv"
SUMMARY="$OUT_DIR/summary.txt"

# ---- interface --------------------------------------------------------------
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
fi
if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
  echo "ERROR: could not resolve a network interface (got '${IFACE:-empty}'). Pass --iface." >&2
  exit 1
fi

NPROC="$(nproc)"
CG_ROOT="/sys/fs/cgroup/system.slice"

# ---- readers (each echoes space-separated numbers; 0 on any failure) --------
# /proc/stat fields: cpu user nice system idle iowait irq softirq steal ...
# busy = total - idle - iowait. Diffed between two snapshots in compute_cpu.
snap_stat()  { cat /proc/stat; }

# service cgroup CPU time (usec) + current RSS (MB). cgroup v2 (Debian 12 default);
# absent cgroup (e.g. service not running) reads as 0 — columns stay parseable.
cg_cpu()  { awk '$1=="usage_usec"{print $2; f=1} END{if(!f) print 0}' \
              "$CG_ROOT/$1.service/cpu.stat" 2>/dev/null || echo 0; }
cg_mem()  { local b; b="$(cat "$CG_ROOT/$1.service/memory.current" 2>/dev/null || echo 0)"
            echo $(( b / 1048576 )); }

net_stat() { # rx_bytes tx_bytes rx_pkts tx_pkts
  local d="/sys/class/net/$IFACE/statistics"
  echo "$(cat "$d/rx_bytes" 2>/dev/null || echo 0) $(cat "$d/tx_bytes" 2>/dev/null || echo 0) \
        $(cat "$d/rx_packets" 2>/dev/null || echo 0) $(cat "$d/tx_packets" 2>/dev/null || echo 0)"
}

sock_stat() { # tcp_inuse tcp_tw
  awk '$1=="TCP:"{print $3, $7; f=1} END{if(!f) print 0, 0}' /proc/net/sockstat 2>/dev/null || echo "0 0"
}

tcpext_stat() { # listen_overflows listen_drops (cumulative)
  awk '$1=="TcpExt:"{ if (!h) { for(i=2;i<=NF;i++) ix[$i]=i; h=1 }
       else { print $ix["ListenOverflows"]+0, $ix["ListenDrops"]+0; f=1 } }
       END{if(!f) print 0, 0}' /proc/net/netstat 2>/dev/null || echo "0 0"
}

retrans_stat() { # retrans_segs (cumulative)
  awk '$1=="Tcp:"{ if (!h) { for(i=2;i<=NF;i++) ix[$i]=i; h=1 }
       else { print $ix["RetransSegs"]+0; f=1 } }
       END{if(!f) print 0}' /proc/net/snmp 2>/dev/null || echo 0
}

mem_used_mb() { # MemTotal - MemAvailable
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)/1024}' /proc/meminfo
}

# compute_cpu PREV_FILE CUR_FILE -> "cpu_pct max_core_pct softirq_pct"
compute_cpu() {
  awk '
    NR==FNR {
      if ($1=="cpu")                { for(i=2;i<=9;i++) pt+=$i; pb=pt-$5-$6; ps=$8 }
      else if ($1 ~ /^cpu[0-9]+$/)  { t=0; for(i=2;i<=9;i++) t+=$i; ppt[$1]=t; ppb[$1]=t-$5-$6 }
      next
    }
    {
      if ($1=="cpu")                { for(i=2;i<=9;i++) ct+=$i; cb=ct-$5-$6; cs=$8 }
      else if ($1 ~ /^cpu[0-9]+$/)  {
        t=0; for(i=2;i<=9;i++) t+=$i; b=t-$5-$6
        dt=t-ppt[$1]; db=b-ppb[$1]
        if (dt>0) { p=db/dt*100; if (p>maxc) maxc=p }
      }
    }
    END {
      dt=ct-pt; if (dt<=0) dt=1
      printf "%.1f %.1f %.1f", (cb-pb)/dt*100, maxc, (cs-ps)/dt*100
    }' "$1" "$2"
}

# ---- summary written on ANY exit (duration elapsed, SIGTERM, Ctrl-C) --------
finalize() {
  trap - EXIT TERM INT
  rows="$(($(wc -l < "$CSV") - 1))"
  if [ "$rows" -lt 1 ]; then
    echo "monitor: fewer than 1 sample collected — no summary" > "$SUMMARY"
    return 0
  fi
  # avg over all samples + avg over "busy" samples (cpu>10%, i.e. load actually
  # running — trims the idle head/tail so background monitoring doesn't dilute).
  awk -F, -v nproc="$NPROC" -v iface="$IFACE" -v interval="$INTERVAL" '
    NR==1 { next }
    {
      n++
      cpu+=$2;            if ($2>cpu_pk)   cpu_pk=$2
      if ($3>core_pk)     core_pk=$3
      if ($4>soft_pk)     soft_pk=$4
      if ($5>mem_pk)      mem_pk=$5
      if ($6>ncpu_pk)     ncpu_pk=$6
      if ($7>nrss_pk)     nrss_pk=$7
      if ($8>bcpu_pk)     bcpu_pk=$8
      if ($9>brss_pk)     brss_pk=$9
      if ($10>lcpu_pk)    lcpu_pk=$10
      if ($11>lrss_pk)    lrss_pk=$11
      if ($12>rx_pk)      rx_pk=$12
      if ($13>tx_pk)      tx_pk=$13
      if ($14>rxp_pk)     rxp_pk=$14
      if ($15>txp_pk)     txp_pk=$15
      if ($16>inuse_pk)   inuse_pk=$16
      if ($17>tw_pk)      tw_pk=$17
      retr+=$18*interval; drops+=$19*interval
      if ($2>10) { bn++; bcpu+=$2; bsoft+=$4; btx+=$13 }
    }
    END {
      printf "samples: %d\n",                 n
      printf "interval_s: %s\n",              interval
      printf "iface: %s\n",                   iface
      printf "nproc: %d\n",                   nproc
      printf "cpu_avg_pct: %.1f\n",           cpu/n
      printf "cpu_busy_avg_pct: %.1f\n",      bn ? bcpu/bn : 0
      printf "cpu_peak_pct: %.1f\n",          cpu_pk
      printf "cpu_max_core_peak_pct: %.1f\n", core_pk
      printf "softirq_peak_pct: %.1f\n",      soft_pk
      printf "softirq_busy_avg_pct: %.1f\n",  bn ? bsoft/bn : 0
      printf "mem_used_peak_mb: %d\n",        mem_pk
      printf "nginx_cpu_peak_pct: %.1f\n",    ncpu_pk
      printf "nginx_rss_peak_mb: %d\n",       nrss_pk
      printf "backend_cpu_peak_pct: %.1f\n",  bcpu_pk
      printf "backend_rss_peak_mb: %d\n",     brss_pk
      printf "lux_cpu_peak_pct: %.1f\n",      lcpu_pk
      printf "lux_rss_peak_mb: %d\n",         lrss_pk
      printf "rx_mbps_peak: %.1f\n",          rx_pk
      printf "tx_mbps_peak: %.1f\n",          tx_pk
      printf "tx_mbps_busy_avg: %.1f\n",      bn ? btx/bn : 0
      printf "rx_kpps_peak: %.1f\n",          rxp_pk
      printf "tx_kpps_peak: %.1f\n",          txp_pk
      printf "tcp_inuse_peak: %d\n",          inuse_pk
      printf "tcp_timewait_peak: %d\n",       tw_pk
      printf "retrans_total: %d\n",           retr
      printf "listen_drops_total: %d\n",      drops
    }' "$CSV" > "$SUMMARY"

  echo
  echo "==================== MONITOR SUMMARY ($LABEL) ===================="
  cat "$SUMMARY"
  echo "  Output: $OUT_DIR"
  echo "==================================================================="
}
trap finalize EXIT
trap 'exit 0' TERM INT

# ---- run --------------------------------------------------------------------
echo "Monitoring target for '${LABEL}' (tier ${TIER}) — iface ${IFACE}, every ${INTERVAL}s$( \
  [ "$DURATION" != "0" ] && echo ", ${DURATION}s window" || echo ", until SIGTERM/Ctrl-C")..."

echo "ts,cpu_pct,cpu_max_core_pct,softirq_pct,mem_used_mb,nginx_cpu_pct,nginx_rss_mb,backend_cpu_pct,backend_rss_mb,lux_cpu_pct,lux_rss_mb,rx_mbps,tx_mbps,rx_kpps,tx_kpps,tcp_inuse,tcp_tw,retrans_ps,listen_drops_ps" > "$CSV"

STAT_PREV="$OUT_DIR/.stat.prev"
STAT_CUR="$OUT_DIR/.stat.cur"

snap_stat > "$STAT_PREV"
read -r P_RX P_TX P_RXP P_TXP <<< "$(net_stat)"
read -r P_OVF P_DROPS <<< "$(tcpext_stat)"
P_RETR="$(retrans_stat)"
P_NGX="$(cg_cpu nginx)"; P_BCK="$(cg_cpu backend)"; P_LUX="$(cg_cpu lux)"
P_TS="$(date +%s.%N)"

END_TS=0
if [ "$DURATION" != "0" ]; then END_TS=$(( $(date +%s) + DURATION )); fi

while :; do
  sleep "$INTERVAL"

  NOW="$(date +%s.%N)"
  snap_stat > "$STAT_CUR"
  read -r CPU MAXCORE SOFT <<< "$(compute_cpu "$STAT_PREV" "$STAT_CUR")"
  read -r C_RX C_TX C_RXP C_TXP <<< "$(net_stat)"
  read -r C_OVF C_DROPS <<< "$(tcpext_stat)"
  C_RETR="$(retrans_stat)"
  C_NGX="$(cg_cpu nginx)"; C_BCK="$(cg_cpu backend)"; C_LUX="$(cg_cpu lux)"
  read -r INUSE TW <<< "$(sock_stat)"
  MEM="$(mem_used_mb)"

  awk -v ts="$NOW" -v pts="$P_TS" \
      -v cpu="$CPU" -v maxc="$MAXCORE" -v soft="$SOFT" -v mem="$MEM" \
      -v ngx="$C_NGX" -v pngx="$P_NGX" -v nrss="$(cg_mem nginx)" \
      -v bck="$C_BCK" -v pbck="$P_BCK" -v brss="$(cg_mem backend)" \
      -v lux="$C_LUX" -v plux="$P_LUX" -v lrss="$(cg_mem lux)" \
      -v rx="$C_RX" -v prx="$P_RX" -v tx="$C_TX" -v ptx="$P_TX" \
      -v rxp="$C_RXP" -v prxp="$P_RXP" -v txp="$C_TXP" -v ptxp="$P_TXP" \
      -v inuse="$INUSE" -v tw="$TW" \
      -v retr="$C_RETR" -v pretr="$P_RETR" \
      -v ovf="$C_OVF" -v povf="$P_OVF" -v drp="$C_DROPS" -v pdrp="$P_DROPS" '
    BEGIN {
      dt = ts - pts; if (dt <= 0) dt = 1
      printf "%d,%s,%s,%s,%d,%.1f,%d,%.1f,%d,%.1f,%d,%.1f,%.1f,%.1f,%.1f,%d,%d,%.1f,%.1f\n",
        ts, cpu, maxc, soft, mem,
        (ngx-pngx)/(dt*10000), nrss,
        (bck-pbck)/(dt*10000), brss,
        (lux-plux)/(dt*10000), lrss,
        (rx-prx)*8/dt/1e6, (tx-ptx)*8/dt/1e6,
        (rxp-prxp)/dt/1000, (txp-ptxp)/dt/1000,
        inuse, tw,
        (retr-pretr)/dt, ((ovf-povf)+(drp-pdrp))/dt
    }' >> "$CSV"

  mv "$STAT_CUR" "$STAT_PREV"
  P_TS="$NOW"; P_RX="$C_RX"; P_TX="$C_TX"; P_RXP="$C_RXP"; P_TXP="$C_TXP"
  P_RETR="$C_RETR"; P_OVF="$C_OVF"; P_DROPS="$C_DROPS"
  P_NGX="$C_NGX"; P_BCK="$C_BCK"; P_LUX="$C_LUX"

  if [ "$END_TS" != "0" ] && [ "$(date +%s)" -ge "$END_TS" ]; then
    break
  fi
done
