#!/bin/bash
# Show the current status of the headless Ubuntu Server VM started by start-vm.sh:
# whether its QEMU process is running, basic process info, the forwarded ports,
# and whether SSH is accepting connections yet.
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES_DIR="$VM_DIR/instances"   # one subdirectory per instance

# Keep these in sync with start-vm.sh
SSH_PORT=2222

# Find the qemu-system process booted from one of our instance disks (only one
# runs at a time).
PATTERN="qemu-system-x86_64.*$INSTANCES_DIR/[^/]*/disk\.qcow2"
PID="$(pgrep -f "$PATTERN" | head -1 || true)"

if [ -z "$PID" ]; then
    echo "VM status: STOPPED (no qemu process for any instance in $INSTANCES_DIR)"
    exit 0
fi

INSTANCE="$(pgrep -af "$PATTERN" | grep -o "$INSTANCES_DIR/[^/]*/disk\.qcow2" | head -1)"
INSTANCE="${INSTANCE%/disk.qcow2}"
INSTANCE="${INSTANCE##*/}"

echo "VM status: RUNNING"
echo "  Name:    $INSTANCE"
echo "  PID:     $PID"

# Process start time and elapsed (uptime), best-effort.
if ELAPSED="$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')" && [ -n "$ELAPSED" ]; then
    echo "  Uptime:  $ELAPSED"
fi

echo "  Ports:   2222->22 (ssh)  8080->8080 (http)  8443->8443 (https)"

# Is SSH accepting connections yet? (cloud-init takes ~30-60s on first boot.)
if command -v nc >/dev/null 2>&1; then
    if nc -z -w 2 localhost "$SSH_PORT" 2>/dev/null; then
        echo "  SSH:     reachable on localhost:$SSH_PORT  (./ssh-vm.sh)"
    else
        echo "  SSH:     not reachable yet on localhost:$SSH_PORT (still booting?)"
    fi
fi
