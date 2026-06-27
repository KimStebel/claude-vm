#!/bin/bash
# Ubuntu Server VM (headless) for running claude code
# Boots an official Ubuntu cloud image, configured via cloud-init.
# Uses KVM acceleration, UEFI boot, and virtio devices.
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"

# Optional host directory to share into the guest via 9p (mounted at ~/host).
# Usage: ./start-vm.sh [HOST_SHARE_DIR]
HOST_SHARE_DIR="${1:-}"
MOUNT_TAG="host"
if [ -n "$HOST_SHARE_DIR" ]; then
    if [ ! -d "$HOST_SHARE_DIR" ]; then
        echo "Error: host share directory does not exist: $HOST_SHARE_DIR" >&2
        exit 1
    fi
    HOST_SHARE_DIR="$(cd "$HOST_SHARE_DIR" && pwd)"   # absolute path
fi

# Ubuntu cloud image (Resolute = 26.04 LTS)
UBUNTU_RELEASE="resolute"
CLOUD_IMG="ubuntu-26.04-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/${CLOUD_IMG}"

BASE="$VM_DIR/base/$CLOUD_IMG"   # pristine downloaded cloud image (never booted directly)
DISK="$VM_DIR/ubuntu-vm.qcow2"   # writable overlay backed by $BASE
SEED="$VM_DIR/seed.iso"          # cloud-init NoCloud seed
OVMF="/usr/share/edk2/x64/OVMF.4m.fd"

# VM resources
CPUS=8
RAM=20G
DISK_SIZE=40G

# Cloud-init login credentials
VM_USER="ubuntu"
VM_PASSWORD="ubuntu"

# SSH port forwarded from host -> guest:22
SSH_PORT=2222

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
if [ ! -f "$SEED" ]; then
    echo "Building cloud-init seed: $SEED"
    SEED_DIR="$(mktemp -d)"
    trap 'rm -rf "$SEED_DIR"' EXIT

    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: ubuntu-vm
local-hostname: ubuntu-vm
EOF

    cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
hostname: ubuntu-vm
ssh_pwauth: true
users:
  - name: $VM_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
EOF

    # Inject the host's SSH public key if one exists
    PUBKEY="$(cat ~/.ssh/*.pub 2>/dev/null | head -1 || true)"
    if [ -n "$PUBKEY" ]; then
        cat >> "$SEED_DIR/user-data" <<EOF
    ssh_authorized_keys:
      - $PUBKEY
EOF
    fi

    cat >> "$SEED_DIR/user-data" <<EOF
chpasswd:
  expire: false
  users:
    - name: $VM_USER
      password: $VM_PASSWORD
      type: text

# 9p share (mount tag "$MOUNT_TAG") -> ~/host. "nofail" so boot succeeds even
# when no host directory is shared (i.e. the VM is started without an argument).
mounts:
  - [ $MOUNT_TAG, /home/$VM_USER/host, 9p, "trans=virtio,version=9p2000.L,msize=104857600,rw,_netdev,nofail", "0", "0" ]
EOF

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
nohup "${QEMU_ARGS[@]}" > /dev/null 2>&1 &
echo "VM started in background (PID: $!)"
echo
echo "Console log: $VM_DIR/console.log"
echo "SSH in once cloud-init finishes (~30-60s on first boot):"
echo "    ssh -p $SSH_PORT $VM_USER@localhost     # password: $VM_PASSWORD"
if [ -n "$HOST_SHARE_DIR" ]; then
    echo
    echo "Sharing host directory (mounted at ~/host in the guest):"
    echo "    $HOST_SHARE_DIR"
fi
