#!/bin/bash
# archstone
# ------------------------------------------------------------------------
# arch linux install script
# es@ethanschoonover.com @ethanschoonover
#
# scp this script into a system booted from Arch install media
# this version design for systems successfully booted using EFI

# ------------------------------------------------------------------------
# 0 ENVIRONMENT
# ------------------------------------------------------------------------
# language, fonts, keymaps, timezone

HOSTNAME=tau
FONT=Lat2-Terminus16
LANGUAGE=en_US.UTF-8
TIMEZONE=US/Pacific
USERNAME=es # not used yet
USERSHELL=zsh

# ------------------------------------------------------------------------
# 0 SCRIPT SETTINGS AND HELPER FUNCTIONS
# ------------------------------------------------------------------------

#set -o nounset
#set -o errexit

SetValue () { VALUENAME="$1" NEWVALUE="$2" FILEPATH="$3"; 
sed -i "s+^#\?\(${VALUENAME}\)=.*$+\1=${NEWVALUE}+" "${FILEPATH}"; }

CommentOutValue () { VALUENAME="$1" FILEPATH="$2"; 
sed -i "s/^\(${VALUENAME}.*\)$/#\1/" "${FILEPATH}"; }

UncommentValue () { VALUENAME="$1" FILEPATH="$2"; 
sed -i "s/^#\(${VALUENAME}.*\)$/\1/" "${FILEPATH}"; }

AddToList () { NEWITEM="$1" LISTNAME="$2" FILEPATH="$3"; 
sed -i "s/\(${LISTNAME}.*\)\()\)/\1 ${NEWITEM}\2/" "${FILEPATH}"; }

GetUUID () {
VOLPATH="$1";
blkid ${DRIVE}${PARTITION_CRYPT_SWAP} \
| awk '{ print $2 }' \
| sed "s/UUID=\"\(.*\)\"/\1/";
}

AURInstall () {
if wget --help > /dev/null; then :; else pacman -S --noconfirm wget; fi;
ORIGDIR="$(pwd)"; mkdir -p /tmp/${1}; cd /tmp/${1};
wget "https://aur.archlinux.org/packages/${1}/${1}.tar.gz";
tar -xzvf ${1}.tar.gz; cd ${1}; makepkg --asroot -si;
cd "$ORIGDIR"; rm -rf /tmp/${1}; 
}

# ------------------------------------------------------------------------
# 1 PREFLIGHT
# ------------------------------------------------------------------------

setfont $FONT

# ------------------------------------------------------------------------
# 2 DRIVE
# ------------------------------------------------------------------------

DRIVE=/dev/sda
PARTITION_EFI_BOOT=1
PARTITION_CRYPT_SWAP=2
PARTITION_CRYPT_ROOT=3
LABEL_BOOT_EFI=bootefi
LABEL_SWAP=swap
LABEL_SWAP_CRYPT=cryptswap
LABEL_ROOT=root
LABEL_ROOT_CRYPT=cryptroot
MOUNT_PATH=/mnt
EFI_BOOT_PATH=/boot/efi

##########################################################################
# START FIRST RUN SECTION (PRE CHROOT)
##########################################################################

if [ `basename $0` != "postchroot.sh" ]; then

# ------------------------------------------------------------------------
# 3 FILESYSTEM
# ------------------------------------------------------------------------
# Here we create three partitions:
# 1. efi and /boot (one partition does double duty)
# 2. swap
# 3. our encrypted root
# Note that all of these are on a GUID partition table scheme. This proves
# to be quite clean and simple since we're not doing anything with MBR
# boot partitions and the like.

# disk prep
sgdisk -Z ${DRIVE} # zap all on disk
sgdisk -a 2048 -o ${DRIVE} # new gpt disk 2048 alignment

# create partitions
# (UEFI BOOT), default start block, 200MB
sgdisk -n ${PARTITION_EFI_BOOT}:0:+200M ${DRIVE}
# (SWAP), default start block, 2GB
sgdisk -n ${PARTITION_CRYPT_SWAP}:0:+2G ${DRIVE}
# (LUKS), default start, remaining space
sgdisk -n ${PARTITION_CRYPT_ROOT}:0:0 ${DRIVE}

