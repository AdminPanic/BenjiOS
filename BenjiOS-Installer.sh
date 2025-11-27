#!/bin/bash
# BenjiOS-Installer.sh - Ubuntu 25.10 post-install configuration script

# Exit immediately if a command exits with a non-zero status (except where we handle errors manually)
set -o errexit
set -o pipefail

# Use noninteractive mode for apt to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Zenity will be used for GUI prompts. Ensure Zenity is installed.
if ! command -v zenity >/dev/null 2>&1; then
    echo "Zenity not found. Installing zenity..."
    sudo apt-get update -y && sudo apt-get install -y zenity
fi

# License acceptance prompt
zenity --question --width=400 --title="License Agreement" \
       --text="This script will install various software. By proceeding, you acknowledge that you agree to the licenses of all included software (e.g. Ubuntu, rEFInd, Steam, Heroic, Lutris, etc.). Do you wish to continue?"
if [[ $? -ne 0 ]]; then
    # User chose "No"
    zenity --info --width=300 --text="Installation canceled. No changes were made."
    exit 0
fi

# Ask if user wants to install rEFInd boot manager
INSTALL_REFIND=$(zenity --list --radiolist --width=400 --height=250 \
    --title="rEFInd Installation" --text="Install rEFInd UEFI Boot Manager?" \
    --column="Select" --column="Option" \
    TRUE "Yes, install rEFInd boot manager" FALSE "No, skip rEFInd")
REFIND_MODE=""  # will hold boot configuration mode if rEFInd is installed
if [[ "$INSTALL_REFIND" == "Yes, install rEFInd boot manager" ]]; then
    # If yes, ask about system boot configuration
    REFIND_MODE=$(zenity --list --radiolist --width=420 --height=240 \
        --title="rEFInd Configuration" --text="Select your system's boot configuration for rEFInd:" \
        --column="Select" --column="Boot Setup" \
        TRUE "Single boot (Ubuntu only)" FALSE "Dual boot (Ubuntu + Windows)" FALSE "Show all entries (no filtering)")
fi

# Ask about Monitoring Stack
INSTALL_MON=$(zenity --question --width=400 --title="Monitoring Tools" \
    --text="Install system monitoring tools (resource monitors, sensors, etc.)?" && echo "Yes" || echo "No")

# Ask about Gaming Stack
INSTALL_GAMING=$(zenity --question --width=400 --title="Gaming Stack" \
    --text="Install Gaming Stack (Steam, Lutris, Heroic, ProtonUp-Qt, MangoHud, GameMode, etc.)?" && echo "Yes" || echo "No")

# Ask about Additional Tools
INSTALL_TOOLS=$(zenity --question --width=400 --title="Additional Tools" \
    --text="Install additional desktop tools (digiKam, KeePassXC, VLC, Rhythmbox, OpenVPN, Thunderbird)?" && echo "Yes" || echo "No")

# Ask about Remote Management
INSTALL_REMOTE=$(zenity --question --width=400 --title="Remote Management" \
    --text="Enable Remote Management features (SSH, Firewall rule, RDP, Wake-on-LAN)?" && echo "Yes" || echo "No")

# Begin installation steps
sudo apt-get update -y

