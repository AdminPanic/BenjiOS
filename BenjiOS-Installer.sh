#!/usr/bin/env bash
set -Eeuo pipefail

# Cosmetic: silence noisy Mesa / libEGL warnings from GTK/Zenity
export LIBGL_DEBUG=quiet
export MESA_DEBUG=silent
export EGL_LOG_LEVEL=error

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
ZENITY_H=640

# Filled when we install GNOME extensions (to hold their UUIDs)
ARCMENU_UUID=""
TASKBAR_UUID=""
BLUR_SHELL_UUID=""

# rEFInd boot mode: single (Ubuntu only), dual (Ubuntu + Windows), all (show everything)
REFIND_BOOT_MODE="dual"

# Extra GNOME extensions explicitly managed
GSCONNECT_UUID="gsconnect@andyholmes.github.io"
UBUNTU_DOCK_UUID="ubuntu-dock@ubuntu.com"

# GPU detection flags
AMD_GPU_DETECTED=false
NVIDIA_GPU_DETECTED=false
INTEL_GPU_DETECTED=false

# Virtualization detection flags
VIRT_TYPE="none"
IS_VIRT=false
IS_KVM=false        # includes Proxmox/QEMU (kvm or qemu)
IS_VMWARE=false
IS_VBOX=false       # VirtualBox
IS_HYPERV=false     # Hyper-V

#--------------------------------------
# Small helper: non-blocking info popup
#--------------------------------------
info_popup() {
    local msg="$1"
    zenity --info --timeout=5 \
           --title="BenjiOS Installer" \
           --width="$ZENITY_W" --height=200 \
           --text="$msg" >/dev/null 2>&1 || true
}

#--------------------------------------
# Basic sanity checks and prep
#--------------------------------------
if [ "$EUID" -eq 0 ]; then
    echo "Please do NOT run this script as root."
    echo "Run it as your normal user (with sudo privileges)."
    exit 1
fi

# Auto-install zenity if missing (first sudo will prompt in terminal if needed)
if ! command -v zenity >/dev/null 2>&1; then
    echo "[BenjiOS] 'zenity' not found – installing it now (sudo prompt may appear in terminal)…"
    sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y zenity
fi

# ---- add this wrapper immediately after the block above ----
# Wrap zenity so its noisy GPU/Mesa warnings don't spam the terminal.
# All stderr from zenity goes to /dev/null, but the script's own errors/logs stay visible.
ZENITY_BIN="$(command -v zenity || echo /usr/bin/zenity)"
zenity() {
    "$ZENITY_BIN" "$@" 2>/dev/null
}
export -f zenity
# ---- end wrapper ----

# Ensure Desktop directory exists
mkdir -p "$DESKTOP_DIR"

# Set non-interactive for all apt/apt-get usage in this script
export DEBIAN_FRONTEND=noninteractive

# Trap any unexpected errors to notify user and exit gracefully
trap 'zenity --error --title="BenjiOS Installer" --width="$ZENITY_W" --height=150 --text="Installation encountered an error and cannot continue."; sudo -k; exit 1' ERR

#--------------------------------------
# License Agreement Dialog
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
# Sudo via Zenity (one-time password entry)
#--------------------------------------
SUDO_PASS="$(zenity --password --title='BenjiOS Installer – sudo access' --width="$ZENITY_W" --height=200)"
if [ -z "$SUDO_PASS" ]; then
    zenity --error --title="BenjiOS Installer" \
           --width="$ZENITY_W" --height=200 \
           --text="No password entered.\nExiting."
    exit 1
fi

# Verify sudo password (this will cache the credentials)
if ! printf '%s\n' "$SUDO_PASS" | sudo -S -v >/dev/null 2>&1; then
    zenity --error --title="BenjiOS Installer" \
           --width="$ZENITY_W" --height=200 \
           --text="Incorrect sudo password.\nExiting."
    exit 1
fi

# Drop the password from memory as soon as possible
unset SUDO_PASS

# Define helper functions for sudo usage (no password needed now due to cached timestamp)
run_sudo() {
    sudo "$@"
}
run_sudo_apt() {
    sudo DEBIAN_FRONTEND=noninteractive "$@"
}

# Optional: prolong sudo timestamp periodically (not strictly necessary if script finishes quickly)
# run_sudo -v

#--------------------------------------
# Helper: backup file with timestamp
#--------------------------------------
backup_file() {
    local target="$1"
    if [ -f "$target" ]; then
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        run_sudo cp -p "$target" "${target}.bak.${ts}"
    fi
}

