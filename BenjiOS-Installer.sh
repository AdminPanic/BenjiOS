#!/usr/bin/env bash
set -e

########################################
# BenjiOS Installer for Ubuntu Desktop
# Target: Ubuntu 25.10 (Questing Quokka)
########################################

########################################
# CONFIG SWITCHES
########################################

# Set this to "false" if you run this on a non-AMD GPU system
AMD_GPU=true

# Set this to "false" if you do NOT want rEFInd installed/configured
INSTALL_REFIND=true

########################################
# Sanity
########################################

if [ "$EUID" -eq 0 ]; then
  echo "Please do NOT run as root. Run this script as your normal user."
  exit 1
fi

DESKTOP_DIR="$HOME/Desktop"
mkdir -p "$DESKTOP_DIR"

echo "==> Updating system packages (apt)"
sudo apt update
sudo apt full-upgrade -y

echo "==> Enabling 32-bit architecture (for gaming / Proton / Wine)"
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install -y libxkbcommon-x11-0:i386

echo "==> Installing debconf-utils (for noninteractive EULA handling)"
sudo apt install -y debconf-utils

echo "==> Pre-seeding Microsoft fonts EULA for ubuntu-restricted-extras"
echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | sudo debconf-set-selections || true
echo 'ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note'       | sudo debconf-set-selections || true

########################################
# Desktop, Office, Network, GNOME core
########################################

echo "==> Installing desktop basics, Office, network tools, GNOME utilities"
sudo apt install -y \
  gnome-tweaks \
  gvfs-backends \
  nautilus-share \
  bluez-obexd \
  libreoffice \
  thunderbird \
  remmina remmina-plugin-rdp remmina-plugin-secret \
  openvpn \
  network-manager-openvpn-gnome \
  vlc \
  rhythmbox \
  ubuntu-restricted-extras \
  gnome-shell-extensions \
  gir1.2-gmenu-3.0 \
  gnome-menus \
  power-profiles-daemon \
  fwupd

########################################
# Gaming / Performance / Monitoring
########################################

echo "==> Installing gaming and performance tools"
sudo apt install -y \
  mesa-utils \
  vulkan-tools \
  gamemode \
  mangohud

echo "==> Installing monitoring, sensors, fancontrol, SMART"
sudo apt install -y \
  lm-sensors \
  fancontrol \
  irqbalance \
  btop \
  nvtop \
  s-tui \
  smartmontools

if [ "$AMD_GPU" = true ]; then
  echo "==> Installing AMD-specific GPU tools"
  sudo apt install -y radeontop
fi

echo "==> Enabling irqbalance service"
sudo systemctl enable --now irqbalance

########################################
# Backups & Git
########################################

echo "==> Installing backup tools & Git"
sudo apt install -y \
  timeshift \
  deja-dup \
  borgbackup \
  git

########################################
# GSConnect (phone integration)
########################################

echo "==> Installing GSConnect (phone integration)"
sudo apt install -y \
  gnome-shell-extension-gsconnect \
  gnome-shell-extension-gsconnect-browsers

########################################
# Flatpak + Flathub
########################################

echo "==> Setting up Flatpak + Flathub"
sudo apt install -y flatpak gnome-software-plugin-flatpak

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

echo "==> Installing Flatpak apps (fresh, current versions)"
flatpak install -y flathub \
  com.mattjakeman.ExtensionManager \
  com.valvesoftware.Steam \
  com.heroicgameslauncher.hgl \
  net.davidotek.pupgui2 \
  net.lutris.Lutris \
  org.keepassxc.KeePassXC \
  com.github.qarmin.czkawka \
  org.kde.digikam \
  com.github.borgbase.Vorta

########################################
# rEFInd + Theme (BsxM1) + Secure Boot Setup (optional)
########################################

if [ "$INSTALL_REFIND" = true ]; then
  echo "==> Installing rEFInd boot manager (with Secure Boot local keys)"
  sudo apt install -y refind shim-signed mokutil

  sudo refind-install \
    --shim /usr/lib/shim/shimx64.efi.signed \
    --localkeys

  sudo mokutil --import /etc/refind.d/keys/refind_local.cer || true

  ESP="/boot/efi"
  REFIND_DIR="$ESP/EFI/refind"
  THEME_DIR="$REFIND_DIR/themes/refind-bsxm1-theme"


  echo "==> Cloning BsxM1 theme into $THEME_DIR"
  sudo mkdir -p "$THEME_DIR"
  if [ ! -d "$THEME_DIR/.git" ]; then
    sudo git clone https://github.com/AlexFullmoon/refind-bsxm1-theme "$THEME_DIR"
  fi

  echo "==> Writing theme.conf with correct paths"
  sudo tee "$THEME_DIR/theme.conf" >/dev/null << 'EOF'