# 1. rEFInd Boot Manager Installation and Configuration
if [[ "$INSTALL_REFIND" == "Yes, install rEFInd boot manager" ]]; then
    echo "Installing rEFInd UEFI boot manager..."
    sudo apt-get install -y refind
    
    # Mount the EFI System Partition if not already (usually /boot/efi is mounted on Ubuntu)
    if ! mountpoint -q /boot/efi; then
        echo "Mounting EFI System Partition..."
        EFI_PART=$(sudo blkid -t PARTLABEL="EFI System" -o device | head -n1)
        if [[ -n "$EFI_PART" ]]; then
            sudo mount "$EFI_PART" /boot/efi
        fi
    fi

    # Copy custom rEFInd config and theme
    echo "Applying custom rEFInd configuration and theme..."
    sudo mkdir -p /boot/efi/EFI/refind/themes/bsmx
    # Download refind.conf from repo
    sudo wget -qO /boot/efi/EFI/refind/refind.conf "${RAW_BASE:-https://raw.githubusercontent.com/YourGitHubUser/BenjiOS-Installer/main}/refind/refind.conf"
    # Download theme files (theme.conf and images)
    sudo wget -qO /boot/efi/EFI/refind/themes/bsmx/theme.conf "${RAW_BASE:-https://raw.githubusercontent.com/YourGitHubUser/BenjiOS-Installer/main}/refind/theme.conf"
    # Download all theme assets (icons, backgrounds, selection images) from the repository
    # (Assuming assets are packaged in a zip for convenience)
    sudo wget -qO /tmp/bsmx_theme.zip "${RAW_BASE:-https://raw.githubusercontent.com/YourGitHubUser/BenjiOS-Installer/main}/refind/BSxM1_theme.zip"
    sudo unzip -o /tmp/bsmx_theme.zip -d /boot/efi/EFI/refind/themes/bsmx/
    sudo rm -f /tmp/bsmx_theme.zip

    # Adjust rEFInd config based on user selection
    if [[ "$REFIND_MODE" == "Single boot (Ubuntu only)" ]]; then
        # Single boot: hide other OS entries (like Windows) if any were present
        sudo sed -i 's/^timeout.*/timeout 5/' /boot/efi/EFI/refind/refind.conf   # faster boot (5s timeout)
        # (No Windows expected, but we ensure quick timeout)
    elif [[ "$REFIND_MODE" == "Dual boot (Ubuntu + Windows)" ]]; then
        # Dual boot: ensure Windows is visible (already handled by default config)
        sudo sed -i 's/^timeout.*/timeout 10/' /boot/efi/EFI/refind/refind.conf  # 10s timeout for menu
        # Already not hiding Windows bootmgr in config, no further action needed
    elif [[ "$REFIND_MODE" == "Show all entries (no filtering)" ]]; then
        # Show all boot entries: do not hide any loaders (including grub or fwupd)
        sudo sed -i 's/^dont_scan_files/#dont_scan_files/' /boot/efi/EFI/refind/refind.conf
        # Optionally enable scanning firmware entries:
        sudo sed -i 's/^#scanfor.*/scanfor internal,external,optical,manual,firmware/' /boot/efi/EFI/refind/refind.conf
        sudo sed -i 's/^timeout.*/timeout 15/' /boot/efi/EFI/refind/refind.conf  # give more time if many entries
    fi
fi

# 2. Monitoring Stack Installation
if [[ "$INSTALL_MON" == "Yes" ]]; then
    echo "Installing monitoring tools..."
    sudo apt-get install -y htop glances btop lm-sensors psensor
    # Configure sensors (non-interactively accept defaults where possible)
    sudo yes | sensors-detect || true  # sensors-detect might prompt; we auto-confirm safe defaults
fi

# 3. Gaming Stack Installation
if [[ "$INSTALL_GAMING" == "Yes" ]]; then
    echo "Installing gaming stack..."
    # Enable 32-bit architecture for gaming libs if not already
    sudo dpkg --add-architecture i386 && sudo apt-get update -y
    # Install core gaming components via APT
    sudo apt-get install -y steam gamemode mangohud
    # Use Lutris PPA for latest Lutris
    sudo add-apt-repository -y ppa:lutris-team/lutris
    sudo apt-get update -y
    sudo apt-get install -y lutris

    # Install Flatpak and Flathub if not already
    if ! command -v flatpak >/dev/null 2>&1; then
        sudo apt-get install -y flatpak gnome-software-plugin-flatpak
        sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    # Install Flatpak apps for gaming
    flatpak install -y flathub com.heroicgameslauncher.hgl   # Heroic Games Launcher
    flatpak install -y flathub net.davidotek.pupgui2         # ProtonUp-Qt
    # (Lutris is installed via apt; Steam via apt as well)

    # Configure MangoHud and GameMode (if any config needed, e.g. enable GameMode globally)
    # Ensure GameMode daemon is running
    systemctl --user enable gamemoded --now || true