#--------------------------------------
# Helper: find mounted EFI System Partition (ESP)
#--------------------------------------
find_esp() {
    local candidates=( /boot/efi /boot/EFI /efi )
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
# Helper: GNOME appearance + power profile
#--------------------------------------
configure_gnome_theme_and_power() {
    if ! command -v gsettings >/dev/null 2>&1; then
        echo "[THEME] 'gsettings' not found – skipping desktop theming." >&2
        return
    fi

    local IF_SCHEMA="org.gnome.desktop.interface"
    echo "[THEME] Applying BenjiOS GNOME look (dark theme + olive accent)…"

    # Dark mode
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
    if gsettings writable org.gnome.shell.ubuntu color-scheme; then
        gsettings set org.gnome.shell.ubuntu color-scheme 'dark' || true
    fi

    # GTK theme, icons, WM theme, sound theme
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-olive-dark' || true
    gsettings set org.gnome.desktop.interface icon-theme 'Yaru-olive-dark' || true
    gsettings set org.gnome.desktop.wm.preferences theme 'Yaru-olive-dark' || true
    gsettings set org.gnome.desktop.sound theme-name 'Yaru' || true

    # Accent color (if supported)
    if gsettings range org.gnome.desktop.interface accent-color >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface accent-color 'olive' || true
        # Apply through Yaru Colors switcher if available
        if [ -x /usr/libexec/yaru-colors-switcher ]; then
            /usr/libexec/yaru-colors-switcher --color olive --theme dark || true
        elif [ -x /usr/lib/yaru-colors-switcher ]; then
            /usr/lib/yaru-colors-switcher --color olive --theme dark || true
        fi
    else
        # Fallback for older Ubuntu (no accent-color key)
        gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-olive-dark' || \
        gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-olive' || true
    fi

    # Rebuild icon caches (best effort, no harm if fails)
    [ -d "$HOME/.icons" ] && gtk-update-icon-cache "$HOME/.icons" >/dev/null 2>&1 || true
    [ -d /usr/share/icons/Yaru ] && run_sudo gtk-update-icon-cache /usr/share/icons/Yaru >/dev/null 2>&1 || true

    # Set power profile to Performance if available
    if command -v powerprofilesctl >/dev/null 2>&1; then
        if powerprofilesctl list 2>/dev/null | grep -q "performance"; then
            powerprofilesctl set performance >/dev/null 2>&1 || true
        fi
    fi
}

#--------------------------------------
# Helpers: GNOME extensions (ArcMenu, Taskbar, Blur My Shell)
#--------------------------------------
ensure_gnome_extension_tools() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "[GNOME] 'curl' not found; cannot install extensions." >&2
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "[GNOME] 'jq' not found; cannot install extensions." >&2
        return 1
    fi
    if ! command -v gnome-extensions >/dev/null 2>&1; then
        echo "[GNOME] 'gnome-extensions' CLI not found; cannot install extensions." >&2
        return 1
    fi
    return 0
}

