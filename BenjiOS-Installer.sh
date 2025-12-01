#!/usr/bin/env bash
set -e

########################################
# BenjiOS Installer v2
# Target: Ubuntu 25.10+ (GNOME, Wayland)
#
# Key features:
#  - Curated stacks (office, gaming, monitoring, backup, management, auto_updates, amd_tweaks, refind)
#  - Flatpak + Flathub setup
#  - rEFInd with BsxM1 theme and selectable boot mode
#  - GNOME dark theme + BenjiOS layout
#  - ArcMenu + App Icons Taskbar:
#       * Installed from extensions.gnome.org
#       * Config seeded from repo
#       * Auto-enabled at the END of the installer
#       * Reboot STRONGLY recommended afterwards
########################################

RAW_BASE="https://raw.githubusercontent.com/AdminPanic/BenjiOS/main"
DESKTOP_DIR="$HOME/Desktop"

ZENITY_W=640
ZENITY_H=480

# Will be filled when we install GNOME extensions
ARCMENU_UUID=""
TASKBAR_UUID=""

# rEFInd boot mode: single (Ubuntu only), dual (Ubuntu + Windows), all (show everything)
REFIND_BOOT_MODE="dual"

# Extra GNOME extensions we control explicitly
GSCONNECT_UUID="gsconnect@andyholmes.github.io"
UBUNTU_DOCK_UUID="ubuntu-dock@ubuntu.com"

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
cat > "$LICENSE_FILE" << 'EOF_LIC'
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
EOF_LIC

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

# Ask rEFInd boot mode if we install it
if $INSTALL_REFIND; then
  REFIND_BOOT_MODE="$(zenity --list \
    --title="BenjiOS – rEFInd Boot Mode" \
    --width="$ZENITY_W" --height="$ZENITY_H" \
    --text="Choose how rEFInd should present boot entries:\n\n• Single Boot Ubuntu\n• Dual Boot Ubuntu + Windows\n• Show all detected entries" \
    --radiolist \
    --column="Use" --column="ID"   --column="Description" \
    TRUE  "dual"   "Dual Boot: Ubuntu + Windows, hide helper/junk entries" \
    FALSE "single" "Single Boot: Ubuntu only, hide Windows entries" \
    FALSE "all"    "Show all detected entries (Linux, Windows, tools, etc.)" \
  )" || true

  case "$REFIND_BOOT_MODE" in
    single|dual|all) ;;
    *) REFIND_BOOT_MODE="dual" ;;
  esac
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

add_apt() { APT_PKGS+=("$@"); }
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
  jq \
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
  cat > "$tmp_file" <<EOF_AUTO
APT::Periodic::Update-Package-Lists "$days";
APT::Periodic::Download-Upgradeable-Packages "$days";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "$days";
EOF_AUTO
  run_sudo cp "$tmp_file" /etc/apt/apt.conf.d/20auto-upgrades
  rm -f "$tmp_file"

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
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface accent-color 'green' 2>/dev/null || true
  fi

  if command -v powerprofilesctl >/dev/null 2>&1; then
    if powerprofilesctl list 2>/dev/null | grep -q "performance"; then
      powerprofilesctl set performance >/dev/null 2>&1 || true
    fi
  fi
}

configure_gnome_look_and_power

#--------------------------------------
# Helpers: GNOME extensions (ArcMenu + App Icons Taskbar)
#--------------------------------------
ensure_gnome_extension_tools() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "[GNOME] curl not found; cannot install extensions." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "[GNOME] jq not found; cannot install extensions." >&2
    return 1
  fi
  if ! command -v gnome-extensions >/dev/null 2>&1; then
    echo "[GNOME] gnome-extensions CLI not found; cannot install extensions." >&2
    return 1
  fi
  return 0
}

