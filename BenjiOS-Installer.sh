#!/usr/bin/env bash
set -e

########################################
# BenjiOS Installer
# Target: Ubuntu 25.10+ (GNOME, Wayland)
########################################

RAW_BASE="https://raw.githubusercontent.com/AdminPanic/BenjiOS/main"
DESKTOP_DIR="$HOME/Desktop"

#--------------------------------------
# Basic sanity
#--------------------------------------

if [ "$EUID" -eq 0 ]; then
  echo "Please do NOT run this script as root. Run it as your normal user."
  exit 1
fi

# Auto-install zenity if missing (first sudo will ask in terminal)
if ! command -v zenity >/dev/null 2>&1; then
  echo "[BenjiOS] zenity not found – installing it now..."
  sudo apt update
  sudo DEBIAN_FRONTEND=noninteractive apt install -y zenity
fi

ZENITY_W=640
ZENITY_H=480

mkdir -p "$DESKTOP_DIR"

# Make all apt/dpkg non-interactive by default
export DEBIAN_FRONTEND=noninteractive

#--------------------------------------
# License dialog via zenity --text-info
#--------------------------------------

LICENSE_FILE="$(mktemp)"
cat > "$LICENSE_FILE" << 'EOF'
BenjiOS Installer – License & EULA summary

This script will:
  • Install packages from Ubuntu repositories
  • Install applications from Flathub via Flatpak
  • Install Microsoft core fonts via ubuntu-restricted-extras
    (EULA accepted non-interactively via debconf preseed)
  • Optionally install rEFInd boot manager and configure a theme

By continuing, you agree to:
  • The Ubuntu / Canonical license terms
  • The Flathub / individual app license terms
  • The Microsoft core fonts EULA (if ubuntu-restricted-extras is installed)

No warranty. Use at your own risk.
EOF

zenity --text-info \
  --title="BenjiOS Installer – License" \
  --width="$ZENITY_W" --height="$ZENITY_H" \
  --filename="$LICENSE_FILE" \
  --checkbox="I have read and agree to these terms."

if [ $? -ne 0 ]; then
  zenity --info --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="Installation cancelled."
  rm -f "$LICENSE_FILE"
  exit 0
fi
rm -f "$LICENSE_FILE"

#--------------------------------------
# Sudo via zenity (cached password)
#--------------------------------------

SUDO_PASS="$(zenity --password --title='BenjiOS Installer – sudo access' \
  --width="$ZENITY_W" --height=200)"

if [ -z "$SUDO_PASS" ]; then
  zenity --error --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="No password entered. Exiting."
  exit 1
fi

run_sudo() {
  # Always enforce non-interactive apt/dpkg
  echo "$SUDO_PASS" | sudo -S DEBIAN_FRONTEND=noninteractive "$@"
}

if ! echo "$SUDO_PASS" | sudo -S -v >/dev/null 2>&1; then
  zenity --error --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="Incorrect sudo password. Exiting."
  exit 1
fi

#--------------------------------------
# Detect AMD GPU
#--------------------------------------

AMD_GPU_DETECTED=false
if lspci | grep -E "VGA|3D" | grep -qi "AMD"; then
  AMD_GPU_DETECTED=true
fi
if $AMD_GPU_DETECTED; then
  AMD_DEFAULT="TRUE"
else
  AMD_DEFAULT="FALSE"
fi

#--------------------------------------
# Stack selection
#--------------------------------------

STACK_SELECTION=$(zenity --list \
  --title="BenjiOS Installer – Component Selection" \
  --width="$ZENITY_W" --height="$ZENITY_H" \
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
  zenity --info --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="No optional stacks selected. Core stack will still be installed."
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

UPDATES_DAYS=""
if $AUTO_UPDATES_SELECTED; then
  UPD_FREQ=$(zenity --list \
    --title="BenjiOS – Auto Updates" \
    --width="$ZENITY_W" --height="$ZENITY_H" \
    --text="How often should automatic APT updates run?" \
    --radiolist \
    --column="Use" --column="ID" --column="Description" \
    TRUE  "daily"   "Install updates every day" \
    FALSE "weekly"  "Install updates once per week" \
  ) || true

  case "$UPD_FREQ" in
    daily)  UPDATES_DAYS="1" ;;
    weekly) UPDATES_DAYS="7" ;;
    *)      UPDATES_DAYS="1" ;;   # default: daily
  esac
fi

INSTALL_REFIND=false
if has_stack "refind"; then
  INSTALL_REFIND=true
fi

#--------------------------------------
# Step 1 – apt update + full-upgrade + i386
#--------------------------------------

zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=200 \
  --text="Step 1: Updating system and enabling 32-bit architecture.\n\nYou can watch progress in the terminal."

echo "==> Step 1: apt update + full-upgrade"
run_sudo apt update
run_sudo apt full-upgrade -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confnew

echo "==> Enabling i386 multiarch"
run_sudo dpkg --add-architecture i386 || true
run_sudo apt update

