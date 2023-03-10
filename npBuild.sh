#!/usr/bin/env bash
# vim:ft=bash:tw=95

# ================================== ITEMS ===================================
# Items can be:
#   * packages
#   * metapackages (base)
#   * groups (base-devel)
 
items_essential=(
    "base"
    "base-devel"
    "linux"
    "linux-firmware"
)

items_additional=(
    "dhcpcd"
    "git"
    "openssh"
    "gvim"
)

items_vm=(
    "virtualbox-guest-utils"
)

items_desktop=(
    "virtualbox"
    "virtualbox-host-modules-arch"
)

# ============================= UTILITY FUNCTIONS ============================

# ================= Partitioning =================

# Use GNU Parted to modify partition tables
mkpart_vm() {
    # Make the disk be MBR partitioned (aka DOS or MS-DOS partitioned)
    parted -s /dev/sda mklabel msdos

    # Create a Linux root (/) partition
    # Suggested size: Remainder of the device
    parted -s /dev/sda mkpart "main-partition" ext4 1MiB 100%
    # Make the partition bootable
    parted -s /dev/sda set 1 boot on
}

# Use GNU Parted to modify partition tables
mkpart_desktop() {
    # Make the disk be GPT partitioned
    parted -s /dev/sda mklabel gpt

    # Create an EFI system partition (ESP) for booting in UEFI mode
    # Use `fat32` as the file system type
    # Sugggested size: At least 300 MiB
    parted -s /dev/sda mkpart "EFI-system-partition" fat32 1MiB 551MiB
    # Make the ESP partition bootable (`esp` is an alias for `boot` on GPT)
    parted -s /dev/sda set 1 esp on

    # Create a Linux swap partition
    # Suggested size: More than 512 MiB
    parted -s /dev/sda mkpart "swap-partition" linux-swap 551MiB 4.501GiB

    # Create a Linux root (/) partition
    # Suggested size: Remainder of the device
    parted -s /dev/sda mkpart "main-partition" ext4 4.501GiB 100%
}

# ============= Creating filesystems =============

# Format the newly created partitions with appropriate file systems
mkfs_vm() {
    # Create an Ext4 file system on Linux root partition
    mkfs.ext4 /dev/sda1
}

# Format the newly created partitions with appropriate file systems
mkfs_desktop() {
    # Format the EFI system partiton to FAT32
    mkfs.fat -F 32 /dev/sda1

    # Initialize partition for swap
    mkswap /dev/sda2

    # Create an Ext4 file system on Linux root partition
    mkfs.ext4 /dev/sda3
}

# ============ Granting sudo access ==============

# Allow sudo access without password (for the members of `wheel` group)
allow_sudo_nopasswd() {
    mountpoint="$1" # optional argument
    sed -E -i 's/^[ ]*(%wheel ALL=\(ALL:ALL\) ALL)[ ]*$/#\1/' "${mountpoint}/etc/sudoers"
    sed -E -i 's/^#?[ ]*(%wheel ALL=\(ALL:ALL\) NOPASSWD: ALL)[ ]*$/\1/' "${mountpoint}/etc/sudoers"
}

# Disallow sudo access without password (for the members of `wheel` group)
disallow_sudo_nopasswd() {
    mountpoint="$1" # optional argument
    sed -E -i 's/^#?[ ]*(%wheel ALL=\(ALL:ALL\) ALL)[ ]*$/\1/' "${mountpoint}/etc/sudoers"
    sed -E -i 's/^#?[ ]*(%wheel ALL=\(ALL:ALL\) NOPASSWD: ALL)[ ]*$/#\1/' "${mountpoint}/etc/sudoers"
}

# ============= Installing packages ==============

install_yay() {
	[[ -f "/usr/bin/yay" ]] || {
    git clone https://aur.archlinux.org/yay.git $srcdir/yay
    chown -R $username:$username $srcdir/yay
    pacman -S --noconfirm --needed go
    runuser -l "$username" -c "{ cd $srcdir/yay || return } && makepkg --noconfirm -si"
    rm -r "$srcdir/yay"
    }
}

install_from_aur() {
    # If a package is not found, skips it
    # If a package is already installed, skips it as well
    runuser -l "$username" -c "yay -S --aur --noconfirm --needed --useask "$1""
}

install_from_git() {
    progname="$(basename "$1" .git)"
    dir="/tmp/$progname"
    sudo -u "$username" git clone --depth 1 "$1" "$dir" || { cd "$dir" || return ; sudo -u "$username" git pull --force origin master;}
    cd "$dir" || exit
    sudo make clean install
    rm -r "$dir"
}

