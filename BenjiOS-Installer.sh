#!/usr/bin/env bash
set -e

########################################
# BenjiOS Installer
# Target: Ubuntu 25.10+ (GNOME, Wayland)
########################################

RAW_BASE="https://raw.githubusercontent.com/AdminPanic/BenjiOS/main"
DESKTOP_DIR="$HOME/Desktop"

#-----------------------------
# Basic sanity checks
#-----------------------------

if [ "$EUID" -eq 0 ]; then
  echo "Please do NOT run this script as root. Run it as your normal user."
  exit 1
fi

if ! command -v zenity >/dev/null 2>&1; then
  echo "Zenity is not installed. Installing it now (this may ask for your sudo password in the terminal once)…"
  sudo apt update && sudo apt install -y zenity
fi


mkdir -p "$DESKTOP_DIR"

export DEBIAN_FRONTEND=noninteractive

#-----------------------------
# License / EULA info
#-----------------------------

LICENSE_TEXT=$'BenjiOS Installer – License & EULA summary\n\n\
This script will:\n\
  • Install packages from Ubuntu repositories\n\
  • Install applications from Flathub via Flatpak\n\
  • Install Microsoft core fonts via ubuntu-restricted-extras\n\
    (EULA accepted non-interactively via debconf preseed)\n\
  • Optionally install rEFInd boot manager and configure a theme\n\n\
By continuing, you agree to:\n\
  • The Ubuntu / Canonical license terms\n\
  • The Flathub / individual app license terms\n\
  • The Microsoft core fonts EULA (if ubuntu-restricted-extras is installed)\n\n\
No warranty. Use at your own risk.\n\n\
Do you want to continue?'

zenity --question \
  --title="BenjiOS Installer – License" \
  --width=500 \
  --text="$LICENSE_TEXT" \
  --ok-label="I Agree" \
  --cancel-label="Cancel"

if [ $? -ne 0 ]; then
  zenity --info --title="BenjiOS Installer" --text="Installation cancelled."
  exit 0
fi

#-----------------------------
# Sudo via Zenity
#-----------------------------

SUDO_PASS="$(zenity --password --title='BenjiOS Installer – sudo access')"

if [ -z "$SUDO_PASS" ]; then
  zenity --error --title="BenjiOS Installer" --text="No password entered. Exiting."
  exit 1
fi

run_sudo() {
  echo "$SUDO_PASS" | sudo -S "$@" >/dev/null
}

# Test sudo
if ! echo "$SUDO_PASS" | sudo -S -v >/dev/null 2>&1; then
  zenity --error --title="BenjiOS Installer" --text="Incorrect sudo password. Exiting."
  exit 1
fi

#-----------------------------
# Detect AMD GPU (for AMD tweaks)
#-----------------------------

AMD_GPU_DETECTED=false
if lspci | grep -E "VGA|3D" | grep -qi "AMD"; then
  AMD_GPU_DETECTED=true
fi

if $AMD_GPU_DETECTED; then
  AMD_DEFAULT="TRUE"
else
  AMD_DEFAULT="FALSE"
fi

#-----------------------------
# Stack selection (Zenity checklist)
#-----------------------------

STACK_SELECTION=$(zenity --list \
  --title="BenjiOS Installer – Component Selection" \
  --width=700 --height=400 \
  --text="Select which stacks to install.\n\nCore system tools are ALWAYS installed.\nYou can re-run this script later to add more stacks." \
  --checklist \
  --column="Install" --column="ID" --column="Description" \
  TRUE  "office"        "Office, mail, basic media, RDP client" \
  TRUE  "gaming"        "Gaming stack: Steam, Heroic, Lutris, Proton tools" \
  TRUE  "monitoring"    "Monitoring: sensors, btop, nvtop, psensor, etc." \
  TRUE  "backup_tools"  "Backup tools: Timeshift, Déjà Dup, Borg, Vorta" \
  TRUE  "management"    "Remote management: SSH server, xRDP, firewall, WoL" \
  TRUE  "auto_updates"  "Automatic APT updates (unattended-upgrades + cron-apt)" \
  "$AMD_DEFAULT" "amd_tweaks" "AMD GPU tweaks (Mesa/Vulkan extras – only if AMD GPU detected)" \
  FALSE "refind"        "rEFInd boot manager with BsxM1 theme (advanced multi-boot)" \
) || true

if [ -z "$STACK_SELECTION" ]; then
  zenity --info --title="BenjiOS Installer" --text="No optional stacks selected. Core stack will still be installed."
fi

has_stack() {
  case "$STACK_SELECTION" in
    *"$1"*) return 0 ;;
    *)      return 1 ;;
  esac
}

AUTO_UPDATES_SELECTED=false
if has_stack "auto_updates"; then
  AUTO_UPDATES_SELECTED=true