echo "==> Installing debconf-utils and pre-seeding MS core fonts EULA"
run_sudo apt install -y debconf-utils
echo "$SUDO_PASS" | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | debconf-set-selections"
echo "$SUDO_PASS" | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note' | debconf-set-selections"

#--------------------------------------
# Package aggregation
#--------------------------------------

APT_PKGS=()
add_apt() { APT_PKGS+=("$@"); }

FLATPAK_PKGS=()
add_flatpak() { FLATPAK_PKGS+=("$@"); }

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

# Management / Remote stack
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

# AMD tweaks (only if AMD GPU present)
if has_stack "amd_tweaks" && $AMD_GPU_DETECTED; then
  add_apt \
    radeontop \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    vulkan-tools \
    mesa-utils
fi

# rEFInd
if $INSTALL_REFIND; then
  add_apt \
    refind \
    shim-signed \
    mokutil
fi

#--------------------------------------
# Install APT packages (non-interactive)
#--------------------------------------

if [ "${#APT_PKGS[@]}" -gt 0 ]; then
  zenity --info --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="Step 2: Installing APT packages…\n\nCheck the terminal for detailed progress."

  declare -A SEEN
  UNIQUE_PKGS=()
  for pkg in "${APT_PKGS[@]}"; do
    if [ -z "${SEEN[$pkg]+x}" ]; then
      SEEN["$pkg"]=1
      UNIQUE_PKGS+=("$pkg")
    fi
  done

  echo "==> Installing APT packages: ${UNIQUE_PKGS[*]}"
  echo "$SUDO_PASS" | sudo -S DEBIAN_FRONTEND=noninteractive apt install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confnew \
    "${UNIQUE_PKGS[@]}"
fi

#--------------------------------------
# Flatpak setup + apps
#--------------------------------------

zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=200 \
  --text="Step 3: Configuring Flatpak and installing apps…"

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

if [ "${#FLATPAK_PKGS[@]}" -gt 0 ]; then
  flatpak install -y flathub "${FLATPAK_PKGS[@]}" || true
fi

#--------------------------------------
# Stack-specific config
#--------------------------------------

# Gaming
if has_stack "gaming"; then
  echo "$SUDO_PASS" | sudo -S systemctl enable --now gamemoded >/dev/null 2>&1 || true
fi

# Monitoring
if has_stack "monitoring"; then
  echo "$SUDO_PASS" | sudo -S systemctl enable --now irqbalance >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S sensors-detect --auto >/dev/null 2>&1 || true
fi