install_from_main() { # Installs all needed programs from main repos.
    # If any package is not found, does not install anything from the list
    # If package is already installed, skips it (shows "up-to date" message)
    sudo pacman -S --noconfirm --needed "$1" || yes | sudo pacman -S --needed "$1" 
}

# =========================== STANDALONE FUNCTIONS ===========================

symlink_dotfiles() {
    source "$HOME/.dotfiles/.zshenv"

    [[ ! -d "$HOME/.config" ]] && mkdir -p "$HOME/.config"

    [[ ! -d "$XDG_DATA_HOME/applications" ]] && mkdir -p "$XDG_DATA_HOME/applications"

    # $HOME
    for full_path in "$DOTFILES_DIR"/.[a-zA-Z]*; do
        file="$(basename "$full_path")"
        # Whenever you iterate over files/folders by globbing, it's good practice to avoid the corner 
        # case where the glob does not match (which makes the loop variable expand to the 
        # (un-matching) glob pattern string itself), hence [[ -e "$full_path" ] is used
        [[ -e "$full_path" ]] && 
            [[ "$file" != ".config" ]] &&
            [[ "$file" != ".local" ]] &&
            [[ "$file" != .git* ]] &&
        ln -sf "$full_path" "$HOME/$file"
    done

    # $XDG_CONFIG_HOME
    for full_path in "$DOTFILES_DIR/.config"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] &&
        ln -sf "$full_path" "$XDG_CONFIG_HOME/$file"
    done

    # ~/.local/bin
    local_bin="$DOTFILES_DIR/.local/bin"
    [[ -e "$local_bin" ]] && ln -sf "$local_bin" "$HOME/.local/bin"

    # ~/.local/share ($XDG_DATA_HOME)
    local_shared="$DOTFILES_DIR/.local/share/riddle00"
    [[ -e "$local_shared" ]] && ln -sf "$local_shared" "$XDG_DATA_HOME/riddle00"

    for full_path in "$DOTFILES_DIR/.local/share/applications"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] &&
        ln -sf $full_path "$XDG_DATA_HOME/applications/$file"
    done
}

unlink_dotfiles() {
    source "$HOME/.dotfiles/.zshenv"

    # $HOME
    for full_path in "$DOTFILES_DIR"/.[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] && 
        [[ "$file" != ".config" ]] &&
        [[ "$file" != ".local" ]] &&
        [[ "$file" != .git* ]] &&
        # Also check if it's symbolic link before deleting
        [[ -L "$HOME/$file" ]] &&
        rm -f "$HOME/$file"
    done

    # $XDG_CONFIG_HOME
    for full_path in "$DOTFILES_DIR/.config"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] &&
        [[ -L "$XDG_CONFIG_HOME/$file" ]] &&
        rm -f "$XDG_CONFIG_HOME/$file"
    done

    # ~/.local/bin
    full_path="$DOTFILES_DIR/.local/bin"
    file="$(basename "$full_path")"
    [[ -e "$full_path" ]] && [[ -L "$HOME/.local/$file" ]] && rm -f "$HOME/.local/$file"

    # ~/.local/share ($XDG_DATA_HOME)
    full_path="$DOTFILES_DIR/.local/share/riddle00"
    file="$(basename "$full_path")"
    [[ -e "$full_path" ]] && [[ -L "$XDG_DATA_HOME/$file" ]] && rm -f "$XDG_DATA_HOME/$file"

    for full_path in "$DOTFILES_DIR/.local/share/applications"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] && [[ -L "$XDG_DATA_HOME/applications/$file" ]] && rm -f "$XDG_DATA_HOME/applications/$file"
    done
}

# Passwordless sudo must be enabled
apply_dotfiles() {
    git clone -b "$repobranch" --depth 1 --recurse-submodules --shallow-submodules -j8 "$dotfilesrepo" "$HOME/.dotfiles"
    sed -i "s/^export MAIN_USER=.*/export MAIN_USER=$username/" "$HOME/.dotfiles/.zshenv"
    sudo chsh -s /bin/zsh "$username"
    source "$HOME/.dotfiles/.zshenv"
    symlink_dotfiles
    vim +PlugInstall +qall
}

