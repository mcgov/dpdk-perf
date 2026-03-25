#!/usr/bin/env bash
# run_all_tests.sh -- Run all testpmd benchmarks on a single VM (no SSH).
#
# Usage:
#   ./run_all_tests.sh --role <sender|receiver> [--duration <seconds>] \
#       [--results-dir <path>] [-- extra testpmd args...]
#
# Iterates over:
#   Queue counts: 1, 2, 4, 8
#   Queue depths: 64, 128, 256, 1024, 2048
# Total: 20 tests.
#
# For coordinated sender+receiver tests across two VMs, use
# run_orchestrator.sh instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Defaults ------------------------------------------------------------------
ROLE=""
RESULTS_DIR="./results"
DURATION=30
EXTRA_ARGS=()

# -- Argument parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)        ROLE="$2";          shift 2 ;;
        --results-dir) RESULTS_DIR="$2";   shift 2 ;;
        --duration)    DURATION="$2";      shift 2 ;;
        --)            shift; EXTRA_ARGS=("$@"); break ;;
        *)             echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ROLE" ]]; then
    echo "Error: --role is required." >&2
    exit 1
fi

# -- Test matrix ---------------------------------------------------------------
QUEUE_COUNTS=(1 2 4 8)
QUEUE_DEPTHS=(64 128 256 1024 2048)

TOTAL=$(( ${#QUEUE_COUNTS[@]} * ${#QUEUE_DEPTHS[@]} ))
COUNT=0

echo "=========================================="
echo " DPDK testpmd Benchmark -- $ROLE"
echo " Duration: ${DURATION}s per test"
echo " Total tests: $TOTAL"
echo " Results dir: $RESULTS_DIR"
echo "=========================================="
echo ""

FAILED=0

for queues in "${QUEUE_COUNTS[@]}"; do
    for depth in "${QUEUE_DEPTHS[@]}"; do
        COUNT=$(( COUNT + 1 ))
        echo "[$COUNT/$TOTAL] Running: queues=$queues depth=$depth ..."

        # Build run_testpmd.sh command
        CMD=("$SCRIPT_DIR/run_testpmd.sh"
            --role "$ROLE"
            --queues "$queues"
            --depth "$depth"
            --results-dir "$RESULTS_DIR"
        )
        if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
            CMD+=(-- "${EXTRA_ARGS[@]}")
        fi

        # Start testpmd in the background (it blocks until quit)
        "${CMD[@]}" &
        TESTPMD_WRAPPER_PID=$!

        # Wait for testpmd to be ready
        READY=0
        for i in $(seq 1 30); do
            if [[ -f /tmp/testpmd_ready ]]; then
                READY=1
                break
            fi
            sleep 1
        done

        if [[ $READY -eq 0 ]]; then
            echo "[$COUNT/$TOTAL] FAIL: testpmd did not become ready" >&2
            kill "$TESTPMD_WRAPPER_PID" 2>/dev/null || true
            wait "$TESTPMD_WRAPPER_PID" 2>/dev/null || true
            FAILED=$(( FAILED + 1 ))
            continue
        fi

        # Run for the specified duration
        sleep "$DURATION"

        # Gracefully stop testpmd
        "$SCRIPT_DIR/stop_testpmd.sh"

        # Wait for the wrapper to exit
        wait "$TESTPMD_WRAPPER_PID" 2>/dev/null || true

        echo "[$COUNT/$TOTAL] PASS: queues=$queues depth=$depth"
        echo ""
    done
done

echo "=========================================="
echo " Complete: $((TOTAL - FAILED))/$TOTAL passed"
if [[ $FAILED -gt 0 ]]; then
    echo " $FAILED test(s) FAILED"
fi
echo " Results in: $RESULTS_DIR/$ROLE/"
echo "=========================================="

exit $FAILED