# Management / Remote (SSH, xRDP, UFW, WOL)
if has_stack "management"; then
  echo "$SUDO_PASS" | sudo -S systemctl enable --now ssh >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S systemctl enable --now xrdp >/dev/null 2>&1 || true

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

  # TLP: keep WOL
  echo "$SUDO_PASS" | sudo -S bash -c 'if [ -f /etc/default/tlp ]; then
    if grep -q "^WOL_DISABLE=" /etc/default/tlp; then
      sed -i "s/^WOL_DISABLE=.*/WOL_DISABLE=N/" /etc/default/tlp
    else
      echo "WOL_DISABLE=N" >> /etc/default/tlp
    fi
  fi' >/dev/null 2>&1 || true

  # ethtool WoL
  if command -v ethtool >/dev/null 2>&1; then
    for iface_path in /sys/class/net/*; do
      iface="$(basename "$iface_path")"
      case "$iface" in
        lo*|vbox*|docker*|virbr*|veth*|br-*|vmnet*) continue ;;
      esac
      echo "$SUDO_PASS" | sudo -S ethtool -s "$iface" wol g >/dev/null 2>&1 || true
    done
  fi

  # nmcli WoL
  if command -v nmcli >/dev/null 2>&1; then
    while IFS=: read -r uuid type; do
      [ "$type" = "802-3-ethernet" ] || continue
      echo "$SUDO_PASS" | sudo -S nmcli connection modify "$uuid" 802-3-ethernet.wake-on-lan magic >/dev/null 2>&1 || true
    done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null || true)
  fi
fi

# Auto updates
if $AUTO_UPDATES_SELECTED && [ -n "$UPDATES_DAYS" ]; then
  echo "$SUDO_PASS" | sudo -S DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

  echo "$SUDO_PASS" | sudo -S bash -c "cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists \"$UPDATES_DAYS\";
APT::Periodic::Download-Upgradeable-Packages \"$UPDATES_DAYS\";
APT::Periodic::Unattended-Upgrade \"$UPDATES_DAYS\";
EOF" >/dev/null 2>&1 || true
fi

#--------------------------------------
# rEFInd install + theme from upstream
#--------------------------------------

if $INSTALL_REFIND; then
  zenity --info --title="BenjiOS Installer – rEFInd" \
    --width="$ZENITY_W" --height=200 \
    --text="Installing rEFInd and applying the BsxM1 theme…"

  echo "$SUDO_PASS" | sudo -S refind-install >/dev/null 2>&1 || true

  ESP="/boot/efi"
  REFIND_DIR="$ESP/EFI/refind"
  THEME_DIR="$REFIND_DIR/themes/refind-bsxm1-theme"

  if [ -d "$ESP/EFI" ]; then
    echo "$SUDO_PASS" | sudo -S rm -rf "$THEME_DIR" >/dev/null 2>&1 || true
    echo "$SUDO_PASS" | sudo -S mkdir -p "$THEME_DIR" >/dev/null 2>&1 || true
    echo "$SUDO_PASS" | sudo -S git clone https://github.com/AlexFullmoon/refind-bsxm1-theme.git "$THEME_DIR" >/dev/null 2>&1 || true

    TMP_REFIND_CONF="/tmp/benjios-refind.conf"
    if curl -fsSL "$RAW_BASE/refind/refind.conf" -o "$TMP_REFIND_CONF"; then
      echo "$SUDO_PASS" | sudo -S cp "$TMP_REFIND_CONF" "$REFIND_DIR/refind.conf" >/dev/null 2>&1 || true
    fi
  fi
fi

#--------------------------------------
# ArcMenu + App Icons Taskbar: dconf + icon
#--------------------------------------

zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=200 \
  --text="Applying ArcMenu and App Icons Taskbar configuration (for when you install the extensions)…"

ICON_TARGET_DIR="$HOME/.local/share/icons/hicolor/48x48/apps"
mkdir -p "$ICON_TARGET_DIR"

if curl -fsSL "$RAW_BASE/assets/Taskbar.png" -o "$ICON_TARGET_DIR/Menu_Icon.png"; then
  echo "[BenjiOS] Installed custom ArcMenu icon: $ICON_TARGET_DIR/Menu_Icon.png"
fi

ARC_CONF_TMP="/tmp/arcmenu.conf"
if curl -fsSL "$RAW_BASE/configs/arcmenu.conf" -o "$ARC_CONF_TMP"; then
  if [ -s "$ARC_CONF_TMP" ]; then
    dconf load /org/gnome/shell/extensions/arcmenu/ < "$ARC_CONF_TMP" || true
  fi
fi

AZTASKBAR_CONF_TMP="/tmp/app-icons-taskbar.conf"
if curl -fsSL "$RAW_BASE/configs/app-icons-taskbar.conf" -o "$AZTASKBAR_CONF_TMP"; then
  if [ -s "$AZTASKBAR_CONF_TMP" ]; then
    dconf load /org/gnome/shell/extensions/aztaskbar/ < "$AZTASKBAR_CONF_TMP" || true
  fi
fi

#--------------------------------------
# GNOME appearance & performance profile
#--------------------------------------

gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' || true
gsettings set org.gnome.desktop.interface accent-color 'green' || true

if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set performance || true
fi

#--------------------------------------
# Extra updates, firmware, cleanup
#--------------------------------------

zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=200 \
  --text="Final step: updating Flatpak apps, firmware, and cleaning up…"

flatpak update -y || true
flatpak remove --unused -y || true

if command -v fwupdmgr >/dev/null 2>&1; then
  echo "$SUDO_PASS" | sudo -S fwupdmgr refresh --force >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S fwupdmgr get-updates      >/dev/null 2>&1 || true
  echo "$SUDO_PASS" | sudo -S fwupdmgr update -y        >/dev/null 2>&1 || true
fi

if command -v snap >/dev/null 2>&1; then
  echo "$SUDO_PASS" | sudo -S snap refresh >/dev/null 2>&1 || true
fi

echo "$SUDO_PASS" | sudo -S apt autoremove --purge -y >/dev/null 2>&1 || true
echo "$SUDO_PASS" | sudo -S apt clean >/dev/null 2>&1 || true

#--------------------------------------
# Post-install guide to Desktop
#--------------------------------------

POST_DOC_NAME="BenjiOS-PostInstall.odt"
if curl -fsSL "$RAW_BASE/docs/$POST_DOC_NAME" -o "$DESKTOP_DIR/$POST_DOC_NAME"; then
  echo "[BenjiOS] Post-install guide saved as: $DESKTOP_DIR/$POST_DOC_NAME"
fi

#--------------------------------------
# Final summary + reboot prompt
#--------------------------------------

zenity --question \
  --title="BenjiOS Installer – Finished" \
  --width="$ZENITY_W" --height="$ZENITY_H" \
  --text="BenjiOS installation and configuration is complete.\n\nA reboot is recommended to apply all changes.\n\nReboot now?" \
  --ok-label="Reboot now" \
  --cancel-label="Later"

if [ $? -eq 0 ]; then
  echo "$SUDO_PASS" | sudo -S reboot
else
  zenity --info --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="You can reboot later.\n\nCheck your Desktop for BenjiOS-PostInstall.odt for the next steps."
fi

exit 0