install_pkgs() {
	[[ -f /etc/sudoers.pacnew ]] && cp /etc/sudoers.pacnew /etc/sudoers # just in case

    # Use all cores for compilation (temporarily)
	sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf

    # Synchronizing system time to ensure successful and secure installation of software
    ntpdate 0.us.pool.ntp.org > /dev/null 2>&1

    srcdir="/home/$username/.local/src"; mkdir -p "$srcdir"; sudo chown -R "$username":wheel $(dirname "$srcdir")

    install_yay

    # Updating the system before installing new software
    pacman -Syu --noconfirm
    runuser --pty -s /bin/bash -l "$username" -c "yay -Sua --noconfirm"

    [[ -f "$progsfile" ]] || curl -LO "$progsfile"
    tail +2 $(basename "$progsfile") > /tmp/progs.tsv
    while IFS=$'\t' read -r tag program comment; do
        case "$tag" in
            "A") install_from_aur "$program" ;;
            "G") install_from_git "$program" ;;
            *) install_from_main "$program" ;;
        esac
    done < /tmp/progs.csv

    # Cleanup
    rmdir "$srcdir" 2> /dev/null 

	# Reset makepkg settings
    sed -i "s/-j$(nproc)/-j2/;s/^MAKEFLAGS/#MAKEFLAGS/" /etc/makepkg.conf
}

