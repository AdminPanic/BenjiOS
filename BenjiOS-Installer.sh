#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# BenjiOS Installer
# Target: Ubuntu 25.10+ (GNOME, Wayland)
#
# Design goals:
#  - Sane defaults, minimal prompting
#  - Script handles logic/orchestration
#  - Repo holds configs (dconf, refind, zram)
########################################

RAW_BASE="https://raw.githubusercontent.com/AdminPanic/BenjiOS/main"
DESKTOP_DIR="$HOME/Desktop"

ZENITY_W=640
ZENITY_H=480

# Filled when we install GNOME extensions
ARCMENU_UUID=""
TASKBAR_UUID=""
BLUR_SHELL_UUID=""

# rEFInd boot mode: single (Ubuntu only), dual (Ubuntu + Windows), all (show everything)
REFIND_BOOT_MODE="dual"

# Extra GNOME extensions we control explicitly
GSCONNECT_UUID="gsconnect@andyholmes.github.io"
UBUNTU_DOCK_UUID="ubuntu-dock@ubuntu.com"

# GPU detection flags
AMD_GPU_DETECTED=false
NVIDIA_GPU_DETECTED=false
INTEL_GPU_DETECTED=false

# Virtualization detection flags
VIRT_TYPE="none"
IS_VIRT=false
IS_KVM=false        # includes Proxmox/QEMU
IS_VMWARE=false
IS_VBOX=false       # VirtualBox
IS_HYPERV=false     # Hyper-V

#--------------------------------------
# Small helper: non-blocking info popup
#--------------------------------------
info_popup() {
  local msg="$1"
  zenity --info \
    --timeout=5 \
    --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="$msg" >/dev/null 2>&1 || true
}

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
# Sudo via zenity (one-time password check)
#--------------------------------------
SUDO_PASS="$(zenity --password --title='BenjiOS Installer – sudo access' \
  --width="$ZENITY_W" --height=200)"

if [ -z "$SUDO_PASS" ]; then
  zenity --error --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="No password entered.\nExiting."
  exit 1
fi

if ! printf '%s\n' "$SUDO_PASS" | sudo -S -v >/dev/null 2>&1; then
  zenity --error --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=200 \
    --text="Incorrect sudo password.\nExiting."
  exit 1
fi

# Drop the password from memory as soon as possible
unset SUDO_PASS

run_sudo() {
  sudo "$@"
}

run_sudo_apt() {
  sudo DEBIAN_FRONTEND=noninteractive "$@"
}

backup_file() {
  local target="$1"
  if [ -f "$target" ]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    run_sudo cp "$target" "${target}.bak.${ts}"
  fi
}

find_esp() {
  local candidates=(
    /boot/efi
    /boot/EFI
    /efi
  )
  local p
  for p in "${candidates[@]}"; do
    if mountpoint -q "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

#--------------------------------------
# Detect GPUs (AMD / NVIDIA / Intel)
#--------------------------------------
GPU_LINES=""

if command -v lspci >/dev/null 2>&1; then
  GPU_LINES="$(lspci | grep -Ei 'VGA|3D|Display' || true)"
else
  echo "[GPU] lspci not found; skipping detailed GPU detection."
fi

if echo "$GPU_LINES" | grep -qi "AMD"; then
  AMD_GPU_DETECTED=true
fi
if echo "$GPU_LINES" | grep -qi "NVIDIA"; then
  NVIDIA_GPU_DETECTED=true
fi
if echo "$GPU_LINES" | grep -qi "Intel"; then
  INTEL_GPU_DETECTED=true
fi

if [ -n "$GPU_LINES" ]; then
  echo "[GPU] Detected GPUs:"
  echo "$GPU_LINES"
fi
$AMD_GPU_DETECTED    && echo "  -> AMD GPU detected"
$NVIDIA_GPU_DETECTED && echo "  -> NVIDIA GPU detected"
$INTEL_GPU_DETECTED  && echo "  -> Intel GPU detected"

#--------------------------------------
# Detect virtualization (KVM/Proxmox, VMware, VirtualBox, Hyper-V)
#--------------------------------------
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo "none")"
else
  VIRT_TYPE="none"
fi

