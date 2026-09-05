# Arch Linux Install Guide — archinstall Path, LUKS Encrypted
### Dell Latitude 5410 · Btrfs + Snapper + GRUB + Minimal KDE Plasma, Dual-Boot with Windows

This is the archinstall-driven install path, with LUKS full-disk encryption baked in throughout. It
lands in the exact same end state as the companion manual document — same 12 subvolumes, same
dedicated ESP, same `grub.cfg`-on-ESP layout, same Snapper/`grub-btrfs` setup — archinstall just
drives the disk/base-package half of it. Steps 12 onward (Snapper, `grub-btrfs`, testing,
post-install) are identical to the manual guide and unaffected by archinstall at all.

This walkthrough matches archinstall's current menu structure and `--config` JSON schema. TUI label
wording can shift release to release; if something doesn't match exactly, use the underlying logic
(which partition gets encrypted, subvolume name/mountpoint pairs, "Manual Partitioning" vs
"best-effort") to find the equivalent option.

⚠️ **Use Manual Partitioning, never "Use a best-effort default partition layout."** Best-effort
assumes the whole disk is yours to wipe — it doesn't know about your Windows partitions.

---

## 0. Decisions made for you, and why

**Bootloader: GRUB, not Limine.** Native btrfs support, and `grub-btrfs` (official Arch package)
auto-generates boot menu entries for every Snapper snapshot.

**A dedicated ESP for Arch, separate from Windows' own** — 300MiB FAT32, holding only GRUB. UEFI
firmware scans all ESPs on a disk regardless of which one each loader lives on, so this is purely
organizational, not a functional requirement for dual-boot.

**`grub.cfg` lives on that dedicated ESP.** archinstall's own `grub-install` call automatically
passes `--boot-directory` matching wherever you mount the ESP-type partition in your custom layout —
since we mount it at `/efi`, that's exactly where `grub.cfg` ends up too, with no extra manual work.
Confirmed firsthand on a real install. The payoff: **Windows boots with zero decryption prompt at
all**, since GRUB never has to touch LUKS just to display its menu — only selecting Arch triggers a
decrypt, and that prompt renders in readable `gfxterm` font rather than GRUB's crude built-in
console, since `grub.cfg`'s `GRUB_GFXMODE` is reachable before any decryption happens.

**Btrfs subvolume layout: flat siblings, `.snapshots` NOT pre-created, `/boot` inside `@`.** The
`/boot`-inside-`@` choice is what makes "restore also restores the matching kernel/initramfs" work —
Arch only ever keeps one installed kernel version, so a mismatch here after a rollback is a hard
boot failure, not a degraded state. Because `/boot` is encrypted this way, GRUB itself has to unlock
LUKS to read the kernel — modern GRUB (2.06+) supports this natively.

**Do not let archinstall pre-create a `.snapshots`/`@.snapshots` subvolume.** Btrfs Assistant's own
source (`isSnapper()` in `btrfs-assistant.cpp`) checks for the literal substring `.snapshots` (with
the dot) to identify a restorable snapshot subvolume. A subvolume pre-created outside Snapper's own
`create-config` — regardless of exact naming — reliably breaks GUI restore, confirmed by direct A/B
testing. Leave it off your custom subvolume list entirely; Snapper creates it correctly after
install (Step 12, identical across both guides).

**`grub-btrfs` + `grub-btrfs-overlayfs` + `snapper`** give both GUI and CLI snapshot restore, all
official Arch packages, no AUR needed. The overlay hook makes a booted snapshot fully writable via a
temporary RAM-backed layer, like a live CD — directly tested with a full `/usr` +
`/var/lib/pacman` wipeout while booted from a snapshot, fully recovered via the GUI restore
afterward.

**Plasma Login Manager (PLM), not SDDM** — current ArchWiki-recommended choice for Plasma 6.6+.
`/var/lib/plasmalogin` and `/var/lib/AccountsService` get their own subvolumes so the login
manager's state stays writable even during a raw snapshot boot.

**`plasma` group (workspace only) + exact app list, not `kde-applications`.** Dolphin, Konsole,
Gwenview, Spectacle, Okular, plus thumbnailers — nothing else.

