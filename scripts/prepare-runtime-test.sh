#!/usr/bin/env bash
#
# Standalone tool to test parachain runtime upgrades on a local zombienet.
#
# Downloads a parachain runtime WASM, generates chain specs, and spawns a
# zombienet network. The relay chain always uses rococo-local (fast-runtime,
# sudo pallet, short epochs) so the parachain activates quickly (~25 relay
# blocks). A specific polkadot binary version can be selected via
# --polkadot-version to control which rococo runtime is embedded.
#
# Runtime upgrades use the parachain's sudo pallet (available on moonbase-local)
# to authorize and apply the upgrade, then notify the relay via sudo.
#
# Usage:
#   ./scripts/prepare-runtime-test.sh \
#       --moonbeam-bin /path/to/moonbeam \
#       --relay kusama --para moonbase --para-runtime-ver 4202 --spawn
#
#   ./scripts/prepare-runtime-test.sh --relay kusama --para moonbase --kill
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIMES_DIR="$ROOT_DIR/runtimes"
SPECS_DIR="$ROOT_DIR/specs"
CONFIGS_DIR="$ROOT_DIR/configs"
BIN_DIR="$ROOT_DIR/bin"

MOONBEAM_REPO="moonbeam-foundation/moonbeam"
POLKADOT_SDK_REPO="paritytech/polkadot-sdk"

RELAY=""
PARA=""
PARA_RUNTIME_VER=""
POLKADOT_VER=""
MOONBEAM_BIN=""
PARA_WASM=""
DO_SPAWN=false
DO_KILL=false
DO_UPGRADE_PARA=""
DO_UPGRADE_RELAY=""
DO_RESTART_RELAY=""

# Resolved at runtime
POLKADOT_CMD="polkadot"

# ---------- parachain metadata ----------

para_id_for() {
    case "$1" in
        moonbeam)  echo 2004 ;;
        moonriver) echo 2023 ;;
        moonbase)  echo 1000 ;;
        *) echo "Unknown parachain: $1" >&2; exit 1 ;;
    esac
}

para_chain_for() {
    case "$1" in
        moonbeam)  echo "moonbeam-local" ;;
        moonriver) echo "moonriver-local" ;;
        moonbase)  echo "moonbase-local" ;;
        *) echo "Unknown parachain: $1" >&2; exit 1 ;;
    esac
}

relay_rpc_port_for() {
    case "$1" in
        polkadot) echo 9900 ;;
        kusama)   echo 9901 ;;
        *) echo "Unknown relay: $1" >&2; exit 1 ;;
    esac
}

para_rpc_port_for() {
    case "$1" in
        moonbeam)  echo 8800 ;;
        moonriver) echo 8801 ;;
        moonbase)  echo 8802 ;;
        *) echo "Unknown parachain: $1" >&2; exit 1 ;;
    esac
}

# ---------- helpers ----------

