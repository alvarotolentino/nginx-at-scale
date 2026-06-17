//! HTTP layer. State is a cloneable redis ConnectionManager pointing at the lux
//! service; each handler clones it cheaply for its commands.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use redis::aio::ConnectionManager;

use crate::db;

pub type AppState = ConnectionManager;

/// GET /api/products → JSON array of all products.
pub async fn list_products(State(cm): State<AppState>) -> impl IntoResponse {
    let products = db::get_all_products(&cm).await;
    Json(products)
}

/// GET /api/products/:id → single product, or 404.
pub async fn get_product(
    State(cm): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match db::get_product(&cm, &id).await {
        Some(product) => (StatusCode::OK, Json(product)).into_response(),
        None => (StatusCode::NOT_FOUND, "product not found").into_response(),
    }
}

/// GET /api/orders → JSON array of all orders.
pub async fn list_orders(State(cm): State<AppState>) -> impl IntoResponse {
    let orders = db::get_all_orders(&cm).await;
    Json(orders)
}

/// GET /health → 200 "ok". Used by the smoke test and Nginx upstream checks.
pub async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}
