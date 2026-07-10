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
cd "$BUILD"
LOG="/tmp/brotli-build.log"
: > "$LOG"
# Keep the build tree + log on failure so the error is inspectable; clean only on success.
build_fail() { log_warn "Build failed — see $LOG (tree kept at $BUILD)"; }
trap build_fail ERR

# ---- sources ----------------------------------------------------------------
# ngx_brotli --recursive brings its own brotli (deps/brotli); nginx `make modules`
# compiles it as part of the module — no separate CMake step needed.
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" | tar xz
git clone --depth=1 --recurse-submodules https://github.com/google/ngx_brotli.git

cd "nginx-${NGINX_VER}"
# Build the module against a --with-compat nginx of the SAME version. --with-compat is
# the supported way to make a binary-compatible dynamic module WITHOUT replaying the
# distro's exact configure args (which reference build paths that don't exist here and
# is what broke the first attempt). Errors are shown, not swallowed.
log_step "configure (--with-compat --add-dynamic-module) — logging to $LOG"
./configure --with-compat --add-dynamic-module=../ngx_brotli >>"$LOG" 2>&1
log_step "make modules — logging to $LOG"
make -j"$(nproc)" modules >>"$LOG" 2>&1

for so in ngx_http_brotli_filter_module.so ngx_http_brotli_static_module.so; do
  [ -f "objs/$so" ] || { echo "ERROR: objs/$so not produced — see $LOG" >&2; exit 1; }
done

install -d "$MOD_DIR"
install -m 0644 objs/ngx_http_brotli_filter_module.so "$MOD_DIR/"
install -m 0644 objs/ngx_http_brotli_static_module.so "$MOD_DIR/"
trap - ERR
rm -rf "$BUILD"
log_ok "Installed brotli modules to ${MOD_DIR}"
log_ok "Next: sudo scripts/apply-tune-nginx.sh --brotli   (adds load_module + brotli_static on, reloads)"