# set partition types
sgdisk -t ${PARTITION_EFI_BOOT}:ef00 ${DRIVE}
sgdisk -t ${PARTITION_CRYPT_SWAP}:8200 ${DRIVE}
sgdisk -t ${PARTITION_CRYPT_ROOT}:8300 ${DRIVE}

# label partitions
sgdisk -c ${PARTITION_EFI_BOOT}:"${LABEL_BOOT_EFI}" ${DRIVE}
sgdisk -c ${PARTITION_CRYPT_SWAP}:"${LABEL_SWAP}" ${DRIVE}
sgdisk -c ${PARTITION_CRYPT_ROOT}:"${LABEL_ROOT}" ${DRIVE}

# format LUKS on root
cryptsetup --cipher=aes-xts-plain --verify-passphrase --key-size=512 \
luksFormat ${DRIVE}${PARTITION_CRYPT_ROOT}
cryptsetup luksOpen ${DRIVE}${PARTITION_CRYPT_ROOT} ${LABEL_ROOT_CRYPT}

# make filesystems
mkfs.vfat ${DRIVE}${PARTITION_EFI_BOOT}
mkfs.ext4 /dev/mapper/${LABEL_ROOT_CRYPT}

# mount target
# mkdir ${MOUNT_PATH}
mount /dev/mapper/${LABEL_ROOT_CRYPT} ${MOUNT_PATH}
mkdir -p ${MOUNT_PATH}${EFI_BOOT_PATH}
mount -t vfat ${DRIVE}${PARTITION_EFI_BOOT} ${MOUNT_PATH}${EFI_BOOT_PATH}

# install base system
pacstrap ${MOUNT_PATH} base base-devel

# ------------------------------------------------------------------------
# 4 BASE INSTALL
# ------------------------------------------------------------------------

# DEBUG: does this need to be here before install?
# kernel modules for EFI install
# ------------------------------------------------------------------------
modprobe efivars
modprobe dm-mod

pacstrap ${MOUNT_PATH} base base-devel

# ------------------------------------------------------------------------
# 5 FILESYSTEM
# ------------------------------------------------------------------------

# write to crypttab
# note: only /dev/disk/by-partuuid, /dev/disk/by-partlabel and
# /dev/sda2 formats work here
cat > ${MOUNT_PATH}/etc/crypttab <<CRYPTTAB_EOF
${LABEL_SWAP_CRYPT} /dev/disk/by-partlabel/${LABEL_SWAP} \
/dev/urandom swap,allow-discards
CRYPTTAB_EOF

# not using genfstab here since it doesn't record partlabel labels
cat > ${MOUNT_PATH}/etc/fstab <<FSTAB_EOF
# /etc/fstab: static file system information
#
# <file system>					<dir>		<type>	\
<options>				<dump>	<pass>

tmpfs						/tmp		tmpfs	\
nodev,nosuid				0	0

/dev/mapper/${LABEL_ROOT_CRYPT}			/      		ext4	\
rw,relatime,data=ordered,discard	0	1

/dev/disk/by-partlabel/${LABEL_BOOT_EFI}	$EFI_BOOT_PATH	vfat	\
rw,relatime,discard			0	2

/dev/mapper/${LABEL_SWAP_CRYPT}			none		swap	\
defaults,discard			0	0
FSTAB_EOF

# ------------------------------------------------------------------------
# 6 CHROOT
# ------------------------------------------------------------------------

# unmount EFI volume first (needs to be remounted post-chroot for grub)
umount ${MOUNT_PATH}${EFI_BOOT_PATH}

cp "$0" "${MOUNT_PATH}/postchroot.sh"

echo -e "\narch-chroot ${MOUNT_PATH} then continue with /postchroot.sh"
exit

#arch-chroot ${MOUNT_PATH} <<EOF
#/postchroot.sh
#EOF

#rm ${MOUNT_PATH}/postchroot.sh
#echo "end of script"
#exit
#unmount /mnt/boot/efi
#unmount /mnt
#reboot
fi

