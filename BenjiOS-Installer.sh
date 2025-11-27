#!/bin/bash
# BenjiOS-Installer.sh - Ubuntu 25.10 post-install configuration script

set -o errexit
set -o pipefail

# Use noninteractive mode for apt to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Raw GitHub base for this repo
RAW_BASE="https://raw.githubusercontent.com/AdminPanic/BenjiOS/main"

########################################
# Ensure Zenity is available
########################################
if ! command -v zenity >/dev/null 2>&1; then
  echo "Zenity not found. Installing zenity..."
  sudo apt-get update -y
  sudo apt-get install -y zenity
fi

########################################
# License prompt
########################################
zenity --question --width=400 --title="License Agreement" \
  --text="This script will install various software.\n\nBy proceeding, you acknowledge that you agree to the licenses of all included software (Ubuntu, rEFInd, Steam, Heroic, Lutris, etc.).\n\nDo you wish to continue?"

if [[ $? -ne 0 ]]; then
  zenity --info --width=300 --text="Installation canceled. No changes were made."
  exit 0
fi

########################################
# Zenity options
########################################

# rEFInd
INSTALL_REFIND=$(zenity --list --radiolist --width=420 --height=260 \
  --title="rEFInd Installation" \
  --text="Install rEFInd UEFI Boot Manager?" \
  --column="Select" --column="Option" \
  TRUE  "Yes, install rEFInd boot manager" \
  FALSE "No, skip rEFInd")

REFIND_MODE=""
if [[ "$INSTALL_REFIND" == "Yes, install rEFInd boot manager" ]]; then
  REFIND_MODE=$(zenity --list --radiolist --width=420 --height=260 \
    --title="rEFInd Configuration" \
    --text="Select your boot configuration for rEFInd:" \
    --column="Select" --column="Boot Setup" \
    TRUE  "Single boot (Ubuntu only)" \
    FALSE "Dual boot (Ubuntu + Windows)" \
    FALSE "Show all entries (no filtering)")
fi

# Monitoring
INSTALL_MON=$(
  zenity --question --width=400 --title="Monitoring Tools" \
    --text="Install monitoring tools (htop, btop, sensors, psensor, etc.)?" \
    && echo "Yes" || echo "No"
)

# Gaming
INSTALL_GAMING=$(
  zenity --question --width=400 --title="Gaming Stack" \
    --text="Install Gaming Stack (Steam, Lutris, Heroic, ProtonUp-Qt, MangoHud, GameMode, etc.)?" \
    && echo "Yes" || echo "No"
)

# Additional Tools
INSTALL_TOOLS=$(
  zenity --question --width=400 --title="Additional Tools" \
    --text="Install additional tools (digiKam, KeePassXC, VLC, Rhythmbox, OpenVPN, Thunderbird)?" \
    && echo "Yes" || echo "No"
)

# Remote management
INSTALL_REMOTE=$(
  zenity --question --width=400 --title="Remote Management" \
    --text="Enable Remote Management features (SSH, firewall rules, RDP, Wake-on-LAN)?" \
    && echo "Yes" || echo "No"
)

########################################
# Common base setup
########################################
echo "==> Updating APT and installing base dependencies..."
sudo apt-get update -y

# Ensure some basic tools we rely on exist
sudo apt-get install -y \
  wget curl unzip dconf-cli software-properties-common