# BsxM1 OpenCanopy theme by BlackOSX (ported to rEFInd by AlexFullmoon)

# 256px icons
icons_dir themes/refind-bsxm1-theme/icons256
big_icon_size 256
selection_big themes/refind-bsxm1-theme/icons256/selection-big.png

# Small icons (48px)
small_icon_size 48
selection_small themes/refind-bsxm1-theme/icons128/selection-small-circle.png

# Background
banner themes/refind-bsxm1-theme/bg_black.png

# Font
font themes/refind-bsxm1-theme/fonts/source-code-pro-extralight-14.png
EOF

  echo "==> Writing refind.conf base config"
  sudo tee "$REFIND_DIR/refind.conf" >/dev/null << 'EOF'
# Auto-generated by BenjiOS Installer (benjios-installer.sh)

timeout 10
use_nvram false
resolution max

enable_mouse
mouse_size 16
mouse_speed 6

# Clean tools row
showtools

# Avoid duplicate boot entries (keep things clean)
dont_scan_files grubx64.efi, fwupx64.efi

# Load BsxM1 theme
include themes/refind-bsxm1-theme/theme.conf

EOF

fi

########################################
# GNOME Shell extensions: ArcMenu + Dash to Panel (user scope)
########################################

echo "==> Installing ArcMenu + Dash to Panel (user extensions)"

EXT_BASE="$HOME/.local/share/gnome-shell/extensions"
mkdir -p "$EXT_BASE"

# Dash to Panel
DTP_UUID="dash-to-panel@jderose9.github.com"
DTP_DIR="$EXT_BASE/$DTP_UUID"

if [ ! -d "$DTP_DIR" ]; then
  echo "   -> Cloning Dash to Panel into $DTP_DIR"
  git clone https://github.com/home-sweet-gnome/dash-to-panel.git "$DTP_DIR"
  if [ -d "$DTP_DIR/schemas" ]; then
    glib-compile-schemas "$DTP_DIR/schemas" || true
  fi
fi

# ArcMenu
ARC_UUID="arcmenu@arcmenu.com"
ARC_DIR="$EXT_BASE/$ARC_UUID"

if [ ! -d "$ARC_DIR" ]; then
  echo "   -> Cloning ArcMenu into $ARC_DIR"
  git clone https://gitlab.com/arcmenu/ArcMenu.git "$ARC_DIR"
  if [ -d "$ARC_DIR/schemas" ]; then
    glib-compile-schemas "$ARC_DIR/schemas" || true
  fi
fi

########################################
# GNOME Shell – enable Dash to Panel + ArcMenu, disable Ubuntu Dock
########################################

echo "==> Enabling Dash to Panel + ArcMenu and disabling Ubuntu Dock"

if command -v gnome-extensions >/dev/null 2>&1; then
  # Disable Ubuntu Dock (so Dash to Panel is the only panel)
  if gnome-extensions list | grep -q 'ubuntu-dock@ubuntu.com'; then
    gnome-extensions disable ubuntu-dock@ubuntu.com || true
  fi

  echo "   -> Enabling Dash to Panel ($DTP_UUID)"
  gnome-extensions enable "$DTP_UUID" || true

  echo "   -> Enabling ArcMenu ($ARC_UUID)"
  gnome-extensions enable "$ARC_UUID" || true
else
  echo "WARNING: gnome-extensions CLI not found; cannot auto-enable extensions."
fi

########################################
# GNOME appearance & power profile
########################################

echo "==> Setting GNOME appearance: dark theme, green accent, performance mode"

# Prefer dark mode
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true

# Dark GTK theme for legacy apps
gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' || true

# Accent color: green (Ubuntu 24.10+/25.x)
gsettings set org.gnome.desktop.interface accent-color 'green' || true

# Power profile: Performance (uses power-profiles-daemon)
if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set performance || true
fi

########################################
# Extra updates: Flatpak, firmware, snaps
########################################

echo "==> Updating Flatpak apps"
flatpak update -y || true

if command -v fwupdmgr >/dev/null 2>&1; then
  echo "==> Checking firmware updates via fwupd"
  sudo fwupdmgr refresh --force || true
  sudo fwupdmgr get-updates      || true
  sudo fwupdmgr update -y        || true
fi

if command -v snap >/dev/null 2>&1; then
  echo "==> Refreshing Snap packages"
  sudo snap refresh || true
fi

########################################
# GUI CHECKLIST on Desktop
########################################