fi

# Auto updates – choose frequency, if selected
UPDATES_DAYS=""
if $AUTO_UPDATES_SELECTED; then
  UPD_FREQ=$(zenity --list \
    --title="BenjiOS – Auto Updates" \
    --width=400 --height=200 \
    --text="How often should automatic APT updates run?" \
    --radiolist \
    --column="Use" --column="ID" --column="Description" \
    TRUE  "daily"   "Install updates every day" \
    FALSE "weekly"  "Install updates once per week" \
  ) || true

  case "$UPD_FREQ" in
    "daily")  UPDATES_DAYS="1" ;;
    "weekly") UPDATES_DAYS="7" ;;
    *)
      # Default to daily if dialog cancelled
      UPDATES_DAYS="1"
      ;;
  esac
fi

INSTALL_REFIND=false
if has_stack "refind"; then
  INSTALL_REFIND=true
fi

#-----------------------------
# System update + multiarch
#-----------------------------

zenity --info --title="BenjiOS Installer" --text="Step 1: Updating system and enabling 32-bit architecture…"

run_sudo apt update -y >/dev/null
run_sudo dpkg --add-architecture i386 || true
run_sudo apt update -y >/dev/null
run_sudo apt full-upgrade -y >/dev/null

# Preseed Microsoft fonts EULA before ubuntu-restricted-extras
run_sudo apt install -y debconf-utils >/dev/null
echo "$SUDO_PASS" | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | debconf-set-selections" >/dev/null 2>&1 || true
echo "$SUDO_PASS" | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note' | debconf-set-selections" >/devnull 2>&1 || true

#-----------------------------
# Package aggregation
#-----------------------------

APT_PKGS=()
add_apt() {
  for pkg in "$@"; do
    APT_PKGS+=("$pkg")
  done
}

FLATPAK_PKGS=()
add_flatpak() {
  for pkg in "$@"; do
    FLATPAK_PKGS+=("$pkg")
  done
}

# Core stack (always)
add_apt \
  gnome-tweaks \
  gvfs-backends \
  nautilus-share \
  bluez-obexd \
  gnome-shell-extensions \
  gir1.2-gmenu-3.0 \
  gnome-menus \
  power-profiles-daemon \
  fwupd \
  debconf-utils \
  curl \
  dconf-cli \
  wget \
  unzip \
  software-properties-common \
  nano \
  git \
  gnome-shell-extension-gsconnect \
  gnome-software-plugin-flatpak \
  flatpak

add_flatpak \
  com.mattjakeman.ExtensionManager

# Office stack
if has_stack "office"; then
  add_apt \
    openvpn \
    libreoffice \
    thunderbird \
    network-manager-openvpn-gnome \
    vlc \
    rhythmbox \
    ubuntu-restricted-extras \
    remmina \
    remmina-plugin-rdp \
    remmina-plugin-secret

  add_flatpak \
    org.keepassxc.KeePassXC \
    com.github.qarmin.czkawka \
    org.kde.digikam
fi

# Gaming stack
if has_stack "gaming"; then
  add_apt \
    mesa-utils \
    vulkan-tools \
    gamemode \
    mangohud \
    lutris \
    libxkbcommon-x11-0:i386 \
    libvulkan1:i386 \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386

  add_flatpak \
    com.valvesoftware.Steam \
    com.heroicgameslauncher.hgl \
    net.davidotek.pupgui2 \
    net.lutris.Lutris
fi

# Monitoring stack
if has_stack "monitoring"; then
  add_apt \
    lm-sensors \
    fancontrol \
    irqbalance \
    btop \
    nvtop \
    s-tui \
    smartmontools \
    radeontop \
    htop \
    glances \
    psensor
fi

# Backup tools stack
if has_stack "backup_tools"; then
  add_apt \
    timeshift \
    deja-dup \
    borgbackup

  add_flatpak \
    com.borgbase.Vorta
fi

# Management (remote) stack
if has_stack "management"; then
  add_apt \
    openssh-server \
    ufw \
    xrdp \
    ethtool
fi

# Auto updates stack
if $AUTO_UPDATES_SELECTED; then
  add_apt \
    unattended-upgrades \
    cron-apt
fi

# AMD tweaks stack (only if AMD GPU)
if has_stack "amd_tweaks" && $AMD_GPU_DETECTED; then
  add_apt \
    radeontop \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    vulkan-tools \
    mesa-utils
fi

# rEFInd stack
if $INSTALL_REFIND; then
  add_apt \
    refind \
    shim-signed \
    mokutil
fi

#-----------------------------
# Deduplicate and install APT packages
#-----------------------------

