# Arch Linux Install Guide — Manual Path, LUKS Encrypted
### Dell Latitude 5410 · Btrfs + Snapper + GRUB + Minimal KDE Plasma, Dual-Boot with Windows

This is the fully-manual (`pacstrap`-based) install path, with LUKS full-disk encryption baked in
throughout rather than treated as an add-on. If you'd rather drive the disk/package setup through
archinstall's guided menu instead, see the companion document,
**"Arch Linux Install Guide — archinstall Path, LUKS Encrypted."** Both land in the same end state
and share everything from Snapper onward.

Every destructive command below only touches the partitions we explicitly carve out. Windows and
its own ESP are never formatted — only ever read.

---

## 0. Decisions made for you, and why

**Bootloader: GRUB, not Limine.** GRUB has native btrfs support, and `grub-btrfs` — an official Arch
package, no AUR needed — auto-generates boot menu entries for every Snapper snapshot and
regenerates the menu automatically whenever a new snapshot is taken. Limine's equivalent
(`limine-snapper-sync`) is AUR-only and less documented for this exact workflow. GRUB's
os-prober-based Windows detection is mature and well-tested.

**A dedicated ESP for Arch, separate from Windows' own.** 300MiB, FAT32, holding only GRUB's own
loader and support files. UEFI firmware doesn't care how many ESPs exist on a disk — it scans all of
them and lists every registered boot entry regardless of which one it lives on, so Windows and Arch
staying on separate ESPs changes nothing about dual-boot working correctly; it's purely a
organizational choice, not a functional requirement.

**`grub.cfg` lives on that dedicated ESP, not inside the encrypted root — set up this way from the
start.** Right now `/boot` still lives inside the encrypted `@` subvolume (see the next point for
why), but GRUB's own config file doesn't have to. Splitting them means: **Windows boots with zero
decryption prompt at all**, since GRUB never has to touch LUKS just to display its menu — only
selecting the Arch entry triggers a decrypt. This is a real, confirmed-working setup, not a
theoretical one: `grub-install --boot-directory=/efi` (a separate flag from `--efi-directory`) is
what makes it happen, and Step 11 below does this from the very first `grub-install`, not as a
later fix.

**Btrfs subvolume layout: flat, top-level siblings for everything *except* `.snapshots` — which is
deliberately left for Snapper itself to create, nested inside `@`, not pre-created by us — with
`/boot` kept *inside* the root subvolume `@`.**
The `/boot`-inside-`@` choice is what makes "restore must also restore the correct kernel/initramfs"
actually work. If `/boot` were its own separate subvolume or partition, a snapshot of `@` would
**not** include the kernel/initramfs active at snapshot time — restoring `@` would silently leave
you with whatever the *current* kernel happens to be, which can be inconsistent, and on Arch
specifically (which only ever keeps one installed kernel version, unlike Ubuntu/Debian) a mismatch
here is a hard boot failure, not a degraded-but-working state. By keeping `/boot` as an ordinary
directory inside `@`, every snapshot of `@` automatically carries its own matching
`vmlinuz`/`initramfs`. Because `/boot` is encrypted this way, **GRUB itself has to unlock LUKS** just
to read the kernel — modern GRUB (2.06+) supports this natively via `GRUB_ENABLE_CRYPTODISK=y` plus
the `cryptodisk`/`luks2` modules, which is exactly what avoids the traditional workaround of a
separate, unencrypted `/boot` — a workaround this guide deliberately avoids, since it would
reintroduce the exact kernel/snapshot mismatch risk above.

The `.snapshots` point is the result of real, hard-won trial and error, and it's the single most
important correction in this guide, so it's worth stating plainly: **do not pre-create a
`@snapshots` subvolume yourself.** Btrfs Assistant's own source code (`isSnapper()` in
`btrfs-assistant.cpp`) determines whether a subvolume is a restorable snapshot by checking whether
its path contains the literal substring `.snapshots` — **with the dot**. A subvolume named
`@snapshots` (no dot) never matches that check; a subvolume named `.snapshots` does. This was
confirmed by direct A/B testing: a pre-created `@snapshots` subvolume reliably fails GUI restore
(`Failed to restore subvolume!`) every time; letting `snapper -c root create-config /` create its
own `.snapshots`, nested inside `@`, restores cleanly via the GUI every time, verified across three
separate destructive drills (deleted kernel, deleted `/etc`, deleted `/usr` + the package database).
Step 6 below creates every subvolume this guide needs *except* `.snapshots`; Step 12 is where Snapper
creates it, and that's the only correct place for it to happen.

**Snapshot boot: `grub-btrfs` + `grub-btrfs-overlayfs` + `snapper`, and both GUI and CLI restore
work correctly.** All three are official Arch packages — **no AUR helper is required anywhere in
this guide.** `grub-btrfs` adds an "Arch Linux snapshots" submenu to GRUB. Snapshots are read-only
by default, which would otherwise break a full desktop boot, so we add the `grub-btrfs-overlayfs`
mkinitcpio hook — the officially recommended way to boot a snapshot with a temporary RAM-backed
writable overlay, like a live CD: fully functional, nothing you do in that session touches the real
snapshot. **Keep this hook enabled — it is not optional and does not cost you anything.** It was
directly tested with a full `/usr` + `/var/lib/pacman` wipeout while booted from a snapshot with the
hook active: the running session, `pacman` itself, and a subsequent GUI restore all worked without
issue.

With `.snapshots` created correctly and this hook in place, **Btrfs Assistant's GUI restore works
reliably, including while booted from inside the snapshot you're restoring** — this guide installs
`btrfs-assistant` as a first-class tool. The manual CLI method (Step 18) remains documented too, as
a proven fallback that doesn't depend on any of the above.

**Login manager: Plasma Login Manager (PLM), not SDDM — and its state directory gets its own
subvolume.** As of Plasma 6.6, KDE ships PLM, a purpose-built fork of SDDM, and it's the current
ArchWiki-recommended choice. A login manager's runtime state directory (`/var/lib/plasmalogin`)
needs to be writable, and if you boot a *raw read-only* snapshot from GRUB, that directory can end
up stuck read-only even with the overlay hook active — a documented btrfs quirk where mount-state
flags can be shared at the whole-filesystem level. The confirmed fix is using the classic `udev`
mkinitcpio hook chain rather than the newer `systemd` one (this guide uses `udev` throughout — see
Step 13), plus giving `/var/lib/plasmalogin` and `/var/lib/AccountsService` (user avatars) their own
top-level subvolumes as cheap extra insurance, the same pattern Fedora's own Btrfs-snapshot guide
uses for `/var/lib/gdm`.

**KDE: `plasma` group (workspace only) + your exact app list, not `kde-applications`.** Arch's
`plasma` group is just the workspace — it does **not** pull in the Dolphin/Konsole/etc. app suite.
We install that group plus exactly: Dolphin (+ plugins), Konsole, Gwenview, Spectacle, Okular, plus
`kio-extras` and thumbnailer packages — nothing else.

**Kernel: `linux` only.** No `linux-lts` alongside it — the snapshot/`grub-btrfs` setup this whole
guide builds already gives kernel-level rollback protection regardless of which kernel track you're
on, so a second kernel installed purely as a fallback is redundant with a safety net you already
have.

**Swap: zram, not a btrfs swapfile or a dedicated partition.** With 16GB RAM and no hibernation
requirement, zram is simply the better fit — compressed RAM-backed swap, no partition to manage, no
btrfs swapfile caveats.

**Two LUKS keyslots, both tuned to the same PBKDF cost.** One for your memorized passphrase, one for
a random keyfile that collapses GRUB's two decrypt stages (its own read of `/boot`, then the
initramfs's mount of root) into a single prompt. Both get tuned in Step 19 — GRUB doesn't guarantee
which slot it tries first, so leaving either one untuned makes boot speed inconsistent from one boot
to the next.

**Snapshot-boot with encryption needs a small fix of our own — `grub-btrfs`'s built-in handling of
this is currently broken.** The packaged `grub-btrfs` has an opt-in flag,
`GRUB_BTRFS_ENABLE_CRYPTODISK`, that's supposed to auto-detect encryption and unlock it for
snapshot boot entries — it doesn't work (confirmed via direct trace: wrong config variable checked,
plus a hardcoded assumption about the LUKS mapping's name that doesn't match this guide's setup),
and turning it on actively breaks `grub-mkconfig` silently. Step 13 leaves that flag off and installs
a small, self-contained script instead that patches `grub-btrfs`'s own output directly — validated
end-to-end, including a real disaster-recovery drill (`/etc` deleted outright, recovered via
snapshot boot, restored via Btrfs Assistant).

