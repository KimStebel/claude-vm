#cloud-config
# Cloud-init user-data template for claude-vm.
#
# This is a template, not the final user-data: start-vm.sh substitutes the
# @@PLACEHOLDER@@ markers (HOSTNAME, VM_USER, VM_PASSWORD, MOUNT_TAG,
# SSH_AUTHORIZED_KEYS) when it builds seed.iso. Shell variables in the embedded
# scripts below use plain "$" — they are consumed inside the guest, not here.
hostname: @@HOSTNAME@@
ssh_pwauth: true

write_files:
  # --- apt-upgrade: refresh + upgrade all packages on every boot ------------
  # A systemd oneshot (ordered after the network is online). The wrapper records
  # the outcome to /var/log/apt-upgrade.status; an MOTD hook surfaces it on every
  # login. Enabled once via runcmd; the enable symlink persists on the overlay
  # disk, so it then runs on every subsequent boot.
  - path: /etc/systemd/system/apt-upgrade.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Update and upgrade apt packages on boot
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/apt-upgrade

      [Install]
      WantedBy=multi-user.target

  - path: /usr/local/sbin/apt-upgrade
    permissions: '0755'
    content: |
      #!/bin/sh
      set -e
      STATUS=/var/log/apt-upgrade.status
      record() { printf '%s\t%s\n' "$1" "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$STATUS"; }
      trap 'record FAILED' EXIT
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -o DPkg::Lock::Timeout=300
      apt-get -y -o DPkg::Lock::Timeout=300 upgrade
      trap - EXIT
      record OK

  - path: /etc/update-motd.d/99-apt-upgrade
    permissions: '0755'
    content: |
      #!/bin/sh
      STATUS=/var/log/apt-upgrade.status
      if systemctl is-active --quiet apt-upgrade.service; then
        echo "apt-upgrade: running now..."
      elif [ -r "$STATUS" ]; then
        result=$(cut -f1 "$STATUS"); when=$(cut -f2- "$STATUS")
        if [ "$result" = OK ]; then
          echo "apt-upgrade: last run OK ($when)"
        else
          echo "apt-upgrade: LAST RUN FAILED ($when) -- sudo journalctl -u apt-upgrade.service"
        fi
      fi

  # --- devtools: one-time first-boot install of the dev-tooling subset ------
  # Mirrors the headless subset of Flexys's laptop-build, adapted for Ubuntu
  # 26.04 (Resolute). Invoked once from runcmd (first boot only). Every step is
  # guarded, so re-running by hand fills in anything that failed:
  #     sudo /usr/local/sbin/setup-devtools
  - path: /usr/local/sbin/setup-devtools
    permissions: '0755'
    content: |
      #!/bin/bash
      # Root half of first-boot dev-tooling setup: apt repos, apt packages, and
      # standalone binaries. Per-user tools are handled by setup-devtools-user.
      set -u
      export DEBIAN_FRONTEND=noninteractive
      APT="apt-get -y -o DPkg::Lock::Timeout=300"
      VM_USER=@@VM_USER@@
      STATUS=/var/log/devtools-setup.status
      warns=0
      log()  { echo "[setup-devtools] $*"; }
      warn() { warns=$((warns + 1)); log "WARN: $*"; }
      finish() {
        when=$(date '+%Y-%m-%d %H:%M:%S %Z')
        if [ "$warns" -eq 0 ]; then printf 'OK\t%s\n' "$when" > "$STATUS"
        else printf 'WARN (%s step(s) failed)\t%s\n' "$warns" "$when" > "$STATUS"; fi
      }
      trap finish EXIT

      # --- Prerequisites ----------------------------------------------------
      $APT update || warn "apt update"
      $APT install ca-certificates curl gnupg apt-transport-https build-essential unzip || warn "prerequisites"
      install -m 0755 -d /etc/apt/keyrings

      # --- Node.js (system-wide) + global CLIs ------------------------------
      # Done first so `claude` works even if a later step fails. System Node
      # (on PATH for all users and non-login shells); nvm is also installed
      # per-user by setup-devtools-user for those who want version switching.
      if ! command -v node >/dev/null 2>&1; then
        log "Installing Node.js (NodeSource current LTS)"
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && $APT install nodejs || warn "nodejs"
      fi
      command -v claude    >/dev/null 2>&1 || npm install -g @anthropic-ai/claude-code || warn "claude-code"
      command -v bw        >/dev/null 2>&1 || npm install -g @bitwarden/cli            || warn "bitwarden-cli"
      command -v json-diff >/dev/null 2>&1 || npm install -g json-diff                 || warn "json-diff"

      # --- Third-party APT repositories -------------------------------------
      if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        log "Adding Docker apt repo"
        { curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
            && chmod a+r /etc/apt/keyrings/docker.asc \
            && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list; } || warn "docker repo"
      fi
      if [ ! -f /etc/apt/sources.list.d/google-cloud-sdk.list ]; then
        log "Adding Google Cloud SDK apt repo (also provides kubectl)"
        { curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg \
            && echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list; } || warn "gcloud repo"
      fi
      if [ ! -f /etc/apt/sources.list.d/helm-stable-debian.list ]; then
        log "Adding Helm apt repo"
        { curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor -o /etc/apt/keyrings/helm.gpg \
            && echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" > /etc/apt/sources.list.d/helm-stable-debian.list; } || warn "helm repo"
      fi
      if [ ! -f /etc/apt/sources.list.d/sbt.list ]; then
        log "Adding sbt apt repo"
        { curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" | gpg --dearmor -o /etc/apt/keyrings/scalasbt.gpg \
            && echo "deb [signed-by=/etc/apt/keyrings/scalasbt.gpg] https://repo.scala-sbt.org/scalasbt/debian all main" > /etc/apt/sources.list.d/sbt.list; } || warn "sbt repo"
      fi

      # --- Install apt packages ---------------------------------------------
      $APT update || warn "apt update (post-repo)"
      $APT install \
        openjdk-21-jdk openjdk-21-source \
        sbt \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin kubectl \
        kubectx helm \
        git jq fzf ripgrep fd-find bat source-highlight moreutils \
        p7zip-full pwgen sshfs || warn "apt package install"

      # Let the VM user drive Docker without sudo.
      getent group docker >/dev/null 2>&1 && usermod -aG docker "$VM_USER"

      # --- Standalone binaries (system-wide, /usr/local/bin) ----------------
      if [ ! -x /usr/local/bin/yq ]; then
        log "Installing yq"
        { curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x /usr/local/bin/yq; } || warn "yq"
      fi
      if [ ! -x /usr/local/bin/micro ]; then
        log "Installing micro"
        ( cd /usr/local/bin && curl -fsSL https://getmic.ro | bash ) || warn "micro"
      fi
      if [ ! -x /usr/local/bin/tgswitch ]; then
        log "Installing tgswitch"
        curl -fsSL https://raw.githubusercontent.com/warrensbox/tgswitch/release/install.sh | bash || warn "tgswitch"
      fi
      if [ ! -x /usr/local/bin/hcl2json ]; then
        log "Installing hcl2json"
        { curl -fsSL -o /usr/local/bin/hcl2json https://github.com/tmccombs/hcl2json/releases/latest/download/hcl2json_linux_amd64 && chmod +x /usr/local/bin/hcl2json; } || warn "hcl2json"
      fi

      # --- Per-user tooling (nvm, tfenv, rustup, bash-it) -------------------
      # The 9p-mount bootcmd runs before cloud-init creates $VM_USER, so on first
      # boot it creates /home/$VM_USER as root; user creation then leaves the home
      # root-owned and without skeleton files. Repair ownership + seed skel before
      # the per-user installs. Non-recursive, so a 9p share under ~/host (already
      # mounted by bootcmd) is left untouched.
      home="/home/$VM_USER"
      if [ -d "$home" ]; then
        chown "$VM_USER:$VM_USER" "$home" || warn "home chown"
        for f in .bashrc .profile .bash_logout; do
          [ -e "$home/$f" ] || { cp -a "/etc/skel/$f" "$home/$f" 2>/dev/null && chown "$VM_USER:$VM_USER" "$home/$f"; }
        done
      fi
      log "Installing per-user tooling for $VM_USER"
      sudo -u "$VM_USER" -H bash /usr/local/sbin/setup-devtools-user || warn "per-user tooling"

      log "Done (warnings: $warns)"

  - path: /usr/local/sbin/setup-devtools-user
    permissions: '0755'
    content: |
      #!/bin/bash
      # Per-user half of first-boot dev-tooling setup. Run as the VM user by
      # setup-devtools. Guarded so re-running only fills in what's missing.
      # Exits non-zero if any step fails, so the caller can flag it.
      set -u
      fails=0
      log()  { echo "[setup-devtools-user] $*"; }
      fail() { fails=$((fails + 1)); log "WARN: $* failed"; }
      BASHRC="$HOME/.bashrc"

      # bash-it first: its installer may rewrite ~/.bashrc, so the PATH/alias
      # lines appended further down must come after it to survive.
      if [ ! -f "$HOME/.bash_it/bash_it.sh" ]; then
        log "Installing bash-it"
        { git clone --depth=1 https://github.com/Bash-it/bash-it.git "$HOME/.bash_it" \
            && "$HOME/.bash_it/install.sh" --silent; } || fail "bash-it"
      fi

      # rustup (Rust toolchain).
      if [ ! -d "$HOME/.rustup" ]; then
        log "Installing rustup"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || fail "rustup"
      fi

      # nvm + Node LTS (per-user version manager; system Node is the default).
      if [ ! -d "$HOME/.nvm" ]; then
        log "Installing nvm + Node LTS"
        if git clone https://github.com/nvm-sh/nvm.git "$HOME/.nvm" \
             && ( cd "$HOME/.nvm" && git checkout "$(git describe --abbrev=0 --tags)" ); then
          if ! grep -q NVM_DIR "$BASHRC" 2>/dev/null; then
            {
              echo 'export NVM_DIR="$HOME/.nvm"'
              echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
              echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
            } >> "$BASHRC"
          fi
          export NVM_DIR="$HOME/.nvm"
          { . "$NVM_DIR/nvm.sh" && nvm install --lts; } || fail "nvm node install"
        else
          fail "nvm"
        fi
      fi

      # tfenv (Terraform version manager).
      if [ ! -d "$HOME/.tfenv" ]; then
        log "Installing tfenv"
        if git clone --depth=1 https://github.com/tfutils/tfenv.git "$HOME/.tfenv"; then
          grep -q '.tfenv/bin' "$BASHRC" 2>/dev/null || echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> "$BASHRC"
        else
          fail "tfenv"
        fi
      fi

      # Aliases: Ubuntu ships fd as fdfind and bat as batcat.
      grep -q 'alias fd=fdfind'  "$BASHRC" 2>/dev/null || echo 'alias fd=fdfind'  >> "$BASHRC"
      grep -q 'alias bat=batcat' "$BASHRC" 2>/dev/null || echo 'alias bat=batcat' >> "$BASHRC"

      log "Done (failures: $fails)"
      [ "$fails" -eq 0 ]

  - path: /etc/update-motd.d/98-devtools
    permissions: '0755'
    content: |
      #!/bin/sh
      STATUS=/var/log/devtools-setup.status
      if [ -r "$STATUS" ]; then
        result=$(cut -f1 "$STATUS"); when=$(cut -f2- "$STATUS")
        echo "devtools-setup: $result ($when)"
      else
        echo "devtools-setup: not complete yet (first-boot install may still be running)"
      fi

users:
  - name: @@VM_USER@@
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys: [@@SSH_AUTHORIZED_KEYS@@]

chpasswd:
  expire: false
  users:
    - name: @@VM_USER@@
      password: @@VM_PASSWORD@@
      type: text

# Mount the 9p share (tag "@@MOUNT_TAG@@") at ~/host on every boot. Using bootcmd
# (which runs each boot) rather than the "mounts" module (which only runs once
# per instance) so it works even on an already-initialized VM. The mount is a
# no-op when no host directory is shared (started without an argument).
bootcmd:
  - mkdir -p /home/@@VM_USER@@/host
  - [ sh, -c, "mountpoint -q /home/@@VM_USER@@/host || mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600,rw @@MOUNT_TAG@@ /home/@@VM_USER@@/host || true" ]

# One-time first-boot setup (runcmd runs only on first boot of an instance):
#   1. Install the developer-tooling subset (Node/Claude Code, JDK, Docker,
#      gcloud/kubectl/helm, Terraform tooling, Rust, CLI utilities, ...). Done
#      before starting apt-upgrade so they don't contend for the apt lock.
#   2. Enable + start apt-upgrade.service; the enable symlink persists on the
#      overlay disk, so it runs on every subsequent boot.
runcmd:
  - /usr/local/sbin/setup-devtools
  - systemctl daemon-reload
  - systemctl enable apt-upgrade.service
  - systemctl start --no-block apt-upgrade.service