if [ "${#APT_PKGS[@]}" -gt 0 ]; then
  zenity --info --title="BenjiOS Installer" --text="Step 2: Installing APT packages…"

  declare -A SEEN
  UNIQUE_PKGS=()
  for pkg in "${APT_PKGS[@]}"; do
    if [ -z "${SEEN[$pkg]+x}" ]; then
      SEEN["$pkg"]=1
      UNIQUE_PKGS+=("$pkg")
    fi
  done

  # Install in one shot
  echo "$SUDO_PASS" | sudo -S apt install -y "${UNIQUE_PKGS[@]}"
fi

#-----------------------------
# Flatpak setup + apps
#-----------------------------

zenity --info --title="BenjiOS Installer" --text="Step 3: Configuring Flatpak and installing apps…"

# Ensure Flathub remote
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

if [ "${#FLATPAK_PKGS[@]}" -gt 0 ]; then
  flatpak install -y flathub "${FLATPAK_PKGS[@]}" || true
fi

#-----------------------------
# Stack-specific config
#-----------------------------

# Gaming: enable gamemoded service
if has_stack "gaming"; then
  echo "$SUDO_PASS" | sudo -S systemctl enable --now gamemoded >/dev/null 2>&1 || true
fi

# Monitoring: enable irqbalance + sensors-detect --auto
if has_stack "monitoring"; then
  echo "$SUDO_PASS" | sudo -S systemctl enable --now irqbalance >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S sensors-detect --auto >/dev/null 2>&1 || true
fi

