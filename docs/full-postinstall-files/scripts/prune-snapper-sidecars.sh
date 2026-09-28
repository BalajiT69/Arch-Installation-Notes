#!/bin/bash
# Prunes orphaned sidecar package-list and pacmanlog files whose corresponding snapper
# snapshot no longer exists (snapper's own cleanup already deleted it).

set -euo pipefail

SIDECAR_DIR=/var/log/snapper-pacman
CONFIG=root

if [[ ! -d "$SIDECAR_DIR" ]]; then
    exit 0
fi

# Current valid snapshot numbers for the config, one per line
valid_numbers=$(snapper -c "$CONFIG" list --columns number 2>/dev/null | tail -n +3 | tr -d ' ')

# Safety guard: snapper always lists snapshot 0 ("current"), so an empty result
# means the query itself failed. Abort rather than treat every sidecar file as an
# orphan and delete all of them.
if [[ -z "$valid_numbers" ]]; then
    echo "prune-snapper-sidecars: snapper returned no snapshot list, aborting without deleting anything" >&2
    exit 1
fi

removed_pkglists=0
removed_pacmanlogs=0

for f in "$SIDECAR_DIR"/*.pkglist; do
    [[ -e "$f" ]] || continue  # handles empty dir (nullglob not set)
    base=$(basename "$f" .pkglist)
    if ! grep -qx "$base" <<< "$valid_numbers"; then
        rm -f "$f"
        removed_pkglists=$((removed_pkglists + 1))
    fi
done

for f in "$SIDECAR_DIR"/*.pacmanlog; do
    [[ -e "$f" ]] || continue  # handles empty dir (nullglob not set)
    base=$(basename "$f" .pacmanlog)
    if ! grep -qx "$base" <<< "$valid_numbers"; then
        rm -f "$f"
        removed_pacmanlogs=$((removed_pacmanlogs + 1))
    fi
done

echo "prune-snapper-sidecars: removed ${removed_pkglists} orphaned .pkglist file(s)"
echo "prune-snapper-sidecars: removed ${removed_pacmanlogs} orphaned .pacmanlog file(s)"