usage() {
    cat << 'EOF'
Standalone tool to test parachain runtime upgrades on a local zombienet.

The relay chain uses rococo-local (fast-runtime, sudo pallet, short epochs)
so the parachain activates quickly (~25 relay blocks).

Usage:
  prepare-runtime-test.sh [OPTIONS]

Required:
  --relay <chain>              Relay chain label: kusama | polkadot
  --para <chain>               Parachain: moonbeam | moonriver | moonbase
  --para-runtime-ver <ver>     Moonbeam spec_version number (e.g. 4202).
                               Not required with --kill.
  --moonbeam-bin <path>        Path to the moonbeam binary (for chain spec
                               generation). Not required for --upgrade-para-runtime
                               or --kill.

Optional:
  --polkadot-version <tag>     polkadot-sdk release tag (e.g. stable2407).
                               Downloads that binary and uses its embedded
                               rococo-local runtime (with sudo + fast epochs).
                               If omitted, uses "polkadot" from PATH.
  --para-wasm <path>           Path to a local parachain runtime WASM file.
                               Skips GitHub download. Use this for runtimes
                               that aren't published as GitHub releases.
  --spawn                      Spawn the network after preparation
  --upgrade-para-runtime <ver> Upgrade the parachain on a running network
  --upgrade-relay-runtime <tag> Upgrade the relay runtime on a running network.
                               Downloads the polkadot binary for <tag>, extracts
                               the embedded rococo WASM, and applies it via sudo.
  --restart-relay-nodes <tag>  Rolling restart of relay validators with a new
                               polkadot binary version. Downloads the binary,
                               finds running validator processes, and restarts
                               each one with the new binary while preserving
                               the chain state and database. Validator and
                               moonbeam collator stdout/stderr are appended to
                               the same zombienet session *.log files as spawn;
                               collators are restarted after relay RPC recovers.
  --kill                       Stop zombienet-spawned relay validators, the
                               parachain collator for --para (matched by chain
                               id + RPC port), and the zombienet spawn process.
                               Does not delete chain data. Only --relay and
                               --para are required with this flag.
  -h, --help                   Show this help

Examples:
  # Start with polkadot from PATH
  ./scripts/prepare-runtime-test.sh \
      --moonbeam-bin /path/to/moonbeam \
      --relay kusama --para moonbase --para-runtime-ver 4202 --spawn

  # Start with a specific polkadot binary version
  ./scripts/prepare-runtime-test.sh \
      --moonbeam-bin /path/to/moonbeam \
      --relay kusama --para moonbase --para-runtime-ver 4202 \
      --polkadot-version stable2407 --spawn

  # Upgrade relay runtime to a newer version (e.g. to fix PVF compatibility)
  ./scripts/prepare-runtime-test.sh \
      --relay kusama --para moonbase \
      --upgrade-relay-runtime stable2512-3

  # Rolling restart: replace polkadot binary on running validators
  ./scripts/prepare-runtime-test.sh \
      --relay kusama --para moonbase \
      --restart-relay-nodes stable2512-3

  # Stop all zombienet relay + parachain processes for this relay/para pair
  ./scripts/prepare-runtime-test.sh \
      --relay kusama --para moonbase --kill

  # Upgrade parachain using a locally-built WASM
  ./scripts/prepare-runtime-test.sh \
      --relay kusama --para moonbase \
      --upgrade-para-runtime 4300 \
      --para-wasm /path/to/moonbase_runtime.wasm
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --relay)                RELAY="$2";             shift 2 ;;
            --para)                 PARA="$2";              shift 2 ;;
            --para-runtime-ver)     PARA_RUNTIME_VER="$2";  shift 2 ;;
            --polkadot-version)     POLKADOT_VER="$2";      shift 2 ;;
            --moonbeam-bin)         MOONBEAM_BIN="$2";       shift 2 ;;
            --para-wasm)            PARA_WASM="$2";          shift 2 ;;
            --spawn)                DO_SPAWN=true;           shift   ;;
            --kill)                 DO_KILL=true;            shift   ;;
            --upgrade-para-runtime)  DO_UPGRADE_PARA="$2";    shift 2 ;;
            --upgrade-relay-runtime) DO_UPGRADE_RELAY="$2";  shift 2 ;;
            --restart-relay-nodes)  DO_RESTART_RELAY="$2";  shift 2 ;;
            -h|--help)              usage ;;
            *) echo "Unknown option: $1" >&2; usage ;;
        esac
    done

    if [[ -z "$RELAY" ]]; then echo "Error: --relay is required" >&2; exit 1; fi
    if [[ -z "$PARA" ]];  then echo "Error: --para is required"  >&2; exit 1; fi
    if $DO_KILL && { $DO_SPAWN || [[ -n "$DO_UPGRADE_PARA" ]] || [[ -n "$DO_UPGRADE_RELAY" ]] || [[ -n "$DO_RESTART_RELAY" ]]; }; then
        echo "Error: --kill cannot be combined with --spawn, upgrade, or restart flags" >&2; exit 1
    fi
    if [[ -z "$DO_UPGRADE_PARA" ]] && [[ -z "$DO_UPGRADE_RELAY" ]] && [[ -z "$DO_RESTART_RELAY" ]] && ! $DO_KILL && [[ -z "$PARA_RUNTIME_VER" ]]; then
        echo "Error: --para-runtime-ver is required" >&2; exit 1
    fi
    if [[ -z "$DO_UPGRADE_PARA" ]] && [[ -z "$DO_UPGRADE_RELAY" ]] && [[ -z "$DO_RESTART_RELAY" ]] && ! $DO_KILL && [[ -z "$MOONBEAM_BIN" ]]; then
        echo "Error: --moonbeam-bin is required (path to moonbeam binary)" >&2; exit 1
    fi
    if [[ -n "$MOONBEAM_BIN" ]] && [[ ! -x "$MOONBEAM_BIN" ]]; then
        echo "Error: moonbeam binary not found or not executable: $MOONBEAM_BIN" >&2; exit 1
    fi
    if [[ -n "$PARA_WASM" ]] && [[ ! -f "$PARA_WASM" ]]; then
        echo "Error: WASM file not found: $PARA_WASM" >&2; exit 1
    fi
}

# ---------- platform detection ----------

polkadot_bin_suffix() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            case "$arch" in
                arm64|aarch64) echo "-aarch64-apple-darwin" ;;
                x86_64)        echo "-x86_64-apple-darwin" ;;
                *)             echo "" ;;
            esac
            ;;
        Linux)
            echo ""
            ;;
        *)
            echo "" ;;
    esac
}

# ---------- download polkadot binaries ----------

