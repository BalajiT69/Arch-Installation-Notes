#!/bin/bash
set -e
cd "$(dirname "$0")/.."
pacman -S --needed - < pkglists/pkglist-official.txt
[ -s pkglists/pkglist-aur.txt ] && echo "Note: install AUR helper first, then: yay -S --needed - < pkglists/pkglist-aur.txt"
