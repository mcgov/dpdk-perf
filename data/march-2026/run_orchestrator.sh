#!/usr/bin/env bash
# run_orchestrator.sh -- Coordinate testpmd benchmarks across sender and
# receiver VMs via SSH.
#
# Usage:
#   ./run_orchestrator.sh --sender <user@host> --receiver <user@host> \
#       [--duration <seconds>] [--results-dir <path>] [-- extra testpmd args...]
#
# For each (queues, depth) combination:
#   1. Start receiver testpmd (via SSH, backgrounds)
#   2. Wait for receiver to signal ready
#   3. Start sender testpmd (via SSH, backgrounds)
#   4. Wait for sender to signal ready
#   5. Sleep for --duration seconds
#   6. Stop sender (stats + stop + quit)
#   7. Stop receiver (stats + stop + quit)
#   8. SCP result logs back to the local results directory
#
# Copies run_testpmd.sh and stop_testpmd.sh to both VMs before starting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Defaults ------------------------------------------------------------------
SENDER=""
RECEIVER=""
DURATION=30
RESULTS_DIR="./results"
EXTRA_ARGS=()
REMOTE_DIR="~/testpmd_bench"
TX_IP="10.0.1.4,10.0.1.5"

# -- Argument parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sender)      SENDER="$2";       shift 2 ;;
        --receiver)    RECEIVER="$2";      shift 2 ;;
        --duration)    DURATION="$2";      shift 2 ;;
        --results-dir) RESULTS_DIR="$2";   shift 2 ;;
        --)            shift; EXTRA_ARGS=("$@"); break ;;
        *)             echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SENDER" || -z "$RECEIVER" ]]; then
    echo "Error: --sender and --receiver are required." >&2
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30"

# -- Set up SSH ControlMaster for persistent connections -----------------------
# Pre-establish TCP connections before testpmd starts generating traffic.
# txonly mode can saturate the NIC and block NEW SSH connections, but
# multiplexed channels over an existing connection still work.
SSH_CONTROL_DIR=$(mktemp -d /tmp/testpmd_ssh.XXXXXX)
SSH_OPTS="$SSH_OPTS -o ControlMaster=auto -o ControlPersist=600"
SENDER_SOCK="$SSH_CONTROL_DIR/sender"
RECEIVER_SOCK="$SSH_CONTROL_DIR/receiver"
SSH_SENDER="$SSH_OPTS -o ControlPath=$SENDER_SOCK"
SSH_RECEIVER="$SSH_OPTS -o ControlPath=$RECEIVER_SOCK"

cleanup_ssh() {
    ssh $SSH_SENDER -O exit "$SENDER" 2>/dev/null || true
    ssh $SSH_RECEIVER -O exit "$RECEIVER" 2>/dev/null || true
    rm -rf "$SSH_CONTROL_DIR"
}
trap cleanup_ssh EXIT

echo "Establishing persistent SSH connections..."
ssh $SSH_SENDER -fN "$SENDER"
ssh $SSH_RECEIVER -fN "$RECEIVER"
echo "SSH connections established."

# -- Copy scripts to both VMs -------------------------------------------------
echo "Copying scripts to VMs..."
for host_info in "SENDER:$SENDER:$SSH_SENDER" "RECEIVER:$RECEIVER:$SSH_RECEIVER"; do
    IFS=: read -r label host ssh_opts <<< "$host_info"
    ssh $ssh_opts "$host" "mkdir -p $REMOTE_DIR"
    scp $ssh_opts \
        "$SCRIPT_DIR/run_testpmd.sh" \
        "$SCRIPT_DIR/stop_testpmd.sh" \
        "$host:$REMOTE_DIR/"
    ssh $ssh_opts "$host" "chmod +x $REMOTE_DIR/*.sh"
done
echo "Scripts deployed."
echo ""

# -- Helper: wait for /tmp/testpmd_ready on a remote host ---------------------
wait_for_ready() {
    local ssh_opts="$1"
    local host="$2"
    local label="$3"
    local timeout=30
    for i in $(seq 1 "$timeout"); do
        if ssh $ssh_opts "$host" "test -f /tmp/testpmd_ready" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "  ERROR: $label did not become ready within ${timeout}s" >&2
    return 1
}

# -- Test matrix ---------------------------------------------------------------
# Each test is: TX_QUEUES:TX_DEPTH:RX_QUEUES:RX_DEPTH
# For symmetric tests, TX and RX use the same values.
TESTS=("4:256:1:1024" "4:256:2:1024" "4:256:4:1024" "4:256:8:1024")

