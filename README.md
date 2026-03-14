# Arch Linux Install Script

Installs Arch Linux with full-disk encryption (LUKS2), btrfs, Secure Boot with custom
keys, and TPM2 auto-unlock. After setup, the disk unlocks automatically on every boot
with no passphrase prompt — as long as the firmware, Secure Boot keys, and kernel have
not changed.

---

## What this sets up

| Feature | Details |
|---|---|
| Disk encryption | LUKS2 on the root partition |
| Filesystem | btrfs with subvolumes for `/home`, `/srv`, `/var`, `/var/log`, `/var/cache`, `/var/tmp` |
| Boot | Unified Kernel Images (UKIs) — kernel + initrd + cmdline bundled into a single signed EFI binary |
| Secure Boot | Custom keys enrolled via `sbctl`; all EFI binaries signed |
| TPM2 auto-unlock | LUKS sealed against PCRs 0 (firmware) + 7 (Secure Boot state) + 11 (UKI binary) |
| Kernel update handling | Pacman hook automatically schedules TPM2 re-enrollment after each kernel update |

---

## Files

| File | Purpose |
|---|---|
| `os-install.sh` | The install script — run this inside the VM or on real hardware |
| `test-qemu.sh` | Manages a local QEMU VM for testing before running on real hardware |

---

## Installation overview

The installation is split into three phases, each run at a different point in the
process:

| Phase | When | Command |
|---|---|---|
| 1 — Install | From the Arch live ISO | `bash os-install.sh install` |
| 2 — Secure Boot | After first boot into installed system | `bash os-install.sh secureboot` |
| 3 — TPM2 | After the Secure Boot reboot | `bash os-install.sh tpm2` |

Phases 2 and 3 must be separate boots because TPM2 enrollment reads PCR 7 (Secure Boot
state). If enrolled during Setup Mode (phase 2), PCR 7 would capture the wrong value
and TPM2 would never unseal on normal boots.

---

## Testing in QEMU (recommended before real hardware)

### Dependencies

Install on your host machine:

```bash
sudo pacman -S qemu-system-x86_64 swtpm edk2-ovmf
```

### 1. Get an Arch ISO

