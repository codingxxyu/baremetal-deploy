SHELL := /usr/bin/env bash
CONFIG ?= config/environments/customer.local.yaml

.PHONY: preflight render validate status import
preflight:
	CONFIG=$(CONFIG) ./scripts/preflight.sh
render: preflight
	CONFIG=$(CONFIG) ./scripts/render.sh
validate: render
	./scripts/validate.sh
status:
	./scripts/status.sh
import:
	./scripts/offline-image-import.sh