case "$VIRT_TYPE" in
  kvm|qemu)
    IS_VIRT=true
    IS_KVM=true
    ;;
  vmware)
    IS_VIRT=true
    IS_VMWARE=true
    ;;
  oracle|virtualbox)
    IS_VIRT=true
    IS_VBOX=true
    ;;
  microsoft|hyperv)
    IS_VIRT=true
    IS_HYPERV=true
    ;;
  *)
    IS_VIRT=false
    ;;
esac

echo "[VIRT] Detected virtualization type: $VIRT_TYPE"
$IS_KVM    && echo "  -> KVM/QEMU guest (includes Proxmox VMs)"
$IS_VMWARE && echo "  -> VMware guest"
$IS_VBOX   && echo "  -> VirtualBox guest"
$IS_HYPERV && echo "  -> Hyper-V guest"

#--------------------------------------
# Stack selection
#--------------------------------------
STACK_SELECTION="$(zenity --list \
  --title="BenjiOS Installer – Component Selection" \
  --width="$ZENITY_W" --height="$ZENITY_H" \
  --text="Select which stacks to install.\n\nCore system tools, GPU tweaks, and VM guest integrations (based on detected hardware) are ALWAYS installed.\nYou can re-run this script later to add more stacks." \
  --checklist \
  --column="Install" --column="ID" --column="Description" \
  TRUE  "office"        "Office, mail, basic media, RDP client" \
  TRUE  "gaming"        "Gaming stack: Steam, Heroic, Lutris, Proton tools" \
  TRUE  "monitoring"    "Monitoring: sensors, btop, nvtop, psensor, disk health" \
  TRUE  "backup_tools"  "Backup tools: Timeshift, Déjà Dup, Borg, Vorta" \
  TRUE  "management"    "Remote management: SSH server, xRDP, firewall, WoL" \
  TRUE  "tweaks"        "Performance tweaks: zram compressed swap + earlyoom" \
  TRUE  "auto_updates"  "Automatic APT updates (unattended-upgrades + cron-apt)" \
  FALSE "refind"        "rEFInd boot manager with BsxM1 theme (advanced multi-boot)" \
)" || true

if [ -z "$STACK_SELECTION" ]; then
  info_popup "No optional stacks selected.\nCore stack, GPU tweaks, and VM integrations (if supported) will still be installed."
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
# Optional kisak-mesa PPA for AMD + gaming
#--------------------------------------
USE_KISAK_MESA=false
if $AMD_GPU_DETECTED && has_stack "gaming"; then
  if zenity --question \
       --title="BenjiOS – AMD GPU detected" \
       --width="$ZENITY_W" --height=220 \
       --text="An AMD GPU and the Gaming stack were detected.\n\nYou can enable the kisak-mesa PPA to get newer Mesa drivers (often better performance and fixes for newer GPUs).\n\nEnable kisak-mesa PPA now?\n\n(Recommended for recent Radeon cards; slightly less conservative than stock Ubuntu Mesa.)"; then
    USE_KISAK_MESA=true
  fi
fi

if $USE_KISAK_MESA; then
  info_popup "Enabling kisak-mesa PPA for newer Mesa drivers…"
  run_sudo_apt apt install -y software-properties-common
  run_sudo add-apt-repository -y ppa:kisak/kisak-mesa
fi

#--------------------------------------
# Step 1 – apt update + full-upgrade + i386
#--------------------------------------
info_popup "Step 1: Updating system and enabling 32-bit architecture.\n\nYou can watch progress in the terminal."

run_sudo_apt apt update
run_sudo_apt apt full-upgrade -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confnew

# Enable multiarch
run_sudo dpkg --add-architecture i386 || true
run_sudo_apt apt update

# Preseed MS core fonts EULA
run_sudo_apt apt install -y debconf-utils
echo | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | debconf-set-selections"
echo | sudo -S bash -c "echo 'ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note' | debconf-set-selections"

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
  flatpak \
  ubuntu-drivers-common \
  fonts-firacode \
  fonts-noto-color-emoji

add_flatpak \
  com.mattjakeman.ExtensionManager

