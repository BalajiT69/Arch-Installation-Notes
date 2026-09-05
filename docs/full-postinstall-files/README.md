# Deployment Index — Full Post-Install Set (Encryption + General)

Every script, hook, timer, service, and PAM override built and validated across this whole project,
organized by real destination folder. **Read the "Manual edits" section at the bottom before
deploying anything** — a few pieces genuinely cannot be safe drop-in files (they contain
system-specific values like UUIDs) and are given as exact commands instead.

---

## Folder → destination map

| This folder | Copies to              | Needs `chmod +x`? |
|---|---|---|
| `scripts/`  | `/usr/local/bin/`      | Yes, on the `.sh` files and `archnews` |
| `hooks/`    | `/etc/pacman.d/hooks/` | No |
| `systemd/`  | `/etc/systemd/system/` | No |
| `pam.d/`    | `/etc/pam.d/`          | No (only needed if using Plasma Login Manager + KWallet) |

---

## What each file does

### `scripts/`

- **`grub-btrfs-crypto-fix.sh`** — **Encryption-specific.** Patches `grub-btrfs`'s own generated
  snapshot boot entries, which are missing a `cryptomount` call due to a confirmed upstream bug
  (wrong cmdline variable checked, hardcoded wrong LUKS mapper name assumption). Idempotent,
  triggered automatically by the `.path` unit below. **Edit the `GBCFG` path inside this file** if
  your `grub.cfg`/`grub-btrfs.cfg` don't live at `/efi/grub` on your system.

- **`setup-luks-keyfile-and-pbkdf.sh`** — **Encryption-specific, one-time, interactive.** Creates
  the keyfile that collapses the two-stage LUKS prompt into one, wires it into GRUB and the
  initramfs, tunes both keyslots' PBKDF cost so GRUB's slow implementation stays fast, and adds
  `:allow-discards` so `discard=async` on your btrfs mounts actually reaches the SSD. **Edit the
  three variables at the top** (`LUKSPART`, `GRUBCFG_OUT`, `PBKDF_MEMORY_KB`) before running.
  Genuinely interactive — it will ask for your LUKS passphrase multiple times; that's expected, not
  a bug.

- **`backup-luks-header.sh`** — **Encryption-specific.** Convenience wrapper for
  `cryptsetup luksHeaderBackup`. Run it any time you change a keyslot (a fresh header backup that
  doesn't match your current keyslots isn't useful). Usage: `sudo ./backup-luks-header.sh
  /dev/nvme0n1pN`. Still moves the file locally only — copying it off this disk afterward is on you.

- **`archnews`** — Minimal, from-scratch Arch news checker (replaces the unmaintained `informant`
  AUR package). Fails **closed** on a fetch error.

- **`snapper-pacman-snapshot.sh`** — Takes a tagged, pre-upgrade Snapper snapshot with a full
  package-list sidecar file, triggered by `95-snapshot.hook` below.

- **`prune-snapper-pkglists.sh`** — Deletes orphaned sidecar `.pkglist` files once Snapper's own
  retention policy has removed their matching snapshot. Run monthly by the timer below.

### `hooks/`

- **`90-archnews.hook`** — Blocks a `pacman` upgrade transaction if there's unread Arch news.
  **Has `AbortOnFail`** — confirmed necessary by real testing; without it, a `PreTransaction` hook
  failing does *not* stop the transaction on its own.
- **`95-snapshot.hook`** — Fires `snapper-pacman-snapshot.sh` before every upgrade. Runs *after*
  `90-` deliberately — no point snapshotting a transaction that's about to be blocked anyway.
- **`94-grub-reinstall.hook`** — Re-runs `grub-install` whenever the `grub` package itself updates.
  **Edit `--boot-directory=` inside this file** to match where your `grub.cfg` actually lives.
- **`95-grub-efi-cfg.hook`** — Regenerates `grub.cfg` on any kernel or `grub` change. **Edit the
  `-o` path** to match, same as above.
- **`clear-cache.hook`** — Optional. Keeps only the 2 most recent cached versions of each package.

### `systemd/`

- **`grub-btrfs-crypto-fix.path`** + **`.service`** — **Encryption-specific.** The watcher pair for
  `grub-btrfs-crypto-fix.sh`. Only the `.path` gets enabled directly (see deployment steps below) —
  never enable the `.service` on its own.
- **`prune-snapper-pkglists.service`** + **`.timer`** — Monthly sidecar cleanup pair. Same rule:
  only the `.timer` gets enabled.

### `pam.d/`

- **`plasmalogin`** + **`plasmalogin-autologin`** — Only relevant if you're using Plasma Login
  Manager (KDE) with KWallet. Pre-corrected copies of the vendor defaults (normally shipped to
  `/usr/lib/pam.d/`, which gets silently overwritten on every `plasma-login-manager` update) with
  `kwalletd=/usr/bin/ksecretd` added — required on Plasma 6, confirmed via `pgrep ksecretd`. If
  autologin is enabled, **also blank the "Login" wallet's password in KWalletManager** — autologin
  never types a password for `pam_kwallet5.so` to unlock the wallet with, so this fix alone isn't
  sufficient in that case.

