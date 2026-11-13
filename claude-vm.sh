#!/bin/bash
# Run Claude Code inside the running VM, in the shared host directory (~/host),
# with --dangerously-skip-permissions (the VM is the sandbox).
# Connects via ssh-vm.sh. Any extra arguments are passed through to claude,
# e.g. ./claude-vm.sh --continue
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")" && pwd)"

# Lets herdr (on the host) recognise this pane as a Claude agent, even though
# the local foreground process is ssh. Also forwarded to the guest.
export HERDR_AGENT=claude

# Build the remote command, quoting the passthrough arguments so they survive
# both the remote shell and the inner login shell. The login shell picks up the
# user's PATH (nvm, ~/.local/bin, ...).
INNER="cd ~/host && exec claude --dangerously-skip-permissions"
if [ $# -gt 0 ]; then
    INNER+="$(printf ' %q' "$@")"
fi
REMOTE="HERDR_AGENT=claude exec bash -lc $(printf '%q' "$INNER")"

# -t forces a TTY so claude's interactive UI works.
exec "$VM_DIR/ssh-vm.sh" -t -- "$REMOTE"
