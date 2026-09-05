#!/bin/bash
set -e
cd "$(dirname "$0")/.."
pacman -Qqen > pkglists/pkglist-official.txt
pacman -Qqem > pkglists/pkglist-aur.txt
echo "Package lists updated."
