#!/bin/bash
# Injects the missing cryptomount block into every grub-btrfs-generated
# snapshot menuentry — a confirmed bug in the packaged grub-btrfs, whose
# own crypto-detection code checks the wrong GRUB cmdline variable and
# hardcodes an assumption that the LUKS mapper is named "cryptdev" rather
# than "root". Idempotent (safe to re-run), and traces the LUKS UUID from
# the actual mounted root rather than "whichever encrypted device the
# kernel happened to enumerate first" (a real ambiguity if a second LUKS
# volume is ever connected).
#
# IMPORTANT: if grub.cfg/grub-btrfs.cfg do not live at /efi/grub on your
# system, change GBCFG below to match (e.g. /boot/grub/grub-btrfs.cfg).
set -euo pipefail

GBCFG="/efi/grub/grub-btrfs.cfg"
[ -f "$GBCFG" ] || exit 0

# Debounce: grub-btrfsd may still be mid-write when the .path unit fires.
# Wait for the file size to settle before reading it, rather than risk
# processing (and overwriting) a half-written file.
SIZE1=$(stat -c%s "$GBCFG" 2>/dev/null || echo 0)
sleep 1
SIZE2=$(stat -c%s "$GBCFG" 2>/dev/null || echo 0)
if [ "$SIZE1" != "$SIZE2" ]; then
    logger -t grub-btrfs-crypto-fix "File still being written, deferring to next trigger"
    exit 0
fi

openers=$(grep -c -- "--class snapshots" "$GBCFG" || true)
already=$(grep -c "cryptomount -u" "$GBCFG" || true)

[ "$openers" -eq 0 ] && exit 0
[ "$already" -ge "$openers" ] && exit 0   # already patched — breaks the self-trigger loop

ROOT_MAPPER=$(findmnt -nvo SOURCE / | sed 's|/dev/mapper/||; s|\[.*\]||')
if [ -z "$ROOT_MAPPER" ]; then
    logger -t grub-btrfs-crypto-fix "Could not resolve root's mapper device, aborting"
    exit 1
fi
REAL_DEV=$(cryptsetup status "$ROOT_MAPPER" 2>/dev/null | awk '/device:/{print $2}')
if [ -z "$REAL_DEV" ]; then
    logger -t grub-btrfs-crypto-fix "Could not determine backing device for $ROOT_MAPPER, aborting"
    exit 1
fi
LUKS_UUID=$(blkid -s UUID -o value "$REAL_DEV" 2>/dev/null)
if [ -z "$LUKS_UUID" ]; then
    logger -t grub-btrfs-crypto-fix "Could not determine LUKS UUID, aborting"
    exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

awk -v uuid="$LUKS_UUID" '
/--class snapshots.*\{[[:space:]]*$/ {
    print
    print "        insmod gzio"
    print "        insmod part_gpt"
    print "        insmod cryptodisk"
    print "        insmod luks2"
    print "        insmod gcry_rijndael"
    print "        insmod gcry_sha256"
    print "        insmod gcry_sha512"
    print "        cryptomount -u " uuid
    next
}
{ print }
' "$GBCFG" > "$TMP"

mv "$TMP" "$GBCFG"
logger -t grub-btrfs-crypto-fix "Patched $openers snapshot menuentry blocks with cryptomount"
