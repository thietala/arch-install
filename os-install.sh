#!/usr/bin/env bash
# Arch Linux install script
# Source: https://walian.co.uk/arch-install-with-secure-boot-btrfs-tpm2-luks-encryption-unified-kernel-images.html
# Features: Secure Boot + btrfs + TPM2 + LUKS + Unified Kernel Images
# Target drive: /dev/nvme0n1

set -euo pipefail

DRIVE="/dev/nvme0n1"
PART_EFI="${DRIVE}p1"
PART_ROOT="${DRIVE}p2"
MAPPER_NAME="linuxroot"
MAPPER="/dev/mapper/${MAPPER_NAME}"

# TPM2 PCRs:
#   PCR 0  - UEFI firmware code       (locks to this firmware version)
#   PCR 7  - Secure Boot state        (requires SB enabled with enrolled keys)
#   PCR 11 - UKI measurement          (systemd-stub measures kernel+initrd+cmdline
#                                      here before executing; binds to exact binary)
#
# QEMU/OVMF note: PCR 11 is non-deterministic in QEMU — use "7" for VM testing.
# On real hardware use "0+7+11" for full security.
TPM2_PCRS="0+7+11"

PACKAGES=(
    base base-devel linux linux-firmware
    amd-ucode
    vim nano
    cryptsetup btrfs-progs dosfstools util-linux
    git unzip
    sbctl
    networkmanager
    sudo
    systemd
    openssh
)
# ──────────────────────────────────────────────────────────────────────────────

CONFIRM_EACH=false

run() {
    echo ""
    echo -e "\e[32m[ $* ]\e[0m"
    if [[ "${CONFIRM_EACH}" == true ]]; then
        read -rp "Execute this command? [Y/n] " _run_confirm || true
        if [[ "${_run_confirm}" =~ ^[Nn]$ ]]; then
            echo "    Skipped."
            return 0
        fi
    fi
    "$@"
}

verify_commands() {
    read -rp "Confirm each command before executing? [y/N] " _confirm_mode || true
    if [[ "${_confirm_mode}" =~ ^[Yy]$ ]]; then
        CONFIRM_EACH=true
    fi
}

