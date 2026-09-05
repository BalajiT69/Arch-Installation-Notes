#!/bin/bash
# One-time, INTERACTIVE setup script — run this yourself, once, from a real
# terminal. It is not a hook or a service: cryptsetup will prompt you for
# your existing LUKS passphrase multiple times below, by design.
#
# What this does, in order:
#   1. Creates a random keyfile and embeds it in the initramfs, so the
#      initramfs-stage LUKS prompt is answered automatically — collapsing
#      GRUB's own prompt + the initramfs prompt into a single visible ask.
#   2. Adds cryptkey=... to GRUB_CMDLINE_LINUX so GRUB knows to pass the
#      keyfile's location through to the initramfs.
#   3. Tunes BOTH LUKS keyslots (passphrase slot + new keyfile slot) to the
#      identical, lower-memory Argon2id cost — necessary because GRUB's own
#      Argon2id implementation is far slower than the kernel's, and GRUB
#      does not guarantee which keyslot it tries first.
#   4. Adds :allow-discards to cryptdevice=, without which discard=async in
#      fstab is a silent no-op — dm-crypt drops TRIM requests by default.
#   5. Regenerates grub.cfg.
#
# EDIT THESE THREE VARIABLES FIRST, to match your actual system:
LUKSPART="/dev/nvme0n1pN"      # your actual LUKS partition — check with: lsblk -f
GRUBCFG_OUT="/efi/grub/grub.cfg"  # or /boot/grub/grub.cfg if grub.cfg lives there instead
PBKDF_MEMORY_KB=262144          # 256 MiB — the tuned-down cost GRUB can handle in a few seconds

set -euo pipefail

echo "=== Step 1: Creating keyfile and embedding it in the initramfs ==="
dd if=/dev/urandom of=/etc/cryptroot.key bs=512 count=4
chmod 000 /etc/cryptroot.key
echo "You will now be asked for your EXISTING LUKS passphrase, to authorize adding the keyfile:"
cryptsetup luksAddKey "$LUKSPART" /etc/cryptroot.key

if ! grep -q '^FILES=(/etc/cryptroot.key)' /etc/mkinitcpio.conf; then
    echo 'FILES=(/etc/cryptroot.key)' >> /etc/mkinitcpio.conf
fi
mkinitcpio -P

echo "=== Step 2: Wiring cryptkey= and :allow-discards into GRUB_CMDLINE_LINUX ==="
if ! grep -q 'cryptkey=rootfs:/etc/cryptroot.key' /etc/default/grub; then
    sed -i '/GRUB_CMDLINE_LINUX=/ s/"$/ cryptkey=rootfs:\/etc\/cryptroot.key"/' /etc/default/grub
fi
if ! grep -q ':allow-discards' /etc/default/grub; then
    sed -i '/GRUB_CMDLINE_LINUX=/ s/:root/:root:allow-discards/' /etc/default/grub
fi
echo "Confirm this line looks right before continuing:"
grep GRUB_CMDLINE_LINUX /etc/default/grub

echo "=== Step 3: Tuning PBKDF cost on the PASSPHRASE keyslot ==="
echo "You will now be asked for your passphrase again, to authorize re-tuning that slot:"
cryptsetup luksConvertKey "$LUKSPART" --pbkdf argon2id --pbkdf-force-iterations 4 --pbkdf-memory "$PBKDF_MEMORY_KB"

echo "=== Identify the keyfile's own slot number ==="
echo "Look for the slot that does NOT yet show Memory: $PBKDF_MEMORY_KB below, note its number:"
cryptsetup luksDump "$LUKSPART" | grep -B6 "Memory:"

read -rp "Enter the keyfile slot's number (the one NOT yet tuned): " KEYFILE_SLOT

echo "=== Step 4: Tuning PBKDF cost on the KEYFILE keyslot (slot $KEYFILE_SLOT) ==="
cryptsetup luksConvertKey "$LUKSPART" --key-slot "$KEYFILE_SLOT" --key-file /etc/cryptroot.key \
  --pbkdf argon2id --pbkdf-force-iterations 4 --pbkdf-memory "$PBKDF_MEMORY_KB"

echo "=== Confirming both slots now match ==="
cryptsetup luksDump "$LUKSPART" | grep Memory

echo "=== Step 5: Regenerating GRUB config ==="
grub-mkconfig -o "$GRUBCFG_OUT"

echo ""
echo "Done. Reboot to test — you should see a single, fast passphrase prompt."
echo "Remember: back up the LUKS header again now that keyslots have changed"
echo "(see backup-luks-header.sh)."
