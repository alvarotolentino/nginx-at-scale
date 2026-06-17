use serde::{Deserialize, Serialize};

/// A catalog item served at /api/products and /api/products/:id.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Product {
    pub id: String,
    pub name: String,
    pub price: f64,
    pub description: String,
    pub stock: u32,
    pub image_url: String,
}

/// A dummy order record served at /api/orders. Generated at seed time to give
/// the dynamic endpoint a non-trivial payload to serialize under load.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Order {
    pub id: String,
    pub product_id: String,
    pub qty: u32,
    pub total: f64,
}