# Office stack
if has_stack "office"; then
  add_apt \
    openvpn \
    libreoffice \
    gimp \
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
  # Strategy:
  #  - Mesa/Vulkan/runtime bits: APT (tied to kernel/driver stack)
  #  - Game launchers/runtimes: Flatpak (usually newest stable builds)
  add_apt \
    mesa-utils \
    vulkan-tools \
    gamemode \
    mangohud \
    libxkbcommon-x11-0:i386 \
    libvulkan1:i386 \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386

  add_flatpak \
    com.valvesoftware.Steam \
    com.heroicgameslauncher.hgl \
    net.davidotek.pupgui2 \
    net.lutris.Lutris \
    com.usebottles.bottles \
    com.discordapp.Discord
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
    psensor \
    gnome-disk-utility
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

# Tweaks stack (zram + earlyoom)
if has_stack "tweaks"; then
  add_apt \
    zram-tools \
    earlyoom
fi

# Auto updates stack
if $AUTO_UPDATES_SELECTED; then
  add_apt \
    unattended-upgrades \
    cron-apt
fi

# GPU-specific tweaks (auto, based on detection)
if $AMD_GPU_DETECTED; then
  add_apt \
    radeontop \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    vulkan-tools \
    mesa-utils
fi

if $NVIDIA_GPU_DETECTED; then
  add_apt \
    vulkan-tools \
    mesa-utils \
    nvidia-settings
fi

if $INTEL_GPU_DETECTED; then
  add_apt \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    vulkan-tools \
    mesa-utils \
    intel-gpu-tools
fi

# VM-specific guest additions / agents
if $IS_KVM; then
  add_apt \
    qemu-guest-agent \
    spice-vdagent
fi

if $IS_VMWARE; then
  add_apt \
    open-vm-tools \
    open-vm-tools-desktop
fi

if $IS_VBOX; then
  add_apt \
    virtualbox-guest-utils \
    virtualbox-guest-x11
fi

if $IS_HYPERV; then
  add_apt \
    linux-tools-virtual \
    linux-cloud-tools-virtual
fi

# rEFInd stack
if $INSTALL_REFIND; then
  add_apt \
    shim-signed \
    mokutil \
    git
fi

#--------------------------------------
# Install APT packages (deduplicated)
#--------------------------------------
if [ "${#APT_PKGS[@]}" -gt 0 ]; then
  info_popup "Step 2: Installing APT packages…\n\nCheck the terminal for detailed progress."

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
# NVIDIA driver autoinstall (if NVIDIA GPU)
#--------------------------------------
if $NVIDIA_GPU_DETECTED; then
  echo "[GPU] NVIDIA GPU detected – running ubuntu-drivers autoinstall…"
  info_popup "Detected NVIDIA GPU.\n\nBenjiOS will now run 'ubuntu-drivers autoinstall' to install the recommended NVIDIA driver."
  run_sudo ubuntu-drivers autoinstall || true
fi

#--------------------------------------
# Flatpak setup + apps
#--------------------------------------
info_popup "Step 3: Configuring Flatpak and installing apps…"

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

if [ "${#FLATPAK_PKGS[@]}" -gt 0 ]; then
  flatpak install -y flathub "${FLATPAK_PKGS[@]}" || true
fi

#--------------------------------------
# Helper: configure auto updates (20auto-upgrades)
#--------------------------------------
setup_auto_updates() {
  local days="$1"   # "1" (daily) or "7" (weekly)
  local tmp_file
  tmp_file="$(mktemp)"

  cat > "$tmp_file" <<EOF_AUTO
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "$days";
APT::Periodic::AutocleanInterval "7";
EOF_AUTO

  if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
    backup_file /etc/apt/apt.conf.d/20auto-upgrades
  fi
  run_sudo cp "$tmp_file" /etc/apt/apt.conf.d/20auto-upgrades
  rm -f "$tmp_file"

  run_sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true
}

if $AUTO_UPDATES_SELECTED && [ -n "$UPDATES_DAYS" ]; then
  setup_auto_updates "$UPDATES_DAYS"
fi

