#!/usr/bin/env bash
set -euo pipefail

### ─── VARIABLES ─────────────────────────────────────────────────────────────
DISK=/dev/nvme0n1
EFI_PART="${DISK}p1"
LUKS_PART="${DISK}p2"
CRYPT_NAME=cryptlvm
VG_NAME=vg
LV_NAME=root

# locale / timezone / keyboard / font
REGION="Europe"
CITY="London"
LOCALE="en_GB.UTF-8"
KEYMAP="pl"
FONT="Lat2-Terminus16"
FONT_MAP="8859-2"

# pacstrap extras
CPU_UCODE="intel-ucode"      # or amd-ucode
EXTRA_PACKAGES="sudo vim lvm2 dracut sbsigntools iwd git efibootmgr binutils dhcpcd man-db"

# your new system user
HOSTNAME="myarch"
USERNAME="paul"

### ─── STAGE 1: Live USB ────────────────────────────────────────────────────

echo "📀  Partitioning ${DISK}..."
parted --script "${DISK}" \
  mklabel gpt \
  mkpart primary fat32 1MiB 513MiB \
  set 1 boot on \
  mkpart primary ext4 513MiB 100%

echo "📂  Formatting EFI..."
mkfs.fat -F32 "${EFI_PART}"

echo "🔒  Setting up LUKS2 on ${LUKS_PART}..."
cryptsetup luksFormat --type luks2 "${LUKS_PART}"
cryptsetup open \
  --perf-no_read_workqueue \
  --perf-no_write_workqueue \
  --persistent \
  "${LUKS_PART}" "${CRYPT_NAME}"

echo "🗃️  Configuring LVM..."
pvcreate "/dev/mapper/${CRYPT_NAME}"
vgcreate "${VG_NAME}" "/dev/mapper/${CRYPT_NAME}"
lvcreate -l 100%FREE "${VG_NAME}" -n "${LV_NAME}"

echo "🖴  Creating root FS..."
mkfs.ext4 "/dev/${VG_NAME}/${LV_NAME}"

echo "🚀  Mounting and pacstrapping..."
mount "/dev/${VG_NAME}/${LV_NAME}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi

pacstrap /mnt base linux linux-firmware "${CPU_UCODE}" ${EXTRA_PACKAGES}

echo "📝  Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

### ─── STAGE 2: Chroot setup ────────────────────────────────────────────────

cat > /mnt/root/chroot-install.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

# 1) Set root password
echo "🔐  Set root password:"
passwd

# 2) Timezone & clock
ln -sf /usr/share/zoneinfo/${REGION}/${CITY} /etc/localtime
hwclock --systohc

# 3) Locale
sed -i 's/^#\\(${LOCALE}\\)/\\1/' /etc/locale.gen
locale-gen
echo LANG=${LOCALE} > /etc/locale.conf

# 4) Console keymap & font
cat > /etc/vconsole.conf <<VCO
KEYMAP=${KEYMAP}
FONT=${FONT}
FONT_MAP=${FONT_MAP}
VCO

# 5) Hostname & hosts
echo "${HOSTNAME}" > /etc/hostname
cat >> /etc/hosts <<HST
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HST

# 6) Create user & wheel sudo
useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "🔐  Set password for ${USERNAME}:"
passwd ${USERNAME}
sed -i 's/^# \\(%wheel ALL=(ALL) ALL\\)/\\1/' /etc/sudoers

# 7) Enable networking
systemctl enable dhcpcd iwd

# 8) Install dracut hooks
mkdir -p /usr/local/bin
cat > /usr/local/bin/dracut-install.sh <<DINS
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
while read -r line; do
  if [[ "\$line" == usr/lib/modules/*/pkgbase ]]; then
    kver="\${line#usr/lib/modules/}"
    kver="\${kver%/pkgbase}"
    dracut --force --uefi --kver "\$kver" /boot/efi/EFI/Linux/arch-linux.efi
  fi
done
DINS
chmod +x /usr/local/bin/dracut-install.sh

cat > /usr/local/bin/dracut-remove.sh <<DREM
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/arch-linux.efi
DREM
chmod +x /usr/local/bin/dracut-remove.sh

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/90-dracut-install.hook <<HIN
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating linux EFI image
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
Depends = dracut
NeedsTargets
HIN

cat > /etc/pacman.d/hooks/60-dracut-remove.hook <<HREM
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing linux EFI image
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
HREM

# 9) Dracut config for unlocking & LVM
UUID=\$(blkid -s UUID -o value ${LUKS_PART})
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/cmdline.conf <<CMD
kernel_cmdline="rd.luks.uuid=\$UUID rd.lvm.lv=${VG_NAME}/${LV_NAME} root=/dev/mapper/${VG_NAME}-${LV_NAME} rootfstype=ext4 rw"
CMD

cat > /etc/dracut.conf.d/flags.conf <<FLG
compress="zstd"
hostonly="no"
FLG

# 10) Re-install linux to trigger hooks and build UKI
pacman -S --noconfirm linux

# 11) UEFI boot entry
efibootmgr --create --disk ${DISK} --part 1 \
  --label "Arch Linux" \
  --loader 'EFI\\Linux\\arch-linux.efi' \
  --unicode

echo "✅  Installation complete!  Reboot when ready."
EOF

chmod +x /mnt/root/chroot-install.sh
arch-chroot /mnt /root/chroot-install.sh
