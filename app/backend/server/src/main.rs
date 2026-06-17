//! 1B Shop backend: a minimal Axum API backed by the `lux` server (Redis-
//! compatible). Its only job is to serve realistic dynamic traffic
//! (products/orders) so the Nginx concurrency numbers measured upstream are
//! meaningful rather than synthetic.

mod db;
mod handlers;
mod models;

use std::time::Duration;

use anyhow::{Context, Result};
use axum::{routing::get, Router};
use tower_http::{cors::CorsLayer, trace::TraceLayer};

use handlers::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    // Structured logging; honor RUST_LOG, default to info.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    // Connect to the lux server over RESP. REDIS_URL points at the lux service
    // (docker-compose: redis://lux:6379; local: redis://127.0.0.1:6379).
    let redis_url =
        std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());
    let client = redis::Client::open(redis_url.clone())
        .with_context(|| format!("opening redis client for {redis_url}"))?;

    // The lux container may still be starting; retry the initial connection so
    // `docker compose up` ordering doesn't race us.
    let cm = connect_with_retry(&client).await?;
    tracing::info!("connected to lux at {redis_url}");

    // Seed dummy data; both calls are idempotent (marker keys gate re-seeding).
    db::seed_products(&cm).await.context("seeding products")?;
    db::seed_orders(&cm).await.context("seeding orders")?;

    // ConnectionManager is cheaply cloneable; share it as Axum state directly.
    let state: AppState = cm;

    let app = Router::new()
        .route("/api/products", get(handlers::list_products))
        .route("/api/products/:id", get(handlers::get_product))
        .route("/api/orders", get(handlers::list_orders))
        .route("/health", get(handlers::health))
        // CORS open for local development only — Nginx terminates and proxies in prod.
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = "0.0.0.0:8080";
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    tracing::info!("backend listening on http://{addr}");

    axum::serve(listener, app)
        .await
        .context("axum server error")?;
    Ok(())
}

/// Open a ConnectionManager, retrying for up to ~30s while the lux service boots.
async fn connect_with_retry(client: &redis::Client) -> Result<AppState> {
    let mut attempt = 0;
    loop {
        match client.get_connection_manager().await {
            Ok(cm) => return Ok(cm),
            Err(e) => {
                attempt += 1;
                if attempt >= 30 {
                    return Err(anyhow::anyhow!(e)).context("lux not reachable after 30 attempts");
                }
                tracing::warn!("lux not ready (attempt {attempt}): {e}; retrying in 1s");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}