#--------------------------------------
# Helper: GNOME appearance + power profile
#--------------------------------------
configure_gnome_theme_and_power() {
  if ! command -v gsettings >/dev/null 2>&1; then
    echo "[THEME] gsettings not found – skipping desktop theming."
    return
  fi

  local IF_SCHEMA="org.gnome.desktop.interface"

  echo "[THEME] Applying BenjiOS GNOME look (dark + green accent)…"

  # Dark mode (upstream + Ubuntu-specific)
  gsettings set "$IF_SCHEMA" color-scheme 'prefer-dark' 2>/dev/null || true
  if gsettings writable org.gnome.shell.ubuntu color-scheme >/dev/null 2>&1; then
    gsettings set org.gnome.shell.ubuntu color-scheme 'dark' 2>/dev/null || true
  fi

  # GTK + icons + sound: stock Yaru
  gsettings set "$IF_SCHEMA" gtk-theme  'Yaru-dark' 2>/dev/null || true
  gsettings set "$IF_SCHEMA" icon-theme 'Yaru'      2>/dev/null || true
  gsettings set org.gnome.desktop.sound theme-name 'Yaru' 2>/dev/null || true

  # Accent color: new GNOME key if available
  if gsettings range "$IF_SCHEMA" accent-color >/dev/null 2>&1; then
    gsettings set "$IF_SCHEMA" accent-color 'green' 2>/dev/null || true

    if [ -x /usr/libexec/yaru-colors-switcher ]; then
      /usr/libexec/yaru-colors-switcher --color green --theme dark || true
    elif [ -x /usr/lib/yaru-colors-switcher ]; then
      /usr/lib/yaru-colors-switcher --color green --theme dark || true
    fi
  else
    gsettings set "$IF_SCHEMA" gtk-theme 'Yaru-green-dark' 2>/dev/null || \
    gsettings set "$IF_SCHEMA" gtk-theme 'Yaru-green'      2>/dev/null || true
  fi

  # Rebuild icon caches (best effort)
  [ -d "$HOME/.icons" ] && gtk-update-icon-cache "$HOME/.icons" >/dev/null 2>&1 || true
  [ -d /usr/share/icons/Yaru ] && run_sudo gtk-update-icon-cache /usr/share/icons/Yaru >/dev/null 2>&1 || true

  # Power profile: performance (guarded)
  if command -v powerprofilesctl >/dev/null 2>&1; then
    if powerprofilesctl list 2>/dev/null | grep -q "performance"; then
      powerprofilesctl set performance >/dev/null 2>&1 || true
    fi
  fi
}

configure_gnome_theme_and_power

#--------------------------------------
# Helpers: GNOME extensions (ArcMenu + App Icons Taskbar + Blur my Shell)
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
  echo "[GNOME] === Configuring GNOME Shell extensions (ArcMenu + App Icons Taskbar + Blur my Shell) ==="

  if ! ensure_gnome_extension_tools; then
    echo "[GNOME] Skipping GNOME extension installation due to missing tools." >&2
    return
  fi

  ARCMENU_UUID="$(install_gnome_extension_by_id 3628 "ArcMenu" || true)"
  TASKBAR_UUID="$(install_gnome_extension_by_id 4944 "App Icons Taskbar" || true)"
  BLUR_SHELL_UUID="$(install_gnome_extension_by_id 3193 "Blur my Shell" || true)"

  if command -v dconf >/dev/null 2>&1; then
    # ArcMenu config
    local arcmenu_tmp
    arcmenu_tmp="$(mktemp)"
    if curl -fsSL "$RAW_BASE/configs/arcmenu.conf" -o "$arcmenu_tmp"; then
      dconf load /org/gnome/shell/extensions/arcmenu/ < "$arcmenu_tmp" 2>/dev/null || \
        echo "[GNOME] WARNING: Failed to load ArcMenu dconf." >&2
    else
      echo "[GNOME] NOTE: Could not fetch arcmenu.conf; skipping ArcMenu config." >&2
    fi
    rm -f "$arcmenu_tmp"

    # App Icons Taskbar config
    local taskbar_tmp
    taskbar_tmp="$(mktemp)"
    if curl -fsSL "$RAW_BASE/configs/app-icons-taskbar.conf" -o "$taskbar_tmp"; then
      dconf load /org/gnome/shell/extensions/app-icons-taskbar/ < "$taskbar_tmp" 2>/dev/null || \
        echo "[GNOME] WARNING: Failed to load App Icons Taskbar dconf." >&2
    else
      echo "[GNOME] NOTE: Could not fetch app-icons-taskbar.conf; skipping Taskbar config." >&2
    fi
    rm -f "$taskbar_tmp"

    # Blur my Shell config
    local blur_tmp
    blur_tmp="$(mktemp)"
    if curl -fsSL "$RAW_BASE/configs/blur-my-shell.conf" -o "$blur_tmp"; then
      dconf load /org/gnome/shell/extensions/blur-my-shell/ < "$blur_tmp" 2>/dev/null || \
        echo "[GNOME] WARNING: Failed to load Blur my Shell dconf." >&2
    else
      echo "[GNOME] NOTE: Could not fetch blur-my-shell.conf; skipping Blur my Shell config." >&2
    fi
    rm -f "$blur_tmp"
  else
    echo "[GNOME] dconf not found; cannot apply extension configs." >&2
  fi

  # Taskbar icon asset (non-fatal if missing in repo)
  local icon_target="$HOME/.local/share/icons/hicolor/48x48/apps/BenjiOS-Menu.png"
  mkdir -p "$(dirname "$icon_target")"
  if curl -fsSL "$RAW_BASE/assets/Taskbar.png" -o "$icon_target"; then
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    fi
  else
    echo "[GNOME] NOTE: Could not fetch Taskbar.png; ArcMenu icon may fall back to default." >&2
  fi

  echo "[GNOME] ArcMenu, App Icons Taskbar, and Blur my Shell are installed and currently DISABLED (will be turned on at the end)."
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

