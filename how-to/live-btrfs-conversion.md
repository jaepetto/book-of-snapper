# How-to: live ext4→btrfs root conversion, no reboot into rescue media

This procedure converts a running system's ext4 root filesystem to btrfs,
live, over an existing SSH session — no rescue ISO, no console access, no
Secure Boot changes, and no manual boot-order/firmware fiddling. It
combines several pieces covered separately elsewhere in this book:
[btrfs](../concepts/btrfs.md), [GRUB internals](../concepts/grub.md),
[initramfs and kexec](../concepts/initramfs-kexec.md),
[dropbear-initramfs](../concepts/dropbear-initramfs.md), and the
[subvolume layout](../concepts/subvolume-layout.md) convention. Read those
first if any given step doesn't make sense on its own — this page assembles
them rather than re-explaining each one.

**End state**: a btrfs root, mounted with no `subvol=` pin, split into the
openSUSE-style layout with `/boot` folded in — **rollback-ready**, but not
yet rollback-*armed*. Installing and configuring `snapper` itself is a
separate next step (see "What this doesn't do yet" below).

**Placeholders used throughout**: `<root-device>` (the current root block
device), `<boot-uuid>` / `<efi-uuid>` (the existing separate `/boot` and
`/boot/efi` filesystem UUIDs), `<btrfs-uuid>` (assigned by `btrfs-convert`),
`<project>` (any short name for local artifacts this procedure creates).

## 1. Preflight

Before touching anything, confirm the starting assumptions hold — every
check here should be able to fail loudly with **nothing changed**:

- Root is currently **ext4**, on the expected device.
- `/boot` is currently a **separate ext4** filesystem (not yet folded —
  this guards against accidentally re-running the procedure against an
  already-converted system).
- `/boot/efi` is **vfat**, and the system is **UEFI** (not legacy BIOS).
- The currently-running kernel's image file exists on disk (it needs to be
  re-loaded via `kexec` later).
- A full backup or hypervisor-level snapshot exists and is current — this
  procedure includes an actual filesystem conversion; treat it with the
  same care as any other irreversible-until-verified disk operation.

If any check fails, stop — don't proceed with a partial or wrong
assumption about the starting state.

## 2. Stage

Prepare everything needed for the conversion *before* jumping into the new
kernel — building and staging first, so the actual jump (step 3) has as
little left to do, and as little that can go wrong, as possible.

1. Mask autonomous package-update timers for the duration, so nothing
   unrelated fires mid-conversion (see the
   [apt/do-release-upgrade integration](../concepts/apt-upgrade-integration.md)
   page's masking note — the same practice applies here, not just to
   release upgrades):
   ```
   systemctl mask --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service
   ```
2. Stage the SSH key for the initramfs **before** installing
   `dropbear-initramfs` — this ordering matters (see the
   [dropbear-initramfs](../concepts/dropbear-initramfs.md) page):
   ```
   mkdir -p /etc/dropbear/initramfs
   install -m 0600 <local-authorized_keys> /etc/dropbear/initramfs/authorized_keys
   ```
3. Install the conversion toolchain:
   ```
   apt-get install -y kexec-tools btrfs-progs dropbear-initramfs
   ```
4. Write a hook script and a premount script for `initramfs-tools` (see
   the [initramfs and kexec](../concepts/initramfs-kexec.md) page for the
   general shape). The hook bundles `btrfs-convert`, `e2fsck`, `tune2fs`,
   and the conversion logic itself into the image; the premount script's
   `PREREQ` should declare `dropbear` so the SSH daemon is guaranteed to be
   up before the conversion logic runs (see the
   [dropbear-initramfs](../concepts/dropbear-initramfs.md) page's fail-hold
   pattern) — its success branch reboots, its failure branch holds the
   initramfs open indefinitely for live debugging over that same SSH
   session.