install_gnome_extension_by_id() {
  local ext_id="$1"
  local label="$2"

  if ! command -v gnome-extensions >/dev/null 2>&1; then
    echo "[GNOME] gnome-extensions CLI missing; cannot install ${label}." >&2
    return 1
  fi

  local shell_ver=""
  if command -v gnome-shell >/dev/null 2>&1; then
    shell_ver="$(gnome-shell --version | awk '{print $3}' | cut -d. -f1)"
  fi

  local url="https://extensions.gnome.org/extension-info/?pk=${ext_id}"
  if [ -n "$shell_ver" ]; then
    url="${url}&shell_version=${shell_ver}"
  fi

  local json uuid download_url
  if ! json="$(curl -fsSL "$url")"; then
    echo "[GNOME] ERROR: Failed to fetch metadata for ${label} (ID ${ext_id})." >&2
    return 1
  fi

  uuid="$(printf '%s\n' "$json" | jq -r '.uuid')"
  download_url="$(printf '%s\n' "$json" | jq -r '.download_url')"

  if [ -z "$uuid" ] || [ "$uuid" = "null" ] || \
     [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
    echo "[GNOME] ERROR: Missing uuid/download_url in metadata for ${label}." >&2
    return 1
  fi

  if gnome-extensions list | grep -Fxq "$uuid"; then
    echo "[GNOME] ${label} already installed as ${uuid}, skipping download." >&2
  else
    echo "[GNOME] Downloading ${label} (${uuid}) from extensions.gnome.org…" >&2
    local tmpfile
    tmpfile="$(mktemp)" || {
      echo "[GNOME] ERROR: mktemp failed for ${label}." >&2
      return 1
    }

    if ! curl -fsSL "https://extensions.gnome.org${download_url}" -o "$tmpfile"; then
      echo "[GNOME] ERROR: Failed to download ${label} payload." >&2
      rm -f "$tmpfile"
      return 1
    fi

    echo "[GNOME] Installing ${label} via gnome-extensions…" >&2
    if ! gnome-extensions install --force "$tmpfile"; then
      echo "[GNOME] ERROR: gnome-extensions install failed for ${label}." >&2
      rm -f "$tmpfile"
      return 1
    fi

    rm -f "$tmpfile"
  fi

  if gnome-extensions info "$uuid" >/dev/null 2>&1; then
    gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    echo "[GNOME] ${label} installed as ${uuid} and kept DISABLED for now." >&2
  fi

  printf '%s\n' "$uuid"
}

configure_gnome_extensions_layout() {
  echo "[GNOME] === Configuring GNOME Shell extensions (ArcMenu + App Icons Taskbar) ==="

  if ! ensure_gnome_extension_tools; then
    echo "[GNOME] Skipping GNOME extension installation due to missing tools." >&2
    return
  fi

  ARCMENU_UUID="$(install_gnome_extension_by_id 3628 "ArcMenu" || true)"
  TASKBAR_UUID="$(install_gnome_extension_by_id 4944 "App Icons Taskbar" || true)"

  if command -v dconf >/dev/null 2>&1; then
    local arcmenu_tmp
    arcmenu_tmp="$(mktemp)"
    if curl -fsSL "$RAW_BASE/configs/arcmenu.conf" -o "$arcmenu_tmp"; then
      dconf load /org/gnome/shell/extensions/arcmenu/ < "$arcmenu_tmp" 2>/dev/null || \
        echo "[GNOME] WARNING: Failed to load ArcMenu dconf." >&2
    else
      echo "[GNOME] NOTE: Could not fetch arcmenu.conf; skipping ArcMenu config." >&2
    fi
    rm -f "$arcmenu_tmp"

    local taskbar_tmp
    taskbar_tmp="$(mktemp)"
    if curl -fsSL "$RAW_BASE/configs/app-icons-taskbar.conf" -o "$taskbar_tmp"; then
      dconf load /org/gnome/shell/extensions/aztaskbar/ < "$taskbar_tmp" 2>/dev/null || \
        echo "[GNOME] WARNING: Failed to load App Icons Taskbar dconf." >&2
    else
      echo "[GNOME] NOTE: Could not fetch app-icons-taskbar.conf; skipping Taskbar config." >&2
    fi
    rm -f "$taskbar_tmp"
  else
    echo "[GNOME] dconf not found; cannot apply extension configs." >&2
  fi

  local icon_target="$HOME/.local/share/icons/hicolor/48x48/apps/BenjiOS-Menu.png"
  mkdir -p "$(dirname "$icon_target")"
  if curl -fsSL "$RAW_BASE/assets/Taskbar.png" -o "$icon_target"; then
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    fi
  else
    echo "[GNOME] NOTE: Could not fetch Taskbar.png; ArcMenu icon may fall back to default." >&2
  fi

  echo "[GNOME] ArcMenu and App Icons Taskbar are installed, configured, and currently DISABLED."
}

configure_gnome_extensions_layout

#--------------------------------------
# Stack-specific system config
#--------------------------------------
if has_stack "gaming"; then
  run_sudo systemctl enable --now gamemoded.service >/dev/null 2>&1 || true
fi

if has_stack "monitoring"; then
  run_sudo systemctl enable --now irqbalance >/dev/null 2>&1 || true
  run_sudo sensors-detect --auto >/dev/null 2>&1 || true
fi

if has_stack "management"; then
  run_sudo systemctl enable --now ssh >/dev/null 2>&1 || true
  run_sudo systemctl enable --now xrdp >/dev/null 2>&1 || true

  run_sudo ufw allow 22/tcp >/dev/null 2>&1 || true
  run_sudo ufw allow 3389/tcp >/dev/null 2>&1 || true
  run_sudo ufw --force enable >/dev/null 2>&1 || true

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
# rEFInd install + theme (BsxM1) with mode
#--------------------------------------
install_and_configure_refind() {
  local mode="$1"

  local esp="/boot/efi"
  if ! mountpoint -q "$esp"; then
    echo "[rEFInd] /boot/efi not mounted – skipping rEFInd configuration."
    return
  fi

  # Run rEFInd’s own installer if present
  if command -v refind-install >/dev/null 2>&1; then
    run_sudo refind-install || true
  fi

  # Paths to the standard loaders on the ESP
  local ubuntu_rel="EFI/ubuntu/shimx64.efi"
  local windows_rel="EFI/Microsoft/Boot/bootmgfw.efi"

  local have_ubuntu=false
  local have_windows=false
  [ -f "$esp/$ubuntu_rel" ]   && have_ubuntu=true
  [ -f "$esp/$windows_rel" ]  && have_windows=true

  # If user picked modes that don't make sense for this machine, degrade gracefully
  local effective_mode="$mode"
  if [ "$effective_mode" = "dual" ] && ! $have_windows; then
    # No Windows -> behave like single boot
    effective_mode="single"
  fi
  if [ "$effective_mode" = "single" ] && ! $have_ubuntu; then
    # Somehow no Ubuntu shim where we expect it -> fall back to full scan
    effective_mode="all"
  fi

  local theme_dir="$esp/EFI/refind/themes/refind-bsxm1-theme"
  run_sudo mkdir -p "$(dirname "$theme_dir")"

  if [ ! -d "$theme_dir" ]; then
    run_sudo git clone --depth=1 https://github.com/AlexFullmoon/refind-bsxm1-theme.git "$theme_dir" || true
  fi

  local refind_dir="$esp/EFI/refind"
  local refind_conf="$refind_dir/refind.conf"
  run_sudo mkdir -p "$refind_dir"

  local tmp_conf
  tmp_conf="$(mktemp)"

  # Base settings (no scanfor here – that depends on mode)
  cat > "$tmp_conf" << 'EOF_REF'
# BenjiOS rEFInd configuration
# Generated by BenjiOS-Installer.sh

timeout 10
use_nvram false
resolution max

# Mouse support
enable_mouse
mouse_size 16
mouse_speed 6

# Basic tools
showtools shell, reboot, shutdown, firmware
EOF_REF

  case "$effective_mode" in
    single)
      # One Secure Boot–friendly Ubuntu entry only (shimx64.efi)
      cat >> "$tmp_conf" << 'EOF_SINGLE'

# Mode: Single Boot Ubuntu
scanfor manual
default_selection "Ubuntu (BenjiOS)"

menuentry "Ubuntu (BenjiOS)" {
    icon /EFI/refind/icons/os_ubuntu.png
    loader \EFI\ubuntu\shimx64.efi
}
EOF_SINGLE
      ;;

    dual)
      # Ubuntu + Windows, both via their standard signed bootloaders
      cat >> "$tmp_conf" << 'EOF_DUAL'