fi

# 4. Additional Tools Installation
if [[ "$INSTALL_TOOLS" == "Yes" ]]; then
    echo "Installing additional productivity tools..."
    sudo apt-get install -y digikam keepassxc vlc rhythmbox openvpn thunderbird
    # Ensure OpenVPN support in NetworkManager
    sudo apt-get install -y network-manager-openvpn network-manager-openvpn-gnome
fi

# 5. Remote Management Setup
if [[ "$INSTALL_REMOTE" == "Yes" ]]; then
    echo "Enabling remote management features..."
    # SSH Service
    sudo apt-get install -y openssh-server
    sudo systemctl enable ssh --now

    # Firewall (UFW) setup: allow SSH (port 22) and RDP (port 3389)
    if sudo ufw status | grep -q "Status: inactive"; then
        sudo ufw allow 22/tcp
        sudo ufw allow 3389/tcp
        sudo ufw --force enable
    else
        sudo ufw allow 22/tcp
        sudo ufw allow 3389/tcp
    fi

    # RDP Service (using xrdp for separate login session)
    sudo apt-get install -y xrdp
    sudo systemctl enable xrdp --now
    sudo adduser xrdp ssl-cert  # allow xrdp to use certificates for encryption
    # (Alternatively, Ubuntu 25.10 has built-in GNOME Remote Desktop for RDP which can be enabled via Settings UI)

    # Wake-on-LAN configuration
    sudo apt-get install -y ethtool
    # Enable WOL on all wired interfaces now and persist via NetworkManager
    for IFACE in $(ls /sys/class/net | grep -v -E '^lo|^vbox'); do
        # Set WOL to "magic packet" for each interface
        sudo ethtool -s "$IFACE" wol g || true
    done
    # Persist WOL via NetworkManager connections
    nmcli -t -f UUID,DEVICE,TYPE connection show | awk -F: '$3=="ethernet"{print $1}' | while read -r UUID; do
        nmcli connection modify "$UUID" 802-3-ethernet.wake-on-lan magic || true
    done

    # Prevent NIC power-down on shutdown (so WOL still works)
    if [[ -f /etc/default/halt ]]; then
        sudo sed -i 's/^NETDOWN=.*/NETDOWN=no/' /etc/default/halt || echo "NETDOWN=no" | sudo tee -a /etc/default/halt
    else
        echo "NETDOWN=no" | sudo tee /etc/default/halt >/dev/null
    fi
    # If TLP (power management) is installed, ensure WOL is not disabled by it
    if [[ -f /etc/default/tlp ]]; then
        sudo sed -i 's/^WOL_DISABLE=.*/WOL_DISABLE=N/' /etc/default/tlp
    fi
fi

# 6. GNOME Shell Extensions and UI Config (ArcMenu, Dash-to-Panel)
echo "Configuring GNOME Shell UI (ArcMenu and Dash-to-Panel extensions)..."
# Install extensions via apt if available
sudo apt-get install -y gir1.2-gmenu-3.0 gnome-shell-extension-arc-menu gnome-shell-extension-dash-to-panel || true
# Load extension settings from provided config files
dconf load /org/gnome/shell/extensions/arc-menu/ < <(wget -qO- "${RAW_BASE:-https://raw.githubusercontent.com/YourGitHubUser/BenjiOS-Installer/main}/configs/arcmenu.conf")
dconf load /org/gnome/shell/extensions/dash-to-panel/ < <(wget -qO- "${RAW_BASE:-https://raw.githubusercontent.com/YourGitHubUser/BenjiOS-Installer/main}/configs/app-icons-taskbar.conf")

# 7. Clean-up
echo "Cleaning up..."
sudo apt-get autoremove -y
sudo apt-get autoclean -y
# Clear any temporary files if created
rm -f /tmp/bsmx_theme.zip 2>/dev/null

zenity --info --width=300 --title="BenjiOS Installer" \
       --text="Installation complete! Some changes may require a reboot (especially rEFInd installation and GNOME extensions). Please reboot your system to apply all changes."