# Management: SSH, xRDP, UFW, WOL
if has_stack "management"; then
  # Enable services
  echo "$SUDO_PASS" | sudo -S systemctl enable --now ssh >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S systemctl enable --now xrdp >/dev/null 2>&1 || true

  # UFW rules
  echo "$SUDO_PASS" | sudo -S ufw allow 22/tcp >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S ufw allow 3389/tcp >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S ufw --force enable >/dev/null 2>&1 || true

  # NETDOWN=no
  echo "$SUDO_PASS" | sudo -S bash -c 'if [ -f /etc/default/halt ]; then
    if grep -q "^NETDOWN=" /etc/default/halt; then
      sed -i "s/^NETDOWN=.*/NETDOWN=no/" /etc/default/halt
    else
      echo "NETDOWN=no" >> /etc/default/halt
    fi
  else
    echo "NETDOWN=no" > /etc/default/halt
  fi' >/dev/null 2>&1 || true

  # TLP keep WOL if present
  echo "$SUDO_PASS" | sudo -S bash -c 'if [ -f /etc/default/tlp ]; then
    if grep -q "^WOL_DISABLE=" /etc/default/tlp; then
      sed -i "s/^WOL_DISABLE=.*/WOL_DISABLE=N/" /etc/default/tlp
    else
      echo "WOL_DISABLE=N" >> /etc/default/tlp
    fi
  fi' >/dev/null 2>&1 || true

  # Enable WoL via ethtool
  if command -v ethtool >/dev/null 2>&1; then
    for iface_path in /sys/class/net/*; do
      iface="$(basename "$iface_path")"
      case "$iface" in
        lo*|vbox*|docker*|virbr*|veth*|br-*|vmnet*)
          continue
          ;;
      esac
      echo "$SUDO_PASS" | sudo -S ethtool -s "$iface" wol g >/dev/null 2>&1 || true
    done
  fi

  # Enable WoL via NetworkManager (nmcli)
  if command -v nmcli >/dev/null 2>&1; then
    while IFS=: read -r uuid type; do
      [ "$type" = "802-3-ethernet" ] || continue
      echo "$SUDO_PASS" | sudo -S nmcli connection modify "$uuid" 802-3-ethernet.wake-on-lan magic >/dev/null 2>&1 || true
    done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null || true)
  fi
fi

# Auto updates: unattended-upgrades + cron-apt config
if $AUTO_UPDATES_SELECTED && [ -n "$UPDATES_DAYS" ]; then
  echo "$SUDO_PASS" | sudo -S dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

  echo "$SUDO_PASS" | sudo -S bash -c "cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists \"$UPDATES_DAYS\";
APT::Periodic::Download-Upgradeable-Packages \"$UPDATES_DAYS\";
APT::Periodic::Unattended-Upgrade \"$UPDATES_DAYS\";
EOF" >/dev/null 2>&1 || true
fi

#-----------------------------
# rEFInd installation + theme
#-----------------------------

if $INSTALL_REFIND; then
  zenity --info --title="BenjiOS Installer – rEFInd" --text="Installing rEFInd boot manager and theme…"

  # Install rEFInd (uses distribution defaults)
  echo "$SUDO_PASS" | sudo -S refind-install >/dev/null 2>&1 || true

  ESP="/boot/efi"
  REFIND_DIR="$ESP/EFI/refind"
  THEME_DIR="$REFIND_DIR/themes/refind-bsxm1-theme"

  if [ -d "$ESP/EFI" ]; then
    # Clone theme from upstream repo
    echo "$SUDO_PASS" | sudo -S rm -rf "$THEME_DIR" >/dev/null 2>&1 || true
    echo "$SUDO_PASS" | sudo -S mkdir -p "$THEME_DIR" >/dev/null 2>&1 || true
    echo "$SUDO_PASS" | sudo -S git clone https://github.com/AlexFullmoon/refind-bsxm1-theme.git "$THEME_DIR" >/dev/null 2>&1 || true

    # Use your refind.conf from repo if available
    TMP_REFIND_CONF="/tmp/benjios-refind.conf"
    if curl -fsSL "$RAW_BASE/refind/refind.conf" -o "$TMP_REFIND_CONF"; then
      echo "$SUDO_PASS" | sudo -S cp "$TMP_REFIND_CONF" "$REFIND_DIR/refind.conf" >/dev/null 2>&1 || true
    fi
  fi
fi

#-----------------------------
# ArcMenu + App Icons Taskbar dconf + icon
#-----------------------------

zenity --info --title="BenjiOS Installer" --text="Applying ArcMenu and App Icons Taskbar configuration (if installed later)…"

ICON_TARGET_DIR="$HOME/.local/share/icons/hicolor/48x48/apps"
mkdir -p "$ICON_TARGET_DIR"

if curl -fsSL "$RAW_BASE/assets/Taskbar.png" -o "$ICON_TARGET_DIR/Menu_Icon.png"; then
  echo "Installed custom ArcMenu icon as Menu_Icon.png"
fi

# ArcMenu dconf
ARC_CONF_TMP="/tmp/arcmenu.conf"
if curl -fsSL "$RAW_BASE/configs/arcmenu.conf" -o "$ARC_CONF_TMP"; then
  if [ -s "$ARC_CONF_TMP" ]; then
    dconf load /org/gnome/shell/extensions/arcmenu/ < "$ARC_CONF_TMP" || true
  fi
fi

# App Icons Taskbar dconf
AZTASKBAR_CONF_TMP="/tmp/app-icons-taskbar.conf"
if curl -fsSL "$RAW_BASE/configs/app-icons-taskbar.conf" -o "$AZTASKBAR_CONF_TMP"; then
  if [ -s "$AZTASKBAR_CONF_TMP" ]; then
    dconf load /org/gnome/shell/extensions/aztaskbar/ < "$AZTASKBAR_CONF_TMP" || true
  fi
fi

#-----------------------------
# GNOME appearance & power profile
#-----------------------------

gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' || true
gsettings set org.gnome.desktop.interface accent-color 'green' || true

if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set performance || true
fi

#-----------------------------
# Extra updates, firmware, cleanup
#-----------------------------

zenity --info --title="BenjiOS Installer" --text="Finalizing: updating Flatpak, firmware, and cleaning up…"

flatpak update -y || true
flatpak remove --unused -y || true

if command -v fwupdmgr >/dev/null 2>&1; then
  echo "$SUDO_PASS" | sudo -S fwupdmgr refresh --force >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S fwupdmgr get-updates >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S fwupdmgr update -y >/devnull 2>&1 || true
fi

if command -v snap >/dev/null 2>&1; then
  echo "$SUDO_PASS" | sudo -S snap refresh >/dev/null 2>&1 || true
fi

echo "$SUDO_PASS" | sudo -S apt autoremove --purge -y >/dev/null 2>&1 || true
echo "$SUDO_PASS" | sudo -S apt clean >/dev/null 2>&1 || true

#-----------------------------
# Post-install guide (ODT) from repo
#-----------------------------

POST_DOC_NAME="BenjiOS-PostInstall.odt"
if curl -fsSL "$RAW_BASE/docs/$POST_DOC_NAME" -o "$DESKTOP_DIR/$POST_DOC_NAME"; then
  echo "Post-install guide saved as $DESKTOP_DIR/$POST_DOC_NAME"
fi

#-----------------------------
# Final summary + reboot prompt
#-----------------------------

zenity --question \
  --title="BenjiOS Installer – Finished" \
  --width=400 \
  --text="BenjiOS installation and configuration is complete.\n\nA reboot is recommended to apply all changes.\n\nReboot now?" \
  --ok-label="Reboot now" \
  --cancel-label="Later"

if [ $? -eq 0 ]; then
  echo "$SUDO_PASS" | sudo -S reboot
else
  zenity --info --title="BenjiOS Installer" --text="You can reboot later. Check your Desktop for BenjiOS-PostInstall.odt for next steps."
fi

exit 0
