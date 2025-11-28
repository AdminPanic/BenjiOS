#!/usr/bin/env bash
set -e

########################################
# BenjiOS Installer v2
# Target: Ubuntu 25.10+ (GNOME, Wayland)
# Fixes:
#  - rEFInd theme reliability (BsxM1 theme, correct include, fallbacks)
#  - ArcMenu icon path mismatch (Taskbar.png -> BenjiOS-Menu.png)
#  - Proper /etc/apt/apt.conf.d/20auto-upgrades generation
#  - Safer powerprofilesctl usage (no noisy errors on unsupported systems)
########################################

RAW_BASE="https://raw.githubusercontent.com/AdminPanic/BenjiOS/main"
DESKTOP_DIR="$HOME/Desktop"

ZENITY_W=640
ZENITY_H=480

#--------------------------------------
# Basic sanity
#--------------------------------------
if [ "$EUID" -eq 0 ]; then
  echo "Please do NOT run this script as root."
  echo "Run it as your normal user."
  exit 1
fi

# Auto-install zenity if missing (first sudo will ask in terminal)
if ! command -v zenity >/dev/null 2>&1; then
  echo "[BenjiOS] zenity not found – installing it now (terminal sudo prompt)…"
  sudo apt update
  sudo DEBIAN_FRONTEND=noninteractive apt install -y zenity
fi

mkdir -p "$DESKTOP_DIR"
export DEBIAN_FRONTEND=noninteractive

#--------------------------------------
# License dialog
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
    --text="No password entered.\nExiting."
  exit 1
fi

run_sudo() {
  echo "$SUDO_PASS" | sudo -S "$@"
}

run_sudo_apt() {
  echo "$SUDO_PASS" | sudo -S DEBIAN_FRONTEND=noninteractive "$@"
}

if ! echo "$SUDO_PASS" | sudo -S -v >/dev/null 2>&1; then
  zenity --error --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="Incorrect sudo password.\nExiting."
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
STACK_SELECTION="$(zenity --list \
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
)" || true

if [ -z "$STACK_SELECTION" ]; then
  zenity --info --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="No optional stacks selected.\nCore stack will still be installed."
fi

has_stack() {
  case "$STACK_SELECTION" in
    *"$1"*) return 0 ;;
    *)      return 1 ;;
  esac
}

AUTO_UPDATES_SELECTED=false
UPDATES_DAYS=""
if has_stack "auto_updates"; then
  AUTO_UPDATES_SELECTED=true
  UPD_FREQ="$(zenity --list \
    --title="BenjiOS – Auto Updates" \
    --width="$ZENITY_W" --height="$ZENITY_H" \
    --text="How often should automatic APT updates run?" \
    --radiolist \
    --column="Use" --column="ID" --column="Description" \
    TRUE  "daily"  "Install updates every day" \
    FALSE "weekly" "Install updates once per week" \
  )" || true

  case "$UPD_FREQ" in
    weekly) UPDATES_DAYS="7" ;;
    *)      UPDATES_DAYS="1" ;;  # default: daily
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

run_sudo_apt apt update
run_sudo_apt apt full-upgrade -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confnew

# Enable multiarch
run_sudo dpkg --add-architecture i386 || true
run_sudo_apt apt update

# Preseed MS core fonts EULA
run_sudo_apt apt install -y debconf-utils
echo "$SUDO_PASS" | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | debconf-set-selections"
echo "$SUDO_PASS" | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note' | debconf-set-selections"

#--------------------------------------
# Package aggregation
#--------------------------------------
APT_PKGS=()
FLATPAK_PKGS=()

add_apt() {
  APT_PKGS+=("$@")
}

