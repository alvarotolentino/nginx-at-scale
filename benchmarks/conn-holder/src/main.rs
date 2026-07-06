//! conn-holder — a connection-*concurrency* benchmark.
//!
//! Unlike wrk/h2load (which push requests-per-second through a small pool of
//! connections), this tool opens N connections and **holds them open** with
//! periodic keepalive requests, so you can measure the server's concurrent-
//! connection ceiling and its memory-per-connection.
//!
//! The real limiter is usually the *tester's* ephemeral ports: one source IP can
//! reach ~28–64k connections to a single `ip:port`. Pass `--source-ip` repeatedly
//! (one per secondary address on the tester) to multiply the ceiling — each address
//! contributes its own ephemeral range and connections are spread round-robin.
//!
//! Measure the *server* side with `scripts/monitor.sh` during the hold: its
//! `tcp_inuse_peak` is the peak concurrent connections, and `mem_used_peak_mb`
//! divided by that gives memory-per-connection.

use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use clap::Parser;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpSocket;
use tokio::time::{interval, sleep_until, Instant as TokioInstant};
use tokio_rustls::rustls::pki_types::ServerName;
use tokio_rustls::rustls::ClientConfig;
use tokio_rustls::TlsConnector;

/// Open and hold N concurrent connections against a target to find its
/// connection ceiling.
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    /// Target `host:port` (e.g. `10.0.0.5:443`).
    #[arg(long)]
    target: String,

    /// Total connections to open and hold.
    #[arg(long, default_value_t = 100_000)]
    connections: u64,

    /// New connections per second during the ramp.
    #[arg(long, default_value_t = 5_000)]
    rate: u64,

    /// Seconds to hold all connections open after the ramp completes.
    #[arg(long, default_value_t = 60)]
    hold: u64,

    /// Negotiate TLS (accepts the self-signed lab cert — benchmark against your own target only).
    #[arg(long, default_value_t = false)]
    tls: bool,

    /// Source IP to bind, round-robin. Repeat once per secondary tester address; each adds ~64k ports.
    #[arg(long = "source-ip")]
    source_ip: Vec<IpAddr>,

    /// Request path.
    #[arg(long, default_value = "/")]
    path: String,

    /// Host header (defaults to the target host).
    #[arg(long)]
    host_header: Option<String>,

    /// Seconds between per-connection keepalive requests — keep below the server's `keepalive_timeout` (65s here).
    #[arg(long, default_value_t = 50)]
    keepalive: u64,

    /// Emit a machine-readable JSON summary line to stdout at the end.
    #[arg(long, default_value_t = false)]
    json: bool,
}

/// Shared, lock-free run counters. Each field is touched once per connection
/// *lifecycle* event (connect / establish / drop), not per I/O op, so at a few
/// thousand events/sec the false-sharing cost of packing them together is
/// negligible — no cache-line padding needed here.
#[derive(Default)]
struct Stats {
    spawned: AtomicU64,
    established: AtomicU64,
    active: AtomicU64,
    peak_active: AtomicU64,
    connect_errors: AtomicU64,
    tls_errors: AtomicU64,
    dropped: AtomicU64,
}

/// Any byte stream we can hold — a plain `TcpStream` or a TLS-wrapped one.
/// This is a held, mostly-idle connection, so the `dyn` vtable dispatch on
/// read/write is off the hot path and costs nothing measurable; it buys us one
/// hold loop instead of duplicating it per stream type.
trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

mod danger {
    //! Accept any server certificate. This tool benchmarks connection *count*
    //! against a target you own (self-signed lab cert), so chain validation is
    //! intentionally skipped — never reuse this verifier in a real client.
    use tokio_rustls::rustls::client::danger::{
        HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
    };
    use tokio_rustls::rustls::crypto::{ring, WebPkiSupportedAlgorithms};
    use tokio_rustls::rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use tokio_rustls::rustls::{DigitallySignedStruct, Error, SignatureScheme};

    #[derive(Debug)]
    pub struct NoVerify(WebPkiSupportedAlgorithms);

    impl NoVerify {
        pub fn new() -> Self {
            Self(ring::default_provider().signature_verification_algorithms)
        }
    }

    impl ServerCertVerifier for NoVerify {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.0.supported_schemes()
        }
    }
}