confirm_config() {
    echo "==> Installation configuration"
    echo "  Drive:       ${DRIVE}"
    echo "  Username:    ${USERNAME}"
    echo "  Locale:      ${LOCALE}"
    echo "  Mirrors:     ${REFLECTOR_COUNTRY}"
    echo "  TPM2 PCRs:   ${TPM2_PCRS}"
    echo "  Keymap / timezone / hostname: prompted next"
    echo ""
    read -rp "Proceed? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

phase_install() {

    verify_commands

    read -rp "Username: " USERNAME
    read -rp "Locale (e.g. fi_FI.UTF-8, en_US.UTF-8): " LOCALE
    read -rp "Mirror country (two-letter code, e.g. FI, DE, GB): " REFLECTOR_COUNTRY
    confirm_config
    echo "==> Phase 1: Installation (live ISO)"

    # ── Disk partitioning ──────────────────────────────────────────────────
    echo "--- Partitioning ${DRIVE} ---"
    run sgdisk -Z "${DRIVE}"
    run sgdisk \
        -n1:0:+512M -t1:ef00 -c1:EFI \
        -N2 -t2:8304 -c2:LINUXROOT \
        "${DRIVE}"
    run partprobe -s "${DRIVE}"
    run lsblk "${DRIVE}"

    # ── LUKS encryption ────────────────────────────────────────────────────
    echo "--- Encrypting root partition ---"
    run cryptsetup luksFormat --type luks2 "${PART_ROOT}"
    run cryptsetup luksOpen "${PART_ROOT}" "${MAPPER_NAME}"

    # ── Filesystems ────────────────────────────────────────────────────────
    echo "--- Creating filesystems ---"
    run mkfs.vfat -F32 -n EFI "${PART_EFI}"
    run mkfs.btrfs -f -L linuxroot "${MAPPER}"

    # ── Mount + btrfs subvolumes ───────────────────────────────────────────
    echo "--- Mounting and creating btrfs subvolumes ---"
    run mount "${MAPPER}" /mnt
    run mkdir /mnt/efi
    run mount "${PART_EFI}" /mnt/efi

    run btrfs subvolume create /mnt/home
    run btrfs subvolume create /mnt/srv
    run btrfs subvolume create /mnt/var
    run btrfs subvolume create /mnt/var/log
    run btrfs subvolume create /mnt/var/cache
    run btrfs subvolume create /mnt/var/tmp

    # ── Mirrors + pacstrap ─────────────────────────────────────────────────
    echo "--- Updating mirrors ---"
    run reflector \
        --country "${REFLECTOR_COUNTRY}" \
        --age 24 \
        --protocol http,https \
        --sort rate \
        --save /etc/pacman.d/mirrorlist

    echo "--- Installing base system ---"
    run pacstrap -K /mnt "${PACKAGES[@]}"

    # ── Locale ────────────────────────────────────────────────────────────
    echo "--- Configuring locale ---"
    echo "LANG=${LOCALE}" > /mnt/etc/locale.conf
    sed -i -e "/^#${LOCALE}/s/^#//" /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen

    # ── Keymap, timezone, hostname ────────────────────────────────────────
    echo "--- Configuring keymap, timezone, hostname (interactive) ---"
    run systemd-firstboot --root=/mnt \
        --prompt-keymap \
        --prompt-timezone \
        --prompt-hostname

    arch-chroot /mnt hwclock --systohc

    # ── User ──────────────────────────────────────────────────────────────
    echo "--- Creating user ${USERNAME} ---"
    run arch-chroot /mnt useradd -G wheel -m "${USERNAME}"
    run arch-chroot /mnt passwd "${USERNAME}"
    # Enable wheel group with password (comment next line and uncomment the one after for NOPASSWD)
    run sed -i -e '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /mnt/etc/sudoers
    # sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' /mnt/etc/sudoers

    # ── mkinitcpio ────────────────────────────────────────────────────────
    echo "--- Configuring mkinitcpio ---"
    cat > /mnt/etc/mkinitcpio.conf <<'EOF'
# vim:set ft=sh
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)
EOF

    run mkdir -p /mnt/efi/EFI/Linux

    cat > /mnt/etc/mkinitcpio.d/linux.preset <<'EOF'
# mkinitcpio preset file to generate UKIs
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default' 'fallback')

default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF

    echo "quiet rw" > /mnt/etc/kernel/cmdline

    echo "--- Generating Unified Kernel Images ---"
    run arch-chroot /mnt mkinitcpio -P

    # ── Services + bootloader ─────────────────────────────────────────────
    echo "--- Enabling services ---"
    run systemctl --root /mnt enable systemd-resolved systemd-timesyncd NetworkManager sshd
    run systemctl --root /mnt mask systemd-networkd

    echo "--- Installing bootloader ---"
    run arch-chroot /mnt bootctl install --esp-path=/efi

    echo "==> Phase 1 complete."
    echo "    Rebooting into UEFI Setup Mode to enable Secure Boot Setup Mode..."
    echo "    After enabling Setup Mode in UEFI, boot into the new system and run:"
    echo "      bash os-install.sh secureboot"
    run sync
    run systemctl reboot --firmware-setup
}

phase_secureboot() {

    verify_commands

    # Phase 2a: enroll Secure Boot keys and sign binaries, then reboot.
    # TPM2 enrollment happens in phase_tpm2 AFTER this reboot, so that
    # PCR 7 (Secure Boot state) is captured with SB fully active — not in Setup Mode.
    echo "==> Phase 2: Secure Boot key enrollment"

    echo "--- Secure Boot status ---"
    run sbctl status

    echo "--- Creating and enrolling Secure Boot keys ---"
    run sudo sbctl create-keys
    run sudo sbctl enroll-keys -m

    echo "--- Signing EFI binaries ---"
    run sudo sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi
    run sudo sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
    run sudo sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
    run sudo sbctl sign -s /efi/EFI/Linux/arch-linux.efi
    run sudo sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi

    echo "--- Reinstalling kernel (verifies signing hooks are working) ---"
    run sudo pacman -S linux

    echo "==> Phase 2 complete."
    echo "    Rebooting — enter your LUKS passphrase this one last time."
    echo "    Once booted, run: bash os-install.sh tpm2"
    run sync
    run reboot
}

