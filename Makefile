# Standalone zombienet multi-runtime testing tool.
#
# Tests parachain runtime upgrades on a local zombienet network.
# The relay chain always uses rococo-local (fast epochs, sudo pallet).
#
# Prerequisites:
#   - A moonbeam binary (built or downloaded)
#   - polkadot-js-api installed globally (npm i -g @polkadot/api-cli)
#   - python3
#
# Quick start:
#   make start \
#       MOONBEAM_BIN=/path/to/moonbeam \
#       PARA=moonbase PARA_RUNTIME_VER=4202 \
#       POLKADOT_VERSION=stable2407
#
#   make upgrade PARA=moonbase NEW_PARA_RUNTIME_VER=4300
#
# Known polkadot-sdk tags and approximate fellows runtime era:
#   stable2407  ~ fellows v1.3.x  (spec ~1003xxx)
#   stable2409  ~ fellows v1.4.x  (spec ~1004xxx)
#   stable2412  ~ fellows v1.6.x  (spec ~1006xxx)
#   stable2503  ~ fellows v1.7.x  (spec ~1007xxx)

ZOMBIENET_VERSION ?= v1.3.138

# Required for prepare/start targets
MOONBEAM_BIN ?=

# Optional: download a specific polkadot binary version.
# If empty, uses "polkadot" from PATH.
POLKADOT_VERSION ?=

RELAY ?= kusama
PARA ?= moonbase
PARA_RUNTIME_VER ?= 4202
NEW_PARA_RUNTIME_VER ?=

# Optional: path to a local parachain runtime WASM file.
# Skips GitHub download. Use for runtimes not published as releases.
PARA_WASM ?=

# ---------- platform detection ----------

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
UNAME_P := $(shell uname -p)

ZOMBIENET_BIN_POSTFIX :=
ifeq ($(UNAME_S),Linux)
	ZOMBIENET_BIN_POSTFIX := -linux
endif
ifeq ($(UNAME_S),Darwin)
	ZOMBIENET_BIN_POSTFIX := -macos
endif
ifeq ($(UNAME_P),x86_64)
	ZOMBIENET_BIN_POSTFIX := $(ZOMBIENET_BIN_POSTFIX)-x64
endif
ifneq ($(filter arm%,$(UNAME_P)),)
	ZOMBIENET_BIN_POSTFIX := $(ZOMBIENET_BIN_POSTFIX)-arm64
endif

ZOMBIENET_DOWNLOAD_URL := https://github.com/paritytech/zombienet/releases/download/$(ZOMBIENET_VERSION)
BIN_PATH := $(CURDIR)/bin
EXPORT_PATH := PATH=$(BIN_PATH):$(PATH)

# ---------- targets ----------

# Optional: polkadot-sdk release tag for relay runtime upgrade on running network.
NEW_RELAY_VERSION ?=

# Optional: polkadot-sdk release tag for rolling binary restart of relay validators.
RESTART_RELAY_VERSION ?=

.PHONY: download-zombienet prepare start upgrade upgrade-relay restart-relay kill clean help

help:
	@echo "Zombienet Multi-Runtime Testing"
	@echo ""
	@echo "Targets:"
	@echo "  download-zombienet  Download the zombienet binary"
	@echo "  prepare             Prepare chain specs and config (no spawn)"
	@echo "  start               Prepare and spawn the network"
	@echo "  upgrade             Upgrade parachain runtime on a running network"
	@echo "  upgrade-relay       Upgrade relay chain runtime on a running network"
	@echo "  restart-relay       Rolling restart relay validators (+ collator) with logs appended to zombienet *.log"
	@echo "  kill                Stop zombienet relay, parachain, and supervisor processes"
	@echo "  clean               Remove all generated files"
	@echo "  help                Show this message"
	@echo ""
	@echo "Variables:"
	@echo "  MOONBEAM_BIN        Path to moonbeam binary (required for prepare/start)"
	@echo "  POLKADOT_VERSION    polkadot-sdk release tag (e.g. stable2407)"
	@echo "  RELAY               Relay chain label (default: kusama)"
	@echo "  PARA                Parachain name (default: moonbase)"
	@echo "  PARA_RUNTIME_VER    Initial parachain runtime (default: 4202)"
	@echo "  NEW_PARA_RUNTIME_VER  Target parachain runtime for upgrade"
	@echo "  NEW_RELAY_VERSION   polkadot-sdk tag for relay runtime upgrade (e.g. stable2512-3)"
	@echo "  RESTART_RELAY_VERSION  polkadot-sdk tag for rolling binary restart"
	@echo "  PARA_WASM           Path to local WASM (skips GitHub download)"
	@echo ""
	@echo "Example:"
	@echo "  make start MOONBEAM_BIN=~/moonbeam PARA=moonbase PARA_RUNTIME_VER=4202 POLKADOT_VERSION=stable2407"

