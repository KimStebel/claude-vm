#!/bin/bash
# Delete an instance's generated artifacts so the next ./start-vm.sh with that
# name starts fresh.
#
# This removes the instance directory (overlay disk, cloud-init seed, and logs),
# giving a brand-new instance on the next boot (re-runs first-boot setup: apt
# upgrade + Node.js/Claude Code install). The downloaded base cloud image is
# kept so the next start doesn't re-download it; pass --all to remove that too.
#
# Usage: ./delete-vm.sh [-y|--yes] [--all] INSTANCE
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES_DIR="$VM_DIR/instances"   # one subdirectory per instance
BASE_DIR="$VM_DIR/base"             # pristine downloaded cloud image(s)

usage() {
    echo "Usage: $(basename "$0") [-y|--yes] [--all] INSTANCE"
    echo "  -y, --yes   Do not prompt for confirmation."
    echo "  --all       Also delete the downloaded base image (forces re-download)."
}

list_instances() {
    local d found=0
    echo "Available instances:" >&2
    for d in "$INSTANCES_DIR"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        echo "    ${d##*/}" >&2
        found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "    (none)" >&2
    fi
}

ASSUME_YES=0
DELETE_BASE=0
INSTANCE=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes)  ASSUME_YES=1 ;;
        --all)     DELETE_BASE=1 ;;
        -h|--help)
            usage
            exit 0 ;;
        -*)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 1 ;;
        *)
            if [ -n "$INSTANCE" ]; then
                usage >&2
                exit 1
            fi
            INSTANCE="$arg" ;;
    esac
done

if [ -z "$INSTANCE" ]; then
    usage >&2
    echo >&2
    list_instances
    exit 1
fi
# Reject anything that could escape the instances directory.
if ! [[ "$INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid instance name: $INSTANCE" >&2
    exit 1
fi
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE"
if [ ! -d "$INSTANCE_DIR" ]; then
    echo "No such instance: $INSTANCE" >&2
    list_instances
    exit 1
fi

# Refuse to delete out from under a running VM — stop it first.
if pgrep -f "qemu-system-x86_64.*$INSTANCE_DIR/disk\.qcow2" >/dev/null 2>&1; then
    echo "Instance '$INSTANCE' is still running. Stop it first:" >&2
    echo "    ./stop-vm.sh" >&2
    exit 1
fi

TARGETS=("$INSTANCE_DIR")
if [ "$DELETE_BASE" -eq 1 ] && [ -d "$BASE_DIR" ]; then
    TARGETS+=("$BASE_DIR")
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
echo "Done. Run ./start-vm.sh HOST_SHARE_DIR $INSTANCE to start over."