install_gnome_extension_by_id() {
    local ext_id="$1"
    local label="$2"

    if ! command -v gnome-extensions >/dev/null 2>&1; then
        echo "[GNOME] ERROR: gnome-extensions CLI missing; cannot install ${label}." >&2
        return 1
    fi

    # Determine current GNOME Shell major version for extension compatibility
    local shell_ver=""
    if command -v gnome-shell >/dev/null 2>&1; then
        shell_ver="$(gnome-shell --version | awk '{print $3}' | cut -d. -f1)"
    fi

    # Fetch extension metadata
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

    if [ -z "$uuid" ] || [ "$uuid" = "null" ] || [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        echo "[GNOME] ERROR: Missing uuid or download_url in metadata for ${label}." >&2
        return 1
    fi

    if gnome-extensions list | grep -Fxq "$uuid"; then
        echo "[GNOME] ${label} already installed (uuid: ${uuid}), skipping download." >&2
    else
        echo "[GNOME] Downloading ${label} (${uuid}) from extensions.gnome.org…" >&2
        local tmpfile
        tmpfile="$(mktemp)" || {
            echo "[GNOME] ERROR: mktemp failed for ${label}." >&2
            return 1
        }

        if ! curl -fsSL "https://extensions.gnome.org${download_url}" -o "$tmpfile"; then
            echo "[GNOME] ERROR: Failed to download ${label} extension archive." >&2
            rm -f "$tmpfile"
            return 1
        fi

        echo "[GNOME] Installing ${label} extension via gnome-extensions..." >&2
        if ! gnome-extensions install --force "$tmpfile"; then
            echo "[GNOME] ERROR: gnome-extensions install failed for ${label}." >&2
            rm -f "$tmpfile"
            return 1
        fi
        rm -f "$tmpfile"
    fi

    # Disable the extension immediately after install (to avoid any interference during setup)
    if gnome-extensions info "$uuid" >/dev/null 2>&1; then
        gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
        echo "[GNOME] ${label} installed as ${uuid} and currently DISABLED (will enable at end)." >&2
    fi

    # Return the UUID (so we can capture it in a variable)
    printf '%s\n' "$uuid"
}

configure_gnome_extensions_layout() {
    echo "[GNOME] === Configuring GNOME Shell extensions (ArcMenu, Taskbar, Blur my Shell) ==="
    if ! ensure_gnome_extension_tools; then
        echo "[GNOME] Skipping GNOME extension installation due to missing tools." >&2
        return
    fi

    # Install extensions and capture their UUIDs (or blank if failed)
    ARCMENU_UUID="$(install_gnome_extension_by_id 3628 "ArcMenu" || true)"
    TASKBAR_UUID="$(install_gnome_extension_by_id 4944 "App Icons Taskbar" || true)"
    BLUR_SHELL_UUID="$(install_gnome_extension_by_id 3193 "Blur my Shell" || true)"

    # Apply pre-configured settings for each extension via dconf
    if command -v dconf >/dev/null 2>&1; then
        # ArcMenu configuration
        local arcmenu_tmp; arcmenu_tmp="$(mktemp)"
        if curl -fsSL "$RAW_BASE/configs/arcmenu.conf" -o "$arcmenu_tmp"; then
            dconf load /org/gnome/shell/extensions/arcmenu/ < "$arcmenu_tmp" 2>/dev/null || \
                echo "[GNOME] WARNING: Failed to load ArcMenu settings." >&2
        else
            echo "[GNOME] NOTE: Could not fetch arcmenu.conf; skipping ArcMenu config." >&2
        fi
        rm -f "$arcmenu_tmp"

        # App Icons Taskbar configuration
        local taskbar_tmp; taskbar_tmp="$(mktemp)"
        if curl -fsSL "$RAW_BASE/configs/app-icons-taskbar.conf" -o "$taskbar_tmp"; then
            dconf load /org/gnome/shell/extensions/aztaskbar/ < "$taskbar_tmp" 2>/dev/null || \
                echo "[GNOME] WARNING: Failed to load App Icons Taskbar settings." >&2
        else
            echo "[GNOME] NOTE: Could not fetch app-icons-taskbar.conf; skipping Taskbar config." >&2
        fi
        rm -f "$taskbar_tmp"

        # Blur My Shell configuration
        local blur_tmp; blur_tmp="$(mktemp)"
        if curl -fsSL "$RAW_BASE/configs/blur-my-shell.conf" -o "$blur_tmp"; then
            dconf load /org/gnome/shell/extensions/blur-my-shell/ < "$blur_tmp" 2>/dev/null || \
                echo "[GNOME] WARNING: Failed to load Blur My Shell settings." >&2
        else
            echo "[GNOME] NOTE: Could not fetch blur-my-shell.conf; skipping Blur My Shell config." >&2
        fi
        rm -f "$blur_tmp"
    else
        echo "[GNOME] 'dconf' not found; cannot apply GNOME extension configs." >&2
    fi

    # Place custom icon for ArcMenu's menu button (non-fatal if fails)
    local icon_target="$HOME/.local/share/icons/hicolor/48x48/apps/BenjiOS-Menu.png"
    mkdir -p "$(dirname "$icon_target")"
    if curl -fsSL "$RAW_BASE/assets/Taskbar.png" -o "$icon_target"; then
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
        fi
    else
        echo "[GNOME] NOTE: Could not fetch Taskbar.png; ArcMenu will use default icon." >&2
    fi

    echo "[GNOME] ArcMenu, App Icons Taskbar, and Blur My Shell extensions are installed (disabled for now; will be enabled at the end)."
}

enable_gnome_layout_extensions() {
    local enable_uuids=()
    local disable_uuids=()

    # Prepare list of extensions to enable (always include GSConnect)
    [ -n "$ARCMENU_UUID" ]    && enable_uuids+=("$ARCMENU_UUID")
    [ -n "$TASKBAR_UUID" ]    && enable_uuids+=("$TASKBAR_UUID")
    [ -n "$BLUR_SHELL_UUID" ] && enable_uuids+=("$BLUR_SHELL_UUID")
    enable_uuids+=("$GSCONNECT_UUID")

    # If ArcMenu + Taskbar are installed, disable Ubuntu Dock (to avoid duplicate launchers)
    if [ -n "$ARCMENU_UUID" ] && [ -n "$TASKBAR_UUID" ]; then
        disable_uuids+=("$UBUNTU_DOCK_UUID")
    else
        echo "[GNOME] WARNING: ArcMenu and/or Taskbar extension missing; Ubuntu Dock will remain enabled." >&2
    fi

    if [ "${#enable_uuids[@]}" -eq 0 ] && [ "${#disable_uuids[@]}" -eq 0 ]; then
        return 0  # nothing to do
    fi

    # Use gsettings to persist extension enable/disable states
    if command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        # Merge enable list with currently enabled extensions
        local current_enabled merged_enabled
        current_enabled="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")"
        current_enabled="${current_enabled#@as }"  # remove any GVariant type prefix
        merged_enabled="$(python3 - "$current_enabled" "${enable_uuids[@]}" << 'PYCODE'
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
PYCODE
)" || merged_enabled=""

        if [ -n "$merged_enabled" ]; then
            gsettings set org.gnome.shell enabled-extensions "$merged_enabled" 2>/dev/null || true
        fi

        # Update disabled-extensions list: first remove any that we are enabling (to avoid conflicts)
        local current_disabled cleaned_disabled final_disabled
        current_disabled="$(gsettings get org.gnome.shell disabled-extensions 2>/dev/null || echo "[]")"
        current_disabled="${current_disabled#@as }"
        cleaned_disabled="$(python3 - "$current_disabled" "${enable_uuids[@]}" << 'PYCODE'
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
PYCODE
)" || cleaned_disabled=""

        # Then add any extensions we want to disable (Ubuntu Dock) to the disabled list
        final_disabled="$(python3 - "$cleaned_disabled" "${disable_uuids[@]}" << 'PYCODE'