---

## 1. Before you touch anything

1. **Back up anything on the target partition you want to keep.** It will be completely erased.
2. Confirm: BitLocker off, Fast Startup off, Secure Boot off in Windows/BIOS.
3. Have a way to get online during install: know your Wi-Fi SSID/password, or use an Ethernet dongle.
4. Download the latest Arch ISO from https://archlinux.org/download/ and write it to a USB stick.
   Verify the checksum.
5. Boot the USB stick. At the boot logo, tap **F12** repeatedly for the one-time boot menu, and
   choose the USB drive under **UEFI:** (not "Legacy" — this guide assumes UEFI mode throughout).

---

## 2. Live environment: verify UEFI mode, get online, and add archzfs-adjacent hygiene

```bash
cat /sys/firmware/efi/fw_platform_size
```
This **must** print `64` — if the directory doesn't exist at all, you booted in legacy/CSM mode;
reboot into the F12 menu and pick the UEFI entry instead.

If you're on Ethernet, you likely already have a connection (check with `ip a`). For Wi-Fi:
```bash
iwctl
device list
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "Your-SSID-Here"
exit
```

Verify connectivity and sync the clock (a wrong clock breaks package signature checks):
```bash
ping -c3 archlinux.org
timedatectl set-ntp true
```

Refresh the mirrorlist for faster downloads:
```bash
reflector --country India --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
```

**Recommended: SSH in from another machine now**, so the rest of this guide can be typed/pasted from
a real terminal instead of the laptop's own keyboard:
```bash
passwd                 # temporary root password, only for this live session
systemctl status sshd  # confirm it's active (enabled by default on the Arch ISO)
ip a                   # note the IP address on your active interface
```
From your other machine:
```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<the-ip-you-noted>
```

Run a terminal multiplexer so a dropped connection doesn't kill a long-running command mid-install:
```bash
tmux new -s install
# if disconnected: reconnect with the same ssh command, then:
tmux attach -t install
```

---

## 3. Identify your disk and partitions — do not skip or assume

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,PARTTYPENAME,MOUNTPOINT
```

Confirm which partition currently holds the OS you're replacing, and which are Windows/Dell
partitions to leave completely alone. Mount read-only and sanity-check before doing anything
destructive:
```bash
mkdir -p /mnt/check
mount -o ro /dev/nvme0n1pN /mnt/check      # the partition you're about to erase
cat /mnt/check/etc/os-release
ls /mnt/check/home
umount /mnt/check
```

---

## 4. Partition: a dedicated ESP for Arch, plus the encrypted btrfs partition

```bash
lsblk -f
```
Leave any existing Windows/shared ESP completely alone. The partition holding the OS you're
replacing gets wiped and **split into two new partitions**: a small dedicated FAT32 ESP for Arch,
and the rest as the encrypted btrfs partition.

⚠️ Confirm the exact device and partition number before running any of this — `sgdisk` deletes the
target partition and everything on it:
```bash
export TARGET=/dev/nvme0n1
export TARGETNUM=N   # the partition number you're replacing — verify first

sgdisk --delete=$TARGETNUM "$TARGET"

# New dedicated ESP, 300MiB:
sgdisk --new=$TARGETNUM:0:+300MiB --typecode=$TARGETNUM:ef00 --change-name=$TARGETNUM:"Arch ESP" "$TARGET"

# Everything remaining goes to the encrypted btrfs partition (next partition number):
sgdisk --new=$((TARGETNUM+1)):0:0 --typecode=$((TARGETNUM+1)):8300 --change-name=$((TARGETNUM+1)):"Arch LUKS" "$TARGET"

partprobe "$TARGET"
lsblk -f "$TARGET"   # confirm both new partitions exist, correctly typed
```

Export safety variables — every command from here on uses these instead of hardcoded names:
```bash
export DISK=/dev/nvme0n1
export ESP=/dev/nvme0n1pN          # the new 300MiB Arch ESP
export LUKSPART=/dev/nvme0n1pN     # the new, larger partition — will hold LUKS+btrfs
echo "ESP=$ESP  LUKSPART=$LUKSPART"
lsblk $DISK
```

Format the new ESP:
```bash
mkfs.fat -F32 -n "ARCHESP" "$ESP"
```

---

## 5. Encrypt and format

```bash
cryptsetup luksFormat --type luks2 "$LUKSPART"
# type YES (all caps) to confirm, then set your encryption passphrase

cryptsetup open "$LUKSPART" root
# enter the passphrase you just set

export ROOTPART=/dev/mapper/root
mkfs.btrfs -f -L archlinux "$ROOTPART"
```

---

## 6. Create the subvolume layout — deliberately *without* `.snapshots`

```bash
mount "$ROOTPART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@var_spool
btrfs subvolume create /mnt/@var_lib_plasmalogin
btrfs subvolume create /mnt/@var_lib_accountsservice

btrfs subvolume list /mnt          # sanity check: you should see all 12 above
umount /mnt
```

**Notice there is no `@snapshots` (or `.snapshots`) creation here — this is deliberate.** See Step 0.

Notes on this layout:
- `@` is `/`, and **`/boot` is NOT separated out** — it's an ordinary directory inside `@`.
- `@opt` is split out for the same reason as `@home`: manually-installed, non-pacman-managed
  software shouldn't be silently deleted by a rollback.
- `@var_log`, `@var_cache`, `@var_tmp`, `@var_spool` are split out so log/cache churn doesn't bloat
  snapshots, and stay writable during a snapshot boot.
- `@var_lib_plasmalogin` and `@var_lib_accountsservice` keep the login manager's state writable
  during a snapshot boot too.

---

## 7. Mount everything for installation

```bash
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@ "$ROOTPART" /mnt

mkdir -p /mnt/{home,root,srv,tmp,opt,var/log,var/cache,var/tmp,var/spool,var/lib/plasmalogin,var/lib/AccountsService,boot,efi}

mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@home     "$ROOTPART" /mnt/home
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@root     "$ROOTPART" /mnt/root
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@srv      "$ROOTPART" /mnt/srv
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@tmp      "$ROOTPART" /mnt/tmp
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@opt      "$ROOTPART" /mnt/opt
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_log  "$ROOTPART" /mnt/var/log
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_cache "$ROOTPART" /mnt/var/cache
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_tmp  "$ROOTPART" /mnt/var/tmp
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_spool "$ROOTPART" /mnt/var/spool
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_lib_plasmalogin "$ROOTPART" /mnt/var/lib/plasmalogin
mount -o noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_lib_accountsservice "$ROOTPART" /mnt/var/lib/AccountsService

mount "$ESP" /mnt/efi

findmnt /mnt        # sanity check the whole tree before continuing
```
`/boot` is **not** mounted separately — it's an empty directory inside `@` right now; `linux`/
`intel-ucode`/`grub` populate it in the next steps.

---

## 8. Install the base system

```bash
pacstrap -K /mnt \
  base linux linux-firmware intel-ucode \
  btrfs-progs grub efibootmgr os-prober mtools dosfstools cryptsetup \
  networkmanager sudo nano vim less \
  plasma plasma-login-manager \
  dolphin dolphin-plugins konsole gwenview spectacle okular \
  kio-extras ffmpegthumbs kdegraphics-thumbnailers \
  kwallet kwallet-pam kwalletmanager ksshaskpass \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber sof-firmware \
  bluez bluez-utils \
  power-profiles-daemon \
  mesa vulkan-intel xorg-server plasma-x11-session xdg-desktop-portal xdg-desktop-portal-kde \
  noto-fonts ttf-dejavu \
  zram-generator \
  snapper grub-btrfs inotify-tools snap-pac btrfsmaintenance btrfs-assistant