# Mode: Dual Boot Ubuntu + Windows
scanfor manual
default_selection "Ubuntu (BenjiOS)"

menuentry "Ubuntu (BenjiOS)" {
    icon /EFI/refind/icons/os_ubuntu.png
    loader \EFI\ubuntu\shimx64.efi
}

menuentry "Windows" {
    icon /EFI/refind/icons/os_win8.png
    loader \EFI\Microsoft\Boot\bootmgfw.efi
}
EOF_DUAL
      ;;

    all)
      # Let rEFInd show everything it finds
      cat >> "$tmp_conf" << 'EOF_ALL'

# Mode: Show all entries
# Let rEFInd auto-detect all loaders.
scanfor internal,external,optical,manual
EOF_ALL
      ;;

    *)
      # Safety net: behave like "all"
      cat >> "$tmp_conf" << 'EOF_FALLBACK'

# Mode: Unknown (fallback to show all)
scanfor internal,external,optical,manual
EOF_FALLBACK
      ;;
  esac

  # Always include the BsxM1 theme, relative to EFI/refind/
  cat >> "$tmp_conf" << 'EOF_THEME'

# BenjiOS theme (BsxM1) – path relative to EFI/refind/
include themes/refind-bsxm1-theme/theme.conf
EOF_THEME

  run_sudo cp "$tmp_conf" "$refind_conf"
  rm -f "$tmp_conf"

  echo "[rEFInd] Installed/updated with mode='${effective_mode}' and BsxM1 theme enabled."
}

if $INSTALL_REFIND; then
  install_and_configure_refind "$REFIND_BOOT_MODE"
fi