download_polkadot_version() {
    local tag="$1"
    local dest_dir="$BIN_DIR/polkadot-${tag}"
    local suffix
    suffix="$(polkadot_bin_suffix)"

    local bins=("polkadot" "polkadot-execute-worker" "polkadot-prepare-worker")

    local all_present=true
    for b in "${bins[@]}"; do
        if [[ ! -x "$dest_dir/$b" ]]; then
            all_present=false
            break
        fi
    done

    if $all_present; then
        echo "  [skip] polkadot ${tag} binaries already present in $(basename "$dest_dir")/"
        return
    fi

    mkdir -p "$dest_dir"
    local base_url="https://github.com/$POLKADOT_SDK_REPO/releases/download/polkadot-${tag}"

    for b in "${bins[@]}"; do
        if [[ -x "$dest_dir/$b" ]]; then
            echo "  [skip] ${b} already present"
            continue
        fi
        local url="${base_url}/${b}${suffix}"
        echo "  Downloading ${b} (${tag})..."
        if ! curl -fL --progress-bar -o "$dest_dir/$b" "$url"; then
            rm -f "$dest_dir/$b"
            echo "Error: Failed to download $url" >&2
            echo "Check that tag 'polkadot-${tag}' exists at:" >&2
            echo "  https://github.com/$POLKADOT_SDK_REPO/releases/tag/polkadot-${tag}" >&2
            exit 1
        fi
        chmod +x "$dest_dir/$b"
    done

    echo "  Polkadot ${tag} binaries ready in $(basename "$dest_dir")/"
}

# ---------- download parachain WASM ----------

download_para_wasm() {
    PARA_WASM_NAME="${PARA}-runtime-${PARA_RUNTIME_VER}.wasm"
    PARA_WASM_PATH="$RUNTIMES_DIR/$PARA_WASM_NAME"

    if [[ -f "$PARA_WASM_PATH" ]]; then
        echo "  [skip] Parachain WASM already present: $PARA_WASM_NAME"
    elif [[ -n "$PARA_WASM" ]]; then
        echo "  Copying local WASM: $PARA_WASM"
        cp "$PARA_WASM" "$PARA_WASM_PATH"
        echo "  Saved: $PARA_WASM_PATH ($(wc -c < "$PARA_WASM_PATH" | xargs) bytes)"
    else
        local url="https://github.com/$MOONBEAM_REPO/releases/download/runtime-$PARA_RUNTIME_VER/$PARA_WASM_NAME"
        echo "  Downloading $url"
        if ! curl -fL --progress-bar -o "$PARA_WASM_PATH" "$url"; then
            rm -f "$PARA_WASM_PATH"
            echo "Error: Failed to download ${PARA_WASM_NAME}." >&2
            echo "  runtime-${PARA_RUNTIME_VER} may not exist at:" >&2
            echo "  https://github.com/$MOONBEAM_REPO/releases" >&2
            echo "" >&2
            echo "  Provide a local WASM with: --para-wasm /path/to/runtime.wasm" >&2
            exit 1
        fi
        echo "  Saved: $PARA_WASM_PATH ($(wc -c < "$PARA_WASM_PATH" | xargs) bytes)"
    fi

    PARA_WASM_HEX_NAME="${PARA}-runtime-${PARA_RUNTIME_VER}.hex"
    PARA_WASM_HEX_PATH="$RUNTIMES_DIR/$PARA_WASM_HEX_NAME"

    if [[ -f "$PARA_WASM_HEX_PATH" ]]; then
        echo "  [skip] Hex-encoded parachain WASM already present: $PARA_WASM_HEX_NAME"
        return
    fi

    echo "  Hex-encoding parachain WASM for zombienet..."
    python3 -c "
import sys
with open(sys.argv[1], 'rb') as f:
    data = f.read()
with open(sys.argv[2], 'w') as f:
    f.write('0x' + data.hex())
" "$PARA_WASM_PATH" "$PARA_WASM_HEX_PATH"
    echo "  Saved: $PARA_WASM_HEX_PATH"
}

# ---------- prepare relay chain spec ----------

# Generate the relay chain spec and resolve the polkadot command.
# Without --polkadot-version: generates rococo-local.json using "polkadot" from PATH.
# With --polkadot-version: downloads the specific polkadot binary and generates
#   rococo-local-<tag>.json from it.
prepare_relay_chain_spec() {
    if [[ -z "$POLKADOT_VER" ]]; then
        RELAY_SPEC="$SPECS_DIR/rococo-local.json"
        POLKADOT_CMD="polkadot"

        if [[ -f "$RELAY_SPEC" ]]; then
            echo "  [skip] Relay spec already exists: $(basename "$RELAY_SPEC")"
            return
        fi

        if ! command -v polkadot &>/dev/null; then
            echo "Error: 'polkadot' not found in PATH." >&2
            echo "Either install polkadot or use --polkadot-version to download one." >&2
            exit 1
        fi

        echo "  Generating rococo-local spec from polkadot in PATH..."
        polkadot build-spec --chain rococo-local --disable-default-bootnode 2>/dev/null \
            > "$RELAY_SPEC"

        local size_kb
        size_kb=$(( $(wc -c < "$RELAY_SPEC" | xargs) / 1024 ))
        echo "  Saved: $(basename "$RELAY_SPEC") (${size_kb} KB)"
        return
    fi

    # Download versioned polkadot binaries
    echo "  Downloading polkadot ${POLKADOT_VER} binaries..."
    download_polkadot_version "$POLKADOT_VER"

    local polkadot_bin="$BIN_DIR/polkadot-${POLKADOT_VER}/polkadot"
    POLKADOT_CMD="$polkadot_bin"

    RELAY_SPEC="$SPECS_DIR/rococo-local-${POLKADOT_VER}.json"
    if [[ -f "$RELAY_SPEC" ]]; then
        echo "  [skip] Relay spec already exists: $(basename "$RELAY_SPEC")"
        return
    fi

    echo "  Generating rococo-local spec from polkadot ${POLKADOT_VER}..."
    "$polkadot_bin" build-spec --chain rococo-local --disable-default-bootnode 2>/dev/null \
        > "$RELAY_SPEC"

    local size_kb
    size_kb=$(( $(wc -c < "$RELAY_SPEC" | xargs) / 1024 ))
    echo "  Saved: $(basename "$RELAY_SPEC") (${size_kb} KB)"
}

