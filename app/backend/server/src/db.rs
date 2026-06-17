//! Data layer over the `lux` server (https://github.com/lux-db/lux).
//!
//! lux speaks RESP (Redis protocol), so we talk to it with redis-rs over the
//! network. The shared state is a `redis::aio::ConnectionManager` — a cheap,
//! cloneable, multiplexed, auto-reconnecting handle. Each helper clones it to a
//! local `mut` (the connection is internally shared) and issues commands.
//!
//! We use explicit `redis::cmd(...)` rather than the typed command traits so the
//! exact RESP command and return type are unambiguous:
//!   SET key value          -> ()
//!   GET key                -> Option<Vec<u8>>
//!   KEYS pattern           -> Vec<String>     (glob, e.g. "product:*")
//!   MGET k1 k2 ...          -> Vec<Option<Vec<u8>>>

use anyhow::Result;
use rand::Rng;
use redis::aio::ConnectionManager;
use uuid::Uuid;

use crate::models::{Order, Product};

const ADJECTIVES: [&str; 5] = ["Fast", "Premium", "Ultra", "Compact", "Smart"];
const NOUNS: [&str; 10] = [
    "Keyboard", "Monitor", "Chair", "Desk", "Headset", "Webcam", "Mouse", "Lamp", "Stand", "Hub",
];

/// Round an f64 to 2 decimal places (currency).
fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

async fn set_bytes(cm: &ConnectionManager, key: &str, value: Vec<u8>) -> Result<()> {
    let mut cm = cm.clone();
    redis::cmd("SET")
        .arg(key)
        .arg(value)
        .query_async::<()>(&mut cm)
        .await?;
    Ok(())
}

async fn get_bytes(cm: &ConnectionManager, key: &str) -> Result<Option<Vec<u8>>> {
    let mut cm = cm.clone();
    let v = redis::cmd("GET")
        .arg(key)
        .query_async::<Option<Vec<u8>>>(&mut cm)
        .await?;
    Ok(v)
}

/// KEYS pattern then MGET — returns the raw byte values for a prefix glob.
async fn scan_values(cm: &ConnectionManager, pattern: &str) -> Result<Vec<Vec<u8>>> {
    let mut cm = cm.clone();
    let keys = redis::cmd("KEYS")
        .arg(pattern)
        .query_async::<Vec<String>>(&mut cm)
        .await?;
    if keys.is_empty() {
        return Ok(Vec::new());
    }
    let values = redis::cmd("MGET")
        .arg(&keys)
        .query_async::<Vec<Option<Vec<u8>>>>(&mut cm)
        .await?;
    Ok(values.into_iter().flatten().collect())
}

/// Seed 100 products (5 adjectives × 10 nouns × 2 variants) once. Idempotent:
/// skips entirely if the "product:seeded" marker key is present.
pub async fn seed_products(cm: &ConnectionManager) -> Result<()> {
    if get_bytes(cm, "product:seeded").await?.is_some() {
        return Ok(());
    }

    let mut count = 0u32;
    for adj in ADJECTIVES {
        for noun in NOUNS {
            for variant in 0..2 {
                let id = Uuid::new_v4().to_string();
                // thread_rng is !Send across .await, so build the record's random
                // fields in a scope that drops the RNG before the await below.
                let product = {
                    let mut rng = rand::thread_rng();
                    let name = if variant == 0 {
                        format!("{adj} {noun}")
                    } else {
                        format!("{adj} {noun} Pro")
                    };
                    let price = round2(rng.gen_range(9.99..=499.99));
                    let stock = rng.gen_range(0..=500);
                    let description = format!(
                        "The {name} delivers reliable performance for everyday use. \
                         A {adj_lower} {noun_lower} built to last.",
                        adj_lower = adj.to_lowercase(),
                        noun_lower = noun.to_lowercase(),
                    );
                    Product { id: id.clone(), name, price, description, stock, image_url: "/assets/placeholder.jpg".to_string() }
                };
                set_bytes(cm, &format!("product:{id}"), serde_json::to_vec(&product)?).await?;
                count += 1;
            }
        }
    }

    set_bytes(cm, "product:seeded", count.to_string().into_bytes()).await?;
    tracing::info!("seeded {count} products");
    Ok(())
}

/// Seed 500 orders referencing random existing product ids. Idempotent via the
/// "order:seeded" marker key.
pub async fn seed_orders(cm: &ConnectionManager) -> Result<()> {
    if get_bytes(cm, "order:seeded").await?.is_some() {
        return Ok(());
    }

    let products = get_all_products(cm).await;
    if products.is_empty() {
        // Nothing to reference yet; bail without the marker so a later call retries.
        return Ok(());
    }

    for _ in 0..500 {
        let order = {
            let mut rng = rand::thread_rng();
            let product = &products[rng.gen_range(0..products.len())];
            let qty = rng.gen_range(1..=5u32);
            Order {
                id: Uuid::new_v4().to_string(),
                product_id: product.id.clone(),
                qty,
                total: round2(product.price * qty as f64),
            }
        };
        set_bytes(cm, &format!("order:{}", order.id), serde_json::to_vec(&order)?).await?;
    }

    set_bytes(cm, "order:seeded", b"500".to_vec()).await?;
    tracing::info!("seeded 500 orders");
    Ok(())
}

/// All products, sorted by name. Marker/malformed records are skipped, not fatal.
pub async fn get_all_products(cm: &ConnectionManager) -> Vec<Product> {
    let values = match scan_values(cm, "product:*").await {
        Ok(v) => v,
        Err(e) => {
            tracing::error!("scan products failed: {e}");
            return Vec::new();
        }
    };
    // The "product:seeded" marker matches the glob but isn't a Product; filter_map
    // drops it (and any malformed record) silently.
    let mut products: Vec<Product> = values
        .into_iter()
        .filter_map(|bytes| serde_json::from_slice::<Product>(&bytes).ok())
        .collect();
    products.sort_by(|a, b| a.name.cmp(&b.name));
    products
}

/// A single product by id, or None if absent / malformed.
pub async fn get_product(cm: &ConnectionManager, id: &str) -> Option<Product> {
    match get_bytes(cm, &format!("product:{id}")).await {
        Ok(Some(bytes)) => serde_json::from_slice::<Product>(&bytes).ok(),
        _ => None,
    }
}

/// All orders, unsorted.
pub async fn get_all_orders(cm: &ConnectionManager) -> Vec<Order> {
    match scan_values(cm, "order:*").await {
        Ok(values) => values
            .into_iter()
            .filter_map(|bytes| serde_json::from_slice::<Order>(&bytes).ok())
            .collect(),
        Err(e) => {
            tracing::error!("scan orders failed: {e}");
            Vec::new()
        }
    }
}
