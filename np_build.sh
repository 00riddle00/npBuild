#!/bin/bash

# items = packages, groups (base-devel), metapackages (base)
main_items=(
    "base"
    "base-devel"
    "linux"
    "linux-firmware"
)

additional_items=(
    "vim"
    "dhcpcd"
    "openssh"
    "git"
)

# =============== vbox =================#

vbox_items=(
    "virtualbox-guest-utils"
)

mkpart_vbox() {
    parted -s /dev/sda mklabel msdos
    parted -s /dev/sda mkpart "primary" "ext4" "0%" "100%"
    parted -s /dev/sda set 1 boot on
}

setup_from_chroot_vbox() {
    arch-chroot /mnt /bin/bash <<END

    echo -e "en_US.UTF-8 UTF-8\nlt_LT.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    ln -s /usr/share/zoneinfo/Europe/Vilnius /etc/localtime

    hwclock --systohc

    echo -e "127.0.0.1 localhost\n::1       localhost" > /etc/hosts
    echo archbox-$(head /dev/urandom -c 2 | base64 | cut -c -3) > /etc/hostname

    mkinitcpio -p linux

    pacman --noconfirm -S grub-bios
    grub-install --recheck /dev/sda
    grub-mkconfig -o /boot/grub/grub.cfg

    useradd -m -G wheel userv
    sed -i "s/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers

    systemctl enable --now sshd
END
}

# prerequisites:
# - create passwd for root user in Live CD
# - start sshd service
# - connect to LiveCD via ssh
arch_install_vbox() {
    timedatectl set-ntp true
    mkpart_vbox
    mkfs.ext4 -F /dev/sda1
    mount /dev/sda1 /mnt
    printf -v items_to_install ' %s' "${main_items[@]} ${additional_items[@]} ${vbox_items[@]}"
    pacstrap /mnt $items_to_install
    genfstab -U /mnt >> /mnt/etc/fstab
    setup_from_chroot_vbox
    umount /mnt
    eject -m
    reboot -f
}

# =============== desktop ==============#

desktop_items=()

mkpart_desktop() {
    echo "empty so far"
}

setup_from_chroot_desktop() {
    echo "empty so far"
}

arch_install_desktop() {
    echo "empty so far"
}
