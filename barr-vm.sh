#!/usr/bin/env bash
# barr-vm.sh — Spin up a Debian 13 cloud VM and deploy the barr playbook.
#
# Usage:
#   ./barr-vm.sh            full setup (download → boot → copy → install Ansible)
#   ./barr-vm.sh start      boot a previously prepared VM
#   ./barr-vm.sh stop       graceful shutdown
#   ./barr-vm.sh ssh        open an interactive SSH session
#   ./barr-vm.sh run        run the Ansible playbook inside the VM
#   ./barr-vm.sh status     show running state
#   ./barr-vm.sh clean      delete all VM artefacts (.vm/)
#
# Override any variable via environment:
#   VM_RAM=8192 VM_CPUS=4 VM_DISK=80G SSH_PORT=2222 ./barr-vm.sh
#
# All overridable variables (with defaults):
#   DEBIAN_IMG_URL  URL of the Debian genericcloud qcow2 image to download
#   WORK_DIR        Working directory for VM artefacts  (.vm/)
#   VM_NAME         QEMU VM name and cloud-init hostname (barr)
#   VM_RAM          RAM in MiB                           (4096)
#   VM_CPUS         vCPU count                           (2)
#   VM_DISK         Overlay disk size (qemu-img syntax)  (40G)
#   SSH_PORT        Host port forwarded to VM port 22    (2222)
#   DEPLOY_USER     User created by cloud-init           (deploy)
#
# Optional host dependency:
#   socat — used for graceful ACPI shutdown (stop command).
#           If absent, stop falls back to SIGTERM immediately.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/.vm}"

IMG_URL="${DEBIAN_IMG_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
IMG_FILE="${WORK_DIR}/base.qcow2"
DISK_FILE="${WORK_DIR}/disk.qcow2"
SEED_FILE="${WORK_DIR}/seed.iso"
PID_FILE="${WORK_DIR}/qemu.pid"
MONITOR_SOCK="${WORK_DIR}/monitor.sock"
SSH_KEY="${WORK_DIR}/id_ed25519"

VM_NAME="${VM_NAME:-barr}"
VM_RAM="${VM_RAM:-4096}"           # MiB
VM_CPUS="${VM_CPUS:-2}"
VM_DISK="${VM_DISK:-40G}"
SSH_PORT="${SSH_PORT:-2222}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
else
  R='' G='' Y='' B='' N=''
fi
info() { echo -e "${B}[INFO]${N}  $*"; }
ok()   { echo -e "${G}[ OK ]${N}  $*"; }
warn() { echo -e "${Y}[WARN]${N}  $*"; }
die()  { echo -e "${R}[ERR ]${N}  $*" >&2; exit 1; }
step() { echo -e "\n${B}──── $* ────${N}"; }

# ── SSH helpers ───────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=5 \
          -i ${SSH_KEY} -p ${SSH_PORT}"

vm_ssh() { ssh ${SSH_OPTS} "${DEPLOY_USER}@127.0.0.1" "$@"; }