phase_tpm2() {

    verify_commands

    # Phase 2b: enroll TPM2 now that Secure Boot is active.
    # PCR 7 now reflects the real Secure Boot state (keys enrolled, SB enforcing).
    echo "==> Phase 3: TPM2 enrollment"

    echo "--- Secure Boot must be active (not Setup Mode) ---"
    run sbctl status

    # Verify the LUKS partition exists before proceeding
    if [[ ! -b "${PART_ROOT}" ]]; then
        echo "ERROR: ${PART_ROOT} not found. Check DRIVE= at the top of this script."
        exit 1
    fi

    echo "--- Current LUKS slots on ${PART_ROOT} ---"
    run sudo systemd-cryptenroll "${PART_ROOT}"

    echo "--- TPM2: Generating recovery key (save this somewhere safe!) ---"
    echo "    You will be prompted for your existing LUKS passphrase to authorise this."
    run sudo systemd-cryptenroll "${PART_ROOT}" --recovery-key

    echo "--- TPM2: Enrolling with PCRs ${TPM2_PCRS} ---"
    echo "    You will be prompted for your existing LUKS passphrase again."
    # PCR 0: firmware, PCR 7: Secure Boot state (now correct), PCR 11: UKI binary.
    run sudo systemd-cryptenroll \
        --tpm2-device=auto \
        --tpm2-pcrs="${TPM2_PCRS}" \
        "${PART_ROOT}"

    echo "--- LUKS slots after enrollment ---"
    run sudo systemd-cryptenroll "${PART_ROOT}"

    echo "--- Installing automatic TPM2 re-enrollment on kernel updates ---"
    install_auto_reenroll

    echo "==> TPM2 enrollment complete."
    echo "    Reboot — disk should unlock automatically via TPM2 (no passphrase prompt)."
}

install_auto_reenroll() {
    # ── Re-enrollment script ───────────────────────────────────────────────
    # Runs at boot after a kernel update; PCR 11 already reflects the new UKI
    # at this point, so sealing against it here binds to the correct binary.
    sudo tee /usr/local/bin/tpm2-reenroll > /dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
LUKS_DEV="${PART_ROOT}"
FLAG=/var/lib/tpm2-reenroll-pending
TPM2_PCRS="${TPM2_PCRS}"


systemd-cryptenroll "${LUKS_DEV}" --tpm2-device=auto --tpm2-pcrs="${TPM2_PCRS}"
systemd-cryptenroll "${LUKS_DEV}" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="${TPM2_PCRS}"
rm -f "\${FLAG}"
systemctl disable tpm2-reenroll-boot.service
echo "TPM2 re-enrollment complete (PCRs \${TPM2_PCRS})."
EOF
    run sudo chmod +x /usr/local/bin/tpm2-reenroll

    # ── Systemd one-shot boot service ──────────────────────────────────────
    # Enabled by the pacman hook; disables itself after running once.
    sudo tee /etc/systemd/system/tpm2-reenroll-boot.service > /dev/null <<'EOF'
[Unit]
Description=TPM2 LUKS re-enrollment after kernel update
Documentation=man:systemd-cryptenroll(1)
ConditionPathExists=/var/lib/tpm2-reenroll-pending
# Must run after LUKS is open so /dev/gpt-auto-root-luks exists
After=cryptsetup.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tpm2-reenroll
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # ── Pacman hook ────────────────────────────────────────────────────────
    # Fires after the 'linux' package is installed or upgraded.
    run sudo mkdir -p /etc/pacman.d/hooks
    sudo tee /etc/pacman.d/hooks/tpm2-reenroll.hook > /dev/null <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux

[Action]
Description = Scheduling TPM2 re-enrollment for next boot (PCR 11 will change)...
When = PostTransaction
Exec = /bin/sh -c 'touch /var/lib/tpm2-reenroll-pending && systemctl enable tpm2-reenroll-boot.service'
EOF

    echo "    Installed: /usr/local/bin/tpm2-reenroll"
    echo "    Installed: /etc/systemd/system/tpm2-reenroll-boot.service"
    echo "    Installed: /etc/pacman.d/hooks/tpm2-reenroll.hook"
}

case "${1:-}" in
    install)    phase_install ;;
    secureboot) phase_secureboot ;;
    tpm2)       phase_tpm2 ;;
    *)
        echo "Usage: $0 {install|secureboot|tpm2}"
        echo "  install     - Run from Arch live ISO (partitions, encrypts, installs)"
        echo "  secureboot  - Run after first boot (enrolls SB keys, reboots)"
        echo "  tpm2        - Run after secureboot reboot (enrolls TPM2 with correct PCRs)"
        echo ""
        echo "  TPM2 re-enrollment after kernel updates is automatic via pacman hook."
        exit 1
        ;;
esac
