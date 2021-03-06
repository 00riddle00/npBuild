#! /usr/bin/env bash

# ======================= VARIABLES =======================

# items = packages, groups (base-devel), metapackages (base)
items_main=(
    "base"
    "base-devel"
    "linux"
    "linux-firmware"
)

items_additional=(
    "dhcpcd"
    "openssh"
    "vim"
    "git"
)

items_vm=(
    "virtualbox-guest-utils"
)

items_desktop=(
    "virtualbox"
    "virtualbox-host-modules-arch"
)

# ==================== UTILITY FUNCTIONS ====================

mkpart_vm() {
    parted -s /dev/sda mklabel msdos
    parted -s /dev/sda mkpart primary ext4 1MiB 100%
    parted -s /dev/sda set 1 boot on
}

mkpart_desktop() {
    parted -s /dev/sda mklabel gpt
    parted -s /dev/sda mkpart primary fat32 1MiB 551MiB
    parted -s /dev/sda set 1 esp on
    parted -s /dev/sda mkpart primary linux-swap 551MiB 4.501GiB
    parted -s /dev/sda mkpart primary ext4 4.501GiB 100%
}

mkfs_vm() {
    mkfs.ext4 /dev/sda1
}

mkfs_desktop() {
    mkfs.fat -F32 /dev/sda1
    mkswap /dev/sda2
    swapon /dev/sda2
    mkfs.ext4 /dev/sda3
}

allow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) ALL/# %wheel ALL=(ALL) ALL/" /mnt/etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/" /mnt/etc/sudoers
}

disallow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/" /mnt/etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /mnt/etc/sudoers
}

# ================= CHROOT FUNCTIONS =================

# ================= INSTALL FUNCTIONS =================

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
    # if a package is not found, skips it
    # if a package is already installed, skips it as well
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
    # if any package is not found, does not install anything from the list
    # if package is already installed, skips it (shows "up-to date" message)
    sudo pacman -S --noconfirm --needed "$1" || yes | sudo pacman -S --needed "$1" 
}

# ================= DOTFILES FUNCTIONS =================

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

# ================= STANDALONE FUNCTIONS =================

# run from arch LiveCD
install_arch() {
    [[ $machine =~ 'vm|desktop' ]] || echo "ERR: The machine type flag -m is empty or incorrect"
    timedatectl set-ntp true

    eval "mkpart_$machine"
    eval "mkfs_$machine"

    [[ $machine =~ "vm" ]] && part="sda1" || part="sda3"
    mount "/dev/$part" /mnt

    # variable indirection is used here
    machine_specific_items=items_$machine[@]
    pacstrap /mnt "${main_items[@]}"
    pacstrap /mnt "${additional_items[@]}"
    pacstrap /mnt "${!machine_specific_items}"

    genfstab -U /mnt >> /mnt/etc/fstab

    arch-chroot /mnt /bin/bash <<END
        echo -e "en_US.UTF-8 UTF-8\nlt_LT.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen
        ln -s /usr/share/zoneinfo/Europe/Vilnius /etc/localtime

        hwclock --systohc

        echo -e "127.0.0.1 localhost\n::1       localhost" > /etc/hosts

        mkinitcpio -p linux

        # Make pacman and yay colorful and adds eye candy on the progress bar because why not.
        grep "^Color" /etc/pacman.conf >/dev/null || sed -i "s/^#Color$/Color/" /etc/pacman.conf
        grep "ILoveCandy" /etc/pacman.conf >/dev/null || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf

        useradd -m -G wheel "$username"
        echo -e "passwd\npasswd\n" | passwd "$username"

        sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers

        sed -Ei "s/^#? ?(PermitRootLogin).*/\1 no/" /etc/ssh/sshd_config
        sed -Ei "s/^#? ?(PasswordAuthentication).*/\1 yes/" /etc/ssh/sshd_config
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

    # copying this script
    cp "$0" "/mnt/home/$username/npBuild.sh"
    chgrp wheel "/mnt/home/$username/npBuild.sh"

    arch-chroot /mnt /bin/bash <<END
        "sh npBuild.sh -f install_pkgs -u $username"
END

    allow_sudo_nopasswd

    arch-chroot /mnt /bin/bash <<END
        runuser --pty -s /bin/bash -l "$username" -c "
            sh npBuild.sh -f apply_dotfile -u $username
        "
END

    disallow_sudo_nopasswd

    rm "/mnt/home/$username/npBuild.sh"
    umount /mnt
    eject -m
    reboot -f
}

install_pkgs() {
	[[ -f /etc/sudoers.pacnew ]] && cp /etc/sudoers.pacnew /etc/sudoers # just in case

    # Use all cores for compilation (temporarily)
	sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf

    # Synchronizing system time to ensure successful and secure installation of software
    ntpdate 0.us.pool.ntp.org >/dev/null 2>&1

    srcdir="/home/$username/.local/src"; mkdir -p "$srcdir"; sudo chown -R "$username":wheel $(dirname "$srcdir")

    install_yay

    # updating the system before installing new software
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

    # cleanup
    rmdir "$srcdir" 2> /dev/null 

	# Reset makepkg settings
    sed -i "s/-j$(nproc)/-j2/;s/^MAKEFLAGS/#MAKEFLAGS/" /etc/makepkg.conf
}

# passwordless sudo must be enabled
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

symlink_dotfiles() {
    source "$HOME/.dotfiles/.zshenv"

    [[ ! -d "$HOME/.config" ]] && mkdir -p "$HOME/.config"

    [[ ! -d "$XDG_DATA_HOME/applications" ]] && mkdir -p "$XDG_DATA_HOME/applications"

    # $HOME
    for full_path in "$DOTFILES_DIR"/.[a-zA-Z]*; do
        file="$(basename "$full_path")"
        # whenever you iterate over files/folders by globbing, it's good practice to avoid the corner 
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
        # also check if it's symbolic link before deleting
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

# ======================= EXECUTION =======================

standalone_functions=(
    "install_arch"
    "install_pkgs"
    "apply_dotfiles"
    "symlink_dotfiles"
    "unlink_dotfiles"
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
                    'install_arch'
                    'install_pkgs'
                    'apply_dotfiles'
                    'symlink_dotfiles'
                    'unlink_dotfiles'

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
