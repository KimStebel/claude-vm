#!/bin/bash
# Ubuntu Server VM (headless) for running claude code
# Boots an official Ubuntu cloud image, configured via cloud-init.
# Uses KVM acceleration, UEFI boot, and virtio devices.
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ubuntu cloud image (Resolute = 26.04 LTS)
UBUNTU_RELEASE="resolute"
CLOUD_IMG="ubuntu-26.04-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/${CLOUD_IMG}"

BASE="$VM_DIR/base/$CLOUD_IMG"   # pristine downloaded cloud image (never booted directly)
DISK="$VM_DIR/ubuntu-vm.qcow2"   # writable overlay backed by $BASE
SEED="$VM_DIR/seed.iso"          # cloud-init NoCloud seed

# VM resources (RAM can be overridden with -m/--memory)
CPUS=8
RAM=12G
DISK_SIZE=80G

# Cloud-init login credentials
VM_USER="ubuntu"
VM_PASSWORD="ubuntu"

# SSH port forwarded from host -> guest:22
SSH_PORT=2222

usage() {
    echo "Usage: $0 [-m|--memory SIZE] [HOST_SHARE_DIR]" >&2
    echo "  -m, --memory SIZE   guest RAM in GiB unless suffixed, e.g. 16 or 8192M (default: $RAM)" >&2
}

# Parse options; whatever positional argument remains is the share directory.
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--memory)
            if [ $# -lt 2 ]; then usage; exit 1; fi
            RAM="$2"
            shift 2
            ;;
        --memory=*)
            RAM="${1#--memory=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done
