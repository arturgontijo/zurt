# Zombienet Multi-Runtime Testing

Standalone tool to test parachain runtime upgrades on a local zombienet network.

The relay chain always uses **rococo-local** (fast-runtime epochs, sudo pallet with Alice), so parachain onboarding is fast (~25 relay blocks). A specific `polkadot` binary version can be selected to control which rococo runtime era is embedded.

Runtime upgrades are performed via the parachain's **sudo pallet** (available on `moonbase-local` with Alith as sudo key), then the relay chain is notified of the new PVF via relay sudo.

## Prerequisites

- A **moonbeam binary** (built from source or downloaded from releases)
- **polkadot-js-api** installed globally: `npm i -g @polkadot/api-cli`
- **python3** (for chain spec patching and hex encoding)
- **curl** (for downloading binaries and runtimes)

If not using `--polkadot-version`, a `polkadot` binary must be in `PATH`.

## Quick Start

```bash
make start MOONBEAM_BIN=/path/to/moonbeam PARA=moonbase PARA_RUNTIME_VER=4202 POLKADOT_VERSION=stable2503
make upgrade NEW_PARA_RUNTIME_VER=4300
make kill
```

See [Examples (Makefile)](#examples-makefile) for one invocation per `make` target.

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make start` | Prepare chain specs and spawn the zombienet network |
| `make prepare` | Prepare chain specs and config without spawning |
| `make upgrade` | Upgrade the parachain runtime on a running network |
| `make upgrade-relay` | Upgrade relay chain runtime (on-chain WASM) on a running network |
| `make restart-relay` | Rolling restart of relay validators with a new polkadot binary |
| `make kill` | Stop zombienet relay validators, parachain collator, and `zombienet spawn` |
| `make download-zombienet` | Download the zombienet binary only |
| `make clean` | Remove all generated/downloaded files |
| `make help` | Show available targets and variables |

### Examples (Makefile)

```bash
# download-zombienet — install bin/zombienet (optional: ZOMBIENET_VERSION=v1.3.138)
make download-zombienet

# prepare — chain specs + zombienet TOML only (no spawn)
make prepare \
    MOONBEAM_BIN=/path/to/moonbeam \
    PARA=moonbase PARA_RUNTIME_VER=4202 \
    POLKADOT_VERSION=stable2503

# start — prepare and run zombienet spawn (foreground until stopped)
make start \
    MOONBEAM_BIN=/path/to/moonbeam \
    PARA=moonbase PARA_RUNTIME_VER=4202 \
    POLKADOT_VERSION=stable2503

# upgrade — parachain runtime on a running network (optional: PARA_WASM=…)
make upgrade PARA=moonbase NEW_PARA_RUNTIME_VER=4300

# upgrade-relay — relay on-chain runtime via sudo (needs running network)
make upgrade-relay NEW_RELAY_VERSION=stable2512-3

# restart-relay — rolling validator binary swap (needs running network)
make restart-relay RESTART_RELAY_VERSION=stable2512-3

# kill — stop relay validators, collator for PARA, and zombienet spawn
make kill RELAY=kusama PARA=moonbase

# clean — remove bin/, runtimes/, specs/, configs/
make clean

# help — print targets and variables
make help
```

## Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MOONBEAM_BIN` | Yes (prepare/start) | - | Path to moonbeam binary |
| `POLKADOT_VERSION` | No | - | polkadot-sdk release tag (e.g. `stable2503`) |
| `RELAY` | No | `kusama` | Relay chain label |
| `PARA` | No | `moonbase` | Parachain name: `moonbeam`, `moonriver`, `moonbase` |
| `PARA_RUNTIME_VER` | No | `4202` | Initial parachain runtime version |
| `NEW_PARA_RUNTIME_VER` | Yes (upgrade) | - | Target runtime version for upgrade |
| `NEW_RELAY_VERSION` | Yes (upgrade-relay) | - | polkadot-sdk tag for relay runtime upgrade |
| `RESTART_RELAY_VERSION` | Yes (restart-relay) | - | polkadot-sdk tag for rolling binary restart |
| `PARA_WASM` | No | - | Path to local WASM file (skips GitHub download) |
| `ZOMBIENET_VERSION` | No | `v1.3.138` | Zombienet release version |

## How It Works

1. **Downloads** the parachain runtime WASM from [moonbeam-foundation/moonbeam](https://github.com/moonbeam-foundation/moonbeam/releases) releases.
2. **Generates** the relay chain spec (`rococo-local`) from the polkadot binary (either from PATH or a downloaded versioned binary).
3. **Patches** the parachain chain spec with the target runtime WASM and correct genesis configuration.
4. **Generates** a zombienet TOML config pointing to all the specs and binaries.
5. **Spawns** the network via `zombienet spawn`.

For parachain upgrades:
1. Dispatches `sudo.sudo(system.authorizeUpgradeWithoutChecks(codeHash))` via Alith on the parachain.
2. Dispatches `system.applyAuthorizedUpgrade(wasm)` via Alith on the parachain.
3. Dispatches `sudo.sudo(paras.forceScheduleCodeUpgrade(paraId, wasm, block))` via Alice on the relay chain to notify it of the new PVF.

For relay runtime upgrades (`upgrade-relay`):
- Dispatches `sudo.sudoUncheckedWeight(system.setCodeWithoutChecks(wasm))` via Alice to replace the on-chain runtime WASM.

For rolling binary restarts (`restart-relay`):
- Downloads the new polkadot binary version.
- Finds running polkadot validator processes (by matching `--validator --insecure-validator-i-know-what-i-do`).
- Stops each validator one at a time, replaces the binary in the command, and restarts it — preserving the chain database, ports, and arguments.
- This is needed when the PVF validation logic in the *client binary* is incompatible with a newer parachain runtime (e.g., `InvalidCoreIndex` errors from UMP signal format changes).

## Known polkadot-sdk Tags

| Tag | Approx. Fellows Era | Spec Version Range |
|-----|---------------------|-------------------|
| `stable2407` | fellows v1.3.x | ~1003xxx |
| `stable2409` | fellows v1.4.x | ~1004xxx |
| `stable2412` | fellows v1.6.x | ~1006xxx |
| `stable2503` | fellows v1.7.x | ~1007xxx |

## Directory Structure

After running, the following directories are created (all gitignored):

```
bin/           Downloaded binaries (zombienet, polkadot-<version>/)
runtimes/      Downloaded parachain runtime WASMs and hex files
specs/         Generated chain specs (relay and parachain)
configs/       Generated zombienet TOML configs
```

## Direct Script Usage

The scripts can be used directly without `make`:

```bash
# Prepare and spawn
./scripts/prepare-runtime-test.sh \
    --moonbeam-bin /path/to/moonbeam \
    --relay kusama --para moonbase --para-runtime-ver 4202 \
    --polkadot-version stable2503 --spawn

# Upgrade on running network
./scripts/prepare-runtime-test.sh \
    --relay kusama --para moonbase \
    --upgrade-para-runtime 4300

# Rolling restart relay validators with a new binary
./scripts/prepare-runtime-test.sh \
    --relay kusama --para moonbase \
    --restart-relay-nodes stable2512-3

# Stop relay + parachain + zombienet supervisor (same RELAY/PARA as start)
./scripts/prepare-runtime-test.sh \
    --relay kusama --para moonbase --kill

# Upgrade relay on-chain runtime
./scripts/prepare-runtime-test.sh \
    --relay kusama --para moonbase \
    --upgrade-relay-runtime stable2512-3

# Upgrade script directly
node scripts/upgrade-para-runtime.mjs \
    ws://127.0.0.1:8802 ws://127.0.0.1:9901 \
    runtimes/moonbase-runtime-4300.wasm 1000
```