########################################
# 1. rEFInd installation and theming
########################################
if [[ "$INSTALL_REFIND" == "Yes, install rEFInd boot manager" ]]; then
  echo "==> Installing rEFInd (non-interactive)..."

  # Preseed debconf so we don't get the ncurses ESP question
  # Template name: refind/install_to_esp  (boolean)
  echo "refind refind/install_to_esp boolean true" | sudo debconf-set-selections

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y refind

  # Make sure EFI system partition is mounted
  if ! mountpoint -q /boot/efi; then
    EFI_PART=$(sudo blkid -t PARTLABEL="EFI System" -o device | head -n1 || true)
    if [[ -n "$EFI_PART" ]]; then
      echo "==> Mounting EFI System Partition ($EFI_PART) on /boot/efi..."
      sudo mount "$EFI_PART" /boot/efi
    else
      echo "WARNING: Could not detect EFI System Partition. Skipping rEFInd theme setup."
    fi
  fi

  if mountpoint -q /boot/efi; then
    REFIND_DIR="/boot/efi/EFI/refind"
    THEME_DIR="$REFIND_DIR/themes/bsmx"

    echo "==> Applying custom rEFInd configuration and BsxM1 theme..."
    sudo mkdir -p "$THEME_DIR"

    # Pull refind.conf and theme.conf from repo
    sudo wget -qO "$REFIND_DIR/refind.conf" \
      "$RAW_BASE/refind/refind.conf"

    sudo wget -qO "$THEME_DIR/theme.conf" \
      "$RAW_BASE/refind/theme.conf"

    # Theme assets (zipped)
    sudo wget -qO /tmp/bsmx_theme.zip \
      "$RAW_BASE/refind/BSxM1_theme.zip"

    sudo unzip -o /tmp/bsmx_theme.zip -d "$THEME_DIR/"
    sudo rm -f /tmp/bsmx_theme.zip

    # Adjust timeouts / visibility according to REFIND_MODE
    if [[ "$REFIND_MODE" == "Single boot (Ubuntu only)" ]]; then
      # Faster timeout, hide obvious non-Linux loaders if your base refind.conf has dont_scan_files
      sudo sed -i 's/^timeout .*/timeout 5/' "$REFIND_DIR/refind.conf"
      # Example: hide fwupd + extra grub entries if present
      sudo sed -i 's/^dont_scan_files.*/dont_scan_files grubx64.efi,fwupx64.efi/' "$REFIND_DIR/refind.conf" || true

    elif [[ "$REFIND_MODE" == "Dual boot (Ubuntu + Windows)" ]]; then
      # Slightly longer timeout for OS choice
      sudo sed -i 's/^timeout .*/timeout 10/' "$REFIND_DIR/refind.conf"
      # Keep dont_scan_files as defined in your shipped config

    elif [[ "$REFIND_MODE" == "Show all entries (no filtering)" ]]; then
      sudo sed -i 's/^timeout .*/timeout 15/' "$REFIND_DIR/refind.conf"
      # Uncomment scanfor if present and include firmware
      sudo sed -i 's/^#\?scanfor.*/scanfor internal,external,optical,manual,firmware/' "$REFIND_DIR/refind.conf" || true
      # Comment out dont_scan_files if present
      sudo sed -i 's/^dont_scan_files/#dont_scan_files/' "$REFIND_DIR/refind.conf" || true
    fi
  fi
fi

########################################
# 2. Monitoring stack
########################################
if [[ "$INSTALL_MON" == "Yes" ]]; then
  echo "==> Installing monitoring tools..."
  sudo apt-get install -y \
    htop glances btop lm-sensors psensor

  # Non-interactive sensors-detect (safe defaults)
  echo "==> Running sensors-detect (auto-confirming defaults)..."
  sudo yes | sudo sensors-detect || true
fi

########################################
# 3. Gaming stack
########################################
if [[ "$INSTALL_GAMING" == "Yes" ]]; then
  echo "==> Installing gaming stack..."

  # 32-bit libs for Wine/Proton
  sudo dpkg --add-architecture i386
  sudo apt-get update -y

  # Core gaming bits (from Ubuntu / Lutris PPA)
  sudo apt-get install -y \
    steam \
    gamemode \
    mangohud

  # Lutris PPA for fresher Lutris
  sudo add-apt-repository -y ppa:lutris-team/lutris
  sudo apt-get update -y
  sudo apt-get install -y lutris

  # Flatpak + Flathub (for Heroic + ProtonUp-Qt)
  if ! command -v flatpak >/dev/null 2>&1; then
    sudo apt-get install -y flatpak gnome-software-plugin-flatpak
  fi

  sudo flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo

  # Heroic & ProtonUp-Qt
  flatpak install -y flathub com.heroicgameslauncher.hgl
  flatpak install -y flathub net.davidotek.pupgui2

  # Ensure GameMode user service is active
  systemctl --user enable gamemoded --now || true
fi

########################################
# 4. Additional desktop tools
########################################
if [[ "$INSTALL_TOOLS" == "Yes" ]]; then
  echo "==> Installing additional desktop tools..."
  sudo apt-get install -y \
    digikam \
    keepassxc \
    vlc \
    rhythmbox \
    openvpn \
    thunderbird \
    network-manager-openvpn \
    network-manager-openvpn-gnome
fi

