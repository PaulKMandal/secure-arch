#!/usr/bin/env bash
set -euo pipefail

### ─── INTERACTIVE VARIABLES ──────────────────────────────────────────────────
read -rp "Target install disk (e.g. /dev/nvme0n1): " DISK
read -rp "New hostname: " HOSTNAME
read -rp "New username: " USERNAME

# Prompt for LUKS passphrase twice, up front
while true; do
  read -rsp "Enter LUKS passphrase: " LUKS_PASS
  echo
  read -rsp "Confirm LUKS passphrase: " LUKS_PASS2
  echo
  [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
  echo "❌  Passphrases do not match, please try again."
done

# Timezone defaults
read -rp "Time zone region (default America): " REGION
REGION=${REGION:-America}
read -rp "Time zone city   (default Chicago): " CITY
CITY=${CITY:-Chicago}

EFI_PART="${DISK}p1"
LUKS_PART="${DISK}p2"
CRYPT_NAME=cryptlvm
VG_NAME=vg
LV_NAME=root

LOCALE="en_US.UTF-8"
KEYMAP="us"
EXTRA_PACKAGES="sudo vim lvm2 dracut sbsigntools iwd git efibootmgr binutils dhcpcd man-db"

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
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "${LUKS_PART}" -
echo -n "$LUKS_PASS" | cryptsetup open \
    --perf-no_read_workqueue --perf-no_write_workqueue --persistent \
    --key-file=- "${LUKS_PART}" "${CRYPT_NAME}"

echo "🗃️  LVM setup..."
pvcreate "/dev/mapper/${CRYPT_NAME}"
vgcreate "${VG_NAME}" "/dev/mapper/${CRYPT_NAME}"
lvcreate -l 100%FREE "${VG_NAME}" -n "${LV_NAME}"

echo "🖴  Make root FS..."
mkfs.ext4 "/dev/${VG_NAME}/${LV_NAME}"

echo "🚀  Mounting + pacstrap prelude..."
mount "/dev/${VG_NAME}/${LV_NAME}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi

### ─── AUTO-DETECT MICROCODE ────────────────────────────────────────────────
CPU_VENDOR_ID=$(awk -F: '/^vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d '[:space:]')
if [[ "$CPU_VENDOR_ID" == "GenuineIntel" ]]; then
  CPU_UCODE="intel-ucode"
elif [[ "$CPU_VENDOR_ID" == "AuthenticAMD" ]]; then
  CPU_UCODE="amd-ucode"
else
  CPU_UCODE=""
  echo "⚠️  Unknown CPU vendor '$CPU_VENDOR_ID' → skipping microcode."
fi
echo "🔍  Will install microcode: ${CPU_UCODE:-<none>}"

echo "📦  Installing base system..."
pacstrap /mnt base linux linux-firmware ${CPU_UCODE} ${EXTRA_PACKAGES}

echo "📝  Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

### ─── STAGE 2: Chroot setup ────────────────────────────────────────────────

cat > /mnt/root/chroot-install.sh <<EOF
#!/usr/bin/env bash
set -eo pipefail

echo "🔐  Set root password:"
passwd

echo "🌐  Timezone & clock"
ln -sf /usr/share/zoneinfo/${REGION}/${CITY} /etc/localtime
hwclock --systohc

echo "🔤  Locale"
sed -i 's/^#\\(${LOCALE}\\)/\\1/' /etc/locale.gen
locale-gen
echo LANG=${LOCALE} > /etc/locale.conf

echo "⌨️  Console keymap"
echo KEYMAP=${KEYMAP} > /etc/vconsole.conf

echo "🏷️  Hostname & hosts"
echo ${HOSTNAME} > /etc/hostname
cat >> /etc/hosts <<HST
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HST

echo "👤  Create user & sudoers"
useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "🔐  Set password for ${USERNAME}:"
passwd ${USERNAME}

# Enable wheel + perpetual sudo
sed -i 's/^# \\(%wheel ALL=(ALL) ALL\\)/\\1/' /etc/sudoers
echo Defaults timestamp_timeout=-1 >> /etc/sudoers

echo "🌐  Enable networking"
systemctl enable dhcpcd iwd

echo "🛠️  Install dracut hooks"
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

echo "🔑  Dracut LUKS & LVM config"
UUID=\$(blkid -s UUID -o value ${LUKS_PART})
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/cmdline.conf <<CMD
kernel_cmdline="rd.luks.uuid=\$UUID rd.lvm.lv=${VG_NAME}/${LV_NAME} root=/dev/mapper/${VG_NAME}-${LV_NAME} rootfstype=ext4 rw"
CMD

cat > /etc/dracut.conf.d/flags.conf <<FLG
compress="zstd"
hostonly="no"
FLG

echo "🔄  Re-install linux to build UKI"
pacman -S --noconfirm linux

echo "🖥️  Create UEFI boot entry"
efibootmgr --create --disk ${DISK} --part 1 \
  --label "Arch Linux" \
  --loader 'EFI\\Linux\\arch-linux.efi' \
  --unicode

echo "✅  Done!  Exit chroot and reboot."
EOF

chmod +x /mnt/root/chroot-install.sh
arch-chroot /mnt /root/chroot-install.sh