# ---------- patch parachain chain spec ----------

patch_para_chain_spec() {
    local para_chain
    para_chain="$(para_chain_for "$PARA")"

    PATCHED_PARA_SPEC="$SPECS_DIR/${para_chain}-rt${PARA_RUNTIME_VER}.json"

    if [[ -f "$PATCHED_PARA_SPEC" ]]; then
        echo "  [skip] Patched parachain spec already exists: $(basename "$PATCHED_PARA_SPEC")"
        return
    fi

    echo "  Generating base parachain spec from moonbeam binary..."
    local base_spec="$SPECS_DIR/${para_chain}-base.json"
    "$MOONBEAM_BIN" build-spec --chain "$para_chain" 2>/dev/null > "$base_spec"

    echo "  Patching parachain spec with runtime ${PARA_RUNTIME_VER} WASM + eligibleCount=1..."
    python3 << PYEOF
import json

with open("$base_spec") as f:
    spec = json.load(f)

with open("$PARA_WASM_PATH", "rb") as f:
    wasm_hex = "0x" + f.read().hex()

genesis = spec.get("genesis", {})
if "runtimeGenesis" not in genesis:
    raise RuntimeError("Expected non-raw spec with runtimeGenesis section")

genesis["runtimeGenesis"]["code"] = wasm_hex
rg = genesis["runtimeGenesis"]
for key in ("config", "patch"):
    if key not in rg:
        continue
    rg[key].setdefault("authorFilter", {})["eligibleCount"] = 1
    break

with open("$base_spec", "w") as f:
    json.dump(spec, f)

print("  Patched WASM + eligibleCount=1 in non-raw spec")
PYEOF

    mv "$base_spec" "$PATCHED_PARA_SPEC"

    local size_mb
    size_mb=$(python3 -c "import os; print(f'{os.path.getsize(\"$PATCHED_PARA_SPEC\") / (1024*1024):.1f}')")
    echo "  Saved: $(basename "$PATCHED_PARA_SPEC") (${size_mb} MB)"
}

# ---------- resolve parachain WASM (for upgrades) ----------

resolve_para_wasm() {
    local ver="$1"
    local wasm_name="${PARA}-runtime-${ver}.wasm"
    local wasm_path="$RUNTIMES_DIR/$wasm_name"

    if [[ -f "$wasm_path" ]]; then
        echo "  [skip] WASM already present: $wasm_name" >&2
        echo "$wasm_path"
        return
    fi

    # Use locally-provided WASM if specified
    if [[ -n "$PARA_WASM" ]]; then
        echo "  Copying local WASM: $PARA_WASM" >&2
        cp "$PARA_WASM" "$wasm_path"
        echo "  Saved: $wasm_path ($(wc -c < "$wasm_path" | xargs) bytes)" >&2
        echo "$wasm_path"
        return
    fi

    local url="https://github.com/$MOONBEAM_REPO/releases/download/runtime-${ver}/$wasm_name"
    echo "  Downloading: $url" >&2
    if curl -fL --progress-bar -o "$wasm_path" "$url" 2>/dev/null; then
        echo "  Saved: $wasm_path ($(wc -c < "$wasm_path" | xargs) bytes)" >&2
        echo "$wasm_path"
        return
    fi
    rm -f "$wasm_path"

    echo "Error: Cannot find runtime WASM for ${PARA} ${ver}." >&2
    echo "  Not found on GitHub and no --para-wasm provided." >&2
    echo "  Provide a local WASM with: --para-wasm /path/to/runtime.wasm" >&2
    return 1
}

# ---------- generate zombienet config ----------