if [ $# -gt 1 ]; then
    usage
    exit 1
fi

# Validate here so a typo fails fast rather than only showing up in qemu.log.
# QEMU would read a bare number as MiB; treat it as GiB instead (-m 16 = 16G).
if ! [[ "$RAM" =~ ^[0-9]+[MmGgTt]?$ ]]; then
    echo "Error: invalid memory size: $RAM (expected e.g. 16, 16G or 8192M)" >&2
    exit 1
fi
if [[ "$RAM" =~ ^[0-9]+$ ]]; then
    RAM="${RAM}G"
fi

# Refuse to start a second VM on the same overlay disk. QEMU takes an exclusive
# write lock on it, so a second instance dies immediately with a "Failed to get
# write lock" message -- but only in qemu.log, after we have already printed a
# "VM started" banner. Detect the running VM here instead, before doing any
# work. Looking for the holder by open file descriptor (rather than by command
# line) also catches a qemu-img or a differently-named process holding it.
disk_holder_pid() {
    local fd pid
    for fd in /proc/[0-9]*/fd/*; do
        [ -e "$fd" ] || continue
        if [ "$(readlink -f "$fd" 2>/dev/null)" = "$DISK" ]; then
            pid="${fd#/proc/}"
            echo "${pid%%/*}"
            return 0
        fi
    done
    return 1
}

if RUNNING_PID="$(disk_holder_pid)"; then
    echo "Error: a VM is already using $DISK (PID $RUNNING_PID)." >&2
    # Report what that VM shares: it is not necessarily what this invocation
    # asked for, and the running share is what the guest actually sees.
    RUNNING_SHARE="$(tr '\0' '\n' < "/proc/$RUNNING_PID/cmdline" 2>/dev/null |
        sed -n 's/^local,path=\([^,]*\),.*/\1/p' | head -1)"
    if [ -n "$RUNNING_SHARE" ]; then
        echo "       It shares: $RUNNING_SHARE" >&2
    else
        echo "       It shares no host directory." >&2
    fi
    echo "Shut it down first (ssh -p $SSH_PORT $VM_USER@localhost sudo poweroff, or kill $RUNNING_PID), then retry." >&2
    exit 1
fi

# Optional host directory to share into the guest via 9p (mounted at ~/host).
# Usage: ./start-vm.sh [-m SIZE] [HOST_SHARE_DIR]
HOST_SHARE_DIR="${1:-}"
MOUNT_TAG="host"
if [ -n "$HOST_SHARE_DIR" ]; then
    if [ ! -d "$HOST_SHARE_DIR" ]; then
        echo "Error: host share directory does not exist: $HOST_SHARE_DIR" >&2
        exit 1
    fi
    HOST_SHARE_DIR="$(cd "$HOST_SHARE_DIR" && pwd)"   # absolute path

    # Safety check: scan the directory for credentials before exposing it to the
    # VM (see scan-credentials.sh). A non-zero exit means the user declined.
    "$VM_DIR/scan-credentials.sh" "$HOST_SHARE_DIR" || exit 1
fi
# UEFI firmware (combined code+vars OVMF image). The path varies by distro, so
# probe the common locations and use the first that exists. Override by setting
# OVMF in the environment.
OVMF="${OVMF:-}"
if [ -z "$OVMF" ]; then
    for _ovmf in \
        /usr/share/edk2/x64/OVMF.4m.fd \
        /usr/share/edk2/ovmf/OVMF.fd \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/qemu/OVMF.fd; do
        if [ -f "$_ovmf" ]; then OVMF="$_ovmf"; break; fi
    done
fi
if [ -z "$OVMF" ] || [ ! -f "$OVMF" ]; then
    echo "Error: could not find OVMF UEFI firmware. Install edk2/ovmf, or set OVMF=/path/to/OVMF.fd" >&2
    exit 1
fi


# --- 1. Download the cloud image (once) -------------------------------------
if [ ! -f "$BASE" ]; then
    echo "Downloading Ubuntu cloud image: $CLOUD_IMG_URL"
    mkdir -p "$(dirname "$BASE")"
    curl -fL --progress-bar -o "$BASE.tmp" "$CLOUD_IMG_URL"
    mv "$BASE.tmp" "$BASE"
fi

# --- 2. Create a writable overlay disk (once) -------------------------------
if [ ! -f "$DISK" ]; then
    echo "Creating overlay disk ($DISK_SIZE) backed by $CLOUD_IMG"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" "$DISK_SIZE"
fi

# --- 3. Build the cloud-init seed (once) ------------------------------------
# The cloud-config lives in cloud-init/user-data.tpl; we substitute the
# @@PLACEHOLDER@@ markers here to produce the final user-data.
if [ ! -f "$SEED" ]; then
    echo "Building cloud-init seed: $SEED"
    TEMPLATE="$VM_DIR/cloud-init/user-data.tpl"
    if [ ! -f "$TEMPLATE" ]; then
        echo "Error: cloud-init template not found: $TEMPLATE" >&2
        exit 1
    fi
    SEED_DIR="$(mktemp -d)"
    trap 'rm -rf "$SEED_DIR"' EXIT

    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: ubuntu-vm
local-hostname: ubuntu-vm
EOF

    # Inject the host's SSH public key if one exists (quoted for the inline YAML
    # list in the template; empty -> "ssh_authorized_keys: []", i.e. no key).
    PUBKEY="$(cat ~/.ssh/*.pub 2>/dev/null | head -1 || true)"
    SSH_KEYS=""
    if [ -n "$PUBKEY" ]; then
        SSH_KEYS="\"$PUBKEY\""
    fi

    # Substitute the template placeholders (| delimiter avoids clashing with the
    # / and + that appear in base64-encoded SSH keys).
    sed -e "s|@@VM_USER@@|$VM_USER|g" \
        -e "s|@@VM_PASSWORD@@|$VM_PASSWORD|g" \
        -e "s|@@MOUNT_TAG@@|$MOUNT_TAG|g" \
        -e "s|@@SSH_AUTHORIZED_KEYS@@|$SSH_KEYS|g" \
        "$TEMPLATE" > "$SEED_DIR/user-data"

    xorriso -as genisoimage -output "$SEED" -volid cidata -joliet -rock \
        "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null 2>&1
    rm -rf "$SEED_DIR"
    trap - EXIT
fi

# --- 4. Boot the VM (headless) ----------------------------------------------
QEMU_ARGS=(
    qemu-system-x86_64
    -enable-kvm
    -machine q35,accel=kvm
    -cpu host
    -smp "$CPUS"
    -m "$RAM"

    # UEFI firmware
    -bios "$OVMF"

    # Disk (overlay) + cloud-init seed
    -drive file="$DISK",format=qcow2,if=virtio,cache=writeback
    -drive file="$SEED",format=raw,if=virtio

    # Network: user-mode, SSH + HTTP(S) forwarded to host ports
    -nic user,model=virtio-net-pci,hostfwd=tcp::"$SSH_PORT"-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::8443-:8443

    # Headless: no graphical display, serial console to a log file
    -display none
    -serial file:"$VM_DIR/console.log"
    -monitor none
)

# Share a host directory into the guest via 9p (mounted at ~/host) when given.
if [ -n "$HOST_SHARE_DIR" ]; then
    QEMU_ARGS+=(
        -virtfs local,path="$HOST_SHARE_DIR",mount_tag="$MOUNT_TAG",security_model=none
    )
fi

echo "Starting Ubuntu Server VM ($CPUS CPUs, $RAM RAM, headless)..."
nohup "${QEMU_ARGS[@]}" > "$VM_DIR/qemu.log" 2>&1 &
echo "VM started in background (PID: $!)"
echo
echo "Console log: $VM_DIR/console.log"
echo "QEMU log:    $VM_DIR/qemu.log    (check here if the VM won't start)"
echo "SSH in once cloud-init finishes (~30-60s on first boot):"
echo "    ssh -p $SSH_PORT $VM_USER@localhost     # password: $VM_PASSWORD"
if [ -n "$HOST_SHARE_DIR" ]; then
    echo
    echo "Sharing host directory (mounted at ~/host in the guest):"
    echo "    $HOST_SHARE_DIR"
fi