```

Notes:
- `pacstrap` will pause and ask which packages in the `plasma` group to install — press **Enter**
  to accept the default (`all`).
- `cryptsetup` is included so the installed system (not just the live ISO) has it — needed for any
  future `cryptsetup` commands run from the booted system itself.
- `intel-ucode` / `mesa` + `vulkan-intel`: correct for this laptop's Intel UHD Graphics, no discrete
  GPU.
- `plasma-x11-session`: Wayland is the default session, bundled with `plasma-workspace` already —
  this adds the X11 session as an additional option, for troubleshooting or app compatibility.
- `sof-firmware`: needed for audio on many modern Intel laptops.
- `power-profiles-daemon`: PowerDevil's Performance/Balanced/Power-saver switcher needs this
  explicitly — it's an optional upstream dependency the `plasma` group doesn't pull in on its own.
- No `base-devel`, no AUR helper — every package above is in Arch's official repos.

---

## 9. Generate fstab — and fix the one thing that matters for rollback

```bash
genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab
```
**Remove the `subvolid=NNN,` part from every btrfs line**, leaving only `subvol=/@...`. A rollback
creates a *new* subvolume with a *new* numeric ID and reassigns the **name** `@` to point at it — a
pinned numeric `subvolid` would silently keep booting the old, un-rolled-back state.
```bash
sed -i 's/,subvolid=[0-9]*//g' /mnt/etc/fstab
grep btrfs /mnt/etc/fstab      # confirm no "subvolid=" remains
```

No `/etc/crypttab` entry is needed for root — that file's own template comment says so explicitly.
Root's unlock is driven by a kernel command-line parameter (`cryptdevice=UUID=...`), which
`grub-mkconfig` adds automatically once `GRUB_ENABLE_CRYPTODISK=y` is set (Step 11) — not by
crypttab, which only matters for *additional* encrypted volumes beyond root (none exist here).

---

## 10. Chroot and configure the base system

```bash
arch-chroot /mnt
```

**Timezone & clock:**
```bash
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc
```

**Locale:**
```bash
sed -i 's/^#en_IN UTF-8/en_IN UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_IN.UTF-8" > /etc/locale.conf
```

**Console keyboard layout:**
```bash
echo "KEYMAP=us" > /etc/vconsole.conf
```

**Hostname:**
```bash
echo "archbox" > /etc/hostname
cat >> /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   archbox.localdomain archbox
EOF
```

**Root password and a regular user:**
```bash
passwd
useradd -m -G wheel -s /bin/bash yourusername
passwd yourusername
EDITOR=nano visudo
# uncomment: %wheel ALL=(ALL:ALL) ALL
```

**Add `encrypt` to the mkinitcpio hooks, and rebuild:**
```bash
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
grep ^HOOKS /etc/mkinitcpio.conf
```
`encrypt` (the classic hook, not `sd-encrypt`) goes after `block` and before `filesystems` —
positioned correctly above already. `grub-btrfs-overlayfs` is included now too, since it's the same
`udev`-family hook chain both need — no separate edit later in Step 13.

**Re-enable the fallback initramfs image** (recent `mkinitcpio` disables it by default; still worth
having — built with `autodetect` off, so it carries a much broader set of storage-controller modules
than the normal image):
```bash
cat /etc/mkinitcpio.d/linux.preset
sed -i "s/^PRESETS=('default')$/#PRESETS=('default')/" /etc/mkinitcpio.d/linux.preset
sed -i "s/^#PRESETS=('default' 'fallback')$/PRESETS=('default' 'fallback')/" /etc/mkinitcpio.d/linux.preset
sed -i 's/^#fallback_image=/fallback_image=/' /etc/mkinitcpio.d/linux.preset
sed -i 's/^#fallback_options=/fallback_options=/' /etc/mkinitcpio.d/linux.preset
grep -E 'PRESETS|fallback_image|fallback_options' /etc/mkinitcpio.d/linux.preset
mkinitcpio -P
ls /boot/initramfs-linux*.img      # should show both files
```

---

## 11. Install GRUB, targeting the dedicated ESP for both loader and config

```bash
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
```
**Careful with the name here** — this is GRUB's own core setting, in `/etc/default/grub`, and it
must be `y`. It is *not* the same variable as `GRUB_BTRFS_ENABLE_CRYPTODISK`, a completely
different setting in a completely different file (`/etc/default/grub-btrfs/config`, set up in Step
13) that must be left **off**. The names are one word apart and easy to conflate later when both
have appeared in this guide — this one, GRUB's own, is the one you want enabled, right now.

This has to be set *before* `grub-install` runs — the installed GRUB binary itself needs the
`cryptodisk` module built in, and `grub-mkconfig` needs it to actually write the `cryptomount`
command into each menu entry. Missing this produces two different, confirmed-real failure modes:
without the module, GRUB can't unlock LUKS at all; with the module present but this setting
commented out, GRUB unlocks fine but *never prompts for a passphrase in the first place*, because
`grub-mkconfig` silently omits `cryptomount` from the menu entries.

```bash
grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB --recheck
```
`--boot-directory=/efi` (separate from `--efi-directory`) is what puts GRUB's own `grub.cfg` and
module set on the unencrypted ESP alongside its loader binary — this is what lets Windows boot with
zero decryption, and lets the Arch entry's passphrase prompt appear in `gfxterm` (readable font)
rather than GRUB's crude built-in text console, since `grub.cfg`'s `GRUB_GFXMODE` setting is
reachable before any decryption happens.

Enable `os-prober` (disabled by default in recent GRUB):
```bash
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
grep -q '^GRUB_DISABLE_OS_PROBER=false' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
```

**Larger GRUB menu text** (on a 1920x1080 panel, `GRUB_GFXMODE=auto` often picks native resolution,
making menu text tiny at normal viewing distance):
```bash
sed -i 's/^GRUB_GFXMODE=.*/GRUB_GFXMODE=1024x768/' /etc/default/grub
grep -q '^GRUB_GFXMODE=' /etc/default/grub || echo 'GRUB_GFXMODE=1024x768' >> /etc/default/grub
```

Generate the config, at its ESP location — not the traditional `/boot/grub/grub.cfg`:
```bash
grub-mkconfig -o /efi/grub/grub.cfg
```

**Check the output** for a Windows Boot Manager line, and confirm `cryptomount` made it into the
config:
```bash
grep -A2 cryptomount /efi/grub/grub.cfg
```
You should see a `cryptomount` line referencing your LUKS partition's UUID. If it's missing,
double-check `GRUB_ENABLE_CRYPTODISK=y` is actually uncommented in `/etc/default/grub`, then re-run
**both** `grub-install` and `grub-mkconfig` — `grub-mkconfig` alone against a binary installed before
`GRUB_ENABLE_CRYPTODISK=y` was set won't fix it.

---

## 12. Set up Snapper — let it create `.snapshots` itself

```bash
snapper --no-dbus -c root create-config /
```
`--no-dbus` is required here specifically because you're inside `arch-chroot` — no D-Bus daemon runs
in a chroot. This is chroot-specific; once rebooted, `dbus.service` runs normally.

That single command creates `/etc/snapper/configs/root` *and* a correctly dot-prefixed `.snapshots`
subvolume, nested inside `@`, with no fstab entry needed. Verify:
```bash
btrfs subvolume list /mnt        # from outside the chroot afterward, or use `/` from inside it
snapper --no-dbus -c root list-configs
```

Give yourself read access without `sudo` for every `list`/`status`/`diff` (not `create`/`delete`/
`rollback`, which always need root):
```bash
sed -i 's/^ALLOW_USERS=.*/ALLOW_USERS="yourusername"/' /etc/snapper/configs/root
```

Tune retention:
```bash
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/'  /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/'    /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/'  /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="2"/' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_QUARTERLY=.*/TIMELINE_LIMIT_QUARTERLY="0"/' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/'  /etc/snapper/configs/root
sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="20"/'                   /etc/snapper/configs/root
sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="10"/' /etc/snapper/configs/root
```

`snap-pac` needs no further config — it auto-snapshots around every `pacman` transaction from now on.

---

## 13. Wire up grub-btrfs, and point its config at the same place GRUB's own lives

```bash
systemctl enable grub-btrfsd
```

**`grub-btrfs` is a completely separate package from GRUB with its own independent config file, and
it has no awareness that `grub.cfg` lives on `/efi` instead of the default `/boot/grub`.** Left
unset, it tries writing to `/boot/grub/grub-btrfs.new` — a directory that doesn't exist on this
layout at all (`/boot` has no `grub` subfolder in it) — and that failure doesn't just skip the
snapshots submenu, it can corrupt the *entire* `grub.cfg` generation, producing a completely broken
boot menu. Set this correctly now, before ever running `grub-mkconfig` again:
```bash
sed -i 's|^#GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/efi/grub"|' /etc/default/grub-btrfs/config
grep GRUB_BTRFS_GRUB_DIRNAME /etc/default/grub-btrfs/config   # confirm it's uncommented and set
```

Regenerate GRUB's config now that grub-btrfs is installed and Snapper has a config:
```bash
grub-mkconfig -o /efi/grub/grub.cfg
```
Watch the output for any `No such file or directory` error on the `grub-btrfs` line — there
shouldn't be one now.

> ## ⚠️ Do NOT set `GRUB_BTRFS_ENABLE_CRYPTODISK="true"` in `/etc/default/grub-btrfs/config`
> Leave that setting commented out — it's the default, and it's correct. This is worth stating
> plainly because the setting exists, sounds like exactly what an encrypted setup needs, and is
> actively broken in the currently-packaged `grub-btrfs` (confirmed via `bash -x` trace against the
> real installed script): its crypto-detection code only checks `GRUB_CMDLINE_LINUX_DEFAULT` for a
> `cryptdevice=` entry (yours is on `GRUB_CMDLINE_LINUX` instead), *and* its regex hardcodes an
> expectation that your LUKS mapping is literally named `cryptdev` — not `root`, which is what this
> guide (and most Arch installs) actually use. Turning this on doesn't just fail to help; it makes
> `grub-mkconfig` **crash silently** partway through, every single time, leaving `grub-btrfs.cfg`
> stale and unchanged with zero error output — the exact symptom that looks like "nothing is
> updating" and can burn hours chasing the wrong cause. Upstream's current, unreleased `master`
> branch has already rewritten this with a `blkid`-based approach; until a release ships it, this
> setting should stay off, and the box below is the actual working solution.

> ## 🔒 The real fix: `grub-btrfs`'s generated snapshot entries never unlock LUKS on their own
> With `GRUB_BTRFS_ENABLE_CRYPTODISK` correctly left off, every snapshot boot entry `grub-btrfs`
> generates is missing a `cryptomount` call entirely — confirmed directly: GRUB can read straight
> through the decrypted volume into any snapshot's `/boot` once manually unlocked at the rescue
> prompt, so the file is never actually missing; the generated menu entry simply never asks GRUB to
> unlock anything before trying to load it. Selecting a snapshot from "Arch Linux snapshots" fails
> with `no such device` / `file not found`, while the regular "Arch Linux" entry works fine, because
> *that* one gets its `cryptomount` line from GRUB's own core scripts, not from `grub-btrfs`.
>
> The fix below is a small, self-contained post-processor: it leaves `grub-btrfs`'s own broken
> crypto logic disabled entirely and instead patches its *output* directly, inserting a correct
> `cryptomount` block into every real snapshot boot entry, triggered automatically any time
> `grub-btrfs.cfg` changes. It's been directly validated end-to-end — snapshot boot on two different
> kernels, and a full disaster-recovery drill (deleted `/etc` outright, booted via a pre-existing
> snapshot through this fix, restored cleanly via Btrfs Assistant, rebooted normally with `/etc`
> fully back).
>
> **1. The fixup script** — idempotent (safe to re-run, does nothing once already patched), derives
> the LUKS UUID dynamically rather than hardcoding it, and traces it from the actual mounted root
> rather than "whichever encrypted device the kernel happened to enumerate first" (a real ambiguity
> if a second LUKS volume — a USB drive, say — is ever connected):
> ```bash
> tee /usr/local/bin/grub-btrfs-crypto-fix.sh <<'SCRIPT'
> #!/bin/bash
> set -euo pipefail
>
> GBCFG="/efi/grub/grub-btrfs.cfg"
> [ -f "$GBCFG" ] || exit 0
>
> # Debounce: grub-btrfsd may still be mid-write when the .path unit fires.
> # Wait for the file size to settle before reading it, rather than risk
> # processing (and overwriting) a half-written file.
> SIZE1=$(stat -c%s "$GBCFG" 2>/dev/null || echo 0)
> sleep 1
> SIZE2=$(stat -c%s "$GBCFG" 2>/dev/null || echo 0)
> if [ "$SIZE1" != "$SIZE2" ]; then
>     logger -t grub-btrfs-crypto-fix "File still being written, deferring to next trigger"
>     exit 0
> fi
>
> openers=$(grep -c -- "--class snapshots" "$GBCFG" || true)
> already=$(grep -c "cryptomount -u" "$GBCFG" || true)
>
> [ "$openers" -eq 0 ] && exit 0
> [ "$already" -ge "$openers" ] && exit 0   # already patched — breaks the self-trigger loop
>
> ROOT_MAPPER=$(findmnt -nvo SOURCE / | sed 's|/dev/mapper/||; s|\[.*\]||')
> if [ -z "$ROOT_MAPPER" ]; then
>     logger -t grub-btrfs-crypto-fix "Could not resolve root's mapper device, aborting"
>     exit 1
> fi
> REAL_DEV=$(cryptsetup status "$ROOT_MAPPER" 2>/dev/null | awk '/device:/{print $2}')
> if [ -z "$REAL_DEV" ]; then
>     logger -t grub-btrfs-crypto-fix "Could not determine backing device for $ROOT_MAPPER, aborting"
>     exit 1
> fi
> LUKS_UUID=$(blkid -s UUID -o value "$REAL_DEV" 2>/dev/null)
> if [ -z "$LUKS_UUID" ]; then
>     logger -t grub-btrfs-crypto-fix "Could not determine LUKS UUID, aborting"
>     exit 1
> fi
>
> TMP=$(mktemp)
> trap 'rm -f "$TMP"' EXIT
>
> awk -v uuid="$LUKS_UUID" '
> /--class snapshots.*\{[[:space:]]*$/ {
>     print
>     print "        insmod gzio"
>     print "        insmod part_gpt"
>     print "        insmod cryptodisk"
>     print "        insmod luks2"
>     print "        insmod gcry_rijndael"
>     print "        insmod gcry_sha256"
>     print "        insmod gcry_sha512"
>     print "        cryptomount -u " uuid
>     next
> }
> { print }
> ' "$GBCFG" > "$TMP"
>
> mv "$TMP" "$GBCFG"
> logger -t grub-btrfs-crypto-fix "Patched $openers snapshot menuentry blocks with cryptomount"
> SCRIPT
> chmod +x /usr/local/bin/grub-btrfs-crypto-fix.sh
> ```
> `cryptomount -u` takes the standard, hyphenated UUID form — confirmed directly, repeatedly, by
> this exact setup's own working GRUB entries (both the manually-run rescue-prompt version and every
> auto-generated normal boot entry use hyphens successfully) — so the UUID is intentionally **not**
> stripped of hyphens here, despite that being a commonly-repeated but incorrect claim online. What
> genuinely *does* drop hyphens in real GRUB output is a different, unrelated construct
> (`set root='cryptouuid/<uuid-no-hyphens>'`), which this script never generates.
>
> `gcry_sha512` is included defensively alongside `gcry_sha256` — this system's own confirmed
> `luksDump` output uses SHA-256, so it's not currently needed, but costs nothing to have available
> if that ever changes.
>
> **2. Trigger automatically whenever `grub-btrfs.cfg` changes** — a `systemd` path unit, which uses
> the kernel's native inotify support (not the separate `inotify-tools` package `grub-btrfsd` itself
> uses):
> ```bash
> tee /etc/systemd/system/grub-btrfs-crypto-fix.path <<'EOF'
> [Unit]
> Description=Watch grub-btrfs.cfg for changes
>
> [Path]
> PathModified=/efi/grub/grub-btrfs.cfg
>
> [Install]
> WantedBy=multi-user.target
> EOF
>
> tee /etc/systemd/system/grub-btrfs-crypto-fix.service <<'EOF'
> [Unit]
> Description=Inject cryptomount into grub-btrfs snapshot entries
>
> [Service]
> Type=oneshot
> ExecStart=/usr/local/bin/grub-btrfs-crypto-fix.sh
> EOF
>
> systemctl daemon-reload
> systemctl enable --now grub-btrfs-crypto-fix.path
> ```
> `--now` matters here, not just `enable` alone — `enable` on its own only creates the boot-time
> symlink for *future* boots; it doesn't arm the watch immediately. Without it, this can sit
> correctly "enabled" but genuinely inactive for as long as the system runs without a fresh reboot —
> a real, confirmed gap: exactly this happened during initial setup, silently missing two real
> snapshots' worth of regeneration before being caught. `--now` starts it in the same command,
> closing that window entirely.
>
> Only the `.path` unit gets enabled, deliberately — it's a persistent, near-free kernel-level watch
> that stays `active (waiting)`; the paired `.service` only springs to life on-demand, matched purely
> by the shared filename convention (no explicit `Unit=` link needed). Enabling the `.service`
> itself would be wrong here — it would try to run once at every boot regardless of whether anything
> actually changed.
>
> **3. Patch the file that already exists right now** — the path unit only reacts to *future*
> changes:
> ```bash
> /usr/local/bin/grub-btrfs-crypto-fix.sh
> journalctl -t grub-btrfs-crypto-fix --no-pager | tail -3   # confirm a "Patched N ..." line
> grep -c "cryptomount -u" /efi/grub/grub-btrfs.cfg          # should be non-zero
> ```
>
> **A known, honest limitation worth knowing rather than being surprised by:** `grub-btrfsd` itself
> (the separate daemon that regenerates `grub-btrfs.cfg` whenever a snapshot is created) occasionally
> misses a snapshot event — a real, observed race in its own watch-then-restart loop, not something
> our fix causes or can control. If a snapshot doesn't show up as bootable shortly after being taken,
> the reliable fallback is simply regenerating by hand — this also gives our own automation something
> to react to:
> ```bash
> sudo grub-mkconfig -o /efi/grub/grub.cfg
> ```
> Worth doing this once, manually, after any snapshot you'd actually want to boot into in a real
> emergency, rather than assuming the daemon caught it.

Create an initial "known good" snapshot:
```bash
snapper --no-dbus -c root create --description "initial install"
```

---

## 14. zram swap

```bash
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
```
No service to enable — `zram-generator` activates this automatically at boot via a systemd
generator.

---

## 15. Enable services

```bash
systemctl enable NetworkManager
systemctl enable systemd-timesyncd
systemctl enable bluetooth
systemctl enable plasmalogin
systemctl enable power-profiles-daemon
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
systemctl set-default graphical.target
systemctl enable btrfs-scrub@-.timer
```
(`grub-btrfsd` was already enabled in Step 13.)

`systemd-timesyncd` is easy to miss: `timedatectl set-ntp true` in Step 2 only applied to the live
ISO session, not the installed one. `systemctl set-default graphical.target` is also easy to miss:
enabling `plasmalogin.service` alone only tells systemd to start it *once* `graphical.target` is
reached — a base install's default target is `multi-user.target` (text console) until this is set.

No `fstrim.timer` needed on top of this — `discard=async` (Step 7) already gives continuous,
kernel-managed TRIM.

---

## 16. Exit and reboot

```bash
exit
umount -R /mnt
cryptsetup close root
reboot
```
Remove the USB installer when the machine restarts. If firmware boots straight into Windows instead
of showing GRUB, tap **F12** and manually pick the Arch/GRUB entry once, then reorder boot priority
permanently afterward (`efibootmgr`, Troubleshooting below).

---

## 17. First boot checks

You should land on GRUB with your Arch entry, an "Arch Linux snapshots" submenu, and a "Windows Boot
Manager" entry — Windows boots with no passphrase prompt at all; selecting Arch prompts once.

After logging into Plasma:
```bash
nmcli device status
bluetoothctl show
wpctl status
lspci -k | grep -EA3 'VGA|3D'
findmnt -t btrfs
btrfs subvolume list /
echo $XDG_SESSION_TYPE      # should print "wayland"
```
If audio is silent, check `journalctl -b | grep -i sof` for firmware load errors.

---

## 18. Test the full snapshot → boot → restore workflow

Worth doing once, deliberately, before relying on it in a real emergency — and worth doing the
*hard* version, not just a light one. A gentle test (deleting one file) proves less than you'd
think; the version below has been run for real, start to finish, on this exact setup: root fully
encrypted, snapshot boot going through Step 13's `cryptomount` fix, a failure severe enough that
`sudo` itself stops working.

```bash
sudo snapper create --description "pre-drill baseline"
```
Then, on a **normal boot** (not from a snapshot), delete something that actually breaks the system
hard rather than cosmetically:
```bash
sudo -i
rm -rf /etc
```
Reboot. The normal "Arch Linux" entry will fail completely — no working `sudo`, no valid
`/etc/passwd` to log in with, dropped to an unusable TTY. That's expected, and it's the point: this
is genuinely the scenario snapshot-boot exists for, not a scenario you can recover from with a
normal reboot alone.

Power back into GRUB, open **"Arch Linux snapshots"**, and pick the pre-drill snapshot. It should
boot into a full working Plasma session via the overlay hook, on a system that moments ago couldn't
boot normally at all.

**Restore for real — Method A, Btrfs Assistant (GUI), recommended:** open it, go to **Snapper** tab
→ **Browse/Restore**, confirm the target shows `@`, select the snapshot, click **Restore**. It saves
the current state as `@_backup_<timestamp>` automatically and tells you to reboot — pick the normal
**"Arch Linux"** entry, not the snapshots submenu. This is a genuinely proven, not theoretical,
recovery path: run end-to-end against a fully deleted `/etc` (a system where even `sudo` itself was
broken), it restored cleanly with no manual intervention beyond the click. Once confirmed working,
the leftover `@_backup_<timestamp>` subvolume is safe to delete — either from Btrfs Assistant's
**Subvolumes** tab, or:
```bash
sudo mkdir -p /mnt/btrfstop && sudo mount -o subvolid=5 "$LUKSPART_MAPPER" /mnt/btrfstop
sudo btrfs subvolume delete "/mnt/btrfstop/@_backup_<timestamp>"
sudo umount /mnt/btrfstop
```

**Method B — CLI, a proven fallback:**
```bash
sudo mkdir -p /mnt/btrfstop
sudo mount -o subvolid=5 "$LUKSPART_MAPPER" /mnt/btrfstop   # e.g. /dev/mapper/root
sudo btrfs subvolume list /mnt/btrfstop | grep snapshot
sudo mv /mnt/btrfstop/@ "/mnt/btrfstop/@_broken_$(date +%Y%m%d)"
sudo btrfs subvolume snapshot /mnt/btrfstop/.snapshots/N/snapshot /mnt/btrfstop/@
sudo umount /mnt/btrfstop
sudo reboot
```
(substitute your actual snapshot number for `N`)

---

## 19. Post-install LUKS convenience and safety

**1. Back up the LUKS header.** If it's ever corrupted, the entire encrypted container becomes
unrecoverable even with the correct passphrase:
```bash
sudo cryptsetup luksHeaderBackup "$LUKSPART" --header-backup-file ~/$(cat /etc/hostname)-luks-header-backup.img
```
`cat /etc/hostname` rather than the `hostname` command — the latter comes from a separate package
(`inetutils`) that isn't guaranteed to be installed, and silently evaluates to nothing if it's
missing, landing you with an oddly-named file rather than an error. Check what actually got created
if you ever see this go sideways:
```bash
ls -la ~ | grep luks-header
```
Move that file **off this disk** immediately — a USB drive, another machine via `scp`, cloud
storage. Redo this backup any time you change a keyslot's passphrase or PBKDF settings (step 3
below) — an old backup reflects the old keyslot state.

**2. Collapse the two passphrase prompts into one.** Right now GRUB prompts once to read `/boot`,
then the `encrypt` initramfs hook prompts again to unlock root — two separate LUKS unlock stages. A
keyfile embedded in the initramfs answers the second one automatically:
```bash
sudo dd if=/dev/urandom of=/etc/cryptroot.key bs=512 count=4
sudo chmod 000 /etc/cryptroot.key
sudo cryptsetup luksAddKey "$LUKSPART" /etc/cryptroot.key   # enter your existing passphrase once

echo 'FILES=(/etc/cryptroot.key)' | sudo tee -a /etc/mkinitcpio.conf
sudo mkinitcpio -P

sudo sed -i '/GRUB_CMDLINE_LINUX=/ s/"$/ cryptkey=rootfs:\/etc\/cryptroot.key"/' /etc/default/grub
grep GRUB_CMDLINE_LINUX /etc/default/grub   # confirm cryptkey=rootfs:/etc/cryptroot.key is there
sudo grub-mkconfig -o /efi/grub/grub.cfg
```
While editing this line, also append `:allow-discards` directly onto the existing `cryptdevice=UUID=...:root`
segment (same field, right after the mapper name `root`, before the next space) — without it,
`discard=async` on every btrfs mount is a **silent no-op**: dm-crypt drops TRIM/discard requests by
default for security reasons (confirmed directly from the kernel's own `dm-crypt` documentation),
and won't pass them through to the physical SSD unless explicitly told to. The tradeoff is real but
narrow — it can reveal which blocks are in-use versus empty to someone with physical access to the
raw device — reasonable to accept on a personal machine for genuine SSD longevity/performance:
```bash
sudo sed -i '/GRUB_CMDLINE_LINUX=/ s/:root/:root:allow-discards/' /etc/default/grub
grep GRUB_CMDLINE_LINUX /etc/default/grub   # confirm :root:allow-discards is now there
sudo grub-mkconfig -o /efi/grub/grub.cfg
```
This is safe because the keyfile only exists *inside* the initramfs, itself inside the encrypted
`@` — reading it out still requires having already unlocked the disk once, at GRUB.

**3. Speed up the remaining GRUB-stage prompt, on *both* keyslots.** LUKS2's default Argon2id cost
(~1GiB memory) is deliberately expensive, but GRUB's own implementation has no hardware
acceleration — the same computation that's instant in the kernel can take 60–90+ seconds in GRUB.
```bash
sudo cryptsetup luksConvertKey "$LUKSPART" --pbkdf argon2id --pbkdf-force-iterations 4 --pbkdf-memory 262144
```
This only re-tunes whichever keyslot matches the passphrase you type — after step 2 above, you have
a **second** keyslot (the keyfile), still at the untouched default. GRUB doesn't guarantee try-order
between slots, so tune that one explicitly too:
```bash
sudo cryptsetup luksConvertKey "$LUKSPART" --key-slot 1 --key-file /etc/cryptroot.key \
  --pbkdf argon2id --pbkdf-force-iterations 4 --pbkdf-memory 262144
```
(check `sudo cryptsetup luksDump "$LUKSPART"` first if your keyfile ended up in a different slot
number). Confirm both slots show `Memory: 262144` before considering this done, then redo step 1's
header backup.

**4. Plasma autologin** (optional — since the disk itself already requires a passphrase, a second
login prompt is genuinely redundant for a personal machine):
```bash
ls /usr/share/wayland-sessions/    # confirm the session name, likely "plasma"
sudo mkdir -p /etc/plasmalogin.conf.d
sudo tee /etc/plasmalogin.conf.d/autologin.conf <<EOF
[Autologin]
User=yourusername
Session=plasma
EOF
```

**5. KWallet auto-unlock** — without this, KWallet prompts separately for its own password on
login even with autologin configured above, which defeats the point:
```bash
grep pam_kwallet /etc/pam.d/plasmalogin*
```
Confirm the `auth`/`session` lines include `kwalletd=/usr/bin/ksecretd` — Plasma 6 moved to a new
secret-service daemon (`ksecretd`), and `pam_kwallet5.so` needs to be told about it explicitly or it
silently falls back to looking for the older `kwallet5` daemon instead:
```
auth       optional     pam_kwallet5.so
session    optional     pam_kwallet5.so auto_start kwalletd=/usr/bin/ksecretd
```
If that parameter is missing, add it to the matching lines in whichever `plasmalogin*` file the
`grep` above found. Confirm after a reboot:
```bash
pgrep ksecretd
```

---

## 20. Post-install (optional): pacman hooks for GRUB maintenance

`grub-install`'s deployed binary/modules on the ESP don't auto-update when the `grub` package
itself is upgraded — only re-running `grub-install` does that, and Arch's `grub` package ships no
hook for this at all:
```bash
sudo tee /etc/pacman.d/hooks/94-grub-reinstall.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = grub

[Action]
Description = Reinstalling GRUB to /efi after a grub package update
When = PostTransaction
Exec = /usr/bin/grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB --recheck
EOF
```
And a config-regen hook for either a kernel or `grub` package change:
```bash
sudo tee /etc/pacman.d/hooks/95-grub-efi-cfg.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = linux
Target = linux-lts
Target = grub

[Action]
Description = Regenerating GRUB config on /efi
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /efi/grub/grub.cfg
EOF
```
`94-` before `95-` is deliberate — pacman runs hooks alphabetically, and the deployed binary should
refresh before the config referencing it regenerates.

---

## 21. Post-install: automated pre-upgrade snapshots + an Arch news gate

Not part of the base install — a maintenance layer worth adding once the system is stable, built
and tested live on both machines this guide covers. Three independent pieces, chained by pacman
hook filename ordering:

**The chain, in order:** `90-archnews.hook` (blocks the whole transaction if there's unread
archlinux.org news) → `95-snapshot.hook` (takes a tagged pre-transaction snapshot with a full
package-list sidecar) → a monthly timer that prunes orphaned sidecar files once snapper's own
cleanup has removed their matching snapshot. Deliberately **pre-only, `Operation = Upgrade` only**
— not `snap-pac`'s default pre+post pair on every install/remove/upgrade. `Operation = Upgrade`
covers `-Syu`, `-Su`, and any `-S <pkg>`/`-U <file>` that replaces an already-installed package —
it does not fire on brand-new installs or removals, which is intentional.

**1. The news gate — `/usr/local/bin/archnews`.** A from-scratch bash replacement for the
unmaintained `informant` AUR package. Tracks only the single most-recent item's GUID (the feed is
always newest-first), not a growing list of every GUID ever seen. Fails **closed** on a fetch
error — blocks the upgrade rather than silently letting it through — with a single-use
`allow-once` override for when you genuinely need to upgrade despite the feed being unreachable:
```bash
sudo tee /usr/local/bin/archnews <<'SCRIPT'
#!/bin/bash
# archnews: minimal Arch Linux news checker, blocks pacman upgrades on
# unread archlinux.org news items. Lightweight bash replacement for the
# unmaintained 'informant' AUR package.
#
# Tracks only the guid of the MOST RECENT item seen (the feed is always
# newest-first) rather than a growing list of every guid ever seen.

set -uo pipefail

FEED_URL="https://archlinux.org/feeds/news/"
STATE_DIR="/var/lib/archnews"
STATE_FILE="${STATE_DIR}/last_seen"
CONFIG_DIR="/etc/archnews"
OVERRIDE_FILE="${CONFIG_DIR}/allow-fetch-error-once"

mkdir -p "$STATE_DIR"

# --- feed fetch/parse -------------------------------------------------

fetch_feed() {
    curl -fsS --max-time 15 -A "archnews/1.0" "$FEED_URL"
}

decode_entities() {
    sed -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' \
        -e "s/&#39;/'/g" -e 's/&quot;/"/g'
}

# Emits one TSV line per item, in feed order (newest first):
#   guid<TAB>pubDate<TAB>title<TAB>link
# Normalizes to one-tag-per-line first (s/></>\n</g) so this works whether
# the feed is pretty-printed or served as a single minified line.
parse_items() {
    local xml="$1"
    printf '%s' "$xml" | sed -e 's/></>\n</g' | awk '
        /<item>/ { in_item=1; guid=""; link=""; title=""; pubdate=""; next }
        /<\/item>/ {
            if (in_item) print guid "\t" pubdate "\t" title "\t" link
            in_item=0; next
        }
        in_item && /^<guid/ {
            line=$0; sub(/^<guid[^>]*>/,"",line); sub(/<\/guid>$/,"",line); guid=line; next
        }
        in_item && /^<link>/ {
            line=$0; sub(/^<link>/,"",line); sub(/<\/link>$/,"",line); link=line; next
        }
        in_item && /^<title>/ {
            line=$0; sub(/^<title>/,"",line); sub(/<\/title>$/,"",line); title=line; next
        }
        in_item && /^<pubDate>/ {
            line=$0; sub(/^<pubDate>/,"",line); sub(/<\/pubDate>$/,"",line); pubdate=line; next
        }
    ' | decode_entities
}

# --- commands -----------------------------------------------------------

cmd_check() {
    local raw
    if ! raw=$(fetch_feed); then
        echo "archnews: ERROR - could not reach the Arch Linux news feed (${FEED_URL})" >&2

        if [[ -f "$OVERRIDE_FILE" ]]; then
            rm -f "$OVERRIDE_FILE"
            echo "archnews: one-time override flag found - allowing this upgrade through despite the fetch error. Override flag has now been cleared." >&2
            exit 0
        fi

        echo "archnews: BLOCKING upgrade for safety - this is a network/fetch failure, not confirmed unread news. If you need to upgrade right now regardless, run:" >&2
        echo "  sudo archnews allow-once" >&2
        echo "then retry the upgrade. This override is single-use and clears itself automatically." >&2
        exit 1
    fi

    local stored=""
    [[ -f "$STATE_FILE" ]] && stored=$(cat "$STATE_FILE")

    local new_titles=()
    while IFS=$'\t' read -r guid pubdate title link; do
        [[ -n "$stored" && "$guid" == "$stored" ]] && break
        new_titles+=("$title")
    done < <(parse_items "$raw")

    if (( ${#new_titles[@]} > 0 )); then
        echo "archnews: ${#new_titles[@]} unread Arch news item(s):" >&2
        for t in "${new_titles[@]}"; do
            echo "  - $t" >&2
        done
        echo "Run 'archnews read' to review and clear, then re-run the upgrade." >&2
        exit 1
    fi
    exit 0
}

cmd_list() {
    local raw
    raw=$(fetch_feed) || { echo "archnews: could not reach the news feed" >&2; exit 3; }
    local stored=""
    [[ -f "$STATE_FILE" ]] && stored=$(cat "$STATE_FILE")

    local seen_stored=0
    [[ -z "$stored" ]] && seen_stored=1   # nothing stored -> everything unread
    while IFS=$'\t' read -r guid pubdate title link; do
        if (( seen_stored )); then mark="*"; else mark=" "; fi
        printf '[%s] %s  %s\n' "$mark" "$pubdate" "$title"
        [[ "$guid" == "$stored" ]] && seen_stored=0
    done < <(parse_items "$raw")
}

cmd_read() {
    local raw
    raw=$(fetch_feed) || { echo "archnews: could not reach the news feed" >&2; exit 3; }
    local stored=""
    [[ -f "$STATE_FILE" ]] && stored=$(cat "$STATE_FILE")

    local new_guids=() new_titles=() new_pubdates=() new_links=()
    local top_guid=""
    while IFS=$'\t' read -r guid pubdate title link; do
        [[ -z "$top_guid" ]] && top_guid="$guid"
        [[ -n "$stored" && "$guid" == "$stored" ]] && break
        new_guids+=("$guid"); new_titles+=("$title"); new_pubdates+=("$pubdate"); new_links+=("$link")
    done < <(parse_items "$raw")

    if (( ${#new_guids[@]} == 0 )); then
        echo "No unread Arch news items."
        return
    fi

    for i in "${!new_guids[@]}"; do
        echo "======================================================================"
        echo "${new_titles[$i]}"
        echo "${new_pubdates[$i]}"
        echo "${new_links[$i]}"
        echo
    done

    read -rp "Mark all ${#new_guids[@]} item(s) as read? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        echo "$top_guid" > "$STATE_FILE"
        echo "Marked as read."
    else
        echo "Left unread - upgrades will keep blocking until you read them."
    fi
}

cmd_seed() {
    local raw
    raw=$(fetch_feed) || { echo "archnews: could not reach the news feed" >&2; exit 3; }
    local top_guid
    top_guid=$(parse_items "$raw" | head -1 | cut -f1)
    if [[ -z "$top_guid" ]]; then
        echo "archnews: could not parse any items from the feed - nothing seeded." >&2
        exit 3
    fi
    echo "$top_guid" > "$STATE_FILE"
    echo "Seeded - current top news item marked as the baseline. Anything published after it will show as unread."
}

cmd_allow_once() {
    mkdir -p "$CONFIG_DIR"
    : > "$OVERRIDE_FILE"
    echo "archnews: override flag set at $OVERRIDE_FILE"
    echo "The next upgrade will proceed even if the news feed can't be reached - but only if it's a fetch error. If news is reachable and there are unread items, this flag does NOT bypass that; you'd still need 'archnews read'."
    echo "This flag is single-use and clears itself automatically once consumed."
}

cmd_allow_clear() {
    if [[ -f "$OVERRIDE_FILE" ]]; then
        rm -f "$OVERRIDE_FILE"
        echo "archnews: override flag removed."
    else
        echo "archnews: no override flag was set."
    fi
}

# --- dispatch -------------------------------------------------------------

case "${1:-}" in
    check)       cmd_check ;;
    list)        cmd_list ;;
    read)        cmd_read ;;
    seed)        cmd_seed ;;
    allow-once)  cmd_allow_once ;;
    allow-clear) cmd_allow_clear ;;
    *)
        echo "usage: archnews {check|list|read|seed|allow-once|allow-clear}" >&2
        exit 2
        ;;