import ast, sys
current = sys.argv[1]
to_disable = sys.argv[2:]
try:
    arr = ast.literal_eval(current)
    if not isinstance(arr, list):
        arr = []
except Exception:
    arr = []
for u in to_disable:
    if u and u not in arr:
        arr.append(u)
print(str(arr))
PYCODE
)" || final_disabled=""

        if [ -n "$final_disabled" ]; then
            gsettings set org.gnome.shell disabled-extensions "$final_disabled" 2>/dev/null || true
        fi
    fi

    # Enable/disable via gnome-extensions (applies changes immediately in this session)
    if command -v gnome-extensions >/dev/null 2>&1; then
        for uuid in "${enable_uuids[@]}"; do
            [ -n "$uuid" ] && gnome-extensions enable "$uuid" >/dev/null 2>&1 || true
        done
        for uuid in "${disable_uuids[@]}"; do
            [ -n "$uuid" ] && gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
        done
    fi

    # Log the result
    if [ "${#disable_uuids[@]}" -gt 0 ]; then
        echo "[GNOME] Ensured extensions (ArcMenu, Taskbar, Blur My Shell, GSConnect) are ENABLED, and Ubuntu Dock is DISABLED."
    else
        echo "[GNOME] Ensured extensions (ArcMenu, Taskbar, Blur My Shell, GSConnect) are ENABLED. (Ubuntu Dock left enabled)"
    fi
}

#--------------------------------------
# Stack selection (Zenity checklist)
#--------------------------------------
STACK_SELECTION="$(zenity --list \
    --title="BenjiOS Installer – Component Selection" \
    --width="$ZENITY_W" --height="$ZENITY_H" \
    --text="Select which stacks to install.\n\nCore system tools, GPU tweaks, and VM guest integrations (based on detected hardware) are ALWAYS installed.\nYou can re-run this script later to add more stacks." \
    --checklist --separator=" " \
    --column="Install" --column="ID" --column="Description" \
    TRUE  "office"        "Office, mail, basic media, RDP client" \
    TRUE  "gaming"        "Gaming stack: Steam, Heroic, Lutris, Proton tools" \
    TRUE  "monitoring"    "Monitoring: sensors, btop, nvtop, psensor, disk health" \
    TRUE  "backup_tools"  "Backup tools: Timeshift, Déjà Dup, Borg, Vorta" \
    TRUE  "management"    "Remote management: SSH server, xRDP, firewall, WoL" \
    TRUE  "tweaks"        "Performance tweaks: zram compressed swap + earlyoom" \
    TRUE  "auto_updates"  "Automatic APT updates (unattended-upgrades)" \
    FALSE "refind"        "rEFInd boot manager with BsxM1 theme (advanced multi-boot)" \
    --extra-button="Advanced" \
)" || true

