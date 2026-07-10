#!/usr/bin/env bash
# Build the ngx_brotli DYNAMIC module against the installed nginx (N1 prerequisite).
#
# Why a build: Debian/RHEL nginx packages don't ship brotli. The proposal's N1
# ("serve precompressed .br assets, ~15-20% smaller than gzip-9") needs the module.
# Static-only, so we build just the filter+static modules as a dynamic .so matching
# the EXACT installed nginx version, then load it with `load_module`.
#
# After this succeeds, enable serving with:  sudo scripts/apply-tune-nginx.sh --brotli
#
# Usage:  sudo scripts/build-brotli-module.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root

command -v nginx >/dev/null 2>&1 || { echo "ERROR: nginx not installed." >&2; exit 1; }

NGINX_VER="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
[ -n "$NGINX_VER" ] || { echo "ERROR: could not detect nginx version." >&2; exit 1; }
MOD_DIR="$(nginx -V 2>&1 | sed -n 's|.*--modules-path=\([^ ]*\).*|\1|p')"
MOD_DIR="${MOD_DIR:-/usr/lib/nginx/modules}"
log_step "Building ngx_brotli for nginx ${NGINX_VER} -> ${MOD_DIR}"

if [ -f "${MOD_DIR}/ngx_http_brotli_static_module.so" ]; then
  log_ok "brotli module already present in ${MOD_DIR} — nothing to build."
  exit 0
fi

# ---- toolchain + nginx build deps -------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y git build-essential libpcre2-dev zlib1g-dev libssl-dev cmake >/dev/null
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cd "$BUILD"

# ---- matching nginx source (module ABI is tied to the exact version + configure) --
CONFIGURE_ARGS="$(nginx -V 2>&1 | sed -n 's|^configure arguments: ||p')"
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" | tar xz
git clone --depth=1 --recurse-submodules https://github.com/google/ngx_brotli.git

# ngx_brotli needs its bundled brotli built once (CMake).
( cd ngx_brotli/deps/brotli && mkdir -p out && cd out \
    && cmake -DCMAKE_BUILD_TYPE=Release .. >/dev/null && cmake --build . --config Release >/dev/null )

cd "nginx-${NGINX_VER}"
# Reuse the distro's configure args so the module ABI matches, add brotli as dynamic.
eval ./configure ${CONFIGURE_ARGS} --add-dynamic-module=../ngx_brotli >/dev/null
make -j"$(nproc)" modules >/dev/null

install -d "$MOD_DIR"
install -m 0644 objs/ngx_http_brotli_filter_module.so "$MOD_DIR/"
install -m 0644 objs/ngx_http_brotli_static_module.so "$MOD_DIR/"
log_ok "Installed brotli modules to ${MOD_DIR}"
log_ok "Next: sudo scripts/apply-tune-nginx.sh --brotli   (adds load_module + brotli_static on, reloads)"
