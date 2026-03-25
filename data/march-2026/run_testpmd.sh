#!/usr/bin/env bash
# run_testpmd.sh -- Start a dpdk-testpmd instance and begin forwarding.
#
# Usage:
#   ./run_testpmd.sh --role <sender|receiver> --queues <N> --depth <D> \
#       [--results-dir <path>] [-- extra testpmd args...]
#
# Reads ~/vdev_args for the netvsc PMD --vdev argument.
# Automatically calculates the core list based on queue count.
# Logs output to results/<role>/<N>q/<D>d/testpmd.log
#
# Creates a control FIFO at /tmp/testpmd_ctl for external command injection.
# Creates /tmp/testpmd_ready marker file when forwarding has started.
# Blocks until testpmd exits. Send 'quit' to the FIFO to stop it, or use
# stop_testpmd.sh to gracefully collect stats and shut down.

set -euo pipefail

FIFO_PATH="/tmp/testpmd_ctl"
READY_MARKER="/tmp/testpmd_ready"

# -- Defaults ------------------------------------------------------------------
ROLE=""
QUEUES=""
DEPTH=""
RESULTS_DIR="./results"
EXTRA_ARGS=()

# -- Argument parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)        ROLE="$2";          shift 2 ;;
        --queues)      QUEUES="$2";        shift 2 ;;
        --depth)       DEPTH="$2";         shift 2 ;;
        --results-dir) RESULTS_DIR="$2";   shift 2 ;;
        --)            shift; EXTRA_ARGS=("$@"); break ;;
        *)             echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# -- Validation ----------------------------------------------------------------
if [[ -z "$ROLE" || -z "$QUEUES" || -z "$DEPTH" ]]; then
    echo "Error: --role, --queues, and --depth are required." >&2
    exit 1
fi

if [[ "$ROLE" != "sender" && "$ROLE" != "receiver" ]]; then
    echo "Error: --role must be 'sender' or 'receiver'." >&2
    exit 1
fi

# -- Cleanup on exit -----------------------------------------------------------
cleanup() {
    exec 3>&- 2>/dev/null || true
    rm -f "$FIFO_PATH" "$READY_MARKER"
}
trap cleanup EXIT

# -- Determine forwarding mode ------------------------------------------------
if [[ "$ROLE" == "sender" ]]; then
    FWD_MODE="txonly"
else
    FWD_MODE="rxonly"
fi

# -- Read vdev args ------------------------------------------------------------
VDEV_ARGS_FILE="$HOME/vdev_args"
if [[ ! -f "$VDEV_ARGS_FILE" ]]; then
    echo "Error: $VDEV_ARGS_FILE not found." >&2
    exit 1
fi
VDEV_ARGS="$(cat "$VDEV_ARGS_FILE")"

# -- Auto-calculate core list --------------------------------------------------
# We need 1 main/control core + QUEUES forwarding cores = QUEUES+1 total.
NEEDED_CORES=$(( QUEUES + 1 ))

# Get list of online CPU IDs (sorted numerically)
mapfile -t AVAILABLE_CORES < <(cat /sys/devices/system/cpu/online | tr ',' '\n' | while read -r range; do
    if [[ "$range" == *-* ]]; then
        start="${range%-*}"
        end="${range#*-}"
        seq "$start" "$end"
    else
        echo "$range"
    fi
done | sort -n)

if [[ ${#AVAILABLE_CORES[@]} -lt $NEEDED_CORES ]]; then
    echo "Error: Need $NEEDED_CORES cores but only ${#AVAILABLE_CORES[@]} available." >&2
    exit 1
fi

# Pick the first NEEDED_CORES cores
SELECTED_CORES=("${AVAILABLE_CORES[@]:0:$NEEDED_CORES}")
CORE_LIST=$(IFS=,; echo "${SELECTED_CORES[*]}")

# -- Build output directory and log path ---------------------------------------
OUT_DIR="${RESULTS_DIR}/${ROLE}/${QUEUES}q/${DEPTH}d"
mkdir -p "$OUT_DIR"
LOG_FILE="${OUT_DIR}/testpmd.log"

# -- Build testpmd command -----------------------------------------------------
# VDEV_ARGS is inserted as-is (~/vdev_args should contain the full flag,
# e.g. "--vdev=net_vdev_netvsc0,iface=eth1")
TESTPMD_CMD=(
    sudo dpdk-testpmd
    -l "$CORE_LIST"
    $VDEV_ARGS
    --
    --forward-mode="$FWD_MODE"
    --txq="$QUEUES"
    --rxq="$QUEUES"
    --txd="$DEPTH"
    --rxd="$DEPTH"
    --stats-period=5
    --nb-cores="$QUEUES"
)

# Append any extra args
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    TESTPMD_CMD+=("${EXTRA_ARGS[@]}")
fi

# -- Write command to log (for reproducibility) --------------------------------
echo "# Command: ${TESTPMD_CMD[*]}" > "$LOG_FILE"
echo "# Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$LOG_FILE"
echo "# Role: $ROLE  Queues: $QUEUES  Depth: $DEPTH" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"

# -- Clean up any leftover state from previous runs ----------------------------
rm -f "$FIFO_PATH" "$READY_MARKER"

# -- Start testpmd using a FIFO to feed the 'start' command -------------------
mkfifo "$FIFO_PATH"

"${TESTPMD_CMD[@]}" < "$FIFO_PATH" >> "$LOG_FILE" 2>&1 &
TESTPMD_PID=$!

# Hold FIFO open so testpmd does not see EOF on its stdin
exec 3>"$FIFO_PATH"

echo "[$ROLE] testpmd started (PID $TESTPMD_PID), waiting for init..."
sleep 5

# Start forwarding
if [[ "$ROLE" == "sender" ]]; then
    echo "start tx_first" >&3
else
    echo "start" >&3
fi

echo "[$ROLE] Forwarding started."

# Signal that this instance is ready for the orchestrator
touch "$READY_MARKER"

# Block until testpmd exits (orchestrator sends 'quit' via the FIFO)
wait "$TESTPMD_PID" 2>/dev/null || true

echo "[$ROLE] testpmd exited. Log saved to $LOG_FILE"