install_arch() {
    # Installs Arch Linux using the live system booted from an installation medium
    # (CD/USB/other) made from an official installation image.

    # -------------------------------------------
    # 1. Pre-installation
    # -------------------------------------------
    
    # It is assumed that the following prerequisites are already satisfied:
    #
    # [1.1 Acquire an installation image]
    #
    # [1.2. Verify signature of the acquired image]
    #
    # [1.3. Prepare an installation medium]
    #
    # [1.4. Boot the live environment]

    # Check if Arch is to be installed on virtual machine or desktop computer
    [[ $machine =~ 'vm|desktop' ]] || echo "ERR: The machine type flag -m is empty or incorrect"

    # -------------------------------------------
    # 1. Pre-installation (continued)
    # -------------------------------------------
    
    # [1.5. Set the console keyboard layout]
    #
    # No action is performed here, the default settings are used:
    #   console keymap:           US
    #   console keyboard layout:  us (us) 
    #   console fonts:            default8xN
    
    # [1.6 Verify the boot mode (by listing the efivars dir)]
    # 
    # If the command shows the directory without error, then the system is booted in UEFI mode.
    # If the directory does not exist, the system may be booted in BIOS (or CSM) mode.
    #
    efivars_dir="/sys/firmware/efi/efivars"

    if ( [[ $machine =~ "vm" ]] && [ -d "$efivars_dir" ] ) || \
        ( [[ $machine =~ "desktop" ]] && [ ! -d "$efivars_dir" ] )
    then
        echo "ERR: The system did not boot in the correct mode"; exit 1
    fi

    # [1.7 Connect to the internet] 
    #
    # Check wired network connection (ethernet cable must be plugged in).
    #
    # DHCP: dynamic IP address and DNS server assignment (provided by systemd-networkd and
    # systemd-resolved) should work out of the box for Ethernet
    #
    # NOTE: In the installation image, systemd-networkd and systemd-resolved are preconfigured
    # and enabled by default. That will not be the case for the installed system.
    # 
    ping -q -c1 archlinux.org &> /dev/null || { echo "ERR: No internet connection"; exit 1; }

    # [1.8. Update the system clock]
    # 
    # In the live environment `systemd-timesyncd` is enabled by default and time will be synced
    # automatically once a connection to the internet is established.
    #
    # Use `timedatectl(1)` to ensure the system clock is accurate (`timedatectl status`).
    #
    # Enable and start `systemd-timesyncd.service` just in case it's not running.
    timedatectl set-ntp 1

    # [1.9. Partition the disks]
    #
    eval "mkpart_$machine"

    # [1.10. Format the partitions]
    #
    eval "mkfs_$machine"

    # [1.11. Mount the file systems]
    
    # Mount the root volume to /mnt
    [[ $machine =~ "vm" ]] && root_part="sda1" || root_part="sda3"
    mount "/dev/$root_part" /mnt

    # Create any remaining mount points and mount their corresponding volumes.
    #
    # For UEFI systems, mount the EFI system partition:
    [[ $machine =~ "desktop" ]] && mount --mkdir /dev/sda1 /mnt/boot

    # If a swap volume is created, enable it with `swapon(8)`:
    [[ $machine =~ "desktop" ]] && swapon /dev/sda2

    # `genfstab(8)` will later detect mounted file systems and swap space

    # -------------------------------------------
    # 2. Installation
    # -------------------------------------------
    
    # [2.1.] Select the mirrors
    #
    # No action is performed here.
    #
    # On the live system, after connecting to the internet, "reflector" updates the mirror list
    # (/etc/pacman.d/mirrorlist) by choosing 20 most recently synchronized HTTPS mirrors and
    # sorting them by download rate.
    # 
    # The mirror list file will later be copied to the new system by pacstrap. It can then be
    # modified from inside the new system, according to the specific needs for that system.

    # [2.2.] Install essential packages
    
    # Variable indirection is used here
    machine_specific_items=items_$machine[@]

    # Use the `pacstrap(8)` script to install:
    #
    # Essential packages: the `base` package, Linux kernel and firmware for common hardware, etc.
    pacstrap -K /mnt "${essential_items[@]}"
    # Additional packages, like text editor, git, etc.
    pacstrap -K /mnt "${additional_items[@]}"
    # Machine specific items, like Virtualbox modules/utilities.
    pacstrap -K /mnt "${!machine_specific_items}"

    # -------------------------------------------
    # 3. Configure the system
    # -------------------------------------------

    # [3.1. Fstab] 
    #
    # Generate an fstab file (used to define how disk partitions, various other block
    # devices, or remote file systems should be mounted into the file system).
    #
    genfstab -U /mnt >> /mnt/etc/fstab

    # [3.2. Chroot] 
    #
    # Change root into the new system
    #
    arch-chroot /mnt /bin/bash <<END

        # [3.3. Time zone]
        
        # Set the time zone
        ln -sf /usr/share/zoneinfo/Europe/Vilnius /etc/localtime

        # Run hwclock(8) to generate /etc/adjtime
        # This command assumes the hardware clock is set to UTC.
        hwclock --systohc

        # Enable and start `systemd-timesyncd.service` just in case it's not running.
        timedatectl set-ntp 1

        # [3.4. Localization]
        
        # Edit /etc/locale.gen and uncomment the needed locales
        sed -i '/^#en_US\.UTF-8 UTF-8[ ]*$/s/^#//' /etc/locale.gen
        sed -i '/^#lt_LT\.UTF-8 UTF-8[ ]*$/s/^#//' /etc/locale.gen

        # Generate the locales
        locale-gen

        # Create the locale.conf(5) file, and set the LANG variable accordingly
        echo "LANG=en_US.UTF-8" > /etc/locale.conf

        # If custom console keyb. layout is set, make changes persistent in `vconsole.conf(5)`
        #
        # No action is performed here, default console keyboard layout is used: `us (us)`

        # [3.5. Network configuration]
        
        # Create the hostname and add it to the newly created `/etc/hostname` file.
        hostname="$machine"-"$(head /dev/urandom -c 2 | base64 | cut -c -3)"-arch
        echo "$hostname" > /etc/hostname

        # Edit /etc/hosts file
        echo -e "<ip-address>  <canonical (full) hostname>  <optional list of aliases>\n" >  /etc/hosts
        echo -e "127.0.0.1  localhost\n"                                                  >> /etc/hosts
        echo -e "::1        localhost\n"                                                  >> /etc/hosts
        echo -e "127.0.1.1  $hostname.localdomain  $hostname"                             >> /etc/hosts
        
        # Start the dhcpcd (DHCP client) daemon for wired interface by enabling the template unit
        # dhcpcd@interface.service, where interface name can be found by listing network interfaces
        systemctl enable "dhcpcd@"$(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}' | sed 's/ //')""

        # [3.6. Initramfs]
        #
        # Creating a new initramfs is usually not required, because mkinitcpio was run on 
        # installation of the kernel package with pacstrap.
        #
        mkinitcpio -P # recreate the initramfs image just in case

        # [3.7. Root password]
        #
        # No action is performed here, the root password is left to be set later, manually
       
        # [3.8. Boot loader]
        #
        # Install a GRUB 2: a Linux-capable boot loader
        #
        case "$machine" in
            "vm") 
                pacman -S --noconfirm grub
                grub-install --target=i386-pc /dev/sda
                grub-mkconfig -o /boot/grub/grub.cfg
                ;;
            "desktop") 
                mount /dev/sda1 /boot
                pacman -S --noconfirm grub efibootmgr
                grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
                grub-mkconfig -o /boot/grub/grub.cfg
                ;;
            *) echo "unknown machine type: '$machine'" >2 && exit 1 ;;
        esac

        # [3.9.(extra) Kernel parameters]
        #
        # Disable "quiet" and "splash" parameters
        #
        sed -E -i 's/^(GRUB_CMDLINE_LINUX_DEFAULT=)".*"[ ]*$/\1"loglevel=3"/' /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg

        # [3.10.(extra) SSH]

        # Disable SSH login as root user and enable SSH password authentication
        sed -E -i 's/^#?[ ]*(PermitRootLogin)[ ]*(yes|no)[ ]*$/\1 no/'         /etc/ssh/sshd_config
        sed -E -i 's/^#?[ ]*(PasswordAuthentication)[ ]*(yes|no)[ ]*$/\1 yes/' /etc/ssh/sshd_config

        # Enable OpenSSH server daemon at boot
        systemctl enable sshd

        # [3.11.(extra) Users and groups]
       
        # Create a user and add it to wheel group
        useradd -m -G wheel "$username"
        echo -e "passwd\npasswd\n" | passwd "$username"

        # Give sudo access to the members of the wheel group
        sed -E -i 's/^#?[ ]*(%wheel ALL=\(ALL:ALL\) ALL)[ ]*$/\1/' /etc/sudoers

        # [3.12.(extra) Pacman]
        
        # Enable multilib repo to run 32 bit apps on x86_64 system.
        sed -i '/\[multilib\][ ]*$/,/Include/s/^#//' /etc/pacman.conf

        # Make it colorful
        sed -i '/^#[ ]*Color[ ]*$/s/^#//' /etc/pacman.conf

        # Add eye candy to the progress bar
        sed -i '/^[ ]*Color[ ]*$/a ILoveCandy' /etc/pacman.conf

        # [3.13.(extra) Vim]
        #
        # Show line numbers in Vim
        #
        echo "set number" >> /etc/vimrc

