# 1B Nginx — convenience targets wrapping the scripts/ bash entrypoints.
# All real logic lives in scripts/; this Makefile is a thin dispatcher so the
# common workflows have a short, memorable name.

SHELL := /bin/bash

.PHONY: help install baseline snapshot load reset layer smoke report sweep

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

install: ## (target) Provision the bare-metal target from scratch
	scripts/install-target.sh

baseline: ## (target) Apply the stock baseline config and snapshot it
	scripts/apply-baseline.sh

snapshot: ## (target) Capture target system state (LABEL=, TIER=1)
	scripts/snapshot.sh --label $(or $(LABEL),run) --tier $(or $(TIER),1)

# Usage: make load TARGET=https://10.0.0.5 LABEL=layer-1 TIER=2
load: ## (tester) Generate load against the target
	@if [ -z "$(TARGET)" ]; then echo "Usage: make load TARGET=https://<ip> LABEL=<label>"; exit 1; fi
	scripts/load-test.sh --target $(TARGET) --label $(or $(LABEL),run) --tier $(or $(TIER),1)

reset: ## (target) Revert all sysctl/Nginx tuning to vanilla state
	scripts/reset-baseline.sh

# Usage: make layer N=1
layer: ## (target) Apply optimization layer N (e.g. make layer N=1)
	@if [ -z "$(N)" ]; then echo "Usage: make layer N=<1-8>"; exit 1; fi
	scripts/apply-layer-$(N).sh

smoke: ## Run the smoke test (add TARGET=https://<ip> for tester mode)
	scripts/smoke-test.sh $(if $(TARGET),--target $(TARGET),)

report: ## (target) Aggregate results into a Markdown report (TIER=1 default)
	scripts/generate-report.sh --tier $(or $(TIER),1)

sweep: ## (target) Full layer sweep, pausing for the tester (TIER=1 default)
	scripts/apply-all-layers.sh --tier $(or $(TIER),1)