---

## Deployment order

```bash
# 1. Copy everything to its real destination
sudo cp scripts/* /usr/local/bin/
sudo cp hooks/* /etc/pacman.d/hooks/
sudo cp systemd/* /etc/systemd/system/
sudo cp pam.d/* /etc/pam.d/          # only if using Plasma Login Manager + KWallet

# 2. Fix permissions
sudo chmod +x /usr/local/bin/archnews \
              /usr/local/bin/snapper-pacman-snapshot.sh \
              /usr/local/bin/prune-snapper-pkglists.sh \
              /usr/local/bin/grub-btrfs-crypto-fix.sh \
              /usr/local/bin/setup-luks-keyfile-and-pbkdf.sh \
              /usr/local/bin/backup-luks-header.sh

# 3. EDIT before running (see "What each file does" above for which variables/paths):
#    - setup-luks-keyfile-and-pbkdf.sh: LUKSPART, GRUBCFG_OUT, PBKDF_MEMORY_KB
#    - grub-btrfs-crypto-fix.sh: GBCFG, if not /efi/grub/grub-btrfs.cfg
#    - 94-grub-reinstall.hook / 95-grub-efi-cfg.hook: --boot-directory / -o paths

# 4. Run the one-time, interactive encryption setup (asks for your passphrase)
sudo /usr/local/bin/setup-luks-keyfile-and-pbkdf.sh

# 5. Back up the header now that keyslots changed
sudo /usr/local/bin/backup-luks-header.sh /dev/nvme0n1pN
# then move the resulting file OFF this disk

# 6. Seed the news gate baseline (skip this and your first upgrade blocks on ALL history)
sudo /usr/local/bin/archnews seed

# 7. Enable the two watchers/timers — --now matters, plain "enable" leaves them
#    dormant until the next reboot, confirmed as a real, missed-snapshot bug
sudo systemctl daemon-reload
sudo systemctl enable --now grub-btrfs-crypto-fix.path
sudo systemctl enable --now prune-snapper-pkglists.timer

# 8. Force the crypto-fix to patch whatever snapshots already exist
sudo /usr/local/bin/grub-btrfs-crypto-fix.sh
sudo journalctl -t grub-btrfs-crypto-fix --no-pager | tail -3   # confirm "Patched N ..."
```

---

## Manual edits — NOT provided as drop-in files, on purpose

These three touch system-specific content (existing UUIDs, existing settings) that would be
actively dangerous to overwrite wholesale. Apply as edits to your *existing* files instead.

**`/etc/mkinitcpio.conf`** — confirm `encrypt` is present, after `block`, before `filesystems`, and
add `grub-btrfs-overlayfs` at the very **end** of `HOOKS` (confirmed correct placement, straight
from `grub-btrfs`'s own documentation) — without it, a booted snapshot has no writable overlay and
almost anything writing to `/etc` or `/var/lib/pacman` will fail with a read-only filesystem error:
```bash
grep ^HOOKS /etc/mkinitcpio.conf
# add grub-btrfs-overlayfs to the end if missing, then:
sudo mkinitcpio -P
```

**`/etc/default/grub`** — three things worth checking, none safe to blindly overwrite:
```bash
grep GRUB_ENABLE_CRYPTODISK /etc/default/grub   # must be uncommented, =y
grep GRUB_DEFAULT /etc/default/grub             # if set, MUST be quoted: GRUB_DEFAULT="1>1"
                                                 # — unquoted, ">" is a real shell redirect;
                                                 # confirmed to create a stray file named "1" in /
```

**`/etc/default/grub-btrfs/config`** — leave `GRUB_BTRFS_ENABLE_CRYPTODISK` commented out; it's
broken in the currently-packaged `grub-btrfs` and silently crashes `grub-mkconfig` if enabled —
that's exactly what `grub-btrfs-crypto-fix.sh` above exists to work around instead:
```bash
grep GRUB_BTRFS_ENABLE_CRYPTODISK /etc/default/grub-btrfs/config   # should be commented out
grep GRUB_BTRFS_GRUB_DIRNAME /etc/default/grub-btrfs/config
# set to wherever your grub.cfg actually lives, if it's not the built-in default
```

**`/etc/fstab`** — `noatime` + `discard=async` on every **btrfs** line only — never on `/efi`
(vfat doesn't support the parameterized `discard=async` form, and adding it there broke a real boot
during testing):
```bash
grep btrfs /etc/fstab   # confirm noatime,discard=async present on every line
grep efi /etc/fstab     # confirm NO discard= option here at all
```