**Kernel: `linux` only**, no `linux-lts` — the snapshot/`grub-btrfs` setup already gives
kernel-level rollback protection regardless of kernel track.

**Two LUKS keyslots, both tuned to the same PBKDF cost** — a passphrase slot and a keyfile slot
(Step 19), with GRUB not guaranteeing which one it tries first.

**Snapshot-boot with encryption needs a small fix of our own — `grub-btrfs`'s built-in handling of
this is currently broken**, confirmed on a real archinstall-built install: its opt-in
`GRUB_BTRFS_ENABLE_CRYPTODISK` flag checks the wrong GRUB cmdline variable and assumes a LUKS
mapping name archinstall doesn't use, so enabling it silently crashes `grub-mkconfig` instead of
helping. Step 5 leaves that flag off and installs a small script that patches `grub-btrfs`'s output
directly instead — validated end-to-end, including a real disaster-recovery drill (`/etc` deleted
outright, recovered via snapshot boot, restored via Btrfs Assistant).

---

## 1. Boot the ISO, get online

```bash
cat /sys/firmware/efi/fw_platform_size
```
Must print `64` — legacy/CSM mode otherwise; reboot into the F12 menu and pick the UEFI entry.

```bash
iwctl
device list
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "Your-SSID-Here"
exit
```
```bash
ping -c3 archlinux.org
timedatectl set-ntp true
reflector --country India --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
```

**Recommended: SSH in from another machine:**
```bash
passwd
systemctl status sshd
ip a
```
```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<the-ip-you-noted>
```

---

## 2. Launch archinstall and work through the menu

```bash
archinstall
```

