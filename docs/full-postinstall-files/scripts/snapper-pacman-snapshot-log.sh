#!/bin/bash
# Captures the transaction's own pacman.log output alongside the snapshot,
# correlated to the same snapshot number the PreTransaction snapshot hook
# already created. pacman.log records every install/upgrade/remove
# unconditionally, regardless of how the transaction was triggered (a shell
# alias, yay, a cron job) — no wrapper or tee needed.

set -euo pipefail

SIDECAR_DIR=/var/log/snapper-pacman
PACMANLOG=/var/log/pacman.log

# Correlate to the snapshot the PreTransaction hook already made this run —
# the most recently created .pkglist file at this point is this transaction's
LATEST_PKGLIST=$(ls -t "$SIDECAR_DIR"/*.pkglist 2>/dev/null | head -1)
[ -z "$LATEST_PKGLIST" ] && exit 0   # no matching snapshot — nothing to attach to
SNAP_NUM=$(basename "$LATEST_PKGLIST" .pkglist)

# Isolate exactly this transaction's slice — safe because pacman only ever
# runs one transaction at a time, so the LAST "started" marker is always
# this one, regardless of how many older unrelated entries precede it
tac "$PACMANLOG" | awk '/\[ALPM\] transaction (started|interrupted)/{print; exit} {print}' | tac \
    > "${SIDECAR_DIR}/${SNAP_NUM}.pacmanlog"