add_flatpak() {
  FLATPAK_PKGS+=("$@")
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

# rEFInd stack
if $INSTALL_REFIND; then
  add_apt \
    refind \
    shim-signed \
    mokutil \
    git
fi

#--------------------------------------
# Install APT packages
#--------------------------------------
if [ "${#APT_PKGS[@]}" -gt 0 ]; then
  zenity --info --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="Step 2: Installing APT packages…\n\nCheck the terminal for detailed progress."

  # Deduplicate
  declare -A SEEN
  UNIQUE_PKGS=()
  for pkg in "${APT_PKGS[@]}"; do
    if [ -z "${SEEN[$pkg]+x}" ]; then
      SEEN["$pkg"]=1
      UNIQUE_PKGS+=("$pkg")
    fi
  done

  echo "==> Installing APT packages: ${UNIQUE_PKGS[*]}"
  run_sudo_apt apt install -y \
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
# Helper: configure auto updates (20auto-upgrades)
#--------------------------------------
setup_auto_updates() {
  local days="$1"
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "$tmp_file" <<EOF
APT::Periodic::Update-Package-Lists "$days";
APT::Periodic::Download-Upgradeable-Packages "$days";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "$days";
EOF
  run_sudo cp "$tmp_file" /etc/apt/apt.conf.d/20auto-upgrades
  rm -f "$tmp_file"

  # Make sure unattended-upgrades service is active
  run_sudo systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
  run_sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true
}

if $AUTO_UPDATES_SELECTED && [ -n "$UPDATES_DAYS" ]; then
  setup_auto_updates "$UPDATES_DAYS"
fi

#--------------------------------------
# Helper: GNOME appearance + power profile
#--------------------------------------
configure_gnome_look_and_power() {
  if command -v gsettings >/dev/null 2>&1; then
    # Dark appearance
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' 2>/dev/null || true
    # Accent (may not exist on all versions)
    gsettings set org.gnome.desktop.interface accent-color 'green' 2>/dev/null || true
  fi

  # Power profile: performance (guarded to avoid noisy failures)
  if command -v powerprofilesctl >/dev/null 2>&1; then
    if powerprofilesctl list 2>/dev/null | grep -q "performance"; then
      powerprofilesctl set performance >/dev/null 2>&1 || true
    fi
  fi
}

configure_gnome_look_and_power

#--------------------------------------
# Helper: GNOME extensions config (ArcMenu + App Icons Taskbar)
#--------------------------------------
configure_gnome_extensions_layout() {
  if ! command -v dconf >/dev/null 2>&1; then
    return
  fi

  # ArcMenu dconf import
  local arcmenu_tmp
  arcmenu_tmp="$(mktemp)"
  if curl -fsSL "$RAW_BASE/configs/arcmenu.conf" -o "$arcmenu_tmp"; then
    dconf load /org/gnome/shell/extensions/arcmenu/ < "$arcmenu_tmp" 2>/dev/null || true
  fi
  rm -f "$arcmenu_tmp"

  # App Icons Taskbar dconf import
  local taskbar_tmp
  taskbar_tmp="$(mktemp)"
  if curl -fsSL "$RAW_BASE/configs/app-icons-taskbar.conf" -o "$taskbar_tmp"; then
    dconf load /org/gnome/shell/extensions/aztaskbar/ < "$taskbar_tmp" 2>/dev/null || true
  fi
  rm -f "$taskbar_tmp"

  # Fix ArcMenu icon mismatch: copy Taskbar.png as BenjiOS-Menu.png to icon theme path
  local icon_target="$HOME/.local/share/icons/hicolor/48x48/apps/BenjiOS-Menu.png"
  mkdir -p "$(dirname "$icon_target")"
  if curl -fsSL "$RAW_BASE/assets/Taskbar.png" -o "$icon_target"; then
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    fi
  fi
}

configure_gnome_extensions_layout

#--------------------------------------
# Stack-specific system config
#--------------------------------------

# Gaming
if has_stack "gaming"; then
  run_sudo systemctl enable --now gamemoded.service >/dev/null 2>&1 || true
fi

# Monitoring
if has_stack "monitoring"; then
  run_sudo systemctl enable --now irqbalance >/dev/null 2>&1 || true
  run_sudo sensors-detect --auto >/dev/null 2>&1 || true
fi

# Management / Remote
if has_stack "management"; then
  run_sudo systemctl enable --now ssh >/dev/null 2>&1 || true
  run_sudo systemctl enable --now xrdp >/dev/null 2>&1 || true

  # Basic firewall rules
  run_sudo ufw allow 22/tcp >/dev/null 2>&1 || true
  run_sudo ufw allow 3389/tcp >/dev/null 2>&1 || true
  run_sudo ufw --force enable >/dev/null 2>&1 || true

  # Keep network up on halt for WoL
  run_sudo bash -c '
    if [ -f /etc/default/halt ]; then
      if grep -q "^NETDOWN=" /etc/default/halt; then
        sed -i "s/^NETDOWN=.*/NETDOWN=no/" /etc/default/halt
      else
        echo "NETDOWN=no" >> /etc/default/halt
      fi
    else
      echo "NETDOWN=no" > /etc/default/halt
    fi
  ' >/dev/null 2>&1 || true

  # If TLP exists, keep WOL on
  if [ -f /etc/default/tlp ]; then
    run_sudo bash -c '
      if grep -q "^WOL_DISABLE=" /etc/default/tlp; then
        sed -i "s/^WOL_DISABLE=.*/WOL_DISABLE=N/" /etc/default/tlp
      else
        echo "WOL_DISABLE=N" >> /etc/default/tlp
      fi
    ' >/dev/null 2>&1 || true
  fi
fi

#--------------------------------------
# rEFInd install + theme (BsxM1)
#--------------------------------------
install_and_configure_refind() {
  # Require ESP mounted at /boot/efi
  local esp="/boot/efi"
  if ! mountpoint -q "$esp"; then
    echo "[BenjiOS] /boot/efi not mounted – skipping rEFInd theme configuration."
    return
  fi

  # Install rEFInd to ESP (if installer is present)
  if command -v refind-install >/dev/null 2>&1; then
    run_sudo refind-install || true
  fi

  local theme_dir="$esp/EFI/refind/themes/refind-bsxm1-theme"
  run_sudo mkdir -p "$(dirname "$theme_dir")"

  if [ ! -d "$theme_dir" ]; then
    # Clone BsxM1 theme
    run_sudo git clone --depth=1 https://github.com/AlexFullmoon/refind-bsxm1-theme.git "$theme_dir" || true
  fi

  local refind_dir="$esp/EFI/refind"
  local refind_conf="$refind_dir/refind.conf"
  run_sudo mkdir -p "$refind_dir"

  # Prefer refind.conf from BenjiOS repo; otherwise use a safe fallback
  local tmp_conf
  tmp_conf="$(mktemp)"

  if curl -fsSL "$RAW_BASE/refind/refind.conf" -o "$tmp_conf"; then
    run_sudo cp "$tmp_conf" "$refind_conf"
  else
    cat > "$tmp_conf" << 'EOF'
timeout 10
use_nvram false
resolution max

enable_mouse
mouse_size 16
mouse_speed 6

showtools
dont_scan_files grubx64.efi,fwupx64.efi

include themes/refind-bsxm1-theme/theme.conf
EOF
    run_sudo cp "$tmp_conf" "$refind_conf"
  fi

  rm -f "$tmp_conf"
}

if $INSTALL_REFIND; then
  install_and_configure_refind
fi

#--------------------------------------
# Maintenance / cleanup
#--------------------------------------
zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=200 \
  --text="Step 4: Running maintenance tasks (firmware, Flatpak, cleanup)…"

# APT cleanup
run_sudo_apt apt autoremove --purge -y || true
run_sudo_apt apt clean || true

# Flatpak cleanup
if command -v flatpak >/dev/null 2>&1; then
  flatpak update -y || true
  flatpak uninstall --unused -y || true
fi

# Firmware updates (refresh metadata + list updates; actual flashing is up to the user)
if command -v fwupdmgr >/dev/null 2>&1; then
  run_sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
  run_sudo fwupdmgr get-updates >/dev/null 2>&1 || true
  # You can run `sudo fwupdmgr update` manually later if desired.
fi

# Snap refresh (if snap exists)
if command -v snap >/dev/null 2>&1; then
  run_sudo snap refresh >/dev/null 2>&1 || true
fi

#--------------------------------------
# Post-install docs
#--------------------------------------
POST_DOC_TMP="$(mktemp)"
if curl -fsSL "$RAW_BASE/docs/BenjiOS-PostInstall.odt" -o "$POST_DOC_TMP"; then
  cp "$POST_DOC_TMP" "$DESKTOP_DIR/BenjiOS-PostInstall.odt"
fi
rm -f "$POST_DOC_TMP"

#--------------------------------------
# Done
#--------------------------------------
zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=220 \
  --text="BenjiOS setup is complete.\n\nYou can find a post-install guide on your Desktop.\n\nConsider rebooting to apply all changes (especially rEFInd / firmware)."

if zenity --question --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="Reboot now?"; then
  run_sudo reboot
fi

exit 0
