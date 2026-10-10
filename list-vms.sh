#!/bin/bash
# List the VM instances created by start-vm.sh, with how much host disk each
# one's overlay uses and which one (if any) is running.
#
# Usage: ./list-vms.sh
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES_DIR="$VM_DIR/instances"   # one subdirectory per instance

# The running instance's disk path, if any (only one runs at a time).
RUNNING_DISK="$(pgrep -af "qemu-system-x86_64.*$INSTANCES_DIR/[^/]*/disk\\.qcow2" |
    grep -o "$INSTANCES_DIR/[^/]*/disk\\.qcow2" | head -1 || true)"

found=0
for d in "$INSTANCES_DIR"/*/; do
    disk="${d}disk.qcow2"
    [ -f "$disk" ] || continue
    if [ "$found" -eq 0 ]; then
        printf '%-20s %10s  %s\n' "INSTANCE" "DISK USED" "STATUS"
        found=1
    fi
    d="${d%/}"
    used="$(du -h "$disk" | cut -f1)"
    status="stopped"
    [ "$disk" = "$RUNNING_DISK" ] && status="running"
    printf '%-20s %10s  %s\n' "${d##*/}" "$used" "$status"
done

if [ "$found" -eq 0 ]; then
    echo "No instances yet. Create one with: ./start-vm.sh HOST_SHARE_DIR INSTANCE"
fi