esac
SCRIPT
sudo chmod +x /usr/local/bin/archnews
```

```bash
sudo tee /etc/pacman.d/hooks/90-archnews.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Checking for unread Arch Linux news...
When = PreTransaction
AbortOnFail
Exec = /usr/local/bin/archnews check
EOF
```
`AbortOnFail` is not optional here, despite the man page listing it that way — without it, a
`PreTransaction` hook exiting non-zero doesn't stop the transaction on its own; pacman just prints
`error: command failed to execute correctly` and moves straight on to the next hook, then proceeds
with the install regardless. Confirmed by real testing on a live upgrade with genuinely unread
news: `archnews` correctly detected and reported the unread items and exited 1, but without this
line the transaction continued anyway, straight through to installing every package — silently
defeating the entire point of the check. If you ever see that exact `error: command failed to
execute correctly` line during an upgrade and it still proceeds, this is the first thing to check.

**One-time setup — seed the baseline so historical news doesn't immediately block your first
upgrade:**
```bash
sudo archnews seed
cat /var/lib/archnews/last_seen   # confirm it printed a real tag:archlinux.org,... guid
```

**2. The snapshot itself — `/usr/local/bin/snapper-pacman-snapshot.sh`.** Pacman feeds the exact
list of upgrade targets via stdin (enabled by `NeedsTargets` on the hook below) — the full list
goes into a sidecar file named after the snapshot number, so the Snapper description itself stays a
short summary rather than an unreadable wall of package names:
```bash
sudo tee /usr/local/bin/snapper-pacman-snapshot.sh <<'SCRIPT'
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
SCRIPT
sudo chmod +x /usr/local/bin/snapper-pacman-snapshot.sh
```

```bash
sudo tee /etc/pacman.d/hooks/95-snapshot.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Taking snapper snapshot before upgrade transaction...
When = PreTransaction
NeedsTargets
Exec = /usr/local/bin/snapper-pacman-snapshot.sh
EOF
```
Worth a moment's thought, though not tested and not applied here: the same `AbortOnFail` gap
technically applies to this hook too — if `snapper` itself fails (disk full, etc.), the upgrade
currently proceeds anyway, without the safety net this whole system exists to provide. Left off
deliberately for now, since only the news-check hook's `AbortOnFail` fix has actually been verified
by testing — add it here too if you'd rather fail closed on a snapshot failure as well.
The `90-`/`95-` numbering is deliberate, not cosmetic — pacman runs same-stage hooks in filename
(lexical) order, so the news check always runs first. If it blocks the transaction, the snapshot
hook never runs at all — you don't end up with a pointless snapshot immediately preceding an
upgrade that got aborted anyway.

**3. Sidecar cleanup — a monthly timer, not a pacman hook.** Snapper's own retention policy
(`NUMBER_LIMIT`/`NUMBER_LIMIT_IMPORTANT`, set back in Step 12) eventually deletes old snapshots on
its own — this just catches the sidecar `.pkglist` files left behind once their matching snapshot
is gone:
```bash
sudo tee /usr/local/bin/prune-snapper-pkglists.sh <<'SCRIPT'
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
SCRIPT
sudo chmod +x /usr/local/bin/prune-snapper-pkglists.sh
```

```bash
sudo tee /etc/systemd/system/prune-snapper-pkglists.service <<'EOF'
[Unit]
Description=Prune orphaned snapper-pacman package-list sidecar files