##########################################################################
# START SECOND RUN SECTION (POST CHROOT)
##########################################################################

# ------------------------------------------------------------------------
# remount efi boot volume
# ------------------------------------------------------------------------
# remount efi boot volume here or grub et al gets confused
mount -t vfat ${DRIVE}${PARTITION_EFI_BOOT} ${EFI_BOOT_PATH}

# ------------------------------------------------------------------------
# language
# ------------------------------------------------------------------------
UncommentValue ${LANGUAGE} /etc/locale.gen
locale-gen
echo LANG=${LANGUAGE} > /etc/locale.conf
export LANG=${LANGUAGE}
cat > /etc/vconsole.conf <<VCONSOLECONF
KEYMAP=
FONT=${FONT}
FONT_MAP=
VCONSOLECONF

# ------------------------------------------------------------------------
# TIME
# ------------------------------------------------------------------------
ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo ${TIMEZONE} >> /etc/timezone
hwclock --systohc --utc # set hardware clock

# ------------------------------------------------------------------------
# HOSTNAME
# ------------------------------------------------------------------------
echo ${HOSTNAME} > /etc/hostname
sed -i "s/localhost\.localdomain/${HOSTNAME}/g" /etc/hosts

# ------------------------------------------------------------------------
# 7 NETWORK
# ------------------------------------------------------------------------
pacman --noconfirm -S \
wireless_tools netcfg wpa_supplicant wpa_actiond dialog
AddToList net-auto-wireless DAEMONS /etc/rc.conf

# ------------------------------------------------------------------------
# 8 RAMDISK
# ------------------------------------------------------------------------

# NOTE: intel_agp drm and i915 for intel graphics
MODULES="dm_mod dm_crypt aes_x86_64 ext2 ext4 vfat intel_agp drm i915"
HOOKS="usb usbinput consolefont encrypt filesystems"
sed -i "s/^MODULES.*$/MODULES=\"${MODULES}\"/" /etc/mkinitcpio.conf
sed -i "s/\(^HOOKS.*\) filesystems \(.*$\)/\1 ${HOOKS} \2/" \
/etc/mkinitcpio.conf

mkinitcpio -p linux

# ------------------------------------------------------------------------
# 9 BOOTLOADER
# ------------------------------------------------------------------------

modprobe efivars
modprobe dm-mod
pacman -S --noconfirm wget efibootmgr gummiboot-efi-x86_64
#AURInstall gummiboot-efi-x86_64 #gummiboot in extra now
install -Dm0644 /usr/lib/gummiboot/gummiboot.efi \
/boot/efi/EFI/arch/gummiboot.efi
install -Dm0644 /usr/lib/gummiboot/gummiboot.efi \
/boot/efi/EFI/boot/bootx64.efi
efibootmgr -c -l '\EFI\arch\gummiboot.efi\' -L "Arch Linux"
cp /boot/vmlinuz-linux /boot/efi/EFI/arch/vmlinuz-linux.efi
cp /boot/initramfs-linux.img /boot/efi/EFI/arch/initramfs-linux.img
cp /boot/initramfs-linux-fallback.img \
/boot/efi/EFI/arch/initramfs-linux-fallback.img
mkdir -p ${EFI_BOOT_PATH}/loader/entries
cat >> ${EFI_BOOT_PATH}/loader/default.conf <<GUMMILOADER
default arch
timeout 4
GUMMILOADER
cat >> ${EFI_BOOT_PATH}/loader/entries/arch.conf <<GUMMIENTRIES
title          Arch Linux
efi            \\EFI\\arch\\vmlinuz-linux.efi
options        initrd=\\EFI\\arch\initramfs-linux.img \
cryptdevice=/dev/sda3:${LABEL_ROOT_CRYPT} \
root=/dev/mapper/${LABEL_ROOT_CRYPT} ro rootfstype=ext4 
GUMMIENTRIES

# ------------------------------------------------------------------------
# 10 POSTFLIGHT
# ------------------------------------------------------------------------

umount $EFI_BOOT_PATH
exit