generate_config() {
    local para_id para_chain relay_rpc para_rpc
    para_id="$(para_id_for "$PARA")"
    para_chain="$(para_chain_for "$PARA")"
    relay_rpc="$(relay_rpc_port_for "$RELAY")"
    para_rpc="$(para_rpc_port_for "$PARA")"

    CONFIG_FILE="$CONFIGS_DIR/${PARA}-${RELAY}-rt${PARA_RUNTIME_VER}.toml"

    local polkadot_cmd_toml
    if [[ "$POLKADOT_CMD" == "polkadot" ]]; then
        polkadot_cmd_toml="polkadot"
    else
        polkadot_cmd_toml="$(python3 -c "import os; print(os.path.relpath('$POLKADOT_CMD', '$ROOT_DIR'))")"
    fi

    # moonbeam command — resolve to absolute path so zombienet can find it
    local moonbeam_cmd_toml
    moonbeam_cmd_toml="$(cd "$(dirname "$MOONBEAM_BIN")" && pwd)/$(basename "$MOONBEAM_BIN")"

    cat > "$CONFIG_FILE" << TOML
[settings]
provider = "native"

[relaychain]
default_command = "${polkadot_cmd_toml}"
default_args = ["-lruntime::bridge-grandpa=trace"]
chain_spec_path = "$(python3 -c "import os; print(os.path.relpath('$RELAY_SPEC', '$ROOT_DIR'))")"

[[relaychain.nodes]]
name = "alice"
validator = true
rpc_port = ${relay_rpc}
args = ["--blocks-pruning=archive", "--state-pruning=archive"]

[[relaychain.nodes]]
name = "bob"
validator = true

[[parachains]]
id = ${para_id}
chain_spec_path = "$(python3 -c "import os; print(os.path.relpath('$PATCHED_PARA_SPEC', '$ROOT_DIR'))")"
cumulus_based = true
genesis_wasm_path = "runtimes/${PARA_WASM_HEX_NAME}"

[[parachains.collators]]
name = "alith"
command = "${moonbeam_cmd_toml}"
rpc_port = ${para_rpc}
args = [
    "--no-hardware-benchmarks",
    "--no-telemetry",
    "-lruntime::bridge-grandpa=trace",
    "--pool-type=fork-aware"
]

[types.Header]
number = "u64"
parent_hash = "Hash"
post_state = "Hash"
TOML

    echo "  Config written: $CONFIG_FILE"
}

# ---------- parachain runtime upgrade on running network ----------

upgrade_para_runtime() {
    local new_ver="$1"
    local para_rpc_port relay_rpc_port para_id
    para_rpc_port="$(para_rpc_port_for "$PARA")"
    relay_rpc_port="$(relay_rpc_port_for "$RELAY")"
    para_id="$(para_id_for "$PARA")"

    local wasm_path
    wasm_path="$(resolve_para_wasm "$new_ver")"

    echo "  Upgrading runtime to ${new_ver}..."
    echo "  1. Parachain sudo: authorize + apply upgrade"
    echo "  2. Relay sudo: paras.forceScheduleCodeUpgrade (notify relay of new PVF)"

    set +e
    node "$SCRIPT_DIR/upgrade-para-runtime.mjs" \
        "ws://127.0.0.1:${para_rpc_port}" \
        "ws://127.0.0.1:${relay_rpc_port}" \
        "$wasm_path" \
        "$para_id" 2>&1
    local rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        echo ""
        echo "  WARNING: Parachain runtime upgrade failed (exit $rc)."
        echo "  You can retry manually:"
        echo "    node $SCRIPT_DIR/upgrade-para-runtime.mjs \\"
        echo "      ws://127.0.0.1:${para_rpc_port} \\"
        echo "      ws://127.0.0.1:${relay_rpc_port} \\"
        echo "      $wasm_path $para_id"
    fi
}

# ---------- relay runtime upgrade on running network ----------

# Extract the rococo-local runtime WASM from a polkadot binary.
# Generates a non-raw spec and pulls out genesis.runtimeGenesis.code.
extract_relay_wasm() {
    local tag="$1"
    local wasm_out="$RUNTIMES_DIR/rococo-local-${tag}.wasm"

    if [[ -f "$wasm_out" ]]; then
        echo "  [skip] Relay WASM already extracted: $(basename "$wasm_out")" >&2
        echo "$wasm_out"
        return
    fi

    download_polkadot_version "$tag" >&2
    local polkadot_bin="$BIN_DIR/polkadot-${tag}/polkadot"

    echo "  Extracting rococo-local WASM from polkadot ${tag}..." >&2
    python3 -c "
import json, subprocess, sys

spec_json = subprocess.check_output(
    ['$polkadot_bin', 'build-spec', '--chain', 'rococo-local',
     '--disable-default-bootnode'],
    stderr=subprocess.DEVNULL,
)
spec = json.loads(spec_json)
code_hex = spec['genesis']['runtimeGenesis']['code']
if code_hex.startswith('0x'):
    code_hex = code_hex[2:]
wasm_bytes = bytes.fromhex(code_hex)
with open('$wasm_out', 'wb') as f:
    f.write(wasm_bytes)
print(f'  Saved: $wasm_out ({len(wasm_bytes) // 1024} KB)', file=sys.stderr)
"
    echo "$wasm_out"
}