Download the latest ISO from [archlinux.org/download](https://archlinux.org/download/)
and place it in this directory.

### 2. Create the VM environment (once)

```bash
bash test-qemu.sh setup
```

This creates `./qemu-test/` containing:
- `arch.qcow2` — 40G virtual NVMe disk (sparse)
- `OVMF_VARS.fd` — UEFI variable store (Secure Boot state persists here between runs)
- `tpm/` — TPM2 emulator state

### 3. Boot the VM

```bash
bash test-qemu.sh run archlinux-*.iso
```

A graphical window opens. At the Arch ISO boot menu, select the first entry and wait
for the shell prompt.

> **QEMU note:** PCR 11 (UKI measurement) is non-deterministic in QEMU due to OVMF
> behaviour. Before running phase 3, change `TPM2_PCRS="0+7+11"` to `TPM2_PCRS="7"`
> at the top of `os-install.sh`. On real hardware use `0+7+11`.

---

## Phase 1 — Install the OS (live ISO)

From inside the VM or booted Arch ISO on real hardware, run:

```bash
bash os-install.sh install
```

The script first asks:

1. **Review each command?** — type `y` to confirm every command before it runs, or press
   Enter to run everything automatically
2. **Username** — the name of your user account
3. **Locale** — type the locale string directly (e.g. `fi_FI.UTF-8`, `en_US.UTF-8`)
4. **Mirror country** — two-letter country code for fastest mirrors (e.g. `FI`, `DE`, `US`)

After confirming the summary, it will prompt for:

5. **LUKS passphrase** — encrypts the root partition; you will need this until TPM2 is
   enrolled in phase 3
6. **Keymap** — interactive selection (e.g. `fi`, `us`, `de`)
7. **Timezone** — interactive selection (e.g. `Europe/Helsinki`)
8. **Hostname** — the machine name (e.g. `archlinux`)
9. **User password** — password for the account created in step 2

The script will then:
- Partition `/dev/nvme0n1` (EFI + encrypted root)
- Format EFI as FAT32, root as btrfs with subvolumes
- Install the base system via `pacstrap`
- Configure locale, keymap, timezone, hostname
- Generate Unified Kernel Images
- Enable NetworkManager, SSH, systemd-resolved, systemd-timesyncd
- Install the systemd-boot bootloader
- **Reboot into UEFI firmware setup** to prepare for Secure Boot

---

## Enable Secure Boot Setup Mode in UEFI

After phase 1 reboots into firmware (OVMF menu in QEMU, or your motherboard's UEFI on
real hardware):

Clear your secureboot keys to set it to Setup Mode

> On QEMU, the OVMF firmware ships with no pre-enrolled keys so it is already in Setup
> Mode. You can verify with `sbctl status` once booted — `Setup Mode: Enabled` means
> you are ready.

---

## Phase 2 — Secure Boot key enrollment

You are now booted into the installed system. Get the script into the VM by serving it
from your host or download it from this repository:

```bash
# On the host machine, from this directory:
python3 -m http.server 8080
```

Then inside the VM:

```bash
curl http://10.0.2.2:8080/os-install.sh -o os-install.sh
bash os-install.sh secureboot
```

> On real hardware, copy the script via USB, git or any other method.

This phase will:
- Ask whether to review each command before running
- Show current Secure Boot status (`sbctl status`)
- Create your own custom Secure Boot key pair (Platform Key, KEK, db)
- Enroll those keys into UEFI firmware, also including Microsoft keys (`-m`) for hardware
  compatibility — your keys sign your own binaries, Microsoft keys cover signed hardware firmware
- Sign all EFI binaries: systemd-boot, BOOTX64.EFI, both UKIs
- Reinstall the kernel to verify the pacman signing hook works
- **Reboot automatically**

At the reboot, enter your LUKS passphrase one more time (TPM2 is not enrolled yet).

---

## Phase 3 — TPM2 enrollment

You are now booted with Secure Boot fully active. Download the script again and run
phase 3:

```bash
curl http://10.0.2.2:8080/os-install.sh -o os-install.sh
bash os-install.sh tpm2
```

This phase will:
1. Ask whether to review each command before running
2. Verify Secure Boot is active (not Setup Mode)
3. Show current LUKS slots
4. **Generate a recovery key** — the key is printed to the terminal; save it somewhere
   safe before continuing (e.g. a password manager or printed paper). This is your
   fallback if TPM2 ever fails to unseal. You will be prompted for your LUKS passphrase.
5. Enroll TPM2 against PCRs `0+7+11` — you will be prompted for your LUKS passphrase
   again to authorise this
6. Install the automatic TPM2 re-enrollment hook for future kernel updates

After phase 3, reboot. The disk should unlock automatically with no passphrase prompt.

---

## Verifying everything works

```bash
# Install tpm2-tools if not present
sudo pacman -S tpm2-tools

# Secure Boot is active and not in Setup Mode
sbctl status

# All EFI binaries are signed
sbctl verify

# LUKS slots — should show: password, recovery, tpm2
sudo systemd-cryptenroll /dev/nvme0n1p2

# Current PCR values that were bound during enrollment
sudo tpm2_pcrread sha256:0,7,11
```

---

## After kernel updates

The pacman hook installed in phase 3 handles re-enrollment automatically:

1. `sudo pacman -Syu` updates the kernel
2. The hook fires, creates a flag file, and enables the re-enrollment boot service
3. **One boot** where the LUKS passphrase is required (PCR 11 changed — new UKI)
4. At that boot, `tpm2-reenroll-boot.service` runs and re-seals TPM2 to the new UKI
5. All subsequent boots unlock automatically again

---

## Troubleshooting

**TPM2 fails to unseal after setup**

Check which PCR is unstable:
```bash
sudo tpm2_pcrread sha256:0,7,11
# reboot, enter passphrase, then run again and compare values
sudo tpm2_pcrread sha256:0,7,11
```
If PCR 0 changes: your firmware version changed (e.g. after a firmware update). Wipe
and re-enroll:
```bash
sudo systemd-cryptenroll /dev/nvme0n1p2 --wipe-slot=tpm2
sudo systemd-cryptenroll /dev/nvme0n1p2 --tpm2-device=auto --tpm2-pcrs="0+7+11"
```

**TPM2 not unsealing in QEMU**

PCR 11 is non-deterministic in QEMU/OVMF. Use PCR 7 only for VM testing:
```bash
sudo systemd-cryptenroll /dev/nvme0n1p2 --wipe-slot=tpm2
sudo systemd-cryptenroll /dev/nvme0n1p2 --tpm2-device=auto --tpm2-pcrs="7"
```

**Forgot to save the recovery key**

As long as you still know the LUKS passphrase (slot 0), you can generate a new recovery
key at any time:
```bash
sudo systemd-cryptenroll /dev/nvme0n1p2 --recovery-key
```

---

## Resetting the VM

To start completely fresh (wipes disk, UEFI state, and TPM state):

```bash
bash test-qemu.sh clean
bash test-qemu.sh setup
```

---

## PCR Reference

| PCR | Measures | Effect |
|---|---|---|
| 0 | UEFI firmware code | Unseals only on this exact firmware version; breaks on firmware updates |
| 7 | Secure Boot state + enrolled keys | Requires Secure Boot on with your specific keys enrolled |
| 11 | Full UKI (kernel + initrd + cmdline) | Binds to exact signed binary; any tampered or different kernel blocks unsealing |
