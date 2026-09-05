#!/bin/bash
# Backs up the LUKS header for the given partition. Run this once at initial
# setup, and again after ANY keyslot change (adding/removing a keyfile,
# re-tuning PBKDF cost, changing your passphrase) — an old header backup
# does not necessarily match your CURRENT keyslots.
#
# This only creates the backup file locally — moving it off this disk
# (a USB drive, another machine, cloud storage) is still on you to do
# afterward. A header backup sitting on the same disk it protects is not
# a backup in any meaningful sense.
#
# Usage: sudo ./backup-luks-header.sh /dev/nvme0n1pN
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <luks-partition>   e.g. $0 /dev/nvme0n1p9" >&2
    exit 1
fi

LUKSPART="$1"
OUTFILE="$HOME/$(cat /etc/hostname)-luks-header-backup-$(date +%Y%m%d).img"

cryptsetup luksHeaderBackup "$LUKSPART" --header-backup-file "$OUTFILE"

echo ""
echo "Header backed up to: $OUTFILE"
echo "Move this file OFF this disk now — scp, USB drive, cloud storage."
echo "Example: scp \"$OUTFILE\" user@otherhost:~/"