[Service]
Type=oneshot
ExecStart=/usr/local/bin/prune-snapper-pkglists.sh
EOF

sudo tee /etc/systemd/system/prune-snapper-pkglists.timer <<'EOF'
[Unit]
Description=Monthly prune of orphaned snapper-pacman package-list files

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now prune-snapper-pkglists.timer
```

**Test before trusting any of it with a real upgrade:**
```bash
archnews list                       # confirm real titles, correct read/unread marks
sudo archnews check; echo "exit: $?"
sudo pacman -Syu                    # the real end-to-end test
snapper list                        # confirm a new "pre" snapshot with a real package count
sudo cat "/var/log/snapper-pacman/$(snapper list | tail -1 | awk '{print $1}').pkglist"
```

**Deploying to a second machine:** all four files are self-contained and copy verbatim — no
per-machine values baked in anywhere. Copy the same `archnews`, `snapper-pacman-snapshot.sh`,
`prune-snapper-pkglists.sh`, all three hook files, and both systemd units, then run
`sudo archnews seed` fresh on that machine too (its baseline should show the same top news item,
since both machines read the same feed).

**Optional, unrelated bonus while you're setting up pacman hooks — cache cleanup**, keeping only
the two most recent cached versions of each package plus the currently-installed one:
```bash
sudo tee /etc/pacman.d/hooks/clear-cache.hook <<'EOF'
[Trigger]
Operation = Remove
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Keep the last cache and the currently installed.
When = PostTransaction
Exec = /usr/bin/paccache -rvk2
EOF
```

---


## Troubleshooting quick reference

**If you ever install a second kernel (e.g. `linux-lts` alongside `linux`) and it boots the wrong
one by default:** `GRUB_DEFAULT` in `/etc/default/grub` takes a `"top-level-index>submenu-index"`
value, both **zero**-indexed — this applies uniformly to GRUB's top-level menu and any submenu,
confirmed directly against GRUB's own documented behavior. Find the real indices from the actual
generated file rather than guessing:
```bash
grep -n "^menuentry\|^submenu" /efi/grub/grub.cfg   # top-level order
```
Then, for whichever entry is a submenu (commonly "Advanced options for Arch Linux"), find the order
*within* it the same way, using that submenu's own line range. **Whatever value you land on, it
must be quoted** — `GRUB_DEFAULT=1>1` (no quotes) is not parsed as the string `"1>1"` at all: since
`/etc/default/grub` is sourced as a shell script, an unquoted `>` is a real shell redirection
operator. Bash reads that as "set `GRUB_DEFAULT` to `1`, then redirect output into a file literally
named `1`" — a confirmed, real failure mode (a stray file named `1` genuinely appeared in `/` on a
live install from exactly this mistake) that also silently breaks the intended default-boot
behavior. Always:
```bash
GRUB_DEFAULT="1>1"
```

**🔒 GRUB boot menu is completely broken — "no such device", "no server is specified", "you need
to load the kernel first", regardless of which entry you pick:**
A partially-written `grub.cfg` — GRUB fell through to its built-in rescue template. Most likely
cause: `grub-btrfs` tried writing to `/boot/grub/grub-btrfs.new`, which doesn't exist on this
layout. From a live ISO, mount and `arch-chroot` back in:
```bash
grep GRUB_BTRFS_GRUB_DIRNAME /etc/default/grub-btrfs/config
```
Fix per Step 13 if not set to `/efi/grub`, then regenerate and watch closely for any
`No such file or directory` error before rebooting again.

**🔒 GRUB boots straight to "no such device" with *no passphrase prompt at all*:**
Different from the above — `cryptomount` was never in the menu entry to begin with:
```bash
grep -B8 "search --no-floppy --fs-uuid" /efi/grub/grub.cfg | grep cryptomount
```
Empty means `GRUB_ENABLE_CRYPTODISK` is commented out in `/etc/default/grub`. Uncomment it, then
redo both `grub-install` and `grub-mkconfig`.

**🔒 Prompted for the passphrase twice on every boot:**
Expected until you do Step 19's keyfile step.

**🔒 One keyslot fast, one slow, inconsistently:**
Only one keyslot got PBKDF-tuned. Confirm with `sudo cryptsetup luksDump "$LUKSPART"` — both should
show the same `Memory:` value. See Step 19's box for tuning the second (keyfile) slot explicitly.

**🔒 Booting a snapshot fails with "no such device" or "file ... not found", even though the
regular "Arch Linux" entry boots fine:** `grub-btrfs`'s generated snapshot entries don't include a
`cryptomount` call on their own — this is expected without Step 13's fix script in place. Confirm
the fix is actually installed and has run:
```bash
grep -c "cryptomount -u" /efi/grub/grub-btrfs.cfg   # should be non-zero
systemctl status grub-btrfs-crypto-fix.path         # should show active (waiting)
```
If the count is 0, re-run `/usr/local/bin/grub-btrfs-crypto-fix.sh` manually and check
`journalctl -t grub-btrfs-crypto-fix` for why it didn't patch anything.

**🔒 `grub-mkconfig` silently stops right after "Detecting snapshots ..." — no `Found snapshot`
lines, no error, and the snapshots submenu never updates:** `GRUB_BTRFS_ENABLE_CRYPTODISK` is set to
`"true"` in `/etc/default/grub-btrfs/config` — it's broken in the currently-packaged `grub-btrfs`
(see Step 13's warning box) and crashes the config generator silently, every time, leaving
`grub-btrfs.cfg` stale. Comment it back out and regenerate:
```bash
grep GRUB_BTRFS_ENABLE_CRYPTODISK /etc/default/grub-btrfs/config
sudo sed -i 's/^GRUB_BTRFS_ENABLE_CRYPTODISK="true"/#GRUB_BTRFS_ENABLE_CRYPTODISK="true"/' /etc/default/grub-btrfs/config
sudo grub-mkconfig -o /efi/grub/grub.cfg
```
This one is easy to reintroduce accidentally while troubleshooting something else — worth checking
this file's contents first if snapshot-boot ever mysteriously stops updating after working fine
before.

**A snapshot doesn't appear in the "Arch Linux snapshots" submenu shortly after being taken:**
`grub-btrfsd`'s own watch occasionally misses an event (see Step 13's note) — not specific to
encryption. Regenerate by hand:
```bash
sudo grub-mkconfig -o /efi/grub/grub.cfg
```

**GRUB doesn't show Windows:**
```bash
sudo os-prober
sudo grub-mkconfig -o /efi/grub/grub.cfg
```

**Firmware always boots Windows, ignoring GRUB:**
```bash
sudo efibootmgr -v
sudo efibootmgr -o 0001,0000   # reorder: put GRUB's entry number first
```

**"Arch Linux snapshots" menu is missing or stale after an update:**
```bash
systemctl status grub-btrfsd
sudo grub-mkconfig -o /efi/grub/grub.cfg
```

**Booting a snapshot gives a black screen / PLM fails to start:**
Confirm `grub-btrfs-overlayfs` is in `/etc/mkinitcpio.conf`'s `HOOKS` and `mkinitcpio -P` was run
afterward. An *existing* snapshot's initramfs is frozen at whatever it was when taken — fixing the
hook now only affects new snapshots.

**`pacstrap` fails to fetch packages / mirror errors:**
```bash
reflector --country India --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
```

**Prefer SDDM over Plasma Login Manager:**
```bash
sudo pacman -S sddm sddm-kcm
sudo systemctl disable --now plasmalogin
sudo systemctl enable --now sddm
```
Never enable both at once. If you switch, give SDDM's state directory the same subvolume treatment:
```bash
sudo mount -o subvolid=5 "$ROOTPART" /mnt
sudo btrfs subvolume create /mnt/@var_lib_sddm
sudo umount /mnt
echo "UUID=$(sudo blkid -s UUID -o value $ROOTPART) /var/lib/sddm btrfs noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@var_lib_sddm 0 0" | sudo tee -a /etc/fstab
sudo mkdir -p /var/lib/sddm
sudo mount -a
```
