#!/bin/bash
# Inspect a directory for credentials/secrets before it is mounted read-write
# into the (untrusted) VM. The assessment is performed by Claude Code running
# locally in non-interactive mode (claude -p) with read-only tools.
#
# Usage: ./scan-credentials.sh <dir>
#
# Exit status:
#   0  safe to proceed (nothing sensitive found, user confirmed, or scan skipped)
#   1  abort (user declined, or no directory given)
#
# Set SKIP_CREDENTIAL_SCAN=1 to bypass the scan entirely.
set -euo pipefail

dir="${1:-}"
if [ -z "$dir" ]; then
    echo "Usage: $0 <dir>" >&2
    exit 1
fi
if [ ! -d "$dir" ]; then
    echo "Error: not a directory: $dir" >&2
    exit 1
fi

reply=""

if [ "${SKIP_CREDENTIAL_SCAN:-}" = "1" ]; then
    echo "Skipping credential scan (SKIP_CREDENTIAL_SCAN=1)."
    exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
    echo "Warning: 'claude' CLI not found; cannot scan '$dir' for credentials." >&2
    read -r -p "Mount it into the VM without scanning? [y/N] " reply || true
    case "${reply:-}" in [yY]*) exit 0 ;; *) echo "Aborted." >&2; exit 1 ;; esac
fi

echo "Scanning '$dir' for credentials with Claude (this may take a moment)..."

prompt="This directory is about to be mounted READ-WRITE into an untrusted virtual machine. \
Inspect it recursively for sensitive credentials or secrets that would be dangerous to expose, such as: \
cloud credentials (GCP service-account JSON, application_default_credentials.json, AWS access keys, Azure), \
SSH or GPG private keys, .env files containing passwords/tokens/API keys, .npmrc/.pypirc auth tokens, \
kubeconfig files, .pem/.key files, .git-credentials, and password databases. \
Skip dependency/build dirs (node_modules, .git, venv, target, dist) and binary files. \
Do not modify anything and do NOT print any secret values. \
List each finding as a short bullet: relative path -- what it is. \
Finish with exactly one line on its own: 'VERDICT: CREDENTIALS_FOUND' if you found anything sensitive, otherwise 'VERDICT: CLEAN'."

output="$(cd "$dir" && claude -p "$prompt" --allowedTools Read Grep Glob 2>/dev/null || true)"

# Show findings (minus the machine-readable verdict marker / blank lines).
printf '%s\n' "$output" | grep -vi 'VERDICT:' | sed '/^[[:space:]]*$/d' || true

if printf '%s' "$output" | grep -qi 'VERDICT: *CREDENTIALS_FOUND'; then
    echo
    read -r -p "Potential credentials found (above). Mount '$dir' into the VM anyway? [y/N] " reply || true
    case "${reply:-}" in [yY]*) echo "Proceeding." ; exit 0 ;; *) echo "Aborted." >&2; exit 1 ;; esac
elif printf '%s' "$output" | grep -qi 'VERDICT: *CLEAN'; then
    echo "No credentials detected; proceeding."
    exit 0
else
    echo "Warning: credential scan did not return a clear result." >&2
    read -r -p "Mount '$dir' into the VM anyway? [y/N] " reply || true
    case "${reply:-}" in [yY]*) exit 0 ;; *) echo "Aborted." >&2; exit 1 ;; esac
fi
