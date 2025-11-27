#!/usr/bin/env bash
# BenjiOS Installer - Ubuntu 25.10 (Questing Quokka)
# Runs as normal user, uses zenity for a simple GUI front-end.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

RAW_BASE="https://raw.githubusercontent.com/AdminPanic/BenjiOS/main"

#-----------------------------
# Helper functions
#-----------------------------

msg() { echo "==> $*"; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_not_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    die "Do NOT run this as root. Run it as your normal user."
  fi
}

ensure_zenity() {
  if ! command -v zenity >/dev/null 2>&1; then
    echo "Zenity not found. Installing zenity..."
    sudo apt-get update -y
    sudo apt-get install -y zenity
  fi
}

detect_amd_gpu() {
  if lspci 2>/dev/null | grep -E "VGA|3D" | grep -qi "AMD"; then
    echo "1"
  else
    echo "0"
  fi
}

preseed_ms_fonts_eula() {
  # So ubuntu-restricted-extras can install non-interactively
  msg "Pre-seeding Microsoft fonts EULA"
  sudo apt-get install -y debconf-utils
  echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | sudo debconf-set-selections || true
  echo 'ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note'       | sudo debconf-set-selections || true
}

update_and_upgrade() {
  msg "Updating APT package lists"
  sudo apt-get update -y
  msg "Upgrading installed packages (full-upgrade)"
  sudo apt-get full-upgrade -y
}

enable_i386() {
  if ! dpkg --print-foreign-architectures | grep -q '^i386$'; then
    msg "Enabling 32-bit (i386) architecture for gaming / Proton"
    sudo dpkg --add-architecture i386
    sudo apt-get update -y
  fi
}

setup_flatpak() {
  msg "Installing Flatpak + GNOME Software plugin"
  sudo apt-get install -y flatpak gnome-software-plugin-flatpak

  if ! flatpak remote-list | grep -q '^flathub'; then
    msg "Adding Flathub Flatpak remote"
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
}

install_base_packages() {
  msg "Installing base desktop / system tools"
  sudo apt-get install -y \
    wget curl git \
    dconf-cli \
    software-properties-common \
    fwupd \
    gnome-shell-extensions \
    gnome-shell-extension-manager \
    gvfs-backends \
    bluez-obexd \
    power-profiles-daemon \
    gnome-tweaks
}

install_core_desktop_stack() {
  msg "Installing core desktop / productivity stack"
  sudo apt-get install -y \
    libreoffice \
    thunderbird \
    remmina remmina-plugin-rdp remmina-plugin-secret \
    openvpn \
    network-manager-openvpn-gnome \
    vlc \
    rhythmbox \
    ubuntu-restricted-extras \
    nautilus-share \
    gnome-shell-extension-gsconnect
}

install_monitoring_stack() {
  msg "Installing monitoring / sensors / fan tools"
  sudo apt-get install -y \
    lm-sensors \
    fancontrol \
    irqbalance \
    btop \
    nvtop \
    s-tui \
    smartmontools

  msg "Enabling irqbalance service"
  sudo systemctl enable --now irqbalance || true
}

install_gaming_stack() {
  msg "Installing gaming-related packages (APT)"
  sudo apt-get install -y \
    mesa-utils \
    vulkan-tools \
    gamemode \
    mangohud \
    libxkbcommon-x11-0:i386 \
    libvulkan1:i386 \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386

  msg "Installing gaming applications (Flatpak)"
  flatpak install -y flathub \
    com.valvesoftware.Steam \
    com.heroicgameslauncher.hgl \
    net.davidotek.pupgui2 \
    net.lutris.Lutris || true
}

install_amd_tweaks() {
  local IS_AMD_GPU="$1"
  if [ "$IS_AMD_GPU" -ne 1 ]; then
    msg "AMD GPU not detected; skipping AMD tweaks."
    return 0
  fi

  msg "AMD GPU detected – installing safe AMD-related tools"
  # radeontop is AMD-specific
  if apt-cache show radeontop >/dev/null 2>&1; then
    sudo apt-get install -y radeontop
  fi

  # We already installed mesa-vulkan-drivers above in gaming stack,
  # but repeat here safely in case user skipped the gaming stack.
  sudo apt-get install -y \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    vulkan-tools \
    mesa-utils
}