END
    # -------------------------------------------
    # 4./5. Post-installation
    # -------------------------------------------

    # [A Little Recursion Never Killed Nobody]
    #
    # Copy this file (shell script) to the newly created user's home dir on the new system and
    # assign it to the `wheel` group (the members of which have sudo access)
    #
    cp "$0" "/mnt/home/$username/npBuild.sh"
    chgrp wheel "/mnt/home/$username/npBuild.sh"

    # [Installing more packages]
    #
    # From inside the new system, run the copy of this file, passing the `-f` option to it with the
    # argument `install_pkgs`, which makes the function `install_pkgs` from the copy of this file to
    # be called. This function installs packages (both from the official repos and from AUR).
    #
    arch-chroot /mnt /bin/bash <<END
        "sh npBuild.sh -f install_pkgs -u $username"
END

    # [Getting and applying dotfiles]
    
    allow_sudo_nopasswd "/mnt"

    arch-chroot /mnt /bin/bash <<END
        runuser --pty -s /bin/bash -l "$username" -c "
            sh npBuild.sh -f apply_dotfiles -u $username
        "
END

    disallow_sudo_nopasswd "/mnt"

    # -------------------------------------------
    # 4./5. Rebooting
    # -------------------------------------------
    
    # Remove the copy of this file from the new system
    rm "/mnt/home/$username/npBuild.sh"

    umount -R /mnt
    eject -m
    reboot -f
}

# ========================== ENTRY POINT (EXECUTION) ==========================

standalone_functions=(
    "symlink_dotfiles"
    "unlink_dotfiles"
    "apply_dotfiles"
    "install_pkgs"
    "install_arch"
)

while getopts ":f:m:u:b:p:h" opt; do 
    case "${opt}" in
        f) function=${OPTARG} ;;
        m) machine=${OPTARG} ;;
        u) username=${OPTARG} ;;
        b) repobranch=${OPTARG} ;;
        p) progsfile=${OPTARG} ;;
        h) printf "
        -f  [Required] Name of one single function to be run.
                List of functions:
                    'symlink_dotfiles'
                    'unlink_dotfiles'
                    'apply_dotfiles'
                    'install_pkgs'
                    'install_arch'

        -m  [Required only for the function 'install_arch'] Machine type. One of two values: {'vm', 'desktop'}
        -u  [Optional] User name. Defaults to 'userv'
        -b  [Optional] Branch of the repo. Defaults to 'master'
        -p  [Optional] Dependencies and programs csv (local file or url).  Defaults to npBuild repo's 'progs.csv' file
        -h  Show help\\n" 
        exit ;;
        *) printf "Invalid option: -%s\\n" "$OPTARG" && exit ;;
    esac
done

[[ -z "$username" ]] && username="userv"
[[ -z "$repobranch" ]] && repobranch="master"
[[ -z "$progsfile" ]] && progsfile="https://raw.githubusercontent.com/00riddle00/NPbuild/$repobranch/packages_all.tsv"
dotfilesrepo="https://github.com/00riddle00/dotfiles"

if [[ -n "$function" ]]; then
    if [[ " ${standalone_functions[@]} " =~ " ${function} " ]]; then
        eval "$function" 
    else
        echo "ERR: The function '$function' does not exist as standalone"
    fi
else
    echo "ERR: no function passed to the script"
fi
