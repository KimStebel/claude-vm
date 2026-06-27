# claude-vm

A headless Ubuntu Server virtual machine for running [Claude Code](https://claude.com/claude-code) in an isolated sandbox.

`start-vm.sh` boots an official Ubuntu cloud image under QEMU/KVM, configured automatically via cloud-init. Everything (image download, overlay disk, cloud-init seed) is created on first run, so a single command gets you a clean VM you can SSH into.

## Why

Running Claude Code inside a throwaway VM keeps it isolated from your host: it can install packages, run commands, and modify files freely without touching your machine. The overlay-disk design means you can always reset to a pristine state by deleting the generated artifacts.

## Requirements

- Linux host with KVM (`/dev/kvm`) available
- `qemu-system-x86_64`, `qemu-img`
- `xorriso` (to build the cloud-init seed ISO)
- OVMF/edk2 UEFI firmware at `/usr/share/edk2/x64/OVMF.4m.fd`
- `curl` (to download the cloud image)

## Usage

```bash
./start-vm.sh
```

On the **first** run the script will:

1. Download the Ubuntu 26.04 (Resolute) server cloud image into `base/`.
2. Create a writable qcow2 overlay (`ubuntu-vm.qcow2`) backed by that image.
3. Build a cloud-init NoCloud seed (`seed.iso`) that creates the `ubuntu` user, sets a password, and injects your SSH public key (the first `~/.ssh/*.pub` found).
4. Boot the VM headless (no display), with the serial console written to `console.log`.

Subsequent runs reuse the existing image, overlay, and seed, so boot is fast.

### Connecting

Once cloud-init finishes (~30–60s on first boot):

```bash
ssh -p 2222 ubuntu@localhost   # password: ubuntu
```

If you have an SSH key, it's injected automatically and you can log in without the password.

## Configuration

Edit the variables near the top of `start-vm.sh`:

| Variable                       | Default     | Description                          |
| ------------------------------ | ----------- | ------------------------------------ |
| `CPUS`                         | `8`         | vCPUs                                |
| `RAM`                          | `20G`       | Memory                               |
| `DISK_SIZE`                    | `40G`       | Overlay disk size                    |
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

- `base/` — the pristine downloaded cloud image (never booted directly)
- `ubuntu-vm.qcow2` — writable overlay disk backing the running VM
- `seed.iso` — cloud-init NoCloud seed
- `console.log` — VM serial console output

To reset the VM to a clean state, delete `ubuntu-vm.qcow2` (and optionally `seed.iso`) and run the script again. Deleting `base/` forces a re-download.

## Stopping the VM

The VM runs in the background. Find and stop it with:

```bash
pkill -f qemu-system-x86_64
```

(or shut it down cleanly from inside via `sudo poweroff`).