#--------------------------------------
# Maintenance / cleanup
#--------------------------------------
zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=200 \
  --text="Step 4: Running maintenance tasks (firmware, Flatpak, cleanup)…"

run_sudo_apt apt autoremove --purge -y || true
run_sudo_apt apt clean || true

if command -v flatpak >/dev/null 2>&1; then
  flatpak update -y || true
  flatpak uninstall --unused -y || true
fi

if command -v fwupdmgr >/dev/null 2>&1; then
  run_sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
  run_sudo fwupdmgr get-updates >/dev/null 2>&1 || true
fi

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
# Enable GNOME layout extensions at the very end
#--------------------------------------
enable_gnome_layout_extensions() {
  # What we want enabled/disabled after install
  local enable_uuids=()
  [ -n "$ARCMENU_UUID" ] && enable_uuids+=("$ARCMENU_UUID")
  [ -n "$TASKBAR_UUID" ] && enable_uuids+=("$TASKBAR_UUID")
  enable_uuids+=("$GSCONNECT_UUID")   # make sure GSConnect is on

  local disable_uuids=("$UBUNTU_DOCK_UUID")  # kill the default Ubuntu Dock

  if [ "${#enable_uuids[@]}" -eq 0 ] && [ "${#disable_uuids[@]}" -eq 0 ]; then
    return
  fi

  # 1) Persist the state with gsettings (if available)
  if command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    # --- enabled-extensions: add our enable_uuids ---
    local current_enabled merged_enabled
    current_enabled="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")"
    current_enabled="${current_enabled#@as }"

    merged_enabled="$(python3 - "$current_enabled" "${enable_uuids[@]}" << 'PY'
import ast, sys
current = sys.argv[1]
uuids = sys.argv[2:]
try:
    arr = ast.literal_eval(current)
    if not isinstance(arr, list):
        arr = []
except Exception:
    arr = []
for u in uuids:
    if u and u not in arr:
        arr.append(u)
print(str(arr))
PY
)" || merged_enabled=""

    if [ -n "$merged_enabled" ]; then
      gsettings set org.gnome.shell enabled-extensions "$merged_enabled" 2>/dev/null || true
    fi

    # --- disabled-extensions: remove our enabled ones, add ones we want disabled ---
    local current_disabled cleaned_disabled final_disabled
    current_disabled="$(gsettings get org.gnome.shell disabled-extensions 2>/dev/null || echo "[]")"
    current_disabled="${current_disabled#@as }"

    cleaned_disabled="$(python3 - "$current_disabled" "${enable_uuids[@]}" << 'PY'
import ast, sys
current = sys.argv[1]
enabled = set(sys.argv[2:])
try:
    arr = ast.literal_eval(current)
    if not isinstance(arr, list):
        arr = []
except Exception:
    arr = []
arr = [x for x in arr if x not in enabled]
print(str(arr))
PY
)" || cleaned_disabled=""

    final_disabled="$(python3 - "$cleaned_disabled" "${disable_uuids[@]}" << 'PY'
import ast, sys
current = sys.argv[1]
disable = sys.argv[2:]
try:
    arr = ast.literal_eval(current)
    if not isinstance(arr, list):
        arr = []
except Exception:
    arr = []
for u in disable:
    if u and u not in arr:
        arr.append(u)
print(str(arr))
PY
)" || final_disabled=""

    if [ -n "$final_disabled" ]; then
      gsettings set org.gnome.shell disabled-extensions "$final_disabled" 2>/dev/null || true
    fi
  fi

  # 2) Also poke the gnome-extensions CLI (helps in the live session)
  if command -v gnome-extensions >/dev/null 2>&1; then
    for uuid in "${enable_uuids[@]}"; do
      [ -n "$uuid" ] && gnome-extensions enable "$uuid" >/dev/null 2>&1 || true
    done
    for uuid in "${disable_uuids[@]}"; do
      [ -n "$uuid" ] && gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    done
  fi

  echo "[GNOME] Ensured ArcMenu, App Icons Taskbar, and GSConnect are ENABLED, Ubuntu Dock is DISABLED."
}

enable_gnome_layout_extensions

#--------------------------------------
# Done
#--------------------------------------
zenity --info --title="BenjiOS Installer" \
  --width="$ZENITY_W" --height=260 \
  --text="BenjiOS setup is complete.\n\nArcMenu and App Icons Taskbar have been installed, configured, and ACTIVATED for the BenjiOS layout.\n\nrEFInd (if selected) was configured using the chosen boot mode and BsxM1 theme.\n\nA reboot is STRONGLY recommended so GNOME and rEFInd fully pick up the new configuration."

if zenity --question --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=220 \
    --text="Reboot now to finalize the BenjiOS layout and rEFInd configuration (strongly recommended)?"; then
  run_sudo reboot
fi

exit 0