install_refind_with_theme() {
  msg "Installing rEFInd boot manager"

  sudo apt-get install -y refind || {
    msg "rEFInd package installation failed – skipping rEFInd configuration."
    return 0
  }

  # rEFInd config / theme only make sense on UEFI systems with /boot/efi mounted
  if [ ! -d /boot/efi ] || ! mount | grep -q " /boot/efi "; then
    msg "/boot/efi is not a mounted ESP – skipping rEFInd theming."
    return 0
  fi

  local REFIND_DIR="/boot/efi/EFI/refind"
  sudo mkdir -p "$REFIND_DIR"

  # Theme directory (we assume your repo has refind/theme.conf + theme files if needed)
  local THEME_DIR="$REFIND_DIR/themes/benjios-bsxm1"
  sudo mkdir -p "$THEME_DIR"

  # Fetch theme.conf and refind.conf from repo if they exist there
  msg "Downloading rEFInd theme + config from BenjiOS repo (if available)"

  # theme.conf (controls icons/background/fonts)
  if curl -fsSL "$RAW_BASE/refind/theme.conf" >/dev/null 2>&1; then
    curl -fsSL "$RAW_BASE/refind/theme.conf" | sudo tee "$THEME_DIR/theme.conf" >/dev/null
  else
    # Fallback minimal theme.conf (safe default)
    sudo tee "$THEME_DIR/theme.conf" >/dev/null << 'EOF'
# Minimal theme placeholder – customize in BenjiOS repo at refind/theme.conf
icons_dir themes/benjios-bsxm1/icons
banner themes/benjios-bsxm1/bg_black.png
EOF
  fi

  # refind.conf (main config)
  if curl -fsSL "$RAW_BASE/refind/refind.conf" >/dev/null 2>&1; then
    curl -fsSL "$RAW_BASE/refind/refind.conf" | sudo tee "$REFIND_DIR/refind.conf" >/dev/null
  else
    # Safe fallback refind.conf (no aggressive hiding)
    sudo tee "$REFIND_DIR/refind.conf" >/dev/null << 'EOF'
timeout 10
use_nvram false
resolution max

# Mouse
enable_mouse
mouse_size 16
mouse_speed 6

# Clean tools row
showtools

# Example: avoid duplicate grub/fwupd entries
dont_scan_files grubx64.efi,fwupx64.efi

# Load BenjiOS theme (BsxM1-based)
include themes/benjios-bsxm1/theme.conf
EOF
  fi

  msg "rEFInd installed; theme + config written to $REFIND_DIR"
  msg "IMPORTANT: On next reboot, enroll the MOK if asked so rEFInd can load with Secure Boot."
}

apply_gnome_appearance() {
  msg "Setting GNOME dark mode, green accent, and performance power profile"

  # Dark mode preference
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
  gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' || true

  # Accent color: green (Ubuntu 25.x)
  gsettings set org.gnome.desktop.interface accent-color 'green' || true

  # Performance power profile
  if command -v powerprofilesctl >/dev/null 2>&1; then
    powerprofilesctl set performance || true
  fi
}

update_flatpaks_and_firmware() {
  msg "Updating Flatpak apps (if any)"
  flatpak update -y || true

  if command -v fwupdmgr >/dev/null 2>&1; then
    msg "Checking firmware updates via fwupd"
    sudo fwupdmgr refresh --force || true
    sudo fwupdmgr get-updates || true
    sudo fwupdmgr update -y || true
  fi
}

cleanup_system() {
  msg "Running APT autoremove/autoclean to tidy up"
  sudo apt-get autoremove -y || true
  sudo apt-get autoclean -y || true
}

write_post_install_notes() {
  local DESKTOP_DIR="$HOME/Desktop"
  mkdir -p "$DESKTOP_DIR"

  cat > "$DESKTOP_DIR/POST_INSTALL_BENJIOS.txt" << 'EOF'
BenjiOS – Post Install Notes (Ubuntu 25.10)
==========================================
This system was prepared by the BenjiOS Installer script.

What was done (if you selected the options in the installer):
------------------------------------------------------------
- System packages updated via: apt full-upgrade
- 32bit (i386) architecture enabled (for gaming / Proton / Wine)
- Flatpak + Flathub configured
- Base system tools installed (GNOME Tweaks, fwupd, GVFS, etc.)
- Optional stacks:
    * Core desktop tools (LibreOffice, Thunderbird, Remmina RDP, OpenVPN, VLC, Rhythmbox, GSConnect)
    * Monitoring stack (lm-sensors, fancontrol, btop, nvtop, s-tui, smartmontools, irqbalance)
    * Gaming stack (mesa-utils, vulkan-tools, gamemode, mangohud, Steam, Heroic, ProtonUp-Qt, Lutris)
    * AMD tweaks (safe AMD GPU extras: mesa-vulkan-drivers, etc., if AMD GPU present)
    * rEFInd + theme (if selected and /boot/efi is mounted)

After reboot – things you may want to check:
--------------------------------------------
1. Login session:
   - At the login screen, pick "Ubuntu (Wayland)" for best VRR / modern GNOME behavior.

2. Displays:
   - Settings → Displays:
     * Set your gaming monitor as "Primary"
     * Set resolution/refresh (e.g. 2560×1440 @ 100 Hz)
     * Enable VRR if offered by the UI

3. GNOME Extensions:
   - The script installed the "Extensions" app and "Extension Manager".
   - Use them to install:
       * ArcMenu (Windows-like start menu)
       * App Icons Taskbar or similar (for taskbar-like behavior)
   - You can customize them to your taste using their GUI settings.

4. Backups (if you install Timeshift / Déjà Dup / Vorta later):
   - Timeshift for system snapshots
   - Déjà Dup ("Backups" app) for home backups
   - Vorta + Borg for more advanced backups

5. rEFInd (if enabled in the installer):
   - On next reboot, if Secure Boot asks to enroll a key:
       * Choose "Enroll MOK"
       * Select the key
       * Reboot again
   - After that you should see rEFInd with the BenjiOS theme.

6. Updates:
   - APT:   sudo apt update && sudo apt full-upgrade
   - Flatpak: flatpak update
   - Firmware: sudo fwupdmgr get-updates && sudo fwupdmgr update

EOF
}