1. **Archinstall language** — leave as English; only affects the installer's own UI.
2. **Locales**: keyboard `us`, language `en_US`, encoding `UTF-8`.
3. **Mirrors and repositories**: region **India** (or nearest).
4. **Disk configuration** → **Manual Partitioning** → select the disk. You'll see the existing
   table (Windows/Dell partitions, plus the one you're replacing). Leave every Windows/Dell
   partition untouched — don't select or edit them:
   - Select the target partition → mark for wipe → filesystem **btrfs** → mount options
     `compress=zstd:3,noatime,space_cache=v2,discard=async` → this opens the subvolume editor. Add
     exactly these 12 name→mountpoint pairs:
     ```
     @                          → /
     @home                      → /home
     @root                      → /root
     @srv                       → /srv
     @tmp                       → /tmp
     @opt                       → /opt
     @var_log                   → /var/log
     @var_cache                 → /var/cache
     @var_tmp                   → /var/tmp
     @var_spool                 → /var/spool
     @var_lib_plasmalogin       → /var/lib/plasmalogin
     @var_lib_accountsservice   → /var/lib/AccountsService
     ```
     **Don't add a `.snapshots`/`@.snapshots` entry.** **Don't add a separate `/boot` entry** —
     `/boot` stays an ordinary directory inside `@`.
   - Now create the dedicated Arch ESP: a new **300MiB** partition, filesystem **FAT32**, flagged
     as **ESP/boot**, mountpoint `/efi`. Keep this fully separate from any existing Windows ESP —
     don't reuse or modify that one at all.
5. **Disk encryption**:
   - Encryption type: **LUKS**.
   - Partition to encrypt: the **btrfs partition itself** (the one holding `@`) — not the ESP (the
     ESP can never be encrypted; UEFI firmware has to read it directly, and firmware doesn't
     understand LUKS). Because this layout has no separate `/boot` partition, encrypting the btrfs
     partition encrypts `/boot` right along with everything else.
   - Set and confirm your passphrase.
6. **Bootloader**: **GRUB**. Leave "unified kernel image" off and "removable" off.
7. **Hostname**: your choice, e.g. `archbox`.
8. **Root password**: set one, or rely on your user's sudo access instead.
9. **User account**: create your user, tick sudo/wheel access.
10. **Profile**: **Minimal** (or unset) — not "KDE Plasma," which pulls in the full
    `kde-applications` suite. The exact app list goes in Additional packages instead.
11. **Audio**: **Pipewire**.
12. **Kernels**: **linux** only — leave `linux-lts` and others unticked.
13. **Network configuration**: **NetworkManager**.
14. **Additional packages**:
    ```
    intel-ucode btrfs-progs os-prober mtools dosfstools networkmanager sudo nano
    vim less plasma plasma-login-manager dolphin dolphin-plugins konsole gwenview spectacle okular
    kio-extras ffmpegthumbs kdegraphics-thumbnailers kwallet kwallet-pam kwalletmanager ksshaskpass
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber sof-firmware bluez bluez-utils
    power-profiles-daemon mesa vulkan-intel xorg-server plasma-x11-session xdg-desktop-portal
    xdg-desktop-portal-kde noto-fonts ttf-dejavu zram-generator snapper grub-btrfs inotify-tools
    snap-pac btrfsmaintenance btrfs-assistant
    ```
    (`grub` and `efibootmgr` don't need listing here — the Bootloader step already installs them.)
15. **Timezone**: `Asia/Kolkata`.
16. **Swap**: **off** — zram is set up separately (Step 14 of the shared post-install steps), not
    archinstall's swapfile option.
17. Back out, confirm every section shows a value, then **Install**. Read the final disk-change
    summary carefully — confirm only your target partitions are formatted, with Windows/Dell
    partitions showing no destructive action.

**Don't reboot when it finishes.** Say no to any reboot prompt, or stay in the chroot if it drops
you into one — the steps below need to happen first.

---

## 3. Inside the chroot: confirm the layout is exactly right

```bash
arch-chroot /mnt/archinstall
```
(skip if already in one)

```bash
findmnt / /efi
ls /boot        # should show only vmlinuz-linux/initramfs-linux.img/intel-ucode.img — no "grub" folder
grep -A8 "menuentry 'Arch Linux'" /efi/grub/grub.cfg | grep -E 'cryptomount|luks2'
```
The last command should return actual `cryptomount`/`insmod luks2` lines. If `/efi/grub/grub.cfg`
doesn't exist yet, or `/boot` is missing the expected files, stop and recheck the disk config from
Step 2 before continuing — don't proceed on an uncertain layout.

Also check `GRUB_ENABLE_CRYPTODISK` explicitly — don't assume it's set just because archinstall
handled the disk encryption menu. **Careful with the name here** — this is GRUB's own core setting,
in `/etc/default/grub`, and it must be `y`. It is *not* the same variable as
`GRUB_BTRFS_ENABLE_CRYPTODISK`, a completely different setting in a completely different file
(`/etc/default/grub-btrfs/config`) that Step 5 below explicitly tells you to leave **off**. The
names are one word apart and easy to conflate — this one, GRUB's own, is the one you want enabled:
```bash
grep GRUB_ENABLE_CRYPTODISK /etc/default/grub
```
Should read `GRUB_ENABLE_CRYPTODISK=y`, uncommented. If it's commented out (`#GRUB_ENABLE_CRYPTODISK=y`),
fix it and redo both commands — a commented-out setting here means GRUB never prompts for a
passphrase at all and fails outright trying to reach a still-locked filesystem:
```bash
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /efi/grub/grub.cfg
```

**Larger GRUB menu text**, and confirm os-prober is enabled:
```bash
sed -i 's/^GRUB_GFXMODE=.*/GRUB_GFXMODE=1024x768/' /etc/default/grub
grep -q '^GRUB_GFXMODE=' /etc/default/grub || echo 'GRUB_GFXMODE=1024x768' >> /etc/default/grub
grep GRUB_DISABLE_OS_PROBER /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
grub-mkconfig -o /efi/grub/grub.cfg
```

**Add the `encrypt` hook check** — archinstall should already have this, but confirm:
```bash
grep ^HOOKS /etc/mkinitcpio.conf
```
Should include `encrypt` after `block` and before `filesystems`. If missing:
```bash
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
```

Exit the chroot when done — continue with Step 4 below (still counting from this document's own
numbering; this is the same content as the manual guide's Steps 12 onward).

```bash
exit
umount -R /mnt/archinstall
reboot
```

---

## 4. Set up Snapper — let it create `.snapshots` itself

After rebooting into the base system, log in (console is fine, graphical isn't set up as default
yet at this point — or SSH back in if you set that up):

```bash
sudo snapper --no-dbus -c root create-config /
```
Once booted normally (not chrooted), you don't actually need `--no-dbus` — but it's harmless to
include either way.

```bash
sudo btrfs subvolume list /
sudo snapper -c root list-configs
```

```bash
sudo sed -i 's/^ALLOW_USERS=.*/ALLOW_USERS="yourusername"/' /etc/snapper/configs/root
sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/'  /etc/snapper/configs/root
sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/'    /etc/snapper/configs/root
sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/'  /etc/snapper/configs/root
sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="2"/' /etc/snapper/configs/root
sudo sed -i 's/^TIMELINE_LIMIT_QUARTERLY=.*/TIMELINE_LIMIT_QUARTERLY="0"/' /etc/snapper/configs/root
sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/'  /etc/snapper/configs/root
sudo sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="20"/'                   /etc/snapper/configs/root
sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="10"/' /etc/snapper/configs/root
```

---

## 5. Wire up grub-btrfs, pointed at the ESP

```bash
sudo systemctl enable grub-btrfsd
```

`grub-btrfs` is a separate package from GRUB with its own independent config, and has no idea
`grub.cfg` lives on `/efi` — it defaults to `/boot/grub/grub-btrfs.new`, which doesn't exist on this
layout. Left unset, this doesn't just skip the snapshots submenu, it can corrupt the entire
`grub.cfg` generation:
```bash
sudo sed -i 's|^#GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/efi/grub"|' /etc/default/grub-btrfs/config
grep GRUB_BTRFS_GRUB_DIRNAME /etc/default/grub-btrfs/config
```

```bash
sudo grub-mkconfig -o /efi/grub/grub.cfg
```
Watch for any `No such file or directory` error — there shouldn't be one.

> ## ⚠️ Do NOT set `GRUB_BTRFS_ENABLE_CRYPTODISK="true"` in `/etc/default/grub-btrfs/config`
> Leave it commented out — that's the default, and it's correct, even though it sounds like exactly
> what an encrypted install needs. It's broken in the currently-packaged `grub-btrfs` (confirmed via
> direct trace against the real installed script on an archinstall-built system): its crypto-detection
> code only checks `GRUB_CMDLINE_LINUX_DEFAULT` for a `cryptdevice=` entry — but on an
> archinstall-built system, `cryptdevice=` lives on `GRUB_CMDLINE_LINUX` instead (confirmed in Step 3
> above) — *and* its regex separately hardcodes an expectation that your LUKS mapping is literally
> named `cryptdev`, not `root` (archinstall's own default mapping name). Enabling this doesn't fail
> to help; it makes `grub-mkconfig` **crash silently**, every time, leaving `grub-btrfs.cfg` stale
> with zero error output. The box below is the actual, working fix.

> ## 🔒 The real fix: `grub-btrfs`'s generated snapshot entries never unlock LUKS on their own
> With that setting correctly left off, every snapshot entry `grub-btrfs` generates is missing a
> `cryptomount` call — confirmed directly: GRUB can read straight into any snapshot's `/boot` once
> manually unlocked, so the file is never actually missing, the generated entry simply never asks
> GRUB to unlock anything first. This fix is a small post-processor: it patches `grub-btrfs.cfg`
> directly, inserting a correct `cryptomount` block into every real snapshot entry, triggered
> automatically whenever that file changes. Directly validated end-to-end on an archinstall-built
> system, including a full disaster-recovery drill — `/etc` deleted outright, recovered via a
> pre-existing snapshot through this fix, restored cleanly via Btrfs Assistant.
>
> **1. The fixup script** — idempotent, derives the LUKS UUID dynamically, and traces it from the
> actual mounted root rather than "whichever encrypted device the kernel happened to enumerate
> first" (a real ambiguity if a second LUKS volume — a USB drive, say — is ever connected):
> ```bash
> sudo tee /usr/local/bin/grub-btrfs-crypto-fix.sh <<'SCRIPT'
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
> sudo chmod +x /usr/local/bin/grub-btrfs-crypto-fix.sh
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
> **2. Trigger automatically whenever `grub-btrfs.cfg` changes:**
> ```bash
> sudo tee /etc/systemd/system/grub-btrfs-crypto-fix.path <<'EOF'
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
> sudo tee /etc/systemd/system/grub-btrfs-crypto-fix.service <<'EOF'
> [Unit]
> Description=Inject cryptomount into grub-btrfs snapshot entries
>
> [Service]
> Type=oneshot
> ExecStart=/usr/local/bin/grub-btrfs-crypto-fix.sh
> EOF
>
> sudo systemctl daemon-reload
> sudo systemctl enable --now grub-btrfs-crypto-fix.path
> ```
> `--now` matters, not just `enable` alone — `enable` on its own only creates the boot-time symlink
> for *future* boots, it doesn't arm the watch immediately. Without it, this can sit correctly
> "enabled" but genuinely inactive for as long as the system runs without a fresh reboot — a real,
> confirmed gap that silently missed two real snapshots' worth of regeneration during initial setup
> before being caught. `--now` starts it in the same command, closing that window entirely.
>
> Only the `.path` unit gets enabled — a persistent, near-free kernel-level watch that stays
> `active (waiting)`; the paired `.service` only runs on-demand, matched by the shared filename
> (no explicit link needed).
>
> **3. Patch the file that already exists right now:**
> ```bash
> sudo /usr/local/bin/grub-btrfs-crypto-fix.sh
> sudo journalctl -t grub-btrfs-crypto-fix --no-pager | tail -3   # confirm "Patched N ..."
> sudo grep -c "cryptomount -u" /efi/grub/grub-btrfs.cfg          # should be non-zero
> ```
>
> **Known limitation worth knowing about:** `grub-btrfsd` (the daemon regenerating this file on
> every new snapshot) occasionally misses an event — a real, observed race in its own watch-then-
> restart loop, unrelated to this fix. If a snapshot doesn't show up as bootable shortly after being
> taken, regenerate by hand:
> ```bash
> sudo grub-mkconfig -o /efi/grub/grub.cfg
> ```
> Worth doing this once, manually, after any snapshot you'd actually rely on in a real emergency.

```bash
sudo snapper -c root create --description "initial install"
```

---

## 6. zram, services, reboot

```bash
sudo tee /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
```

```bash
sudo systemctl enable systemd-timesyncd
sudo systemctl enable plasmalogin
sudo systemctl enable power-profiles-daemon
sudo systemctl enable snapper-timeline.timer
sudo systemctl enable snapper-cleanup.timer
sudo systemctl set-default graphical.target
sudo systemctl enable btrfs-scrub@-.timer
```
(`NetworkManager`, `bluetooth` should already be enabled by archinstall's own network/audio menu
choices — confirm with `systemctl is-enabled NetworkManager bluetooth`.)

```bash
sudo reboot
```

---

## 7. First boot checks

Windows boots with no passphrase prompt; selecting Arch prompts once, in readable `gfxterm` font.
```bash
nmcli device status
bluetoothctl show
wpctl status
lspci -k | grep -EA3 'VGA|3D'
findmnt -t btrfs
btrfs subvolume list /
echo $XDG_SESSION_TYPE      # should print "wayland"
```

---

## 8. Test the full snapshot → boot → restore workflow

Worth doing the *hard* version, not a light one — this exact sequence has been run for real,
start to finish, on an archinstall-built system: root fully encrypted, snapshot boot going through
Step 5's `cryptomount` fix, a failure severe enough that `sudo` itself stops working.

```bash
sudo snapper create --description "pre-drill baseline"
```
On a **normal boot**, delete something that breaks the system hard, not cosmetically:
```bash
sudo -i
rm -rf /etc
```
Reboot. The normal entry fails completely — no working `sudo`, no valid `/etc/passwd`, dropped to
an unusable TTY. Expected, and the point: this is genuinely the scenario snapshot-boot exists for.

Power back into GRUB, open **"Arch Linux snapshots"**, pick the pre-drill snapshot — should boot
into a full working Plasma session via the overlay hook, on a system that moments ago couldn't boot
normally at all.

**Restore — Method A, Btrfs Assistant (GUI):** **Snapper** tab → **Browse/Restore** → confirm
target `@` → select snapshot → **Restore** → reboot into the normal **"Arch Linux"** entry. Proven,
not theoretical — run end-to-end against a fully deleted `/etc`, restored cleanly with no manual
intervention beyond the click. The leftover `@_backup_<timestamp>` subvolume this creates is safe to
delete afterward, from Btrfs Assistant's **Subvolumes** tab or via `btrfs subvolume delete`.

**Method B — CLI fallback:**
```bash
sudo mkdir -p /mnt/btrfstop
sudo mount -o subvolid=5 /dev/mapper/<your-mapping-name> /mnt/btrfstop
sudo btrfs subvolume list /mnt/btrfstop | grep snapshot
sudo mv /mnt/btrfstop/@ "/mnt/btrfstop/@_broken_$(date +%Y%m%d)"
sudo btrfs subvolume snapshot /mnt/btrfstop/.snapshots/N/snapshot /mnt/btrfstop/@
sudo umount /mnt/btrfstop
sudo reboot
```

---

## 9. Post-install LUKS convenience and safety

**1. Back up the LUKS header:**
```bash
sudo cryptsetup luksHeaderBackup /dev/nvme0n1pN --header-backup-file ~/$(cat /etc/hostname)-luks-header-backup.img
```
(substitute your actual LUKS partition). `cat /etc/hostname` rather than the `hostname` command —
the latter comes from a separate package (`inetutils`) that isn't guaranteed to be installed, and
silently evaluates to nothing if missing, landing you with an oddly-named file rather than an
error; check `ls -la ~ | grep luks-header` if that ever happens. Move the file off this disk
immediately. Redo after any keyslot change (step 3 below).

**2. Collapse the two passphrase prompts into one:**
```bash
sudo dd if=/dev/urandom of=/etc/cryptroot.key bs=512 count=4
sudo chmod 000 /etc/cryptroot.key
sudo cryptsetup luksAddKey /dev/nvme0n1pN /etc/cryptroot.key

echo 'FILES=(/etc/cryptroot.key)' | sudo tee -a /etc/mkinitcpio.conf
sudo mkinitcpio -P

sudo sed -i '/GRUB_CMDLINE_LINUX=/ s/"$/ cryptkey=rootfs:\/etc\/cryptroot.key"/' /etc/default/grub
grep GRUB_CMDLINE_LINUX /etc/default/grub   # confirm cryptkey=rootfs:/etc/cryptroot.key is there
sudo grub-mkconfig -o /efi/grub/grub.cfg
```
Note: on an archinstall-built system, crypt parameters typically live on `GRUB_CMDLINE_LINUX` (not
`_DEFAULT`) — confirm which line actually has `cryptdevice=` on it before editing, and match that
one.

While editing this line, also append `:allow-discards` directly onto the existing
`cryptdevice=UUID=...:root` segment (same field, right after the mapper name `root`) — without it,
`discard=async` on every btrfs mount is a **silent no-op**: dm-crypt drops TRIM/discard requests by
default for security reasons (confirmed from the kernel's own `dm-crypt` documentation), and won't
pass them through to the physical SSD unless explicitly told to. The tradeoff is real but narrow —
it can reveal which blocks are in-use versus empty to someone with physical access to the raw
device — reasonable to accept on a personal machine for genuine SSD longevity/performance:
```bash
sudo sed -i '/GRUB_CMDLINE_LINUX=/ s/:root/:root:allow-discards/' /etc/default/grub
grep GRUB_CMDLINE_LINUX /etc/default/grub   # confirm :root:allow-discards is now there
sudo grub-mkconfig -o /efi/grub/grub.cfg
```

**3. Speed up the remaining GRUB-stage prompt, on *both* keyslots:**
```bash
sudo cryptsetup luksConvertKey /dev/nvme0n1pN --pbkdf argon2id --pbkdf-force-iterations 4 --pbkdf-memory 262144
```
This only re-tunes the slot matching your typed passphrase. Tune the keyfile slot explicitly too
(check its number first with `sudo cryptsetup luksDump /dev/nvme0n1pN`):
```bash
sudo cryptsetup luksConvertKey /dev/nvme0n1pN --key-slot 1 --key-file /etc/cryptroot.key \
  --pbkdf argon2id --pbkdf-force-iterations 4 --pbkdf-memory 262144
```
Confirm both slots show `Memory: 262144`, then redo step 1's header backup.

**4. Plasma autologin** (optional):
```bash
ls /usr/share/wayland-sessions/    # confirm session name, likely "plasma"
sudo mkdir -p /etc/plasmalogin.conf.d
sudo tee /etc/plasmalogin.conf.d/autologin.conf <<EOF
[Autologin]
User=yourusername
Session=plasma
EOF
```

**5. KWallet auto-unlock** — without this, KWallet prompts separately on login even with autologin
configured above:
```bash
grep pam_kwallet /etc/pam.d/plasmalogin*
```
Confirm the `auth`/`session` lines include `kwalletd=/usr/bin/ksecretd` — Plasma 6 moved to a new
secret-service daemon (`ksecretd`), and `pam_kwallet5.so` needs to be told about it explicitly:
```
auth       optional     pam_kwallet5.so
session    optional     pam_kwallet5.so auto_start kwalletd=/usr/bin/ksecretd
```
Add the parameter if missing, then confirm after reboot with `pgrep ksecretd`.

---

## 10. Post-install (optional): pacman hooks for GRUB maintenance

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

---

## 11. Post-install: automated pre-upgrade snapshots + an Arch news gate

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

Same failure modes and fixes as the manual guide's Troubleshooting section — worth reading there in
full. The two most important, both confirmed on a real archinstall-built install:

**If you ever install a second kernel and it boots the wrong one by default:** `GRUB_DEFAULT` takes
a `"top-level-index>submenu-index"` value, both zero-indexed — find the real indices from
`grep -n "^menuentry\|^submenu" /efi/grub/grub.cfg` rather than guessing, and **always quote the
result**: `GRUB_DEFAULT="1>1"`, never unquoted. Since `/etc/default/grub` is sourced as a shell
script, an unquoted `>` is a real redirection operator — confirmed as a genuine, real failure on a
live install (a stray file named `1` appeared in `/`, and the intended default silently didn't
apply), not a theoretical concern.

**🔒 GRUB menu completely broken ("no such device" / "no server specified" / "need to load the
kernel first") regardless of entry chosen:** `grub-btrfs`'s `GRUB_BTRFS_GRUB_DIRNAME` wasn't set —
Step 5 above. Check and fix, then regenerate and watch for write errors before rebooting again.

**🔒 GRUB reaches "no such device" with *no passphrase prompt at all*:** `GRUB_ENABLE_CRYPTODISK` is
commented out in `/etc/default/grub` — Step 3 above already has you check this explicitly, since
it's genuinely not guaranteed to be set correctly out of the box even on a fresh archinstall-built
system. Fix and redo both `grub-install` and `grub-mkconfig`.

**🔒 Booting a snapshot fails with "no such device" or "file ... not found", even though the
regular "Arch Linux" entry boots fine:** Step 5's `cryptomount` fix isn't installed or hasn't run.
```bash
sudo grep -c "cryptomount -u" /efi/grub/grub-btrfs.cfg   # should be non-zero
systemctl status grub-btrfs-crypto-fix.path               # should show active (waiting)
```
If the count is 0, re-run `/usr/local/bin/grub-btrfs-crypto-fix.sh` manually.

**🔒 `grub-mkconfig` stops right after "Detecting snapshots ..." with no error and no `Found
snapshot` lines, and the snapshots submenu never updates:** `GRUB_BTRFS_ENABLE_CRYPTODISK` got set
to `"true"` in `/etc/default/grub-btrfs/config` — broken in the currently-packaged `grub-btrfs`
(Step 5's warning box), crashes the generator silently every time. Comment it back out and
regenerate:
```bash
sudo sed -i 's/^GRUB_BTRFS_ENABLE_CRYPTODISK="true"/#GRUB_BTRFS_ENABLE_CRYPTODISK="true"/' /etc/default/grub-btrfs/config
sudo grub-mkconfig -o /efi/grub/grub.cfg
```

**A snapshot doesn't appear in the snapshots submenu shortly after being taken:** `grub-btrfsd`'s
own watch occasionally misses an event (Step 5's note) — regenerate by hand with
`sudo grub-mkconfig -o /efi/grub/grub.cfg`.
