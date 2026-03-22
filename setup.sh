#!/bin/bash

set -e

SMB_MOUNTS=(
    "//SERVER/SHARE1 /mnt/share/data"
    "//SERVER/SHARE2 /mnt/share/appdata"
)

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

echo "Starting setup..."

read -rp "Confirm each command before executing? [y/N] " _confirm_mode || true
[[ "${_confirm_mode}" =~ ^[Yy]$ ]] && CONFIRM_EACH=true

# ── Enable extra repository ─────────────────────────────────────────────────────
if ! grep -q '^\[extra\]' /etc/pacman.conf; then
    run sudo sed -i '/^#\[extra\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi

# ── Enable multilib repository ─────────────────────────────────────────────────────
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    run sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi

# ── System update ──────────────────────────────────────────────────────────────
run sudo pacman -Syu --noconfirm

# ── Pacman packages ────────────────────────────────────────────────────────────
PACKAGES=(
    # Build tools
    base-devel
    git
    cmake
    cpio

    # Graphics
    mesa
    lib32-mesa
    lib32-vulkan-radeon

    # Hyprland ecosystem
    hyprland
    hyprpaper
    hypridle
    hyprlock
    hyprpolkitagent
    swaync                      # notifications
    sddm                        # Login manager
    rofi
    quickshell

    # Terminal
    kitty

    # Audio
    pipewire
    pipewire-pulse
    wireplumber
    pavucontrol
    playerctl                   # media keys + waybar mpris

    # Network
    networkmanager              # nmtui (used in waybar network click)
    firewalld
    clamav
    github-cli
    usbguard
    bluez
    bluez-utils
    blueman                     # Bluetooth GUI manager + tray applet

    # keyring
    gnome-keyring

    # Brightness
    brightnessctl

    # Display / Wayland utilities
    wl-clipboard
    xdg-desktop-portal-gtk
    xdg-desktop-portal-hyprland
    xdg-user-dirs

    # File management
    udiskie
    udisks2
    lf
    rsync                       # lf paste-progress
    cifs-utils                  # SMB/Samba mounts
    unzip
    unrar
    p7zip
    poppler                     # pdftotext for lf pdf preview

    # Media
    vlc
    vlc-plugins-all
    gwenview                    # image viewer (used in lf open)
    ffmpegthumbnailer           # video thumbnails in lf preview

    # Browser
    firefox

    # Qt theming + Wayland support
    qt6ct
    qt5-wayland
    qt6-wayland
    kvantum
    adw-gtk-theme

    # Fonts
    ttf-jetbrains-mono-nerd     # coding font with icons (kitty + lf)
    ttf-nerd-fonts-symbols      # standalone Nerd Font symbols (waybar icons)
    ttf-nerd-fonts-symbols-mono # monospace variant for terminals
    ttf-font-awesome            # Font Awesome (waybar fallback icons)
    papirus-icon-theme


    # Screenshot
    grim
    slurp

    # Better text preview in lf
    bat

    # Gaming
    steam

    flatpak
)