# >>> New: Advanced options handling <<<
if [ "$STACK_SELECTION" = "Advanced" ]; then
    # Open Advanced Options dialog
    ADV_TASKS="$(zenity --list \
        --title="BenjiOS Installer – Advanced Options" \
        --width="$ZENITY_W" --height="$ZENITY_H" \
        --text="Select advanced tasks to perform." \
        --checklist --separator=" " \
        --column="Run" --column="ID" --column="Description" \
        FALSE "repair_refind" "Repair rEFInd boot manager (reinstall files and ensure configured)" \
        FALSE "theme"         "Reapply BenjiOS GNOME theme and settings" \
        FALSE "update_system" "Update system packages and apps (APT, Flatpak, Snap)" \
        FALSE "change_mode"   "Change rEFInd boot display mode (single, dual, or all entries)" \
    )" || true

    if [ -z "$ADV_TASKS" ]; then
        zenity --info --title="BenjiOS Installer" \
               --width="$ZENITY_W" --height=150 \
               --text="No advanced tasks selected. Exiting."
        exit 0
    fi

    for task in $ADV_TASKS; do
        case "$task" in
            repair_refind)
                if [ ! -d /sys/firmware/efi ]; then
                    zenity --error --title="BenjiOS – Repair rEFInd" \
                           --width="$ZENITY_W" --height=150 \
                           --text="UEFI system not detected. rEFInd repair is not applicable."
                else
                    info_popup "Repairing rEFInd boot manager..."
                    esp="$(find_esp)"
                    if [ -z "$esp" ]; then
                        zenity --error --title="BenjiOS – Repair rEFInd" \
                               --width="$ZENITY_W" --height=150 \
                               --text="EFI System Partition not found. Cannot repair rEFInd."
                    else
                        run_sudo_apt apt install -y refind shim-signed mokutil
                        if command -v refind-install >/dev/null 2>&1; then
                            run_sudo refind-install || true
                        fi
                        theme_dir="$esp/EFI/refind/themes/refind-bsxm1-theme"
                        run_sudo mkdir -p "$(dirname "$theme_dir")"
                        if [ -d "$theme_dir" ]; then
                            run_sudo bash -c "cd '$theme_dir' && git pull" || true
                        else
                            run_sudo git clone --depth=1 https://github.com/AlexFullmoon/refind-bsxm1-theme.git "$theme_dir" || true
                        fi
                        refind_conf="$esp/EFI/refind/refind.conf"
                        if [ ! -f "$refind_conf" ]; then
                            run_sudo curl -fsSL "$RAW_BASE/configs/refind/refind-dual.conf" -o "$refind_conf" || true
                        fi
                        SB_STATE="$(od -An -t u1 -j 4 -N 1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $1}')"
                        if [ "$SB_STATE" = "1" ]; then
                            cert="$esp/EFI/refind/keys/refind_local.cer"
                            if [ -f "$cert" ]; then
                                MOK_PASS="$(zenity --password --title='BenjiOS – rEFInd Secure Boot' --text='Enter a password to enroll rEFInd key (you will need to confirm it on reboot):')"
                                if [ -n "$MOK_PASS" ]; then
                                    printf '%s\n%s\n' "$MOK_PASS" "$MOK_PASS" | run_sudo mokutil --import "$cert" || true
                                    unset MOK_PASS
                                    info_popup "rEFInd Secure Boot key import scheduled. Enroll key on next reboot."
                                else
                                    zenity --warning --title="BenjiOS – rEFInd Secure Boot" \
                                           --width="$ZENITY_W" --height=150 \
                                           --text="No password entered. rEFInd key enrollment skipped."
                                fi
                            else
                                zenity --warning --title="BenjiOS – rEFInd Secure Boot" \
                                       --width="$ZENITY_W" --height=150 \
                                       --text="No rEFInd Secure Boot key found to enroll. You may need to disable Secure Boot."
                            fi
                        fi
                    fi
                fi
                ;;
            theme)
                info_popup "Reapplying GNOME theme and settings..."
                configure_gnome_theme_and_power || true
                configure_gnome_extensions_layout || true
                enable_gnome_layout_extensions || true
                ;;
            update_system)
                info_popup "Updating system packages and Flatpak apps..."
                run_sudo_apt apt update
                run_sudo_apt apt -o upgrade -y
                run_sudo_apt apt autoremove -y || true
                run_sudo_apt apt clean || true
                if command -v flatpak >/dev/null 2>&1; then
                    flatpak update -y || true
                    flatpak uninstall --unused -y || true
                fi
                if command -v snap >/dev/null 2>&1; then
                    run_sudo snap refresh || true
                fi
                ;;
            change_mode)
                if [ ! -d /sys/firmware/efi ] || [ ! -d "$(find_esp)/EFI/refind" ]; then
                    zenity --error --title="BenjiOS – rEFInd Boot Mode" \
                           --width="$ZENITY_W" --height=150 \
                           --text="Cannot change rEFInd mode: rEFInd is not installed."
                else
                    esp="$(find_esp)"
                    NEW_MODE="$(zenity --list \
                        --title="BenjiOS – Change rEFInd Boot Mode" \
                        --width="$ZENITY_W" --height="$ZENITY_H" \
                        --text="Select new rEFInd boot mode:" \
                        --radiolist \
                        --column="Use" --column="ID" --column="Description" \
                        FALSE "single" "Single Boot: Ubuntu only (hide Windows entries)" \
                        FALSE "dual"   "Dual Boot: Ubuntu + Windows (hide auxiliary entries)" \
                        FALSE "all"    "Show all entries (Linux, Windows, recovery, etc.)" )"
                    if [ -n "$NEW_MODE" ]; then
                        refind_conf="$esp/EFI/refind/refind.conf"
                        backup_file "$refind_conf"
                        tmp_conf="$(mktemp)"
                        refind_src="$RAW_BASE/configs/refind/refind-$NEW_MODE.conf"
                        if curl -fsSL "$refind_src" -o "$tmp_conf"; then
                            run_sudo cp "$tmp_conf" "$refind_conf"
                        fi
                        rm -f "$tmp_conf"
                        info_popup "rEFInd boot mode changed to '$NEW_MODE'."
                    fi
                fi
                ;;
        esac
    done

    zenity --info --title="BenjiOS Installer" \
           --width="$ZENITY_W" --height=200 \
           --text="Selected advanced tasks have been completed."
    sudo -k
    exit 0
fi

if [ -z "$STACK_SELECTION" ]; then
    info_popup "No optional stacks selected.\nCore stack, GPU tweaks, and VM integrations (if supported) will still be installed."
fi

# Helper to check if a given stack ID was selected
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
        *)      UPDATES_DAYS="1" ;;  # default to daily if not specified
    esac
fi

