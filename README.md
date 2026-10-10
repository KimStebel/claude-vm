# claude-vm

A headless Ubuntu Server virtual machine for running [Claude Code](https://claude.com/claude-code) in an isolated sandbox.

`start-vm.sh` boots an official Ubuntu cloud image under QEMU/KVM, configured automatically via cloud-init. Everything (image download, overlay disk, cloud-init seed) is created on first run, so a single command gets you a clean VM you can SSH into.

You can keep several named **instances**, each with its own disk. Only one runs at a time.

## Why

Running Claude Code inside a throwaway VM keeps it isolated from your host: it can install packages, run commands, and modify files freely without touching your machine. The overlay-disk design means you can always reset to a pristine state by deleting the generated artifacts.

## Requirements

- Linux host with KVM (`/dev/kvm`) available
- `qemu-system-x86_64`, `qemu-img`
- `xorriso` (to build the cloud-init seed ISO)
- OVMF/edk2 UEFI firmware at `/usr/share/edk2/x64/OVMF.4m.fd`
- `curl` (to download the cloud image)
- `claude` CLI (optional — used to scan a shared directory for credentials; see [Credential safety scan](#credential-safety-scan))

## Usage

```bash
./start-vm.sh [-m|--memory SIZE] HOST_SHARE_DIR INSTANCE
```

- `-m`, `--memory SIZE` sets the guest RAM, e.g. `16` or `8192M` (default `12G`). A bare number is taken as GiB; add an `M` suffix for MiB.
- `HOST_SHARE_DIR` is a host directory shared into the guest (see [Sharing a host directory](#sharing-a-host-directory)).
- `INSTANCE` names the VM instance to boot (letters, digits, `.`, `_`, `-`). Each instance has its own disk under `instances/<name>/`, and the name is also the guest's hostname.

```bash
./start-vm.sh -m 16G ~/projects/myapp work   # 16 GiB RAM, share ~/projects/myapp, boot instance "work"
```

Run `./list-vms.sh` (or `./start-vm.sh` without arguments) to see the existing
instances. If the named instance doesn't exist yet, you're asked whether to
create it (answering no, or running without a terminal, aborts).

When an instance is first created the script will:

1. Download the Ubuntu 26.04 (Resolute) server cloud image into `base/` (once, shared by all instances).
2. Create a writable qcow2 overlay (`instances/<name>/disk.qcow2`) backed by that image.
3. Build a cloud-init NoCloud seed (`instances/<name>/seed.iso`) from `cloud-init/user-data.tpl` that creates the `ubuntu` user, sets a password, and injects your SSH public key (the first `~/.ssh/*.pub` found).
4. Boot the VM headless (no display), with the serial console written to `instances/<name>/console.log`.

On the first boot, cloud-init also installs a **developer-tooling subset**
(mirroring the headless parts of Flexys's `laptop-build`, adapted for Ubuntu
26.04). This is driven by two generated scripts — `/usr/local/sbin/setup-devtools`
(root: apt repos + packages + standalone binaries) and `setup-devtools-user`
(per-user tools) — invoked once from `runcmd`:

- **Node.js** (current LTS, system-wide via NodeSource) + global npm CLIs:
  **Claude Code**, BitWarden CLI (`bw`), `json-diff`
- **JDK 21**, **sbt**, **Docker CE** (+ buildx/compose; the `ubuntu` user is added
  to the `docker` group)
- **google-cloud-cli** (+ GKE auth plugin), **kubectl**, **kubectx**, **helm**
- Terraform tooling: **tfenv**, **tgswitch**, **hcl2json**
- **Rust** (via rustup), **nvm** + Node LTS (per-user, for version switching),
  **bash-it**
- CLI utilities: `git`, `jq`, `yq`, `fzf`, `ripgrep`, `fd`, `bat`, `micro`,
  `source-highlight`, `moreutils`, `sshfs`, and more

Because this runs via `runcmd`, it happens only on the **first** boot of an
instance, and the first boot therefore takes several minutes. Each step is
guarded, so if something fails (e.g. a transient network error) you can re-run
it by hand to fill in the gaps:

```bash
sudo /usr/local/sbin/setup-devtools
```

The outcome is recorded to `/var/log/devtools-setup.status` and shown on every
SSH login via an MOTD hook (`devtools-setup: OK (…)` / `WARN (…)`). To re-run the
whole first-boot setup from scratch, delete the instance (`./delete-vm.sh <name>`)
and start it again.

Cloud-init also installs and enables a systemd service (`apt-upgrade.service`)
that refreshes the apt index and upgrades all installed packages on **every**
boot, ordered after the network is online. The service is enabled once (the
enable symlink persists on the overlay disk), so every subsequent start upgrades
packages too.

The outcome of each run is recorded to `/var/log/apt-upgrade.status`, and an
MOTD hook prints it on **every SSH login**, so a failure can't go unnoticed:

```
apt-upgrade: last run OK (2026-06-27 12:40:11 UTC)
apt-upgrade: LAST RUN FAILED (2026-06-27 12:40:11 UTC) -- sudo journalctl -u apt-upgrade.service
```

For full logs: `journalctl -u apt-upgrade.service` inside the VM.

Subsequent runs of the same instance reuse its overlay and seed, so boot is fast.

Only one instance can run at a time (they all forward the same host ports).
`start-vm.sh` refuses to start while any instance is running and tells you which
one it is.

### Connecting

Once cloud-init finishes (~30–60s on first boot), use the helper script:

```bash
./ssh-vm.sh                 # interactive shell
./ssh-vm.sh -- uptime       # run a command and exit
```

`ssh-vm.sh` connects as `ubuntu` on the forwarded port and passes any extra
arguments through to `ssh`. If you have an SSH key it's injected automatically
and you log in without a password; otherwise you'll be prompted for it
interactively (default: `ubuntu`). It relaxes host-key checking because the
guest's host key changes whenever the VM is reset.

Equivalent manual command:

```bash
ssh -p 2222 ubuntu@localhost   # password: ubuntu
```

## Sharing a host directory

The first positional argument is a host directory shared into the guest over [9p](https://wiki.qemu.org/Documentation/9psetup):

```bash
./start-vm.sh ~/projects/myapp work
```

It's mounted inside the VM at `~/host` (i.e. `/home/ubuntu/host`):

```bash
ssh -p 2222 ubuntu@localhost
ls ~/host        # contents of the shared host directory
```

### Credential safety scan

Because the shared directory is mounted **read-write** into a VM you may be
running untrusted code in, `start-vm.sh` runs a safety check before mounting it.
The check is delegated to `scan-credentials.sh`, which invokes Claude Code
locally in non-interactive mode (`claude -p`, with read-only tools) to inspect
the directory for sensitive material — cloud credentials (GCP/AWS/Azure), SSH/GPG
private keys, `.env` files with passwords or API tokens, `kubeconfig`, `.pem`
keys, `.git-credentials`, and similar.

- If anything sensitive is found, it's listed and you're asked whether to mount
  the directory anyway. Declining aborts the boot.
- Requires the `claude` CLI on the host; if it's missing you're asked whether to
  proceed without scanning.
- Set `SKIP_CREDENTIAL_SCAN=1` to bypass the scan entirely.
- You can run the scan on its own: `./scan-credentials.sh <dir>`.

```bash
SKIP_CREDENTIAL_SCAN=1 ./start-vm.sh ~/projects/myapp work   # skip the scan
```

Notes:

- The mount is configured with `security_model=none`, so files keep their host UID/GID. Read/write works seamlessly when the host user and the guest `ubuntu` user share the same UID (typically `1000`).
- The guest mount entry is created once, when the cloud-init seed is built, and uses `nofail`.

## Configuration

Edit the variables near the top of `start-vm.sh`:

| Variable                       | Default     | Description                          |
| ------------------------------ | ----------- | ------------------------------------ |
| `CPUS`                         | `8`         | vCPUs                                |
| `RAM`                          | `12G`       | Memory (override per run with `-m`)  |
| `DISK_SIZE`                    | `80G`       | Overlay disk size                    |
| `VM_USER` / `VM_PASSWORD`      | `ubuntu`    | Login credentials                    |
| `SSH_PORT`                     | `2222`      | Host port forwarded to guest `:22`   |
| `UBUNTU_RELEASE` / `CLOUD_IMG` | `resolute`  | Ubuntu cloud image to download       |

### Port forwarding

User-mode networking forwards the following host ports into the guest:

| Host port | Guest port | Purpose          |
| --------- | ---------- | ---------------- |
| `2222`    | `22`       | SSH              |
| `8080`    | `8080`     | HTTP             |
| `8443`    | `8443`     | HTTPS            |

## Generated artifacts

These are created on first run and ignored by git:

- `base/` — the pristine downloaded cloud image (never booted directly), shared by all instances
- `instances/<name>/disk.qcow2` — the instance's writable overlay disk
- `instances/<name>/seed.iso` — the instance's cloud-init NoCloud seed
- `instances/<name>/console.log` — VM serial console output
- `instances/<name>/qemu.log` — QEMU output (check here if the VM won't start)

To reset an instance to a clean state, delete it with `./delete-vm.sh` (or
remove `instances/<name>/` by hand) and start it again:

```bash
./delete-vm.sh work         # remove instances/work/ (keeps base image)
./delete-vm.sh --all work   # also remove the downloaded base image (forces re-download)
```

Run `./delete-vm.sh` without a name to list the instances. It refuses to delete
an instance that is still running (stop it first with `./stop-vm.sh`) and
prompts before deleting; pass `-y`/`--yes` to skip the prompt. The next start
creates a brand-new cloud-init instance, so first-boot setup (apt upgrade +
Node.js/Claude Code install) runs again.

## Stopping the VM

The VM runs in the background. Stop it with:

```bash
./stop-vm.sh
```

`stop-vm.sh` finds the QEMU process booted from one of the `instances/*/disk.qcow2`
disks (so it won't touch unrelated QEMU instances), sends it `SIGTERM`, waits up
to ~15s for a clean exit, then falls back to `SIGKILL`. If no instance is
running it just says so and exits. `status-vm.sh` likewise reports which
instance is running.

You can also shut it down cleanly from inside via `sudo poweroff`.

## Scripts

| Script          | Purpose                                                       |
| --------------- | ------------------------------------------------------------- |
| `start-vm.sh`   | Boot an instance (creates its disk / seed on first run)       |
| `scan-credentials.sh` | Scan a host dir for credentials before sharing it (uses Claude) |
| `ssh-vm.sh`     | SSH into the running VM (password prompted if no key)         |
| `list-vms.sh`   | List instances with disk usage and which one is running       |
| `status-vm.sh`  | Show which instance is running, uptime, ports, SSH readiness  |
| `stop-vm.sh`    | Stop the running VM (graceful SIGTERM, SIGKILL fallback)      |
| `delete-vm.sh`  | Delete an instance (disk/seed/logs) to start over fresh       |