TOTAL=${#TESTS[@]}
COUNT=0
FAILED=0

echo "=========================================="
echo " DPDK testpmd Benchmark"
echo " Sender:   $SENDER"
echo " Receiver: $RECEIVER"
echo " Duration: ${DURATION}s per test"
echo " Total:    $TOTAL tests"
echo "=========================================="
echo ""

for test_spec in "${TESTS[@]}"; do
    IFS=: read -r tx_queues tx_depth rx_queues rx_depth <<< "$test_spec"
    COUNT=$(( COUNT + 1 ))
    echo "[$COUNT/$TOTAL] sender=${tx_queues}q/${tx_depth}d receiver=${rx_queues}q/${rx_depth}d"

    # Build extra-args strings for remote shell
    EXTRA_STR=""
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        EXTRA_STR="-- ${EXTRA_ARGS[*]}"
    fi

    # Sender gets --tx-ip and --txonly-multi-flow
    SENDER_EXTRA_STR="-- --tx-ip=$TX_IP --txonly-multi-flow"
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        SENDER_EXTRA_STR="-- --tx-ip=$TX_IP --txonly-multi-flow ${EXTRA_ARGS[*]}"
    fi

    RESULT_SUBDIR="tx${tx_queues}q${tx_depth}d_rx${rx_queues}q${rx_depth}d"

    # Kill any leftover testpmd and clean up state on both VMs
    ssh $SSH_RECEIVER "$RECEIVER" \
        "PID=\$(pgrep -x dpdk-testpmd); if [ -n \"\$PID\" ]; then echo 'Killing leftover testpmd (PID \$PID)'; sudo kill -s INT \$PID; sleep 2; sudo kill -9 \$PID 2>/dev/null; fi; rm -f /tmp/testpmd_ctl /tmp/testpmd_ready" 2>/dev/null || true
    ssh $SSH_SENDER "$SENDER" \
        "PID=\$(pgrep -x dpdk-testpmd); if [ -n \"\$PID\" ]; then echo 'Killing leftover testpmd (PID \$PID)'; sudo kill -s INT \$PID; sleep 2; sudo kill -9 \$PID 2>/dev/null; fi; rm -f /tmp/testpmd_ctl /tmp/testpmd_ready" 2>/dev/null || true

    # -- 1. Start receiver -------------------------------------------------
    echo "  Starting receiver..."
    ssh $SSH_RECEIVER "$RECEIVER" \
        "cd $REMOTE_DIR && ./run_testpmd.sh --role receiver --queues $rx_queues --depth $rx_depth --results-dir ./results/$RESULT_SUBDIR $EXTRA_STR" &
    RX_PID=$!

    if ! wait_for_ready "$SSH_RECEIVER" "$RECEIVER" "Receiver"; then
        kill $RX_PID 2>/dev/null || true
        wait $RX_PID 2>/dev/null || true
        FAILED=$(( FAILED + 1 ))
        echo "[$COUNT/$TOTAL] FAIL"
        echo ""
        continue
    fi
    echo "  Receiver ready."

    # -- 2. Start sender ---------------------------------------------------
    echo "  Starting sender..."
    ssh $SSH_SENDER "$SENDER" \
        "cd $REMOTE_DIR && ./run_testpmd.sh --role sender --queues $tx_queues --depth $tx_depth --results-dir ./results/$RESULT_SUBDIR $SENDER_EXTRA_STR" &
    TX_PID=$!

        if ! wait_for_ready "$SSH_SENDER" "$SENDER" "Sender"; then
            # Stop receiver, clean up
            ssh $SSH_RECEIVER "$RECEIVER" "$REMOTE_DIR/stop_testpmd.sh" 2>/dev/null || true
            kill $TX_PID 2>/dev/null || true
            wait $TX_PID 2>/dev/null || true
            wait $RX_PID 2>/dev/null || true
            FAILED=$(( FAILED + 1 ))
            echo "[$COUNT/$TOTAL] FAIL"
            echo ""
            continue
        fi
        echo "  Sender ready."

        # -- 3. Run the test ---------------------------------------------------
        echo "  Both forwarding. Waiting ${DURATION}s..."
        sleep "$DURATION"

        # -- 4. Stop sender first ----------------------------------------------
        echo "  Stopping sender..."
        ssh $SSH_SENDER "$SENDER" "$REMOTE_DIR/stop_testpmd.sh" || true
        wait $TX_PID 2>/dev/null || true

        # -- 5. Stop receiver --------------------------------------------------
        echo "  Stopping receiver..."
        ssh $SSH_RECEIVER "$RECEIVER" "$REMOTE_DIR/stop_testpmd.sh" || true
        wait $RX_PID 2>/dev/null || true

        # -- 6. Copy results back ----------------------------------------------
        echo "  Copying results..."
        mkdir -p "$RESULTS_DIR/sender/$RESULT_SUBDIR"
        mkdir -p "$RESULTS_DIR/receiver/$RESULT_SUBDIR"

        scp $SSH_SENDER \
            "$SENDER:$REMOTE_DIR/results/$RESULT_SUBDIR/sender/${tx_queues}q/${tx_depth}d/testpmd.log" \
            "$RESULTS_DIR/sender/$RESULT_SUBDIR/testpmd.log" 2>/dev/null || true
        scp $SSH_RECEIVER \
            "$RECEIVER:$REMOTE_DIR/results/$RESULT_SUBDIR/receiver/${rx_queues}q/${rx_depth}d/testpmd.log" \
            "$RESULTS_DIR/receiver/$RESULT_SUBDIR/testpmd.log" 2>/dev/null || true

        echo "[$COUNT/$TOTAL] PASS: sender=${tx_queues}q/${tx_depth}d receiver=${rx_queues}q/${rx_depth}d"
        echo ""
done

echo "=========================================="
echo " Complete: $((TOTAL - FAILED))/$TOTAL passed"
if [[ $FAILED -gt 0 ]]; then
    echo " $FAILED test(s) FAILED"
fi
echo " Results in: $RESULTS_DIR/"
echo "=========================================="

exit $FAILED
