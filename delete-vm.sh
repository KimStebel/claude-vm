#!/bin/bash
# Delete this VM's generated artifacts so the next ./start-vm.sh starts fresh.
#
# By default this removes the overlay disk, the cloud-init seed, and the console
# log, giving a brand-new instance on the next boot (re-runs first-boot setup:
# apt upgrade + Node.js/Claude Code install). The downloaded base cloud image is
# kept so the next start doesn't re-download it; pass --all to remove that too.
#
# Usage: ./delete-vm.sh [-y|--yes] [--all]
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$VM_DIR/ubuntu-vm.qcow2"   # writable overlay this VM boots from
SEED="$VM_DIR/seed.iso"          # cloud-init NoCloud seed
CONSOLE="$VM_DIR/console.log"    # serial console output
BASE_DIR="$VM_DIR/base"          # pristine downloaded cloud image(s)

ASSUME_YES=0
DELETE_BASE=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)  ASSUME_YES=1 ;;
        --all)     DELETE_BASE=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [-y|--yes] [--all]"
            echo "  -y, --yes   Do not prompt for confirmation."
            echo "  --all       Also delete the downloaded base image (forces re-download)."
            exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $(basename "$0") [-y|--yes] [--all]" >&2
            exit 1 ;;
    esac
done

# Refuse to delete out from under a running VM — stop it first.
if pgrep -f "qemu-system-x86_64.*$DISK" >/dev/null 2>&1; then
    echo "VM is still running. Stop it first:" >&2
    echo "    ./stop-vm.sh" >&2
    exit 1
fi

# Collect the artifacts that actually exist.
TARGETS=()
for f in "$DISK" "$SEED" "$CONSOLE"; do
    [ -e "$f" ] && TARGETS+=("$f")
done
if [ "$DELETE_BASE" -eq 1 ] && [ -d "$BASE_DIR" ]; then
    TARGETS+=("$BASE_DIR")
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "Nothing to delete (no VM artifacts found)."
    exit 0
fi

echo "The following will be deleted:"
for t in "${TARGETS[@]}"; do
    echo "    $t"
done

if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

rm -rf "${TARGETS[@]}"
echo "Done. Run ./start-vm.sh to start over."