cat > "$DESKTOP_DIR/POST_INSTALL_GUI_STEPS.txt" << 'EOF'
Ubuntu 25.10 – Post-Install GUI Checklist (BenjiOS)
===================================================

This file is your “after install” checklist once benjios-installer.sh has finished.

1. Login Session, Displays & VRR
--------------------------------
1. At the login screen:
   - Click the gear icon and select “Ubuntu (Wayland)” for proper VRR and modern GNOME behavior.
2. In Settings → Displays:
   - Set the center monitor as Primary.
   - Arrange the side monitors to match the physical layout (portrait left, etc.).
   - Gaming monitor:
     - 2560x1440 @ 100 Hz
     - Enable “Variable Refresh Rate (VRR)” if available.

2. Windows-like Desktop (Dash to Panel + ArcMenu)
-------------------------------------------------
Already done by script:
  - Ubuntu Dock disabled.
  - Dash to Panel + ArcMenu installed and enabled.

Now just customize:

1. Dash to Panel:
   - Right-click on the panel → “Dash to Panel Settings”.
   - Position: Bottom.
   - Panel size: e.g. 32–40 px.
   - Optional: enable “Intellihide” so the bar hides in fullscreen games.
2. ArcMenu:
   - Right-click the ArcMenu icon → “ArcMenu Settings”.
   - Choose a layout (Windows 10/11 style, Whisker, etc.).
   - Make sure ArcMenu sits on the left side of the panel.

(Once you’re happy, you can export your layout with:
  dconf dump /org/gnome/shell/extensions/dash-to-panel/ > dash-to-panel.dconf
  dconf dump /org/gnome/shell/extensions/arcmenu/       > arcmenu.dconf
and later we can hard-bake those into the installer.)

3. Online Accounts & Cloud
--------------------------
1. Settings → Online Accounts:
   - Add your Google account:
     - Enable Mail, Calendar, Contacts, Files (Drive).
   - Add your Microsoft / Exchange / Office 365 account.
2. Files (Nautilus):
   - “Google Drive” should appear in the sidebar.
3. Synology NAS (SMB):
   - Files → “Other Locations” → “Connect to Server”:
     - smb://YOUR-NAS-NAME-OR-IP/YOUR_SHARE
   - Save credentials and add as a bookmark.

4. Phone Integration (GSConnect + KDE Connect)
----------------------------------------------
1. Ensure GSConnect is active:
   - Look for it in the system menu / top bar.
2. On Android:
   - Install “KDE Connect” from Play Store / F-Droid.
3. Pair phone ↔ PC:
   - Test sending a file both ways.
   - Optionally allow notifications, clipboard sync, SMS.
4. Bluetooth file transfer:
   - Settings → Bluetooth:
     - Turn Bluetooth on.
     - Pair your phone.
   - Use “Send/Receive Files” via Bluetooth (bluez-obexd is installed).

5. Gaming: Steam, Heroic, Lutris, Proton-GE, MangoHud, GameMode
----------------------------------------------------------------
1. Steam (Flatpak):
   - Log in.
   - Settings → Steam Play:
     - Enable for supported and all other titles.
   - Use ProtonUp-Qt (Flatpak) to install Proton-GE and select it per-game.
2. Heroic Games Launcher (Flatpak):
   - Log in to Epic / GOG / Amazon.
   - Point games to your preferred library locations.
3. Lutris (Flatpak):
   - Use for non-Steam titles, emulators, and custom Wine setups.
4. MangoHud + GameMode for Steam games:
   - In Steam → game → Properties → Launch options:
     gamemoderun mangohud %command%

6. Backups (Timeshift, Déjà Dup, Vorta/Borg)
--------------------------------------------
1. Timeshift:
   - Start Timeshift.
   - Select RSYNC mode.
   - Protect your root partition.
   - Enable scheduled snapshots (e.g. daily, plus before major upgrades).
2. “Backups” (Déjà Dup):
   - Start the “Backups” app.
   - Backup your home folder.
   - Set destination to your NAS or an external drive.
   - Enable schedule (daily/weekly).
3. Vorta (Flatpak):
   - Create a Borg repository on your NAS or external SSD.
   - Configure encrypted, deduplicated backups for important data.

7. Photos, Passwords & Cleanup
------------------------------
1. KeePassXC (Flatpak):
   - Open or create your password database.
   - Enable browser integration if you want auto-fill.
2. digiKam (Flatpak):
   - Add collections:
     - Local picture folders (e.g. ~/Pictures).
     - NAS shares (mounted via SMB).
   - Use tags, albums, and face recognition as needed.
