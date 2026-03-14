#!/usr/bin/env bash
# QEMU test environment for os-install.sh
# Tests: NVMe drive + UEFI Secure Boot (OVMF) + TPM2 (swtpm)
#
# USAGE:
#   First time:  bash test-qemu.sh setup   # creates disk image + TPM state
#   Run VM:      bash test-qemu.sh run      # boots into Arch ISO
#   Resume:      bash test-qemu.sh run      # same command after install phases
#   Clean up:    bash test-qemu.sh clean

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
VM_DIR="$(pwd)/qemu-test"
DISK_IMAGE="${VM_DIR}/arch.qcow2"
DISK_SIZE="40G"
OVMF_CODE="/usr/share/OVMF/x64/OVMF_CODE.secboot.4m.fd"   # read-only, Secure Boot capable
OVMF_VARS_ORIG="/usr/share/OVMF/x64/OVMF_VARS.4m.fd"      # template (no keys = Setup Mode)
OVMF_VARS="${VM_DIR}/OVMF_VARS.fd"                          # writable per-VM copy
TPM_STATE="${VM_DIR}/tpm"
TPM_SOCK="${VM_DIR}/tpm/swtpm.sock"
RAM="4G"
CPUS="2"
# ──────────────────────────────────────────────────────────────────────────────

check_deps() {
    local missing=()
    command -v qemu-system-x86_64 &>/dev/null || missing+=(qemu-system-x86_64)
    command -v swtpm               &>/dev/null || missing+=(swtpm)
    command -v swtpm_setup         &>/dev/null || missing+=(swtpm)

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing[*]}"
        echo "Install with: sudo pacman -S qemu-system-x86_64 swtpm"
        exit 1
    fi
}

find_iso() {
    # Accept ISO path as argument, or auto-detect in current directory
    if [[ -n "${1:-}" ]]; then
        ISO="${1}"
    else
        ISO="$(ls ./*.iso 2>/dev/null | head -1 || true)"
    fi

    if [[ -z "${ISO}" || ! -f "${ISO}" ]]; then
        echo "No Arch ISO found. Either:"
        echo "  bash test-qemu.sh run /path/to/archlinux.iso"
        echo "  Place an .iso file in $(pwd)"
        exit 1
    fi
    echo "Using ISO: ${ISO}"
}

cmd_setup() {
    check_deps
    mkdir -p "${VM_DIR}" "${TPM_STATE}"

    echo "--- Creating ${DISK_SIZE} NVMe disk image ---"
    qemu-img create -f qcow2 "${DISK_IMAGE}" "${DISK_SIZE}"

    echo "--- Copying OVMF vars (Secure Boot Setup Mode — no pre-enrolled keys) ---"
    cp "${OVMF_VARS_ORIG}" "${OVMF_VARS}"

    echo "--- Initialising swtpm TPM2 state ---"
    swtpm_setup \
        --tpmstate "${TPM_STATE}" \
        --tpm2 \
        --overwrite \
        --log /dev/null

    echo ""
    echo "==> Setup complete. Files in: ${VM_DIR}"
    echo "    Next: bash test-qemu.sh run /path/to/archlinux.iso"
}

start_swtpm() {
    # Kill any stale swtpm instance holding a lock on the state dir
    pkill -f "swtpm.*${TPM_STATE}" 2>/dev/null || true
    sleep 0.3
    rm -f "${TPM_SOCK}"

    swtpm socket \
        --tpmstate "dir=${TPM_STATE}" \
        --tpm2 \
        --ctrl "type=unixio,path=${TPM_SOCK}" \
        --flags not-need-init,startup-clear \
        --daemon

    # Wait for socket to appear
    local i=0
    while [[ ! -S "${TPM_SOCK}" && $i -lt 20 ]]; do
        sleep 0.1; ((i++))
    done
    [[ -S "${TPM_SOCK}" ]] || { echo "swtpm failed to start"; exit 1; }
    echo "--- swtpm started (${TPM_SOCK}) ---"
}

cmd_run() {
    check_deps
    find_iso "${1:-}"

    [[ -f "${DISK_IMAGE}" ]] || { echo "Run 'bash test-qemu.sh setup' first."; exit 1; }
    [[ -f "${OVMF_VARS}"  ]] || { echo "Run 'bash test-qemu.sh setup' first."; exit 1; }

    start_swtpm

    echo "--- Starting QEMU (graphical window will open) ---"
    echo "    UEFI menu        → press Escape at the TianoCore splash"
    echo "    Secure Boot      → Device Manager → Secure Boot Configuration → Reset to Setup Mode"
    echo "    Exit QEMU        → close the window, or Ctrl+A X in this terminal"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -machine q35,smm=on \
        -m "${RAM}" \
        -cpu host \
        -smp "${CPUS}" \
        \
        `# UEFI firmware — secboot variant starts in Setup Mode (no enrolled keys)` \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        \
        `# NVMe drive — appears as /dev/nvme0n1 inside the VM` \
        -drive file="${DISK_IMAGE}",if=none,id=nvme0,format=qcow2 \
        -device nvme,drive=nvme0,serial=nvme0 \
        \
        `# TPM2 via swtpm socket` \
        -chardev socket,id=chrtpm,path="${TPM_SOCK}" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-crb,tpmdev=tpm0 \
        \
        `# Arch ISO` \
        -cdrom "${ISO}" \
        -boot order=dc,menu=on \
        \
        `# Graphical display` \
        -vga std \
        -display gtk,gl=off \
        `# Serial console also forwarded to this terminal for OS-level output` \
        -serial mon:stdio
}

cmd_clean() {
    echo "Removing ${VM_DIR} ..."
    rm -rf "${VM_DIR}"
    echo "Done."
}

case "${1:-}" in
    setup) cmd_setup ;;
    run)   cmd_run "${2:-}" ;;
    clean) cmd_clean ;;
    *)
        echo "Usage: $0 {setup|run [iso]|clean}"
        echo "  setup         - Create disk image + TPM2 state (run once)"
        echo "  run [iso]     - Start the VM (boots ISO first time, disk on subsequent runs)"
        echo "  clean         - Delete all VM files"
        echo ""
        echo "Workflow:"
        echo "  1. bash test-qemu.sh setup"
        echo "  2. bash test-qemu.sh run archlinux.iso"
        echo "     → inside VM: bash os-install.sh install"
        echo "     → VM reboots to UEFI; enable Secure Boot Setup Mode, then boot installed system"
        echo "  3. bash test-qemu.sh run archlinux.iso   (ISO still attached, boots disk)"
        echo "     → inside VM: bash os-install.sh secureboot"
        exit 1
        ;;
esac