upgrade_relay_runtime() {
    local tag="$1"
    local relay_rpc_port
    relay_rpc_port="$(relay_rpc_port_for "$RELAY")"

    local wasm_path
    wasm_path="$(extract_relay_wasm "$tag")"

    echo "  Upgrading relay runtime to ${tag}..."
    echo "  sudo.sudoUncheckedWeight(system.setCodeWithoutChecks(wasm))"

    set +e
    node "$SCRIPT_DIR/upgrade-relay-runtime.mjs" \
        "ws://127.0.0.1:${relay_rpc_port}" \
        "$wasm_path" 2>&1
    local rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        echo ""
        echo "  WARNING: Relay runtime upgrade failed (exit $rc)."
        echo "  You can retry manually:"
        echo "    node $SCRIPT_DIR/upgrade-relay-runtime.mjs \\"
        echo "      ws://127.0.0.1:${relay_rpc_port} $wasm_path"
    fi
}

# ---------- rolling binary restart of relay validators ----------

# Zombienet native: logs are …/<session>/<node>.log (e.g. …/zombie-…/alice.log).
# --base-path may be …/<session>/<node> or …/<session>/<node>/data (substrate layout).
zombienet_node_log_path() {
    local base_path="$1"
    [[ -z "$base_path" ]] && return 1
    local normalized="${base_path%/}"
    local zombie_dir node_name node_dir

    if [[ "$normalized" == */data ]]; then
        node_dir="$(dirname "$normalized")"
        zombie_dir="$(dirname "$node_dir")"
        node_name="$(basename "$node_dir")"
    else
        zombie_dir="$(dirname "$normalized")"
        node_name="$(basename "$normalized")"
    fi
    printf '%s\n' "${zombie_dir}/${node_name}.log"
}