INSTALL_REFIND=false
REFIND_ENROLL_KEY=false    # initialize flag for secure boot key enrollment
if has_stack "refind"; then
    # Only install rEFInd if running on a UEFI system
    if [ -d /sys/firmware/efi ]; then
        INSTALL_REFIND=true
        # Ask rEFInd boot mode
        REFIND_BOOT_MODE="$(zenity --list \
            --title="BenjiOS – rEFInd Boot Mode" \
            --width="$ZENITY_W" --height="$ZENITY_H" \
            --text="Choose how rEFInd should present boot entries:\n\n• Single Boot Ubuntu\n• Dual Boot Ubuntu + Windows\n• Show all detected entries" \
            --radiolist \
            --column="Use" --column="ID" --column="Description" \
            TRUE  "dual"   "Dual Boot: Ubuntu + Windows, hide auxiliary/irrelevant entries" \
            FALSE "single" "Single Boot: Ubuntu only, hide Windows entries" \
            FALSE "all"    "Show all detected entries (Linux, Windows, recovery, etc.)" \
        )" || true

        case "$REFIND_BOOT_MODE" in
            single|dual|all) ;; 
            *) REFIND_BOOT_MODE="dual" ;;
        esac

        # If Secure Boot is enabled, offer options for rEFInd installation
        if $SB_ENABLED; then
            SB_REFIND_CHOICE="$(zenity --list \
                --title="BenjiOS – rEFInd & Secure Boot" \
                --width="$ZENITY_W" --height="$ZENITY_H" \
                --text="Secure Boot is enabled. rEFInd requires additional steps to work with Secure Boot.\n\nChoose how to proceed with rEFInd installation:" \
                --radiolist \
                --column="Use" --column="ID" --column="Description" \
                FALSE "skip"    "Skip rEFInd installation (keep current bootloader)" \
                TRUE  "mok"     "Install rEFInd with Secure Boot support (enroll key via MOK on reboot)" \
                FALSE "no_mok"  "Install rEFInd without Secure Boot support (disable Secure Boot manually later)" \
            )" || true

            case "$SB_REFIND_CHOICE" in
                mok)
                    REFIND_ENROLL_KEY=true
                    ;;
                skip|"")
                    INSTALL_REFIND=false
                    ;;
                no_mok)
                    REFIND_ENROLL_KEY=false
                    ;;
            esac
        fi

    else
        zenity --warning --title="BenjiOS – rEFInd Skipped" \
               --width="$ZENITY_W" --height=150 \
               --text="rEFInd boot manager requires UEFI, but this system is not UEFI.\nSkipping rEFInd installation."
        INSTALL_REFIND=false
    fi
fi

#--------------------------------------
# Optional kisak-mesa PPA for AMD Gaming
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
    # Ensure add-apt-repository is available
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        run_sudo apt update
        run_sudo apt install -y software-properties-common
    fi
    # Only add PPA if not already present, to avoid duplicates
    if ! grep -Rq "kisak.*kisak-mesa" /etc/apt/sources.list /etc/apt/sources.list.d; then
        run_sudo add-apt-repository -y ppa:kisak/kisak-mesa
    else
        echo "[APT] kisak-mesa PPA already exists, skipping add-apt-repository."
    fi
fi

#--------------------------------------
# Step 1 – System update/upgrade + multiarch
#--------------------------------------
info_popup "Step 1: Updating system and enabling 32-bit support.\n\nYou can watch progress in the terminal."

# Update package lists and upgrade installed packages to latest
run_sudo_apt apt update
run_sudo_apt apt full-upgrade -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confnew

# Ensure AppArmor profiles are up-to-date (fix Flatpak revokefs issue on Ubuntu 25.10)
if systemctl is-active --quiet apparmor.service 2>/dev/null; then
    run_sudo systemctl reload apparmor.service || run_sudo systemctl restart apparmor.service || true
fi

# Enable multiarch for 32-bit packages (for gaming/wine compatibility)
run_sudo dpkg --add-architecture i386 || true
run_sudo_apt apt update

# Preseed Microsoft core fonts EULA (to avoid pop-up during install)
run_sudo_apt apt install -y debconf-utils
run_sudo debconf-set-selections <<EOF
ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true
ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note
EOF

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

# Core stack (always installed)
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
    # Core gaming libraries via APT (drivers, etc.)
    add_apt \
        mesa-utils \
        vulkan-tools \
        gamemode \
        mangohud \
        libxkbcommon-x11-0:i386 \
        libvulkan1:i386 \
        mesa-vulkan-drivers \
        mesa-vulkan-drivers:i386

    # Game launchers via Flatpak (latest versions)
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
    add_apt unattended-upgrades
    # Note: cron-apt intentionally not included to avoid conflict with unattended-upgrades
fi

# GPU-specific tweaks (auto-added based on detection)
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
        refind \
        shim-signed \
        mokutil \
        git    # for cloning theme
fi

#--------------------------------------
# Install APT packages (deduplicated)
#--------------------------------------
if [ "${#APT_PKGS[@]}" -gt 0 ]; then
    info_popup "Step 2: Installing APT packages…\n\nSee terminal for progress."
    # Deduplicate package list
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
# NVIDIA driver autoinstall (if NVIDIA GPU detected)
#--------------------------------------
if $NVIDIA_GPU_DETECTED; then
    echo "[GPU] NVIDIA GPU detected – running ubuntu-drivers autoinstall…"
    info_popup "Detected NVIDIA GPU.\n\nBenjiOS will now run 'ubuntu-drivers autoinstall' to install the recommended NVIDIA driver."
    run_sudo ubuntu-drivers autoinstall || true
fi

#--------------------------------------
# Flatpak setup + apps installation
#--------------------------------------
info_popup "Step 3: Configuring Flatpak and installing apps…"

# Add Flathub remote if not already added
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

# Install Flatpak packages, if any
if [ "${#FLATPAK_PKGS[@]}" -gt 0 ]; then
    echo "==> Installing Flatpak apps: ${FLATPAK_PKGS[*]}"
    flatpak install -y flathub "${FLATPAK_PKGS[@]}" || true
