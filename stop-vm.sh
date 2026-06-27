#!/bin/bash
# Stop the headless Ubuntu Server VM started by start-vm.sh.
# Finds the QEMU process bound to this VM's overlay disk and shuts it down,
# preferring a clean SIGTERM and falling back to SIGKILL.
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$VM_DIR/ubuntu-vm.qcow2"   # writable overlay this VM boots from

# Match only the qemu-system process for *this* VM (by its overlay disk path),
# so unrelated QEMU instances on the host are left untouched.
PIDS="$(pgrep -f "qemu-system-x86_64.*$DISK" || true)"

if [ -z "$PIDS" ]; then
    echo "VM is not running (no qemu process for $DISK)."
    exit 0
fi

echo "Stopping VM (PID(s): $PIDS)..."
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
