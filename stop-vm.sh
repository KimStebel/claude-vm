#!/bin/bash
# Stop the headless Ubuntu Server VM started by start-vm.sh.
# Finds the QEMU process bound to any instance's overlay disk (only one runs at
# a time) and shuts it down, preferring a clean SIGTERM and falling back to
# SIGKILL.
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES_DIR="$VM_DIR/instances"   # one subdirectory per instance

# Match only qemu-system processes booted from one of *our* instance disks, so
# unrelated QEMU instances on the host are left untouched.
PATTERN="qemu-system-x86_64.*$INSTANCES_DIR/[^/]*/disk\.qcow2"
PIDS="$(pgrep -f "$PATTERN" || true)"

if [ -z "$PIDS" ]; then
    echo "VM is not running (no qemu process for any instance in $INSTANCES_DIR)."
    exit 0
fi

INSTANCE="$(pgrep -af "$PATTERN" | grep -o "$INSTANCES_DIR/[^/]*/disk\.qcow2" | head -1)"
INSTANCE="${INSTANCE%/disk.qcow2}"
INSTANCE="${INSTANCE##*/}"

echo "Stopping instance '$INSTANCE' (PID(s): $PIDS)..."
kill $PIDS 2>/dev/null || true

# Wait up to ~15s for a clean exit before forcing it.
for _ in $(seq 1 30); do
    if ! kill -0 $PIDS 2>/dev/null; then
        echo "VM stopped."
        exit 0
    fi
    sleep 0.5
done

echo "VM did not stop in time; sending SIGKILL..."
kill -9 $PIDS 2>/dev/null || true
echo "VM killed."