fi

configure_gnome_theme_and_power
configure_gnome_extensions_layout

#--------------------------------------
# Helper: configure auto updates (unattended-upgrades)
#--------------------------------------
setup_auto_updates() {
    local days="$1"  # "1" (daily) or "7" (weekly)
    local tmp_file
    tmp_file="$(mktemp)"

    cat > "$tmp_file" <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "$days";
APT::Periodic::AutocleanInterval "7";
EOF

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

# Apply GNOME Terminal (Ptyxis) configuration
if command -v dconf >/dev/null 2>&1; then
    tmp_term="$(mktemp)"
    if curl -fsSL "$RAW_BASE/configs/terminal.conf" -o "$tmp_term"; then
        dconf load /org/gnome/Ptyxis/ < "$tmp_term" 2>/dev/null || \
            echo "[GNOME] WARNING: Failed to load Terminal settings." >&2
    else
        echo "[GNOME] NOTE: Could not fetch terminal.conf; skipping Terminal config." >&2
    fi
    rm -f "$tmp_term"
else
    echo "[GNOME] 'dconf' not found; cannot apply Terminal config." >&2
fi

#--------------------------------------
# Stack-specific system configuration
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

    # Ensure network not shut down on poweroff/reboot (for Wake-on-LAN etc.)
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

    # Ensure Wake-on-LAN not disabled on suspend (if TLP is present)
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

if has_stack "tweaks"; then
    echo "[TWEAKS] Configuring zram (compressed RAM swap) and earlyoom…"
    # Apply custom zramswap config
    tmp_zram="$(mktemp)"
    if curl -fsSL "$RAW_BASE/configs/zramswap" -o "$tmp_zram"; then
        if [ -f /etc/default/zramswap ]; then
            backup_file /etc/default/zramswap
        fi
        run_sudo cp "$tmp_zram" /etc/default/zramswap
    else
        echo "[TWEAKS] WARNING: Could not fetch zramswap config; keeping default settings." >&2
    fi
    rm -f "$tmp_zram"

    # Enable zram swap service (name varies by Ubuntu version)
    run_sudo systemctl enable --now zramswap.service >/dev/null 2>&1 || \
    run_sudo systemctl enable --now zramswap >/dev/null 2>&1 || true

    run_sudo systemctl enable --now earlyoom.service >/dev/null 2>&1 || true
fi

# VM guest services enablement
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
# rEFInd installation + theme config
#--------------------------------------
install_and_configure_refind() {
    local mode="$1"

    # Find ESP mount point
    local esp
    if ! esp="$(find_esp)"; then
        echo "[rEFInd] EFI system partition not found – skipping rEFInd configuration."
        return
    fi

    # Run rEFInd's own installer (writes to ESP), skipping if already installed with Secure Boot key
    if $SB_ENABLED && [ -f "$esp/EFI/refind/keys/refind_local.cer" ]; then
        echo "[rEFInd] Already installed with Secure Boot key; skipping rEFInd installation to preserve keys."
    else
        if command -v refind-install >/dev/null 2>&1; then
            run_sudo refind-install || true
        fi
    fi

    # Define common EFI paths
    local ubuntu_rel="EFI/ubuntu/shimx64.efi"
    local windows_rel="EFI/Microsoft/Boot/bootmgfw.efi"
    local have_ubuntu=false have_windows=false
    [ -f "$esp/$ubuntu_rel" ]  && have_ubuntu=true
    [ -f "$esp/$windows_rel" ] && have_windows=true

    # Adjust mode if necessary based on actual OS presence
    local effective_mode="$mode"
    if [ "$effective_mode" = "dual" ] && ! $have_windows; then
        effective_mode="single"
    fi
    if [ "$effective_mode" = "single" ] && ! $have_ubuntu; then
        effective_mode="all"
    fi

    # Prepare theme installation
    local theme_dir="$esp/EFI/refind/themes/refind-bsxm1-theme"
    run_sudo mkdir -p "$(dirname "$theme_dir")"
    if [ ! -d "$theme_dir" ]; then
        run_sudo git clone --depth=1 https://github.com/AlexFullmoon/refind-bsxm1-theme.git "$theme_dir" || true
    fi

    # Prepare rEFInd config
    local refind_dir="$esp/EFI/refind"
    local refind_conf="$refind_dir/refind.conf"
    run_sudo mkdir -p "$refind_dir"

    # Choose the appropriate config file from the repo
    local refind_src
    case "$effective_mode" in
        single) refind_src="$RAW_BASE/configs/refind/refind-single.conf" ;;
        dual)   refind_src="$RAW_BASE/configs/refind/refind-dual.conf" ;;
        all)    refind_src="$RAW_BASE/configs/refind/refind-all.conf" ;;
        *)      refind_src="$RAW_BASE/configs/refind/refind-all.conf" ;;
    esac

    local tmp_conf; tmp_conf="$(mktemp)"
    if ! curl -fsSL "$refind_src" -o "$tmp_conf"; then
        echo "[rEFInd] WARNING: Could not download rEFInd config '$refind_src'; leaving existing config untouched." >&2
        rm -f "$tmp_conf"
        return
    fi

    # Backup existing config if any, then install new one
    if [ -f "$refind_conf" ]; then
        run_sudo cp -p "$refind_conf" "${refind_conf}.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    run_sudo cp "$tmp_conf" "$refind_conf"
    rm -f "$tmp_conf"

    echo "[rEFInd] Installed/updated rEFInd with mode='${effective_mode}' (configuration from repo applied)."
}