# After relay validators are swapped, restart moonbeam collator(s) for this network
# with stdout/stderr appended to the same zombienet <name>.log files.
restart_collators_same_logs() {
    local para_rpc_port para_id
    para_rpc_port="$(para_rpc_port_for "$PARA")"
    para_id="$(para_id_for "$PARA")"

    echo ""
    echo "  Restarting parachain collator(s) (same command, append to zombienet logs)..."

    local -a pids=()
    local -a cmds=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid rest
        pid="$(echo "$line" | awk '{print $1}')"
        rest="$(echo "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')"
        [[ -z "$pid" || -z "$rest" ]] && continue
        pids+=("$pid")
        cmds+=("$rest")
    done < <(ps -ww -eo pid,args 2>/dev/null \
        | grep -E -- "--rpc-port(=|[[:space:]]+)${para_rpc_port}([[:space:]]|$)" \
        | grep -E -- "--parachain-id(=|[[:space:]]+)${para_id}([[:space:]]|$)" \
        | grep -E '[mM]oonbeam' || true)

    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "  (No moonbeam collator process matched rpc-port ${para_rpc_port} / para-id ${para_id}; skipped.)"
        return 0
    fi

    local i
    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        local cmd="${cmds[$i]}"

        local base_path log_file
        base_path="$(echo "$cmd" | sed -n 's/.*--base-path \([^ ]*\).*/\1/p')"
        if [[ -z "$base_path" ]]; then
            echo "  WARNING: Could not parse --base-path for collator PID ${pid}; skipping." >&2
            continue
        fi
        log_file="$(zombienet_node_log_path "$base_path")" || continue

        echo "  --- Restarting collator (PID ${pid}) → ${log_file} ---"

        kill "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi

        echo "--- collator restarted at $(date -u) ---" >> "$log_file"
        nohup bash -c "exec $cmd" >> "$log_file" 2>&1 &
        echo "  Started collator (PID $!)"
        if [[ $i -lt $((${#pids[@]} - 1)) ]]; then
            sleep 3
        fi
    done
}

restart_relay_nodes() {
    local tag="$1"
    local relay_rpc_port
    relay_rpc_port="$(relay_rpc_port_for "$RELAY")"

    echo "  Downloading polkadot ${tag} binaries..."
    download_polkadot_version "$tag"
    local new_bin
    new_bin="$(cd "$BIN_DIR/polkadot-${tag}" && pwd)/polkadot"

    echo ""
    echo "  Finding running polkadot validator processes..."

    local pids=()
    local cmds=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid
        pid="$(echo "$line" | awk '{print $1}')"
        local cmd
        cmd="$(echo "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')"
        pids+=("$pid")
        cmds+=("$cmd")
    done < <(ps -ww -eo pid,args 2>/dev/null | grep "[p]olkadot.*--validator.*--insecure-validator-i-know-what-i-do" || true)

    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "  ERROR: No polkadot validator processes found." >&2
        echo "  Make sure the zombienet network is running." >&2
        exit 1
    fi

    echo "  Found ${#pids[@]} validator process(es)"
    echo ""

    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        local cmd="${cmds[$i]}"

        local name
        name="$(echo "$cmd" | sed -n 's/.*--name \([^ ]*\).*/\1/p')"

        local old_bin
        old_bin="$(echo "$cmd" | awk '{print $1}')"

        local new_cmd="${cmd/$old_bin/$new_bin}"

        local base_path log_file
        base_path="$(echo "$cmd" | sed -n 's/.*--base-path \([^ ]*\).*/\1/p')"
        if [[ -z "$base_path" ]]; then
            echo "  ERROR: Could not parse --base-path from validator command line." >&2
            exit 1
        fi
        log_file="$(zombienet_node_log_path "$base_path")"

        echo "  --- Restarting ${name} (PID ${pid}) → ${log_file} ---"
        echo "  Old: ${old_bin}"
        echo "  New: ${new_bin}"

        echo "  Stopping ${name}..."
        kill "$pid" 2>/dev/null || true

        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
            sleep 1
            waited=$((waited + 1))
        done

        if kill -0 "$pid" 2>/dev/null; then
            echo "  Force-killing ${name}..."
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi

        echo "  Starting ${name} with polkadot ${tag}..."
        echo "--- restarted with polkadot ${tag} at $(date -u) ---" >> "$log_file"
        nohup bash -c "exec $new_cmd" >> "$log_file" 2>&1 &
        local new_pid=$!
        echo "  Started ${name} (PID ${new_pid})"

        # Brief pause between nodes to avoid simultaneous restart
        if [[ $i -lt $((${#pids[@]} - 1)) ]]; then
            echo "  Waiting 5s before next node..."
            sleep 5
        fi

        echo ""
    done

    echo "  All validators restarted. Waiting for relay RPC on port ${relay_rpc_port}..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if curl -s -H "Content-Type: application/json" \
            -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
            "http://127.0.0.1:${relay_rpc_port}" 2>/dev/null | grep -q "result"; then
            echo "  Relay RPC is back on port ${relay_rpc_port}"
            break
        fi
        sleep 2
        attempts=$((attempts + 1))
        if [[ $((attempts % 5)) -eq 0 ]]; then
            echo "  Waiting... (${attempts}/${max_attempts})"
        fi
    done

    if [[ $attempts -ge $max_attempts ]]; then
        echo "  WARNING: Relay RPC did not respond within $((max_attempts * 2))s."
        echo "  Check logs manually."
        return
    fi

    echo ""
    echo "  Checking relay chain health..."
    local health
    health="$(curl -s -H "Content-Type: application/json" \
        -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
        "http://127.0.0.1:${relay_rpc_port}" 2>/dev/null)"
    echo "  Health: ${health}"

    local version
    version="$(curl -s -H "Content-Type: application/json" \
        -d '{"id":1,"jsonrpc":"2.0","method":"state_getRuntimeVersion","params":[]}' \
        "http://127.0.0.1:${relay_rpc_port}" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d['result']
    print(f\"{r['specName']}/{r['specVersion']} (impl: {r['implName']}/{r['implVersion']})\")
except Exception:
    print('(could not parse)')
" 2>/dev/null)"
    echo "  Runtime: ${version}"

    restart_collators_same_logs
}

# ---------- stop zombienet (relay + parachain + supervisor) ----------

# SIGTERM a PID, wait up to ~10s, then SIGKILL if still alive.
sig_stop_pid() {
    local pid="$1"
    local label="${2:-PID ${pid}}"

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    echo "  Stopping ${label} (${pid})..."
    kill "$pid" 2>/dev/null || true

    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "  Force-killing ${label} (${pid})..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
}

kill_zombienet_network() {
    local para_rpc_port para_id
    para_rpc_port="$(para_rpc_port_for "$PARA")"
    para_id="$(para_id_for "$PARA")"

    echo "=== Stopping Zombienet Network ==="
    echo "  Relay label: $RELAY (parachain RPC filter: ${para_rpc_port}, para id: ${para_id})"
    echo ""

    local -a collator_pids=()
    local -a validator_pids=()
    local -a zombienet_pids=()

    local line pid

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid="$(echo "$line" | awk '{print $1}')"
        [[ -z "$pid" ]] && continue
        collator_pids+=("$pid")
    done < <(ps -ww -eo pid,args 2>/dev/null \
        | grep -E -- "--rpc-port(=|[[:space:]]+)${para_rpc_port}([[:space:]]|$)" \
        | grep -E -- "--parachain-id(=|[[:space:]]+)${para_id}([[:space:]]|$)" || true)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid="$(echo "$line" | awk '{print $1}')"
        [[ -z "$pid" ]] && continue
        validator_pids+=("$pid")
    done < <(ps -ww -eo pid,args 2>/dev/null \
        | grep "[p]olkadot.*--validator.*--insecure-validator-i-know-what-i-do" || true)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid="$(echo "$line" | awk '{print $1}')"
        [[ -z "$pid" ]] && continue
        zombienet_pids+=("$pid")
    done < <(ps -ww -eo pid,args 2>/dev/null \
        | grep -E "[z]ombienet.*[[:space:]]spawn[[:space:]]" || true)

    local found=false
    if [[ ${#collator_pids[@]} -gt 0 ]]; then found=true; fi
    if [[ ${#validator_pids[@]} -gt 0 ]]; then found=true; fi
    if [[ ${#zombienet_pids[@]} -gt 0 ]]; then found=true; fi

    if ! $found; then
        echo "  No matching zombienet processes found (collators on rpc-port ${para_rpc_port} / para-id ${para_id}, polkadot validators, or zombienet spawn)."
        echo ""
        echo "=== Nothing to stop ==="
        return 0
    fi

    if [[ ${#collator_pids[@]} -gt 0 ]]; then
        echo "  Parachain collator(s): ${#collator_pids[@]} process(es)"
        for pid in "${collator_pids[@]}"; do
            sig_stop_pid "$pid" "collator"
        done
        echo ""
    fi

    if [[ ${#validator_pids[@]} -gt 0 ]]; then
        echo "  Relay validator(s): ${#validator_pids[@]} process(es)"
        for pid in "${validator_pids[@]}"; do
            sig_stop_pid "$pid" "relay validator"
        done
        echo ""
    fi

    if [[ ${#zombienet_pids[@]} -gt 0 ]]; then
        echo "  Zombienet supervisor: ${#zombienet_pids[@]} process(es)"
        for pid in "${zombienet_pids[@]}"; do
            sig_stop_pid "$pid" "zombienet"
        done
        echo ""
    fi

    echo "=== Zombienet processes stopped ==="
}

# ---------- main ----------

main() {
    parse_args "$@"
    mkdir -p "$RUNTIMES_DIR" "$SPECS_DIR" "$CONFIGS_DIR"

    if $DO_KILL; then
        kill_zombienet_network
        exit 0
    fi

    # Rolling restart of relay validator binaries
    if [[ -n "$DO_RESTART_RELAY" ]]; then
        echo "=== Rolling Restart: Relay Validator Binaries ==="
        echo "  Target polkadot version: $DO_RESTART_RELAY"
        echo ""
        restart_relay_nodes "$DO_RESTART_RELAY"
        echo ""
        echo "=== Rolling restart complete ==="
        echo ""
        echo "  Tip: If the on-chain runtime also needs upgrading, run:"
        echo "    make upgrade-relay NEW_RELAY_VERSION=$DO_RESTART_RELAY"
        exit 0
    fi

    # Standalone relay upgrade on a running network
    if [[ -n "$DO_UPGRADE_RELAY" ]]; then
        echo "=== Upgrading Relay Chain Runtime ==="
        echo "  Relay: $RELAY (-> polkadot $DO_UPGRADE_RELAY)"
        echo ""
        upgrade_relay_runtime "$DO_UPGRADE_RELAY"
        exit 0
    fi

    # Standalone parachain upgrade on a running network
    if [[ -n "$DO_UPGRADE_PARA" ]]; then
        echo "=== Upgrading Parachain Runtime ==="
        echo "  Parachain: $PARA (-> runtime $DO_UPGRADE_PARA)"
        echo ""
        upgrade_para_runtime "$DO_UPGRADE_PARA"
        exit 0
    fi

    echo "=== Preparing Runtime Test ==="
    if [[ -n "$POLKADOT_VER" ]]; then
        echo "  Relay:     rococo-local (polkadot ${POLKADOT_VER})"
    else
        echo "  Relay:     rococo-local (polkadot from PATH)"
    fi
    echo "  Parachain: $PARA (runtime $PARA_RUNTIME_VER)"
    echo "  Moonbeam:  $MOONBEAM_BIN"
    echo ""

    echo "--- Resolving WASMs ---"
    download_para_wasm
    echo ""

    echo "--- Chain specs ---"
    prepare_relay_chain_spec
    patch_para_chain_spec
    echo ""

    echo "--- Generating zombienet config ---"
    generate_config
    echo ""

    echo "=== Done ==="
    echo ""
    echo "To spawn the network:"
    echo "  make start \\"
    echo "      MOONBEAM_BIN=$MOONBEAM_BIN \\"
    echo "      RELAY=$RELAY PARA=$PARA PARA_RUNTIME_VER=$PARA_RUNTIME_VER"
    if [[ -n "$POLKADOT_VER" ]]; then
        echo "      POLKADOT_VERSION=$POLKADOT_VER"
    fi
    echo ""
    echo "After parachain starts producing blocks, upgrade the parachain:"
    echo "  make upgrade \\"
    echo "      RELAY=$RELAY PARA=$PARA NEW_PARA_RUNTIME_VER=<target_ver>"
    echo ""

    if $DO_SPAWN; then
        echo ""
        echo "=== Spawning network ==="
        if [[ -n "$POLKADOT_VER" ]]; then
            export PATH="$BIN_DIR/polkadot-${POLKADOT_VER}:$BIN_DIR:$PATH"
        else
            export PATH="$BIN_DIR:$PATH"
        fi
        exec zombienet spawn "$CONFIG_FILE"
    fi
}

main "$@"