5. Build the custom image (a separate file — this does **not** touch the
   system's normal boot initramfs):
   ```
   mkinitramfs -o /var/tmp/<project>-initrd.img $(uname -r)
   ```

## 3. Fire

```
kexec -s -l /boot/vmlinuz-$(uname -r) --initrd=/var/tmp/<project>-initrd.img \
  --command-line="root=<root-device> ro ip=<client>::<gateway>:<netmask>:<hostname>::off:<dns> panic=0"
kexec -e
```

`-s` specifically (not `-l`, not plain `kexec` defaults) and `kexec -e` to
fire (not `systemctl kexec`, which hangs against this kind of image) —
both are explained on the [initramfs and kexec](../concepts/initramfs-kexec.md)
page. Reconnect over SSH to the dropbear session once the jump completes —
a hypervisor console may not visibly repaint through the jump, so absence
of console output isn't evidence anything failed.

## 4. Inside the initramfs: the actual conversion

This runs automatically (it's the premount script's job), but understanding
each phase matters for debugging a failure live, which the fail-hold
pattern makes possible:

1. **Filesystem check.** `e2fsck` the now-unmounted root, accepting exit
   codes ≤ 2 as success (an unclean shutdown before this point always
   leaves a dirty journal, which `e2fsck` reports as "corrected" — see the
   initramfs/kexec page's `set -e` gotcha).
2. **Clear `orphan_file` if present**, then run `btrfs-convert` (see the
   [btrfs](../concepts/btrfs.md) page — this is the in-place conversion
   that keeps the original filesystem recoverable as a subvolume until a
   `btrfs balance` runs).
3. **Create `@` and `@home`**, mount the new filesystem at a working
   mountpoint.
4. **Perform the subvolume split**, resumably:
   ```
   SPLIT="var/log var/cache var/tmp var/crash var/spool srv opt root usr/local"
   ```
   For each entry: skip it if it's already a subvolume (idempotent
   re-run); otherwise rename the existing directory aside, create the
   subvolume, restore ownership and permissions **by reference** from the
   renamed original (`chown --reference`, `chmod --reference` — this is
   what preserves sticky bits on `/var/tmp`/`/var/crash` and `0700` on
   `/root`, which a naive recreation would lose), copy the data back, and
   remove the renamed original. Checking "already a subvolume" first, and
   detecting a half-renamed `<dir>.orig` left over from an interrupted
   prior attempt, is what makes a failed-and-retried run safe to resume
   rather than needing to start over. See the
   [subvolume layout](../concepts/subvolume-layout.md) page for *why*
   these specific directories.
5. **Fold `/boot` into `@`**: copy the real `/boot`'s contents into the
   (currently empty, since `/boot` was a separate mount) `@/boot`, then
   create a nested subvolume for the GRUB platform modules directory
   (e.g. `@/boot/grub/x86_64-efi`) so it's automatically excluded from
   every future snapshot — GRUB's own modules must never revert.
6. **Write the new `/etc/fstab`**: no `subvol=` on `/` (follow the btrfs
   default subvolume), `subvol=@home` on `/home`, one line per split
   subvolume, the GRUB-platform-modules subvolume pinned explicitly,
   `/boot/efi` unchanged — and critically, **no separate `/boot` line at
   all** anymore.
7. **Un-pin GRUB's subvolume assumption**, via `dpkg-divert` rather than a
   plain `sed` edit (see the [GRUB internals](../concepts/grub.md) page —
   a future `grub2-common` upgrade would silently restore a `sed`-patched
   conffile; a diverted original survives it):
   ```
   mkdir -p /usr/share/<project>
   dpkg-divert --local --divert /usr/share/<project>/10_linux.orig --rename --add /etc/grub.d/10_linux
   sed 's|rootflags=subvol=${rootsubvol} ||' /usr/share/<project>/10_linux.orig > /etc/grub.d/10_linux
   chmod 0755 /etc/grub.d/10_linux
   ```
   (The diversion target must live *outside* `/etc/grub.d/` itself — the
   config generator processes every non-excluded file it finds in that
   directory, and a stray `.orig` left inside it would produce duplicate
   menu entries.)
8. **Clean up**: purge `dropbear-initramfs` (see its own page's "treat it
   as temporary" note), remove this procedure's own hook/premount scripts
   and the staged initramfs image, disable any swap file from the old
   layout, regenerate the real system initramfs, then `sync` and reboot.
   On any failure at any of the steps above, the premount script's failure
   branch holds the initramfs open instead — fix the specific step live
   over the still-open SSH session and re-run the conversion script
   directly, without a second `kexec`.

## 5. Verify

After the reboot:

- `findmnt /` shows the btrfs filesystem, root device now reads the btrfs
  UUID, and the mount options carry **no** `subvol=` (following the
  default subvolume, as intended).
- `btrfs subvolume list /` shows every subvolume from the split, plus
  `@home` and the excluded GRUB-modules subvolume.
- The system reports **zero failed units** and boots to a normal login —
  a locked-down or partially-converted state should be caught here, not
  discovered later.

## What this doesn't do yet

This procedure ends with a filesystem **ready** for snapshot-based
rollback — the layout is correct, GRUB is un-pinned — but `snapper` itself
isn't installed or configured, and there's no boot-menu integration for
browsing or booting into snapshots yet. Arming the system for actual
rollback is a separate next step, layered on top of what this page
produces.

## Further reading

- [btrfs](../concepts/btrfs.md)
- [GRUB internals](../concepts/grub.md)
- [initramfs and kexec](../concepts/initramfs-kexec.md)
- [dropbear-initramfs](../concepts/dropbear-initramfs.md)
- [Subvolume layout](../concepts/subvolume-layout.md)
- [apt/do-release-upgrade integration](../concepts/apt-upgrade-integration.md)