vm_rsync() {
  rsync -az --delete \
    -e "ssh ${SSH_OPTS}" \
    "$@"
}

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in qemu-system-x86_64 qemu-img ssh ssh-keygen curl rsync; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  # Need at least one ISO tool
  if ! command -v cloud-localds &>/dev/null \
  && ! command -v genisoimage &>/dev/null \
  && ! command -v mkisofs    &>/dev/null \
  && ! command -v xorriso    &>/dev/null; then
    missing+=("cloud-image-utils | genisoimage | mkisofs | xorriso")
  fi

  [[ ${#missing[@]} -eq 0 ]] || die "Missing dependencies: ${missing[*]}"
}

# ── Image download ────────────────────────────────────────────────────────────
download_image() {
  if [[ -f "$IMG_FILE" ]]; then
    ok "Base image already present, skipping download."
    return
  fi
  info "Downloading Debian 13 cloud image..."
  curl -L --progress-bar -o "$IMG_FILE" "$IMG_URL"
  ok "Image saved to $IMG_FILE"
}

# ── SSH key ───────────────────────────────────────────────────────────────────
gen_ssh_key() {
  if [[ -f "$SSH_KEY" ]]; then
    ok "SSH key already exists."
    return
  fi
  info "Generating deployment SSH key..."
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "barr-deploy"
  ok "Key: $SSH_KEY"
}

# ── Cloud-init seed ───────────────────────────────────────────────────────────
build_seed() {
  if [[ -f "$SEED_FILE" ]]; then
    ok "Seed ISO already exists."
    return
  fi

  local pubkey
  pubkey="$(cat "${SSH_KEY}.pub")"

  info "Writing cloud-init user-data..."
  cat > "${WORK_DIR}/user-data" << EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.local
manage_etc_hosts: true

users:
  - name: ${DEPLOY_USER}
    gecos: Deploy User
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${pubkey}

package_update: true
package_upgrade: false
packages:
  - python3
  - python3-pip
  - rsync
  - git

# Mask daily apt timers so they don't interfere with Ansible package tasks.
runcmd:
  - systemctl mask apt-daily.timer apt-daily-upgrade.timer
  - systemctl mask apt-daily.service apt-daily-upgrade.service

final_message: "Cloud-init done. System ready in \$UPTIME seconds."
EOF

  cat > "${WORK_DIR}/meta-data" << EOF
instance-id: ${VM_NAME}-001
local-hostname: ${VM_NAME}
EOF

  info "Building cloud-init seed ISO..."
  if command -v cloud-localds &>/dev/null; then
    cloud-localds "$SEED_FILE" "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"
  elif command -v genisoimage &>/dev/null; then
    genisoimage -quiet -output "$SEED_FILE" -volid cidata -joliet -rock \
      "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"
  elif command -v mkisofs &>/dev/null; then
    mkisofs -quiet -output "$SEED_FILE" -volid cidata -joliet -rock \
      "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"
  else
    # xorriso last resort
    xorriso -as mkisofs -quiet -output "$SEED_FILE" -volid cidata -joliet -rock \
      "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"
  fi
  ok "Seed ISO: $SEED_FILE"
}

# ── VM disk ───────────────────────────────────────────────────────────────────
prepare_disk() {
  if [[ -f "$DISK_FILE" ]]; then
    ok "VM disk already exists."
    return
  fi
  info "Creating VM disk (backing: base image, size: ${VM_DISK})..."
  qemu-img create -f qcow2 \
    -b "$(realpath "$IMG_FILE")" -F qcow2 \
    "$DISK_FILE" "$VM_DISK"
  ok "Disk: $DISK_FILE"
}

# ── QEMU start ────────────────────────────────────────────────────────────────
detect_accel() {
  if [[ "$OSTYPE" == linux* ]] && [[ -r /dev/kvm ]]; then
    echo "-enable-kvm -cpu host"
  elif [[ "$OSTYPE" == darwin* ]]; then
    echo "-accel hvf -cpu host"
  else
    warn "No hardware acceleration available — TCG will be slow."
    echo "-cpu qemu64"
  fi
}

start_vm() {
  if vm_is_running; then
    warn "VM is already running (PID $(cat "$PID_FILE"))."
    return
  fi

  # shellcheck disable=SC2046
  qemu-system-x86_64 \
    -name "$VM_NAME" \
    -m "$VM_RAM" \
    -smp "$VM_CPUS" \
    $(detect_accel) \
    -drive "file=${DISK_FILE},format=qcow2,if=virtio,cache=writeback" \
    -drive "file=${SEED_FILE},format=raw,if=virtio,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -display none \
    -daemonize \
    -pidfile "$PID_FILE"

  ok "VM started — PID $(cat "$PID_FILE"), SSH → localhost:${SSH_PORT}"
}

vm_is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# ── Wait for SSH ──────────────────────────────────────────────────────────────
wait_ssh() {
  info "Waiting for SSH (up to 5 min)..."
  local i
  for ((i=1; i<=60; i++)); do
    if vm_ssh true 2>/dev/null; then
      ok "SSH ready after $((i * 5))s"
      return 0
    fi
    printf "  [%2d/60] waiting...\r" "$i"
    sleep 5
  done
  die "SSH did not become available after 5 minutes."
}

# ── Copy playbook ─────────────────────────────────────────────────────────────
copy_playbook() {
  info "Syncing playbook to VM:~/barr/ ..."
  vm_rsync \
    --exclude='.vm/' \
    --exclude='.git/' \
    --exclude='*.pyc' \
    --exclude='__pycache__/' \
    "${REPO_DIR}/" \
    "${DEPLOY_USER}@127.0.0.1:barr/"
  ok "Playbook synced."
}

# ── Install Ansible ───────────────────────────────────────────────────────────
install_ansible() {
  info "Installing Ansible on the VM..."
  vm_ssh bash << 'REMOTE'
set -e
# cloud-init may still be running its own apt operations when SSH first
# becomes available. Poll until the apt lists lock is free (up to 60s).
for i in $(seq 1 12); do
  sudo flock --nonblock /var/lib/apt/lists/lock true 2>/dev/null && break || sleep 5
done
sudo apt-get install -y ansible
ansible --version
REMOTE
  ok "Ansible installed."
}

# ── Run playbook ──────────────────────────────────────────────────────────────
run_playbook() {
  info "Running playbook inside the VM..."
  vm_ssh "cd barr && ansible-playbook -i inventory_local.ini install.yml"
}

# ── Stop VM ───────────────────────────────────────────────────────────────────
stop_vm() {
  if ! vm_is_running; then
    warn "VM does not appear to be running."
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
    return
  fi
  local pid
  pid=$(cat "$PID_FILE")
  info "Sending ACPI power-down to VM (PID ${pid})..."
  # Prefer graceful shutdown via QEMU monitor
  if [[ -S "$MONITOR_SOCK" ]] && command -v socat &>/dev/null; then
    echo "system_powerdown" | socat - "UNIX-CONNECT:${MONITOR_SOCK}" 2>/dev/null || true
    # Give the VM up to 30s to shut down cleanly
    local i
    for ((i=0; i<30; i++)); do
      vm_is_running || break
      sleep 1
    done
  fi
  # Force-kill if still running
  if vm_is_running; then
    warn "Graceful shutdown timed out, force-killing."
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  ok "VM stopped."
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  echo ""
  if vm_is_running; then
    ok "VM is RUNNING (PID $(cat "$PID_FILE"))"
    echo "   SSH : ssh -i ${SSH_KEY} -p ${SSH_PORT} ${DEPLOY_USER}@127.0.0.1"
    echo "   Run : ./barr-vm.sh run"
    echo "   Stop: ./barr-vm.sh stop"
  else
    warn "VM is NOT running."
    [[ -f "$DISK_FILE" ]] && echo "   Disk exists → ./barr-vm.sh start to restart." \
                          || echo "   No disk found → ./barr-vm.sh to do full setup."
  fi
  echo ""
}

# ── Clean ─────────────────────────────────────────────────────────────────────
clean_vm() {
  if vm_is_running; then
    stop_vm
  fi
  if [[ -d "$WORK_DIR" ]]; then
    read -r -p "Delete ${WORK_DIR}? This removes the disk and keys. [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Aborted."; return; }
    rm -rf "$WORK_DIR"
    ok "Cleaned."
  else
    ok "Nothing to clean."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-setup}"

  mkdir -p "$WORK_DIR"

  case "$cmd" in
    setup)
      step "Checking dependencies"
      check_deps

      step "Base image"
      download_image

      step "SSH key"
      gen_ssh_key

      step "Cloud-init seed"
      build_seed

      step "VM disk"
      prepare_disk

      step "Starting VM"
      start_vm

      step "Waiting for SSH"
      wait_ssh

      step "Copying playbook"
      copy_playbook

      step "Installing Ansible"
      install_ansible

      step "Done"
      echo ""
      ok  "VM is ready. Connect with:"
      echo "    ssh -i ${SSH_KEY} -p ${SSH_PORT} ${DEPLOY_USER}@127.0.0.1"
      echo ""
      info "Edit group_vars/all.yml (caddy_domain, media paths, etc.), then:"
      echo "    ./barr-vm.sh run      # run the playbook inside the VM"
      echo "    ./barr-vm.sh ssh      # drop into an interactive shell"
      echo ""
      ;;
    start)
      check_deps
      [[ -f "$DISK_FILE" ]] || die "No VM disk found. Run './barr-vm.sh' first."
      [[ -f "$SEED_FILE" ]] || die "No seed ISO found. Run './barr-vm.sh' first."
      start_vm
      ;;
    stop)  stop_vm ;;
    ssh)
      vm_is_running || die "VM is not running."
      # shellcheck disable=SC2086
      ssh ${SSH_OPTS} "${DEPLOY_USER}@127.0.0.1"
      ;;
    run)
      vm_is_running || die "VM is not running. Start it first."
      copy_playbook
      run_playbook
      ;;
    status) show_status ;;
    clean)  clean_vm ;;
    *)
      echo "Unknown command: $cmd"
      echo "Usage: $0 {setup|start|stop|ssh|run|status|clean}"
      exit 1
      ;;
  esac
}

main "$@"