# Tweaks stack: zram + earlyoom using repo config
if has_stack "tweaks"; then
  echo "[TWEAKS] Configuring zram (zram-tools) and earlyoom…"

  tmp_zram="$(mktemp)"
  if curl -fsSL "$RAW_BASE/configs/zramswap" -o "$tmp_zram"; then
    if [ -f /etc/default/zramswap ]; then
      backup_file /etc/default/zramswap
    fi
    run_sudo cp "$tmp_zram" /etc/default/zramswap
  else
    echo "[TWEAKS] WARNING: Could not fetch zramswap config from repo, keeping distro default." >&2
  fi
  rm -f "$tmp_zram"

  run_sudo systemctl enable --now zramswap.service >/dev/null 2>&1 || \
  run_sudo systemctl enable --now zramswap >/dev/null 2>&1 || true

  run_sudo systemctl enable --now earlyoom.service >/dev/null 2>&1 || true
fi

# VM guest services
if $IS_KVM; then
  run_sudo systemctl enable --now qemu-guest-agent.service >/dev/null 2>&1 || true
  run_sudo systemctl enable --now spice-vdagent.service >/dev/null 2>&1 || true
fi

if $IS_VMWARE; then
  run_sudo systemctl enable --now open-vm-tools.service >/dev/null 2>&1 || true
fi

if $IS_VBOX; then
  run_sudo systemctl enable --now vboxservice.service >/dev/null 2>&1 || true
fi

if $IS_HYPERV; then
  for svc in hv-kvp-daemon.service hv-vss-daemon.service hv-fcopy-daemon.service; do
    run_sudo systemctl enable --now "$svc" >/dev/null 2>&1 || true
  done
fi