prompt_install() {
    # Usage: prompt_install <label> <cmd...> -- <pkg...>
    # Splits args on '--' into command and package list
    local label="$1"; shift
    local cmd=()
    while [[ "$1" != "--" ]]; do cmd+=("$1"); shift; done
    shift  # consume '--'
    local pkgs=("$@")
    local already_installed=()
    local to_install=()

    for pkg in "${pkgs[@]}"; do
        if pacman -Q "$pkg" &>/dev/null; then
            already_installed+=("$pkg")
        else
            to_install+=("$pkg")
        fi
    done

    [[ ${#already_installed[@]} -gt 0 ]] && echo "${label}: skipping already installed: ${already_installed[*]}"

    if [[ ${#to_install[@]} -gt 0 ]]; then
        run "${cmd[@]}" -S --needed "${to_install[@]}"
    else
        echo "${label}: all packages already installed, nothing to do."
    fi
}

prompt_install "pacman" sudo pacman -- "${PACKAGES[@]}"

# Install ALL noto & adobe fonts
run sudo pacman -S --needed $(pacman -Ssq noto-fonts)
run sudo pacman -S --needed $(pacman -Ssq adobe-source-han)

# ── Flatpak ─────────────────────────────────────────────────────────────────────
FLATPAK_APPS=(
    com.github.iwalton3.jellyfin-media-player
    tv.plex.PlexDesktop
    com.plexamp.Plexamp
)

run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
_installed_flatpaks=$(flatpak list --app --columns=application 2>/dev/null)
for _app in "${FLATPAK_APPS[@]}"; do
    if echo "$_installed_flatpaks" | grep -qx "$_app"; then
        echo "flatpak: $_app already installed, skipping"
    else
        run flatpak install --noninteractive flathub "$_app"
    fi
done

# Qt-based flatpaks need explicit Wayland socket access (not granted by default)
run flatpak override --user --socket=wayland tv.plex.PlexDesktop
run flatpak override --user --socket=wayland com.plexamp.Plexamp

# ── AUR (yay) ──────────────────────────────────────────────────────────────────
if ! command -v yay &>/dev/null; then
    echo "Installing yay..."
    run git clone https://aur.archlinux.org/yay.git /tmp/yay
    (cd /tmp/yay && run makepkg -si --noconfirm)
    run rm -rf /tmp/yay
fi

AUR_PACKAGES=(
    hyprshutdown                # shutdown menu (used in hyprland.conf)
    sweet-gtk-theme             # Sweet GTK theme (set in hyprland.conf)
    sweet-cursor-theme          # Sweet cursor theme (HYPRCURSOR_THEME=Sweet)
    ttf-all-the-icons
    wlogout                     # power menu (waybar power button)
)

prompt_install "yay" yay -- "${AUR_PACKAGES[@]}"

# ── Services ───────────────────────────────────────────────────────────────────
run sudo systemctl enable --now NetworkManager
run sudo systemctl enable --now firewalld
run sudo systemctl enable --now bluetooth
run sudo systemctl enable --now sddm

# ── ClamAV ─────────────────────────────────────────────────────────────────────
# Remove the 'Example' line that prevents services from starting
sudo sed -i '/^Example$/d' /etc/clamav/freshclam.conf
sudo sed -i '/^Example$/d' /etc/clamav/clamd.conf
echo "--- Updating ClamAV virus database (this may take a while) ---"
run sudo freshclam
run sudo systemctl enable --now clamav-freshclam   # automatic daily DB updates
run sudo systemctl enable --now clamav-daemon       # on-demand scanning daemon

# ── USBGuard ───────────────────────────────────────────────────────────────────
echo ""
echo "USBGuard: ensure all trusted USB devices (keyboard, mouse, etc.) are connected."
read -r -p "Generate USBGuard policy from currently connected devices and enable? [y/N] " _usbguard
if [[ "$_usbguard" =~ ^[Yy]$ ]]; then
    run sudo sh -c 'usbguard generate-policy > /etc/usbguard/rules.conf'
    run sudo systemctl enable --now usbguard
else
    echo "Skipping USBGuard. Run manually later:"
    echo "  sudo sh -c 'usbguard generate-policy > /etc/usbguard/rules.conf'"
    echo "  sudo systemctl enable --now usbguard"
fi

# ── gnome-keyring ──────────────────────────────────────────────────────────────
# PAM integration so keyring auto-unlocks on login via sddm
if ! grep -q 'pam_gnome_keyring' /etc/pam.d/sddm 2>/dev/null; then
    sudo tee -a /etc/pam.d/sddm > /dev/null <<'EOF'
auth     optional pam_gnome_keyring.so
session  optional pam_gnome_keyring.so auto_start
password optional pam_gnome_keyring.so
EOF
fi

# ── DNS-over-TLS (Mullvad) ─────────────────────────────────────────────────────
sudo systemctl enable systemd-resolved
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/dns-over-tls.conf > /dev/null <<'EOF'
[Resolve]
DNS=194.242.2.4#dns.mullvad.net 2a07:e340::4#dns.mullvad.net
DNSOverTLS=yes
DNSSEC=no
Domains=~.
EOF
run sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
run sudo systemctl restart systemd-resolved
run sudo systemctl restart NetworkManager

# ── udiskie ────────────────────────────────────────────────────────────────────
run sudo systemctl enable --now udisks2
mkdir -p ~/.config/udiskie
cat > ~/.config/udiskie/config.yml <<'EOF'
program_options:
  automount: true
  notify: true
  tray: false         # no tray icon (mako handles notifications)
  file_manager: lf

icon_names:
  media: [media-removable, media-flash]
EOF

# ── XDG user directories ───────────────────────────────────────────────────────
run xdg-user-dirs-update

# ── SMB persistent mounts ──────────────────────────────────────────────────────
# All entries share the same credentials file
SMB_CREDENTIALS="$HOME/.smbcredentials"

echo "Creating credentials file for SMB"

if [[ ! -f "$SMB_CREDENTIALS" ]]; then
    read -r -p "SMB username: " smb_user
    read -r -s -p "SMB password: " smb_pass
    echo
    printf 'username=%s\npassword=%s\n' "$smb_user" "$smb_pass" > "$SMB_CREDENTIALS"
    chmod 600 "$SMB_CREDENTIALS"
    echo "Credentials saved to $SMB_CREDENTIALS"
else
    echo "Credentials file already exists at $SMB_CREDENTIALS, skipping"
fi

for entry in "${SMB_MOUNTS[@]}"; do
    smb_server=$(echo "$entry" | awk '{print $1}')
    smb_mount=$(echo "$entry" | awk '{print $2}')
    run sudo mkdir -p "$smb_mount"
    fstab_entry="${smb_server} ${smb_mount} cifs credentials=${SMB_CREDENTIALS},uid=$(id -u),gid=$(id -g),_netdev,nofail,x-systemd.automount 0 0"
    if ! grep -qF "$smb_mount" /etc/fstab; then
        echo "$fstab_entry" | sudo tee -a /etc/fstab
        echo "Added SMB mount $smb_server -> $smb_mount to /etc/fstab"
    else
        echo "SMB mount $smb_mount already in /etc/fstab, skipping"
    fi
done

# ── SSH key ────────────────────────────────────────────────────────────────────
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY" ]]; then
    echo "No SSH key found at $SSH_KEY."
    read -r -p "Generate one now? [y/N] " gen_ssh
    if [[ "$gen_ssh" =~ ^[Yy]$ ]]; then
        read -r -p "Identifier or email for SSH key: " ssh_email
        run ssh-keygen -t ed25519 -C "$ssh_email" -f "$SSH_KEY" -N ""
        eval "$(ssh-agent -s)"
        run ssh-add "$SSH_KEY"
    else
        echo "Skipping SSH key generation. Cannot clone dotfiles via SSH — exiting."
        exit 1
    fi
fi

# ── GitHub auth + SSH key registration ─────────────────────────────────────────
if ! gh auth status &>/dev/null; then
    echo "Logging into GitHub (device flow — open the URL on any device)..."
    BROWSER=echo gh auth login --hostname github.com --git-protocol ssh --web
fi

if ! gh ssh-key list 2>/dev/null | grep -qF "$(cat "${SSH_KEY}.pub" | awk '{print $2}')"; then
    echo "Registering SSH key with GitHub..."
    run gh ssh-key add "${SSH_KEY}.pub" --title "$(hostname)"
fi

# ── Dotfiles ───────────────────────────────────────────────────────────────────
DOTFILES_DIR=~/Documents/workspace/dotfiles
if [[ ! -d "$DOTFILES_DIR" ]]; then
    run git clone git@github.com:thietala/dotfiles.git "$DOTFILES_DIR"
fi
run bash "$DOTFILES_DIR/install.sh"

echo ""
echo "Reminder to manually allow bluetooth for usb guard"
echo "Setup complete. Log out and back in (or reboot) to start Hyprland."