bin/zombienet:
	@mkdir -p bin
	@echo "Downloading zombienet $(ZOMBIENET_VERSION)..."
	@curl -fL --progress-bar -o bin/zombienet \
		"$(ZOMBIENET_DOWNLOAD_URL)/zombienet$(ZOMBIENET_BIN_POSTFIX)"
	@chmod +x bin/zombienet

download-zombienet: bin/zombienet

prepare: bin/zombienet
	@test -n "$(MOONBEAM_BIN)" || { echo "Error: MOONBEAM_BIN is required"; exit 1; }
	@$(EXPORT_PATH) ./scripts/prepare-runtime-test.sh \
		--moonbeam-bin $(MOONBEAM_BIN) \
		--relay $(RELAY) --para $(PARA) --para-runtime-ver $(PARA_RUNTIME_VER) \
		$(if $(POLKADOT_VERSION),--polkadot-version $(POLKADOT_VERSION)) \
		$(if $(PARA_WASM),--para-wasm $(PARA_WASM))

start: bin/zombienet
	@test -n "$(MOONBEAM_BIN)" || { echo "Error: MOONBEAM_BIN is required"; exit 1; }
	@$(EXPORT_PATH) ./scripts/prepare-runtime-test.sh \
		--moonbeam-bin $(MOONBEAM_BIN) \
		--relay $(RELAY) --para $(PARA) --para-runtime-ver $(PARA_RUNTIME_VER) \
		$(if $(POLKADOT_VERSION),--polkadot-version $(POLKADOT_VERSION)) \
		$(if $(PARA_WASM),--para-wasm $(PARA_WASM)) \
		--spawn

upgrade: bin/zombienet
	@test -n "$(NEW_PARA_RUNTIME_VER)" || { echo "Error: NEW_PARA_RUNTIME_VER is required"; exit 1; }
	@$(EXPORT_PATH) ./scripts/prepare-runtime-test.sh \
		--relay $(RELAY) --para $(PARA) \
		--upgrade-para-runtime $(NEW_PARA_RUNTIME_VER) \
		$(if $(PARA_WASM),--para-wasm $(PARA_WASM))

upgrade-relay:
	@test -n "$(NEW_RELAY_VERSION)" || { echo "Error: NEW_RELAY_VERSION is required (e.g. stable2512-3)"; exit 1; }
	@$(EXPORT_PATH) ./scripts/prepare-runtime-test.sh \
		--relay $(RELAY) --para $(PARA) \
		--upgrade-relay-runtime $(NEW_RELAY_VERSION)

restart-relay:
	@test -n "$(RESTART_RELAY_VERSION)" || { echo "Error: RESTART_RELAY_VERSION is required (e.g. stable2512-3)"; exit 1; }
	@$(EXPORT_PATH) ./scripts/prepare-runtime-test.sh \
		--relay $(RELAY) --para $(PARA) \
		--restart-relay-nodes $(RESTART_RELAY_VERSION)

kill:
	@$(EXPORT_PATH) ./scripts/prepare-runtime-test.sh \
		--relay $(RELAY) --para $(PARA) \
		--kill

clean:
	rm -rf bin/ runtimes/ specs/ configs/
