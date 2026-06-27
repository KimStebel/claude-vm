#!/bin/bash
# SSH into the headless Ubuntu Server VM started by start-vm.sh.
# Logs in as the cloud-init user over the forwarded host port. If no SSH key
# was injected, you'll be prompted for the password interactively (default: ubuntu).
# Any extra arguments are passed through to ssh (e.g. a remote command to run).
set -euo pipefail

# Keep these in sync with start-vm.sh
VM_USER="ubuntu"
SSH_PORT=2222

# StrictHostKeyChecking/UserKnownHostsFile are relaxed because the guest host
# key changes whenever the VM is reset (new overlay disk), and localhost:2222
# may point at different VMs over time.
exec ssh \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$VM_USER@localhost" "$@"
