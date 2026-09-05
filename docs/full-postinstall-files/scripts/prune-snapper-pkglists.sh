#!/bin/bash
# Prunes orphaned sidecar package-list files whose corresponding snapper
# snapshot no longer exists (snapper's own cleanup already deleted it).

set -euo pipefail

SIDECAR_DIR=/var/log/snapper-pacman
CONFIG=root

if [[ ! -d "$SIDECAR_DIR" ]]; then
    exit 0
fi

# Current valid snapshot numbers for the config, one per line
valid_numbers=$(snapper -c "$CONFIG" list --columns number 2>/dev/null | tail -n +3 | tr -d ' ')

removed=0
for f in "$SIDECAR_DIR"/*.pkglist; do
    [[ -e "$f" ]] || continue  # handles empty dir (nullglob not set)
    base=$(basename "$f" .pkglist)
    if ! grep -qx "$base" <<< "$valid_numbers"; then
        rm -f "$f"
        removed=$((removed + 1))
    fi
done

echo "prune-snapper-pkglists: removed ${removed} orphaned file(s)"