3. Czkawka (Flatpak):
   - Scan for duplicate files, large files, and junk on your SSDs and NAS.
   - Carefully review before deleting.

8. rEFInd – After First Reboot (if enabled)
-------------------------------------------
1. On the first reboot after running the script, the “MOK Manager” screen appears:
   - Choose “Enroll MOK”.
   - Select refind_local.cer.
   - Enter the password you set when mokutil ran.
   - Reboot again.
2. You should now see rEFInd as your boot menu, using the BsxM1 theme.

9. Application Overview (what all this stuff does)
--------------------------------------------------
Core desktop:
- Settings – Configure displays, sound, power, online accounts, users, etc.
- Ubuntu Software / App Center – Install and update GUI applications (including Flatpak via plugin).
- Files (Nautilus) – File manager for local disks, NAS shares, and Google Drive.
- Terminal – Command-line shell for advanced tasks.
- GNOME Tweaks – Extra desktop options (titlebar buttons, fonts, themes, etc.).
- Extensions (built-in GNOME app) – Manage system GNOME Shell extensions.
- Extension Manager (Flatpak) – Browse and manage GNOME Shell extensions from Flathub.

Office, mail, remote access:
- LibreOffice Writer/Calc/Impress/etc. – Office suite for documents, spreadsheets, and presentations.
- Thunderbird – Email client for your GMX, Exchange, and Google mail accounts.
- Remmina – Remote desktop client for RDP, VNC, SSH and more.
- OpenVPN + NetworkManager OpenVPN plugin – Lets you configure VPN connections in Settings → Network.

Media & browsing:
- Firefox (default Ubuntu browser) – Web browsing, streaming, web apps.
- VLC – Video player for basically any media format.
- Rhythmbox – Music player and library manager.

Gaming:
- Steam (Flatpak) – Main PC gaming platform (Steam store + Proton).
- Heroic Games Launcher (Flatpak) – Games from Epic, GOG, Amazon/Prime, etc.
- Lutris (Flatpak) – Unified launcher for games from many sources, including emulators and Wine setups.
- ProtonUp-Qt (Flatpak) – Manage custom Proton-GE and Wine-GE versions for better compatibility.
- Gamemode – Temporary system performance boost when launched via “gamemoderun”.
- MangoHud – On-screen overlay with FPS, frametime, and hardware stats.

Backups & storage:
- Timeshift – System-level snapshots (for rolling back after bad updates).
- Backups (Déjà Dup) – Simple scheduled backups of your home folder to NAS/external drives.
- BorgBackup – Advanced backup engine (used by Vorta) with deduplication and encryption.
- Vorta (Flatpak) – GUI for BorgBackup; handles schedules and multiple backup sets.
- smartmontools (smartctl) – Check SSD/HDD health and SMART status.

Photos, passwords, cleanup:
- digiKam (Flatpak) – Powerful photo organizer for local and NAS libraries.
- KeePassXC (Flatpak) – Password manager storing encrypted password databases locally or on NAS.
- Czkawka (Flatpak) – Cleanup tool to find duplicate / large / unnecessary files.

Monitoring, sensors, fans:
- btop – Terminal-based system monitor (CPU, RAM, disk, processes).
- s-tui – Terminal CPU usage/temperature monitor and stress tester.
- nvtop – GPU usage monitor (for GPUs supported by the Mesa/DRM stack).
- radeontop (if AMD_GPU=true) – Detailed AMD GPU usage / stats.
- lm-sensors – Reads temperature and voltage sensors.
- fancontrol – CLI tools to experiment with fan behavior (main curves still in BIOS/UEFI).
- irqbalance – Automatically spreads IRQ load across CPU cores.

Integration & misc:
- GSConnect – Integrates your Android phone (KDE Connect app) with GNOME.
- BlueZ / bluez-obexd – Bluetooth stack + file transfer support.
- rEFInd – EFI boot manager with a nice theme for multi-boot setups.
- Flatpak – Sandbox packaging system for apps from Flathub.
- fwupd – Firmware updater for BIOS/UEFI, SSDs, and some peripherals.

10. Optional Fine-Tuning
------------------------
- GNOME Tweaks:
  - Enable minimize/maximize buttons.
  - Adjust fonts, cursor, and themes.
- Sound:
  - Choose your default output (speakers, headset) and input (microphone).
- Power:
  - Adjust screen blanking and suspend behavior to match your gaming/office habits.
- Drivers:
  - For special hardware or NVIDIA GPUs, open “Software & Updates → Additional Drivers”.

EOF

echo "==> Done. A reboot is recommended. After reboot, follow POST_INSTALL_GUI_STEPS.txt on your Desktop."
