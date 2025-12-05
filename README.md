This entire thing is under construction and not be used by the public!
If you still trying to use it you do this at your own risk with no liability whatsoever on my end!

Command to run this on a freshly installed Ubuntu 25.10 OS

wget -O BenjiOS-Installer.sh https://raw.githubusercontent.com/AdminPanic/BenjiOS/main/BenjiOS-Installer.sh && chmod +x BenjiOS-Installer.sh && ./BenjiOS-Installer.sh

OR

bash <(wget -qO- https://raw.githubusercontent.com/AdminPanic/BenjiOS/main/BenjiOS-Installer.sh)

This is an installer script designed to run under Ubuntu 25.10 and later.
In theory this should also be safe to run under earlier Ubuntu Versions.
The goal is to have an Windows like experience while not having to deal with "gaming" distros, old kernels, crappy display manager, etc.
From a few months of testing multiple Linux distros (Ubuntu, Mint, Fedora, Nebora, CachyOS, SteamOS, Arch, Kubuntu, etc.) I found Ubuntu 25.10 to be the sweet spot.
Having said this the main reasons why I decided on Ubuntu:
- Wayland as default DPM
- GSConnect working properly
- Proper Google Drive, Exchange integration
- Good enough gaming performance
- Newer Kernel compared to other non rolling distros

The script will install a bunch of programs and designs to get the windowsy look and feal along with very useful software.
It is based on Zenity as frontend and designed in a way so a user only have to touch the terminal one single time at installation (calling the script).
All the other options and programs are selected via GUI / Zenity Interface.
Hardware detection is automated to detected AMD / Intel / nVidia GPU´s and install the proper drivers.
Also it detects the most important virualization platforms (KVM/Proxmox / VMWare / Hyper-V / Virtualbox) and installs the correct addons.
