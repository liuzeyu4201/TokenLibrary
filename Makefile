.DEFAULT_GOAL := help
.PHONY: start logs help hashcred
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
mode ?= service

help:
	@echo "make start [mode=service|middleware]"
	@echo "make logs  [mode=service|middleware]"
	@echo "Default mode: service. Configuration: .env (see docs/operations/deployment.md)."

start:
	@python3 "$(ROOT)/deploy/scripts/manage.py" start --mode "$(mode)"

logs:
	@python3 "$(ROOT)/deploy/scripts/manage.py" logs --mode "$(mode)"

hashcred:
	cd "$(ROOT)/server" && go run ./cmd/hashcred $(ARGS)
