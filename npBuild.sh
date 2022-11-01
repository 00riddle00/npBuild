#!/usr/bin/env bash

# ================================== ITEMS ===================================
# * packages
# * metapackages (base)
# * groups (base-devel)
 
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
    "vim"
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
    parted -s /dev/sda mkpart primary ext4 1MiB 100%
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
    parted -s /dev/sda mkpart primary fat32 1MiB 551MiB
    # Make the ESP partition bootable (`esp` is an alias for `boot` on GPT)
    parted -s /dev/sda set 1 esp on

    # Create a Linux swap partition
    # Suggested size: More than 512 MiB
    parted -s /dev/sda mkpart primary linux-swap 551MiB 4.501GiB

    # Create a Linux root (/) partition
    # Suggested size: Remainder of the device
    parted -s /dev/sda mkpart primary ext4 4.501GiB 100%
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
    # Enable the swap volume
    swapon /dev/sda2

    # Create an Ext4 file system on Linux root partition
    mkfs.ext4 /dev/sda3
}

# ============ Granting sudo access ==============

# Allow sudo access without password (for the members of `wheel` group)
allow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) ALL/# %wheel ALL=(ALL) ALL/" /mnt/etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/" /mnt/etc/sudoers
}

# Disallow sudo access without password (for the members of `wheel` group)
disallow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/" /mnt/etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /mnt/etc/sudoers
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
	dir="$srcdir/$progname"
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

# ============== Applying dotfiles ===============

make_some_files_immutable() {
    sudo -S chattr +i "$DOTFILES_DIR/.config/Thunar/accels.scm"
    sudo -S chattr +i "$DOTFILES_DIR/.config/filezilla/filezilla.xml"
    sudo -S chattr +i "$DOTFILES_DIR/.config/htop/htoprc"
    sudo -S chattr +i "$DOTFILES_DIR/.config/mimeapps.list"

    re='^[0-9.]+$'

    for dir in $(ls "$DOTFILES_DIR/.config/GIMP"); do
        if [[ $dir =~ $re ]] ; then
            sudo -S chattr +i "$DOTFILES_DIR/.config/GIMP/$dir/menurc"
        fi
    done
}

prepare_sublime_text() {
    mkdir "$XDG_CONFIG_HOME/sublime-text-3/Installed Packages"
    wget -P "$XDG_CONFIG_HOME/sublime-text-3/Installed Packages" https://packagecontrol.io/Package%20Control.sublime-package
}

install_vim_plugins() {
    apps=(
        "cmake"
        "git"
        "python"
        "zsh"
    )

    for app in "${apps[@]}"; do
        res="$(pacman -Qqe | grep -E "(^|\s)$app($|\s)")";

        if [[ -z "$res" ]]; then
            sudo pacman -S --noconfirm "$app"
        fi
    done
    # TODO replace with vim-plug's one-liner "vim +PlugInstall" and test it
    rm -rf "$DOTFILES_DIR/.vim/bundle/Vundle.vim"
    git clone https://github.com/VundleVim/Vundle.vim.git "$DOTFILES_DIR/.vim/bundle/Vundle.vim"
    vim +PluginInstall +qall
    python ~/.vim/bundle/YouCompleteMe/install.py
}

apply_finishing_touches() {
    strfile "$HOME/.dotfiles/bin/cowsay/rms/rms_say"
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
    prepare_sublime_text
    make_some_files_immutable
    install_vim_plugins
    apply_finishing_touches
}