prompt_reboot() {
  if command -v zenity >/dev/null 2>&1; then
    if zenity --question --title="BenjiOS Installer" \
      --text="BenjiOS setup is complete.\n\nReboot now to apply all changes?" \
      --width=400; then
      msg "Rebooting..."
      systemctl reboot || sudo reboot
    else
      msg "No reboot requested. You can reboot later."
    fi
  else
    read -r -p "Reboot now to apply all changes? [y/N]: " REPLY
    case "${REPLY,,}" in
      y|yes)
        msg "Rebooting..."
        sudo reboot
        ;;
      *)
        msg "No reboot requested. You can reboot later."
        ;;
    esac
  fi
}

#-----------------------------
# MAIN
#-----------------------------

require_not_root
ensure_zenity

IS_AMD_GPU=$(detect_amd_gpu)

# License / info dialog
zenity --question \
  --title="BenjiOS Installer for Ubuntu 25.10" \
  --width=520 \
  --ok-label="I Agree" \
  --cancel-label="Cancel" \
  --text=$'This script will:\n\n- Update your Ubuntu 25.10 system\n- Install selected software stacks (gaming, tools, monitoring)\n- Optionally install rEFInd boot manager + theme\n- Apply some GNOME appearance tweaks\n\nIt uses official Ubuntu repos + Flathub.\n\nBy continuing, you agree that you are responsible for your system,\nespecially when dual-booting or modifying boot loaders.\n\nProceed?' \
  || exit 1

# Zenity checklist for options
AMD_DESC="AMD GPU tweaks (safe extras)"
if [ "$IS_AMD_GPU" -eq 0 ]; then
  AMD_DESC="$AMD_DESC – AMD GPU NOT detected (this option will do nothing)."
fi

SELECTIONS=$(zenity --list \
  --title="BenjiOS – Choose what to install" \
  --width=650 --height=380 \
  --text="Select the components you want to install.\n\nYou can re-run the script later with different choices." \
  --checklist \
  --column="Select" --column="ID" --column="Description" \
  TRUE  "core"     "Core desktop tools (Office, Mail, RDP, VPN, media, GSConnect)" \
  TRUE  "monitor"  "Monitoring stack (sensors, btop, nvtop, s-tui, smartmontools)" \
  TRUE  "gaming"   "Gaming stack (Steam, Heroic, Lutris, ProtonUp-Qt, Gamemode, MangoHud)" \
  TRUE  "amd"      "$AMD_DESC" \
  FALSE "refind"   "Install rEFInd boot manager + BenjiOS theme (UEFI only)" \
  || true)

HAS_CORE=0
HAS_MONITOR=0
HAS_GAMING=0
HAS_AMD=0
HAS_REFIND=0

case "$SELECTIONS" in
  *core*)    HAS_CORE=1 ;;
esac
case "$SELECTIONS" in
  *monitor*) HAS_MONITOR=1 ;;
esac
case "$SELECTIONS" in
  *gaming*)  HAS_GAMING=1 ;;
esac
case "$SELECTIONS" in
  *amd*)     HAS_AMD=1 ;;
esac
case "$SELECTIONS" in
  *refind*)  HAS_REFIND=1 ;;
esac

msg "Selections:"
msg "  Core desktop stack:      $HAS_CORE"
msg "  Monitoring stack:        $HAS_MONITOR"
msg "  Gaming stack:            $HAS_GAMING"
msg "  AMD tweaks:              $HAS_AMD (AMD GPU detected: $IS_AMD_GPU)"
msg "  rEFInd + theme:          $HAS_REFIND"

# Actual work
preseed_ms_fonts_eula
update_and_upgrade
enable_i386
install_base_packages
setup_flatpak

if [ "$HAS_CORE" -eq 1 ]; then
  install_core_desktop_stack
fi

if [ "$HAS_MONITOR" -eq 1 ]; then
  install_monitoring_stack
fi

if [ "$HAS_GAMING" -eq 1 ]; then
  install_gaming_stack
fi

if [ "$HAS_AMD" -eq 1 ]; then
  install_amd_tweaks "$IS_AMD_GPU"
fi

if [ "$HAS_REFIND" -eq 1 ]; then
  install_refind_with_theme
fi

apply_gnome_appearance
update_flatpaks_and_firmware
cleanup_system
write_post_install_notes

msg "=========================================="
msg "  BenjiOS Installer – setup complete"
msg "=========================================="
msg "A summary / checklist was written to:"
msg "  $HOME/Desktop/POST_INSTALL_BENJIOS.txt"

prompt_reboot
