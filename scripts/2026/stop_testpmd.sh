#!/usr/bin/env bash
# stop_testpmd.sh -- Gracefully stop a running testpmd instance.
#
# Sends SIGINT to dpdk-testpmd, which triggers its graceful shutdown:
# it stops forwarding, prints per-port and accumulated forward statistics,
# and exits cleanly. Falls back to SIGKILL after 10 seconds.

set -euo pipefail

READY_MARKER="/tmp/testpmd_ready"

# Find testpmd PID
TESTPMD_PID="$(pgrep -x dpdk-testpmd 2>/dev/null || true)"

if [[ -z "$TESTPMD_PID" ]]; then
    echo "No dpdk-testpmd process found."
    rm -f "$READY_MARKER"
    exit 0
fi

echo "Sending SIGINT to dpdk-testpmd (PID $TESTPMD_PID)..."
sudo kill -s INT "$TESTPMD_PID" 2>/dev/null || true

# Wait up to 10 seconds for testpmd to exit
for i in $(seq 1 10); do
    if ! pgrep -x dpdk-testpmd > /dev/null 2>&1; then
        echo "testpmd exited cleanly."
        rm -f "$READY_MARKER"
        exit 0
    fi
    sleep 1
done

# If still alive, force kill
TESTPMD_PID="$(pgrep -x dpdk-testpmd 2>/dev/null || true)"
if [[ -n "$TESTPMD_PID" ]]; then
    echo "testpmd did not exit, sending SIGKILL..."
    sudo kill -9 "$TESTPMD_PID" 2>/dev/null || true
fi

rm -f "$READY_MARKER"