########################################
# 5. Remote management
########################################
if [[ "$INSTALL_REMOTE" == "Yes" ]]; then
  echo "==> Enabling remote management (SSH, RDP, WOL)..."

  # SSH server
  sudo apt-get install -y openssh-server
  sudo systemctl enable ssh --now

  # UFW firewall rules for SSH + RDP
  if sudo ufw status | grep -q "Status: inactive"; then
    sudo ufw allow 22/tcp
    sudo ufw allow 3389/tcp
    sudo ufw --force enable
  else
    sudo ufw allow 22/tcp
    sudo ufw allow 3389/tcp
  fi

  # xrdp for RDP sessions
  sudo apt-get install -y xrdp
  sudo systemctl enable xrdp --now
  sudo adduser xrdp ssl-cert || true

  # Wake-on-LAN
  sudo apt-get install -y ethtool

  # Enable WOL now on all non-loopback, non-virtual interfaces
  for IFACE in $(ls /sys/class/net | grep -Ev '^(lo|vbox|docker|virbr)'); do
    sudo ethtool -s "$IFACE" wol g || true
  done

  # Persist WOL via NetworkManager
  nmcli -t -f UUID,TYPE connection show | awk -F: '$2=="ethernet"{print $1}' | while read -r UUID; do
    nmcli connection modify "$UUID" 802-3-ethernet.wake-on-lan magic || true
  done

  # Prevent NETDOWN so NIC stays powered for WOL
  if [[ -f /etc/default/halt ]]; then
    sudo sed -i 's/^NETDOWN=.*/NETDOWN=no/' /etc/default/halt || true
  else
    echo "NETDOWN=no" | sudo tee /etc/default/halt >/dev/null
  fi

  # If TLP exists, ensure it doesn't kill WOL
  if [[ -f /etc/default/tlp ]]; then
    sudo sed -i 's/^WOL_DISABLE=.*/WOL_DISABLE=N/' /etc/default/tlp || true
  fi
fi

########################################
# 6. GNOME Shell – ArcMenu + Taskbar config
########################################
echo "==> Configuring GNOME Shell UI (ArcMenu + Taskbar layout)..."

# Dependencies for ArcMenu (gmenu)
sudo apt-get install -y gir1.2-gmenu-3.0

# Try to install ArcMenu & Dash-to-Panel from Ubuntu repos (if available)
sudo apt-get install -y \
  gnome-shell-extension-arc-menu \
  gnome-shell-extension-dash-to-panel \
  || true

# Download and place the BenjiOS taskbar icon
ICON_DIR="$HOME/.local/share/icons/BenjiOS"
mkdir -p "$ICON_DIR"
wget -qO "$ICON_DIR/taskbar.png" "$RAW_BASE/assets/taskbar.png"

# Load ArcMenu settings from repo
if command -v dconf >/dev/null 2>&1; then
  wget -qO- "$RAW_BASE/configs/arcmenu.conf" \
    | dconf load /org/gnome/shell/extensions/arc-menu/ || true

  # Load Dash-to-Panel / App Icons Taskbar layout into that schema path
  wget -qO- "$RAW_BASE/configs/app-icons-taskbar.conf" \
    | dconf load /org/gnome/shell/extensions/dash-to-panel/ || true
fi

########################################
# 7. Clean-up
########################################
echo "==> Cleaning up..."
sudo apt-get autoremove -y
sudo apt-get autoclean -y
rm -f /tmp/bsmx_theme.zip 2>/dev/null || true

########################################
# Final summary + reboot prompt
########################################
SUMMARY=$(
  cat <<EOF
BenjiOS Installer – setup complete.

What was done:
  • Updated APT and installed base tools (wget, unzip, dconf-cli)
  • (Optional) Installed and themed rEFInd boot manager
  • (Optional) Installed monitoring tools (htop, btop, sensors, psensor)
  • (Optional) Installed gaming stack (Steam, Lutris, Heroic, ProtonUp-Qt, GameMode, MangoHud)
  • (Optional) Installed extra desktop tools (digiKam, KeePassXC, VLC, Rhythmbox, OpenVPN, Thunderbird)
  • (Optional) Enabled remote management (SSH, firewall, xrdp, Wake-on-LAN)
  • Configured GNOME Shell with ArcMenu + Taskbar layout and BenjiOS icon

A reboot is strongly recommended to fully apply all changes.
EOF
)

zenity --info --width=450 --title="BenjiOS Installer" --text="$SUMMARY"

if zenity --question --width=350 --title="BenjiOS Installer" \
   --text="Reboot now to apply all changes?"; then
  sudo reboot
fi

exit 0