install_pkgs() {
	[[ -f /etc/sudoers.pacnew ]] && cp /etc/sudoers.pacnew /etc/sudoers # just in case

    # Use all cores for compilation (temporarily)
	sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf

    # Synchronizing system time to ensure successful and secure installation of software
    ntpdate 0.us.pool.ntp.org >/dev/null 2>&1

    srcdir="/home/$username/.local/src"; mkdir -p "$srcdir"; sudo chown -R "$username":wheel $(dirname "$srcdir")

    install_yay

    # Updating the system before installing new software
    pacman -Syu --noconfirm
    runuser --pty -s /bin/bash -l "$username" -c "yay -Sua --noconfirm"

    [[ -f "$progsfile" ]] || curl -LO "$progsfile"
    sed '/^#/d' "$progsfile" > /tmp/progs.csv
    while IFS=, read -r tag program comment; do
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

# Install Arch from Live CD/USB
install_arch() {
    # Check if Arch is to be installed on virtual machine or desktop computer
    [[ $machine =~ 'vm|desktop' ]] || echo "ERR: The machine type flag -m is empty or incorrect"

    # -------------------------------------------
    # Pre-installation
    # -------------------------------------------

    # Update the system clock
    # 
    # In the live environment `systemd-timesyncd` is enabled by default and time will be synced
    # automatically once a connection to the internet is established.
    #
    # Use `timedatectl(1)` to ensure the system clock is accurate.
    timedatectl set-ntp true # just in case

    # Partition the disks
    eval "mkpart_$machine"

    # Format the partitions
    eval "mkfs_$machine"

    # Mount the file systems (the root volume)
    # `genfstab(8)` will later detect mounted file systems and swap space
    [[ $machine =~ "vm" ]] && part="sda1" || part="sda3"
    mount "/dev/$part" /mnt

    # -------------------------------------------
    # Installation
    # -------------------------------------------

    # Variable indirection is used here
    machine_specific_items=items_$machine[@]

    # Use the `pacstrap(8)` script to install:
    #
    # Essential packages: the `base` package, Linux kernel and firmware for common hardware, etc.
    pacstrap -K /mnt "${essential_items[@]}"
    # Additional packages, like `vim`, `git`, etc.
    pacstrap -K /mnt "${additional_items[@]}"
    # Machine specific items, like Virtualbox modules/utilities.
    pacstrap -K /mnt "${!machine_specific_items}"

    # -------------------------------------------
    # Configuring the system
    # -------------------------------------------

    # [1. Fstab] 
    
    # Generate an fstab file (used to define how disk partitions, various other block
    # devices, or remote file systems should be mounted into the file system).
    genfstab -U /mnt >> /mnt/etc/fstab

    # [2. Chroot] 
    
    # Change root into the new system
    arch-chroot /mnt /bin/bash <<END

        # [3. Time zone]
        
        # Set the time zone
        ln -s /usr/share/zoneinfo/Europe/Vilnius /etc/localtime

        # Run hwclock(8) to generate /etc/adjtime
        # This command assumes the hardware clock is set to UTC.
        hwclock --systohc

        # [4. Localization]

        # Edit /etc/locale.gen and uncomment the needed locales
        echo -e "en_US.UTF-8 UTF-8\nlt_LT.UTF-8 UTF-8" >> /etc/locale.gen
        # Generate the locales
        locale-gen

        echo -e "127.0.0.1 localhost\n::1       localhost" > /etc/hosts

        mkinitcpio -p linux

        # Make pacman and yay colorful and adds eye candy on the progress bar because why not.
        grep "^Color" /etc/pacman.conf >/dev/null || sed -i "s/^#Color$/Color/" /etc/pacman.conf
        grep "ILoveCandy" /etc/pacman.conf >/dev/null || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf

        useradd -m -G wheel "$username"
        echo -e "passwd\npasswd\n" | passwd "$username"

        # Give sudo access to the members of the wheel group
        sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers

        # [8. SSH]

        # Disable SSH login as root user and enable SSH password authentication
        sed -Ei "s/^#? ?(PermitRootLogin).*/\1 no/" /etc/ssh/sshd_config
        sed -Ei "s/^#? ?(PasswordAuthentication).*/\1 yes/" /etc/ssh/sshd_config

        # Enable OpenSSH server daemon at boot
        systemctl enable sshd

        systemctl enable "dhcpcd@"$(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}' | sed 's/ //')""

        case "$machine" in
            "vm") 
                pacman --noconfirm -S grub-bios
                grub-install --recheck /dev/sda
                grub-mkconfig -o /boot/grub/grub.cfg
                ;;
            "desktop") 
                mkdir /efi
                mount /dev/sda1 /efi
                pacman -S grub efibootmgr
                grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=arch_grub --recheck
                grub-mkconfig -o /boot/grub/grub.cfg
                ;;
            *) echo "unknown variable '$machine'" >2 && exit 1 ;;
        esac

        echo "$machine"-"$(head /dev/urandom -c 2 | base64 | cut -c -3)"-arch > /etc/hostname
END

    # Copying this script
    cp "$0" "/mnt/home/$username/npBuild.sh"
    chgrp wheel "/mnt/home/$username/npBuild.sh"

    arch-chroot /mnt /bin/bash <<END
        "sh npBuild.sh -f install_pkgs -u $username"
END

    allow_sudo_nopasswd

    arch-chroot /mnt /bin/bash <<END
        runuser --pty -s /bin/bash -l "$username" -c "
            sh npBuild.sh -f apply_dotfiles -u $username
        "
END

    disallow_sudo_nopasswd

    rm "/mnt/home/$username/npBuild.sh"

    # -------------------------------------------
    # Rebooting
    # -------------------------------------------

    umount /mnt
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
[[ -z "$progsfile" ]] && progsfile="https://raw.githubusercontent.com/00riddle00/NPbuild/master/progs.csv"
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
