#!/bin/bash
# Pre-transaction snapper snapshot helper for the pacman hook.
# pacman feeds the list of matched upgrade targets via stdin (NeedsTargets
# on the hook). Full package list goes to a sidecar file named after the
# snapshot number, so the snapper description itself can stay short.
# Snapshot is tagged with the "number" cleanup algorithm so NUMBER_CLEANUP
# in /etc/snapper/configs/root actually reaps it over time.

set -euo pipefail

SIDECAR_DIR=/var/log/snapper-pacman
mkdir -p "$SIDECAR_DIR"

packages=$(cat)
count=$(echo "$packages" | grep -c . || true)

if [[ -z "$packages" ]]; then
    description="pacman upgrade (no targets reported)"
else
    description="pacman upgrade (${count} packages)"
fi

snap_num=$(/usr/bin/snapper -c root create -d "$description" -t pre -c number -p)

if [[ -n "$packages" ]]; then
    echo "$packages" > "${SIDECAR_DIR}/${snap_num}.pkglist"
fi