#--------------------------------------
# rEFInd install + theme (BsxM1) with mode, using repo configs
#--------------------------------------
install_and_configure_refind() {
  local mode="$1"

  local esp
  if ! esp="$(find_esp)"; then
    echo "[rEFInd] EFI system partition not found – skipping rEFInd configuration."
    return
  fi

  local refind_dir="$esp/EFI/refind"
  local refind_conf="$refind_dir/refind.conf"

  # Ensure rEFInd is installed (package name differs between Ubuntu releases)
  if ! command -v refind-install >/dev/null 2>&1 && [ ! -d "$refind_dir" ]; then
    echo "[rEFInd] Installing rEFInd boot manager package (refind/refind-efi)…"
    if ! run_sudo_apt apt install -y refind && ! run_sudo_apt apt install -y refind-efi; then
      echo "[rEFInd] WARNING: Could not install rEFInd package (refind or refind-efi); skipping configuration." >&2
      return
    fi
  fi

  # Only run refind-install if the rEFInd directory does not exist yet
  if [ ! -d "$refind_dir" ] && command -v refind-install >/dev/null 2>&1; then
    run_sudo refind-install || true
  fi

  local ubuntu_rel="EFI/ubuntu/shimx64.efi"
  local windows_rel="EFI/Microsoft/Boot/bootmgfw.efi"

  local have_ubuntu=false
  local have_windows=false
  [ -f "$esp/$ubuntu_rel" ]  && have_ubuntu=true
  [ -f "$esp/$windows_rel" ] && have_windows=true

  local effective_mode="$mode"
  if [ "$effective_mode" = "dual" ] && ! $have_windows; then
    effective_mode="single"
  fi
  if [ "$effective_mode" = "single" ] && ! $have_ubuntu; then
    effective_mode="all"
  fi

  local theme_dir="$refind_dir/themes/refind-bsxm1-theme"
  run_sudo mkdir -p "$(dirname "$theme_dir")"

  if [ ! -d "$theme_dir" ]; then
    run_sudo git clone --depth=1 https://github.com/AlexFullmoon/refind-bsxm1-theme.git "$theme_dir" || true
  fi

  run_sudo mkdir -p "$refind_dir"

  local tmp_conf refind_src
  tmp_conf="$(mktemp)"

  case "$effective_mode" in
    single) refind_src="$RAW_BASE/configs/refind/refind-single.conf" ;;
    dual)   refind_src="$RAW_BASE/configs/refind/refind-dual.conf" ;;
    all)    refind_src="$RAW_BASE/configs/refind/refind-all.conf" ;;
    *)      refind_src="$RAW_BASE/configs/refind/refind-all.conf" ;;
  esac

  if ! curl -fsSL "$refind_src" -o "$tmp_conf"; then
    echo "[rEFInd] WARNING: Could not fetch rEFInd config '$refind_src' from repo, leaving existing config untouched." >&2
    rm -f "$tmp_conf"
    return
  fi

  if [ -f "$refind_conf" ]; then
    backup_file "$refind_conf"
  fi
  run_sudo cp "$tmp_conf" "$refind_conf"
  rm -f "$tmp_conf"

  echo "[rEFInd] Installed/updated with mode='${effective_mode}' using config from repo (ESP: $esp)."
}

if $INSTALL_REFIND; then
  install_and_configure_refind "$REFIND_BOOT_MODE"
fi

#--------------------------------------
# Maintenance / cleanup
#--------------------------------------
info_popup "Step 4: Running maintenance tasks (firmware, Flatpak, cleanup)…"

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
  local enable_uuids=()
  [ -n "$ARCMENU_UUID" ]     && enable_uuids+=("$ARCMENU_UUID")
  [ -n "$TASKBAR_UUID" ]     && enable_uuids+=("$TASKBAR_UUID")
  [ -n "$BLUR_SHELL_UUID" ]  && enable_uuids+=("$BLUR_SHELL_UUID")
  enable_uuids+=("$GSCONNECT_UUID")

  local disable_uuids=("$UBUNTU_DOCK_UUID")

  if [ "${#enable_uuids[@]}" -eq 0 ] && [ "${#disable_uuids[@]}" -eq 0 ]; then
    return
  fi

  if command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
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

  if command -v gnome-extensions >/dev/null 2>&1; then
    for uuid in "${enable_uuids[@]}"; do
      [ -n "$uuid" ] && gnome-extensions enable "$uuid" >/dev/null 2>&1 || true
    done
    for uuid in "${disable_uuids[@]}"; do
      [ -n "$uuid" ] && gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    done
  fi

  echo "[GNOME] Ensured ArcMenu, App Icons Taskbar, Blur my Shell, and GSConnect are ENABLED, Ubuntu Dock is DISABLED."
}

enable_gnome_layout_extensions

#--------------------------------------
# Done
#--------------------------------------
info_popup "BenjiOS setup is complete.\n\nArcMenu, App Icons Taskbar, Blur my Shell and GSConnect have been installed, configured, and ACTIVATED for the BenjiOS layout.\n\nrEFInd (if selected) was configured using a config from the repo.\n\nA reboot is STRONGLY recommended so GNOME and rEFInd fully pick up the new configuration."

if zenity --question --title="BenjiOS Installer" \
    --width="$ZENITY_W" --height=220 \
    --text="Reboot now to finalize the BenjiOS layout and rEFInd configuration (strongly recommended)?"; then
  run_sudo reboot
fi

exit 0