/// Open one connection and hold it until `deadline`, re-requesting every
/// `keepalive` interval so the server does not reap it as idle.
async fn hold_connection(
    target: SocketAddr,
    source: Option<IpAddr>,
    tls: Option<(TlsConnector, ServerName<'static>)>,
    request: Arc<Vec<u8>>,
    keepalive: Duration,
    deadline: TokioInstant,
    stats: Arc<Stats>,
) {
    let socket = match if target.is_ipv4() {
        TcpSocket::new_v4()
    } else {
        TcpSocket::new_v6()
    } {
        Ok(s) => s,
        Err(_) => {
            stats.connect_errors.fetch_add(1, Relaxed);
            return;
        }
    };
    if let Some(ip) = source {
        // Port 0 → the OS picks an ephemeral port from *this* source address's range.
        if socket.bind(SocketAddr::new(ip, 0)).is_err() {
            stats.connect_errors.fetch_add(1, Relaxed);
            return;
        }
    }
    let tcp = match socket.connect(target).await {
        Ok(s) => s,
        Err(_) => {
            stats.connect_errors.fetch_add(1, Relaxed);
            return;
        }
    };
    let _ = tcp.set_nodelay(true);

    let mut conn: Box<dyn Stream> = match tls {
        Some((connector, server_name)) => match connector.connect(server_name, tcp).await {
            Ok(s) => Box::new(s),
            Err(_) => {
                stats.tls_errors.fetch_add(1, Relaxed);
                return;
            }
        },
        None => Box::new(tcp),
    };

    let mut buf = [0u8; 8192];
    // Prime the connection: one request/response confirms the server accepted it.
    if conn.write_all(&request).await.is_err() || !matches!(conn.read(&mut buf).await, Ok(n) if n > 0) {
        stats.connect_errors.fetch_add(1, Relaxed);
        return;
    }

    stats.established.fetch_add(1, Relaxed);
    stats.active.fetch_add(1, Relaxed);

    loop {
        let next = TokioInstant::now() + keepalive;
        tokio::select! {
            _ = sleep_until(deadline) => break,
            _ = sleep_until(next.min(deadline)) => {
                if TokioInstant::now() >= deadline { break; }
                if conn.write_all(&request).await.is_err()
                    || !matches!(conn.read(&mut buf).await, Ok(n) if n > 0)
                {
                    stats.dropped.fetch_add(1, Relaxed);
                    break;
                }
            }
        }
    }

    stats.active.fetch_sub(1, Relaxed);
}

/// Progress line every 2s until aborted; also tracks the running peak.
async fn reporter(stats: Arc<Stats>, total: u64) {
    let start = Instant::now();
    let mut tick = interval(Duration::from_secs(2));
    tick.tick().await; // consume the immediate first tick
    loop {
        tick.tick().await;
        let active = stats.active.load(Relaxed);
        stats.peak_active.fetch_max(active, Relaxed);
        eprintln!(
            "[{:>4}s] established={} active={} peak={} conn_err={} tls_err={} dropped={} spawned={}/{}",
            start.elapsed().as_secs(),
            stats.established.load(Relaxed),
            active,
            stats.peak_active.load(Relaxed),
            stats.connect_errors.load(Relaxed),
            stats.tls_errors.load(Relaxed),
            stats.dropped.load(Relaxed),
            stats.spawned.load(Relaxed),
            total,
        );
    }
}

async fn resolve(target: &str) -> Result<SocketAddr> {
    if let Ok(sa) = target.parse::<SocketAddr>() {
        return Ok(sa);
    }
    tokio::net::lookup_host(target)
        .await
        .with_context(|| format!("could not resolve {target}"))?
        .next()
        .with_context(|| format!("no address for {target}"))
}

/// Extract the host portion of a `host:port` (also strips `[...]` for IPv6).
fn host_of(target: &str) -> String {
    match target.rsplit_once(':') {
        Some((h, _)) => h.trim_matches(|c| c == '[' || c == ']').to_string(),
        None => target.to_string(),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let target = resolve(&args.target).await?;
    let host = args
        .host_header
        .clone()
        .unwrap_or_else(|| host_of(&args.target));

    let request = Arc::new(
        format!(
            "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: keep-alive\r\nUser-Agent: conn-holder\r\n\r\n",
            args.path, host
        )
        .into_bytes(),
    );

    let tls = if args.tls {
        // Idempotent: ignore the error if a provider is already installed.
        let _ = tokio_rustls::rustls::crypto::ring::default_provider().install_default();
        let config = ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(danger::NoVerify::new()))
            .with_no_client_auth();
        let connector = TlsConnector::from(Arc::new(config));
        let server_name = ServerName::try_from(host.clone())
            .map_err(|e| anyhow::anyhow!("invalid server name {host:?}: {e}"))?;
        Some((connector, server_name))
    } else {
        None
    };

    let sources: Vec<Option<IpAddr>> = if args.source_ip.is_empty() {
        vec![None]
    } else {
        args.source_ip.iter().map(|ip| Some(*ip)).collect()
    };

    let stats = Arc::new(Stats::default());
    let keepalive = Duration::from_secs(args.keepalive.max(1));
    let ramp = Duration::from_secs_f64(args.connections as f64 / args.rate.max(1) as f64);
    let deadline = TokioInstant::now() + ramp + Duration::from_secs(args.hold);

    eprintln!(
        "conn-holder → {target} (tls={}) | {} conns @ {}/s ramp (~{:.0}s) + {}s hold | {} source IP(s)",
        args.tls,
        args.connections,
        args.rate,
        ramp.as_secs_f64(),
        args.hold,
        sources.len(),
    );

    let reporter_handle = tokio::spawn(reporter(stats.clone(), args.connections));

    // Ramp: spawn in fixed-cadence batches so the connect rate is smooth and the
    // server's accept path isn't hit by a single thundering herd.
    let batch = Duration::from_millis(25);
    let per_batch = (((args.rate as f64) * batch.as_secs_f64()).ceil() as u64).max(1);
    let mut ticker = interval(batch);
    let mut spawned = 0u64;
    while spawned < args.connections {
        ticker.tick().await;
        let n = per_batch.min(args.connections - spawned);
        for _ in 0..n {
            let src = sources[(spawned as usize) % sources.len()];
            let tls = tls.clone();
            let request = request.clone();
            let stats = stats.clone();
            tokio::spawn(hold_connection(
                target, src, tls, request, keepalive, deadline, stats,
            ));
            spawned += 1;
        }
        stats.spawned.store(spawned, Relaxed);
    }

    // Wait out the hold, or stop early on Ctrl-C.
    tokio::select! {
        _ = sleep_until(deadline + Duration::from_secs(2)) => {}
        _ = tokio::signal::ctrl_c() => eprintln!("\ninterrupted — reporting current state"),
    }
    reporter_handle.abort();

    // Final peak read.
    stats
        .peak_active
        .fetch_max(stats.active.load(Relaxed), Relaxed);
    let peak = stats.peak_active.load(Relaxed);
    let established = stats.established.load(Relaxed);
    let conn_err = stats.connect_errors.load(Relaxed);
    let tls_err = stats.tls_errors.load(Relaxed);
    let dropped = stats.dropped.load(Relaxed);

    eprintln!("\n──────── summary ────────");
    eprintln!("target:            {target}  (tls={})", args.tls);
    eprintln!("requested:         {}", args.connections);
    eprintln!("established (peak): {peak}");
    eprintln!("total established:  {established}");
    eprintln!("connect errors:    {conn_err}");
    eprintln!("tls errors:        {tls_err}");
    eprintln!("dropped mid-hold:  {dropped}");
    eprintln!("→ on the TARGET, read scripts/monitor.sh: tcp_inuse_peak ≈ {peak}; mem_used_peak_mb ÷ that = KB/conn.");

    if args.json {
        // Hand-rolled to avoid a serde dependency for one line.
        println!(
            "{{\"target\":\"{target}\",\"tls\":{},\"requested\":{},\"peak_established\":{peak},\"total_established\":{established},\"connect_errors\":{conn_err},\"tls_errors\":{tls_err},\"dropped\":{dropped}}}",
            args.tls, args.connections
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_of_strips_port() {
        assert_eq!(host_of("10.0.0.5:443"), "10.0.0.5");
        assert_eq!(host_of("example.com:80"), "example.com");
        assert_eq!(host_of("[::1]:443"), "::1");
        assert_eq!(host_of("bare-host"), "bare-host");
    }

    #[tokio::test]
    async fn resolve_parses_socketaddr() {
        let sa = resolve("127.0.0.1:8080").await.expect("valid socketaddr");
        assert_eq!(sa.port(), 8080);
        assert!(sa.ip().is_loopback());
    }
}
