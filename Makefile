# 1B Nginx — convenience targets wrapping the scripts/ bash entrypoints.
# All real logic lives in scripts/; this Makefile is a thin dispatcher so the
# common workflows have a short, memorable name.

SHELL := /bin/bash

.PHONY: help baseline measure reset layer smoke report run

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

baseline: ## Apply the stock baseline config and measure it
	scripts/apply-baseline.sh

measure: ## Run wrk + capture a full metrics snapshot
	scripts/measure.sh

reset: ## Revert all sysctl/Nginx tuning to vanilla state
	scripts/reset-baseline.sh

# Usage: make layer N=1
layer: ## Apply optimization layer N (e.g. make layer N=1)
	@if [ -z "$(N)" ]; then echo "Usage: make layer N=<1-8>"; exit 1; fi
	scripts/apply-layer-$(N).sh

smoke: ## Run the integration smoke test
	scripts/smoke-test.sh

report: ## Aggregate results into a Markdown report (TIER=1 default)
	scripts/generate-report.sh --tier $(or $(TIER),1)

run: ## Full end-to-end sweep across all layers (TIER=1 default)
	scripts/run-all-layers.sh --tier $(or $(TIER),1)