if $INSTALL_REFIND; then
    install_and_configure_refind "$REFIND_BOOT_MODE"
fi

# >>> New: Trigger MOK key enrollment if needed <<<
if $INSTALL_REFIND && $REFIND_ENROLL_KEY; then
    esp="$(find_esp)" || true
    if [ -n "$esp" ] && [ -f "$esp/EFI/refind/keys/refind_local.cer" ]; then
        MOK_PASS="$(zenity --password --title='BenjiOS – rEFInd Secure Boot' --text='Enter a password to enroll rEFInd key (you will need to confirm it on reboot):')"
        if [ -n "$MOK_PASS" ]; then
            printf '%s\n%s\n' "$MOK_PASS" "$MOK_PASS" | run_sudo mokutil --import "$esp/EFI/refind/keys/refind_local.cer" || true
            unset MOK_PASS
            info_popup "rEFInd Secure Boot key import scheduled. Enroll key on next reboot."
        else
            zenity --warning --title="BenjiOS – rEFInd Secure Boot" \
                   --width="$ZENITY_W" --height=150 \
                   --text="No password entered. rEFInd key enrollment skipped."
        fi
    else
        zenity --warning --title="BenjiOS – rEFInd Secure Boot" \
               --width="$ZENITY_W" --height=150 \
               --text="rEFInd Secure Boot key not found. You may need to disable Secure Boot."
    fi
fi

#--------------------------------------
# Maintenance / cleanup tasks
#--------------------------------------
info_popup "Step 4: Running maintenance tasks (cleanup, updates)…"

# Clean up APT caches and remove residual packages
run_sudo_apt apt autoremove --purge -y || true
run_sudo_apt apt clean || true

# Update Flatpak runtimes and remove unused (if flatpak is installed)
if command -v flatpak >/dev/null 2>&1; then
    flatpak update -y || true
    flatpak uninstall --unused -y || true
fi

# Refresh firmware update metadata (so GUI apps start with latest data)
if command -v fwupdmgr >/dev/null 2>&1; then
    run_sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
    run_sudo fwupdmgr get-updates >/dev/null 2>&1 || true
fi

# Update any snap packages (will do nothing if snapd not present or no snaps)
if command -v snap >/dev/null 2>&1; then
    run_sudo snap refresh >/dev/null 2>&1 || true
fi

#--------------------------------------
# Post-install documentation (copy to Desktop)
#--------------------------------------
POST_DOC_TMP="$(mktemp)"
if curl -fsSL "$RAW_BASE/docs/BenjiOS-PostInstall.odt" -o "$POST_DOC_TMP"; then
    cp "$POST_DOC_TMP" "$DESKTOP_DIR/BenjiOS-PostInstall.odt"
fi
rm -f "$POST_DOC_TMP"

#--------------------------------------
# Enable GNOME layout extensions at the very end
#--------------------------------------
enable_gnome_layout_extensions

#--------------------------------------
# Done – final message and optional reboot
#--------------------------------------
# Prepare final user message
FINAL_MSG="BenjiOS setup is complete.\n\n"
FINAL_MSG+="ArcMenu, App Icons Taskbar, Blur My Shell and GSConnect have been installed, configured, and activated for the BenjiOS layout."
if [ -n "$ARCMENU_UUID" ] && [ -n "$TASKBAR_UUID" ]; then
    FINAL_MSG+="\nUbuntu Dock has been disabled in favor of the new layout."
else
    FINAL_MSG+="\n(Note: A custom dock layout was not fully applied, so the default Ubuntu Dock remains enabled.)"
fi
if $INSTALL_REFIND; then
    FINAL_MSG+="\n\nrEFInd was installed and configured (${REFIND_BOOT_MODE} mode) as the boot manager."
else
    FINAL_MSG+="\n\nrEFInd was not installed."
fi
if $INSTALL_REFIND && $SB_ENABLED; then
    if $REFIND_ENROLL_KEY; then
        FINAL_MSG+="\n(Please complete the Secure Boot key enrollment for rEFInd on next reboot.)"
    else
        FINAL_MSG+="\n(Secure Boot is still enabled; you must disable it in your BIOS/UEFI to use rEFInd.)"
    fi
fi
FINAL_MSG+="\n\nA reboot is STRONGLY recommended so that GNOME and any driver or bootloader changes take full effect."

zenity --info --title="BenjiOS Installer" \
       --width="$ZENITY_W" --height=220 \
       --text="$FINAL_MSG"

# Prompt for reboot
if zenity --question --title="BenjiOS Installer" \
          --width="$ZENITY_W" --height=150 \
          --text="Reboot now to finalize the BenjiOS layout and rEFInd configuration (strongly recommended)?"; then
    run_sudo reboot
fi

# Cleanup: expire sudo timestamp
sudo -k

exit 0
