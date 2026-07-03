#!/usr/bin/env bash
# =============================================================================
# Provision the TARGET node (bare metal, Debian 12 or 13) from a clean install.
#
# Installs and wires up the full stack as systemd services — NO Docker:
#   lux (RESP DB, loopback)  ->  backend (Axum, loopback)  ->  nginx (TLS, :443)
# plus the self-signed lab cert, the nftables firewall, and the baseline config.
#
# Run as root on the target:   sudo scripts/install-target.sh
# Then start a sweep:          sudo scripts/apply-all-layers.sh --tier <n>
#
# Idempotent-ish: re-running rebuilds the app and re-installs units. Layers are
# applied separately by apply-layer-N.sh / apply-all-layers.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# Ensure all scripts are executable (git does not always preserve the +x bit).
chmod +x "$SCRIPT_DIR"/*.sh

require_root

WEBROOT="/var/www/1b-shop"
BACKEND_BIN="/usr/local/bin/1b-backend"
LUX_BIN="/usr/local/bin/lux"
LUX_DATA="/var/lib/lux"

# ---- 1. system packages -----------------------------------------------------
log_step "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
  nginx build-essential pkg-config libssl-dev libaio-dev \
  numactl nftables curl git ca-certificates python3
log_ok "Base packages installed"

# Node 20 for the frontend build (NodeSource if the distro version is too old).
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt 18 ]; then
  log_step "Installing Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
log_ok "Node $(node -v) ready"

# ---- 2. Rust toolchain (stable, >= 1.85) ------------------------------------
if ! command -v cargo >/dev/null 2>&1; then
  log_step "Installing Rust (stable)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
# shellcheck disable=SC1090,SC1091
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
rustup update stable >/dev/null 2>&1 || true
log_ok "Rust $(cargo --version) ready"

# ---- 3. service users -------------------------------------------------------
log_step "Creating service users (appsvc, luxsvc)"
for u in appsvc luxsvc; do
  if ! id "$u" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$u"
    log_ok "Created system user ${u}"
  fi
done

# ---- 4. build + install the frontend ----------------------------------------
log_step "Building frontend (Vite)"
( cd "$ROOT_DIR/app/frontend" && npm install && npm run build )
mkdir -p "$WEBROOT"
# Vite emits to nginx/static (outDir ../../nginx/static); copy that into the webroot.
cp -r "$ROOT_DIR/nginx/static/." "$WEBROOT/"
chown -R root:root "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} +
find "$WEBROOT" -type f -exec chmod 644 {} +
log_ok "Frontend installed to ${WEBROOT}"

# ---- 5. build + install the backend -----------------------------------------
log_step "Building backend (cargo release)"
( cd "$ROOT_DIR/app/backend" && cargo build --release -p server )
install -m 0755 "$ROOT_DIR/app/backend/target/release/server" "$BACKEND_BIN"
log_ok "Backend installed to ${BACKEND_BIN}"

# ---- 6. build + install lux -------------------------------------------------
if [ ! -x "$LUX_BIN" ]; then
  log_step "Building lux from source (github.com/lux-db/lux)"
  cargo install --git https://github.com/lux-db/lux lux --root /usr/local \
    || log_warn "cargo install lux failed — install the lux binary to ${LUX_BIN} manually"
fi
install -d -o luxsvc -g luxsvc -m 0700 "$LUX_DATA"
log_ok "lux data dir ${LUX_DATA} (0700, luxsvc)"

# ---- 7. systemd units -------------------------------------------------------
log_step "Installing systemd units + hardening drop-ins"
install -m 0644 "$ROOT_DIR/deploy/systemd/lux.service"     /etc/systemd/system/lux.service
install -m 0644 "$ROOT_DIR/deploy/systemd/backend.service" /etc/systemd/system/backend.service
install -d /etc/systemd/system/nginx.service.d
install -m 0644 "$ROOT_DIR/deploy/systemd/nginx.service.d/hardening.conf" \
  /etc/systemd/system/nginx.service.d/hardening.conf
systemctl daemon-reload
systemctl enable --now lux.service
systemctl enable --now backend.service
log_ok "lux + backend services enabled and started"

# ---- 8. TLS cert (self-signed lab cert) -------------------------------------
log_step "Installing self-signed TLS cert"
[ -f "$ROOT_DIR/certs/nginx.crt" ] || "$SCRIPT_DIR/generate-certs.sh"
mkdir -p /etc/nginx/certs
cp "$ROOT_DIR/certs/nginx.crt" "$ROOT_DIR/certs/nginx.key" /etc/nginx/certs/
chmod 600 /etc/nginx/certs/nginx.key
log_ok "Cert installed to /etc/nginx/certs"

# ---- 9. baseline nginx config + restart under hardening ---------------------
# Ensure dirs referenced in the hardening drop-in ReadWritePaths exist.
# On Debian+nginx.org these are created by the package; on Ubuntu they may not be.
mkdir -p /var/cache/nginx /var/lib/nginx

log_step "Installing baseline nginx config"
nginx_install_conf "$ROOT_DIR/nginx/baseline.conf"
nginx -t
systemctl restart nginx     # restart (not reload) so the hardening drop-in takes effect
systemctl enable nginx
log_ok "nginx running (baseline) under systemd hardening"

# ---- 10. firewall -----------------------------------------------------------
log_step "Applying nftables firewall (only 22/80/443 inbound)"
cp "$ROOT_DIR/deploy/firewall/nftables.conf" /etc/nftables.conf
systemctl enable --now nftables
nft -f /etc/nftables.conf
log_ok "Firewall active — backend (8080) and lux (6379) stay loopback-only"

# ---- 11. smoke test ---------------------------------------------------------
log_step "Running target smoke test"
"$SCRIPT_DIR/smoke-test.sh" || log_warn "smoke test reported failures — inspect above"

echo
log_ok "Target provisioned. Next:"
echo "    sudo scripts/apply-all-layers.sh --tier <n>      # apply + snapshot each layer"
echo "    # from the tester: scripts/load-test.sh --target https://<this-ip> --label <layer>"
