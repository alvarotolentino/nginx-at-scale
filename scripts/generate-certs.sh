#!/usr/bin/env bash
# Generate a self-signed cert for LOCAL TESTING ONLY (never for production).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_DIR="$ROOT_DIR/certs"

mkdir -p "$CERT_DIR"

# 4096-bit RSA key + self-signed cert, valid 365 days. CN and SAN cover localhost
# so curl/wrk against https://localhost validate the name (with -k for the self-sign).
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout "$CERT_DIR/nginx.key" \
  -out "$CERT_DIR/nginx.crt" \
  -days 365 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"

chmod 600 "$CERT_DIR/nginx.key"
echo "Generated: $CERT_DIR/nginx.crt and $CERT_DIR/nginx.key"
