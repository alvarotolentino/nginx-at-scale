# `dev/` — local development & tester convenience

**This is NOT the benchmark target.** The real target is bare metal, provisioned by
[`scripts/install-target.sh`](../scripts/install-target.sh) and run as systemd services
(see the [root README](../README.md)). Containers namespace away the kernel, network
stack, NUMA topology, and NIC tuning that this whole project exists to measure — so a
number taken against this Docker stack means nothing for the 1B-concurrency thesis.

Use this folder for:

- **Iterating on the app** (frontend/backend) without provisioning a box.
- **Standing up a throwaway target** for a separate tester node to hit while you develop
  `scripts/load-test.sh`.

## Usage

```bash
# from the repo root
docker compose -f dev/docker-compose.yml --profile build run --rm frontend-build
docker compose -f dev/docker-compose.yml up -d lux backend nginx
# app on http://localhost  (baseline, untuned nginx, HTTP only)
```

"Prod-like" immutable backend image (still local, not the tuned target):

```bash
docker compose -f dev/docker-compose.yml -f dev/docker-compose.prod.yml up -d --build
```

## How dev differs from the bare-metal target

| | dev (here) | bare-metal target |
|---|---|---|
| Runtime | Docker Compose | systemd services |
| Backend bind | `0.0.0.0:8080` (`BIND_ADDR` override) | `127.0.0.1:8080` (loopback) |
| lux bind | `0.0.0.0:6379` (container DNS) | `127.0.0.1:6379` (loopback) |
| CORS | permissive (`CORS_DEV=1`) | off (same-origin via nginx) |
| TLS / firewall / sandbox | none | self-signed TLS, nftables, systemd hardening |
| Tuning layers | not applicable | sysctl + nginx layers 1–8 |
