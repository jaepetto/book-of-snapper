# GRUB internals

GRUB (GRand Unified Bootloader) is the boot loader most Linux distributions
use to get from firmware (BIOS or UEFI) to a running kernel. Two of its
internals matter a lot once snapshots and rollback enter the picture: how
its configuration file actually gets built, and how it remembers a
one-shot boot choice across a single reboot.

## The config-generation pipeline

`grub-mkconfig` (invoked as `update-grub` on Debian/Ubuntu) generates
`/boot/grub/grub.cfg`. It does this by running every executable script
under `/etc/grub.d/` **in lexical order** and concatenating whatever each
one prints to stdout. That's the entire mechanism — there's no separate
templating engine, just shell scripts whose job is to emit fragments of
GRUB config syntax.

This is why the scripts are numbered (`00_header`, `10_linux`,
`41_snapshots-btrfs`, ...): the prefix controls ordering, and any one
script can be inspected, patched, or replaced independently of the others.
`00_header` typically emits environment-block loading and global settings;
`10_linux` scans installed kernels and emits their boot entries; a
third-party tool like grub-btrfs can drop in its own numbered script
(`41_snapshots-btrfs`) to add snapshot-specific entries without touching
anything else.

## Conffiles and package upgrades

On a Debian-family system, the scripts under `/etc/grub.d/` are shipped by
a package (`grub2-common` and friends) and tracked by dpkg as **conffiles**
— files dpkg manages but expects a local administrator might modify.
Editing one directly works until the next package upgrade, which will
either silently restore the packaged version or interactively prompt about
the conflict, depending on how dpkg is invoked.

Two ways to make an edit survive that:

- **`sed`-patch the file in place.** Simple, but the patch doesn't survive
  the next package upgrade — dpkg's conffile handling doesn't know or care
  that a `sed` command produced the current content; it just sees a file
  that differs from the packaged version and reverts or prompts.
- **`dpkg-divert`.** Redirects the *packaged* file to a different path,
  then installs a patched file at the original path. A future package
  upgrade installs its new version to the diversion target instead of
  overwriting the (now-diverted-away-from) active file — the local patch
  survives untouched. The trade-off: the active copy is now frozen at
  whatever it was when diverted, so upstream changes (a security fix, a new
  feature) land silently in the `.orig` and need to be periodically
  diffed against and the patch reapplied by hand.

One concrete gotcha worth knowing if you use this pattern on `/etc/grub.d/`
specifically: the diversion target **must not** live inside
`/etc/grub.d/` itself. `grub-mkconfig` processes every file it finds in
that directory (skipping only a few well-known suffixes like `.dpkg-*`,
`.rpmsave`, `~`), and a `.orig` file is not one of the excluded suffixes —
leaving a diverted original inside the directory generates a second,
duplicate set of menu entries. Divert to somewhere else entirely, e.g.
`/usr/share/<your-project>/10_linux.orig`.

## The `grubenv` environment block

GRUB can persist a small set of key=value pairs across boots in a fixed-
size file, conventionally `/boot/grub/grubenv`. This is what
`grub-reboot`/`grub-set-default` actually manipulate — `grub-reboot`
writes a `next_entry` value that GRUB consumes and clears on the very next
boot (a true one-shot); `grub-set-default` writes `saved_entry`
persistently.

### The LVM/RAID storage restriction

The GRUB manual states this plainly:

> "For safety reasons, this storage is only available when installed on a
> plain disk (no LVM or RAID), using a non-checksumming filesystem (no
> ZFS), and using BIOS or EFI functions (no ATA, USB or IEEE1275)."

In practice: if `/boot/grub` (and therefore `grubenv`) lives on a device
behind LVM or RAID indirection, GRUB's own pre-boot code — which has to
talk to storage using its own minimal drivers, long before an OS and its
device-mapper stack exist — can't reliably write to it. `grub-set-default`
still works (it just rewrites the whole config file, a normal write from
userspace), but `grub-reboot`'s one-shot write silently fails to have any
effect — `next_entry` never actually gets set where GRUB's boot-time code
will find it, so the "boot this once" request is dropped and the system
just boots its normal default, indefinitely.

A separate, plain vfat EFI System Partition (ESP) — a real GPT partition
outside any LVM/RAID device, which every UEFI system already has — happily
satisfies the restriction. Relocating the environment block there is a
generic fix for any LVM-or-RAID-backed root filesystem, not something
specific to one distro.

### Fixing it: relocate the environment block to the ESP

Working sequence, verified end-to-end with real reboots on a btrfs-on-LVM
root:

1. Create a real, empty `grubenv` on the ESP:
   `grub-editenv /boot/efi/EFI/<id>/grubenv create`.
2. `dpkg-divert` `/etc/grub.d/00_header` (per the conffile pattern above),
   and patch the diverted-from copy to *unconditionally* search for the ESP
   by UUID, point `$env_block` at the file created in step 1, and
   `load_env` from there — replacing **both** the original unconditional
   `load_env` call and any conditional relocation logic, so the read path
   and the write path always agree on the same file. (Getting only one of
   the two redirected reproduces the exact same "stuck forever" bug against
   a different file.)
3. Regenerate the config (`update-grub`).
4. Since the stock `grub-reboot`/`grub-set-default` tools have no way to
   target a non-default `grubenv` path, replace their one-shot use with a
   direct call: `grub-editenv <path-to-ESP-grubenv> set next_entry=<id>`.

Verified behavior: two one-shot boots (each targeting a different kernel)
both self-cleared `next_entry` immediately after being consumed, and a
third, plain reboot (nothing set) fell back correctly to the real default —
the one-shot mechanism restored to working as designed.

## A second, harder blocker: a hard-coded config path

Relocating `grubenv` fixes the one-shot *boot selection* mechanism. It does
not fix a separate problem some btrfs-on-LVM layouts hit: `grub-install`
can bake the ESP's tiny bootstrap stub with a **hard-coded subvolume path**
to the main `grub.cfg`, e.g.:

```
search.fs_uuid <uuid> root lvmid/…
set prefix=($root)'/@/boot/grub'
configfile $prefix/grub.cfg
```

If `@` here is a specific subvolume name (a common convention for the
"main" subvolume in an openSUSE-style layout), GRUB will **always** load
that subvolume's `grub.cfg`, regardless of which subvolume is actually set
as the filesystem's default. Concretely, this means:

- Any GRUB config regeneration (`update-grub`, `grub-install`) run while
  booted from a *different* subvolume (e.g. from inside a snapshot after a
  rollback) writes to a `grub.cfg` path GRUB will never read, and can even
  re-point the ESP stub at the wrong subvolume — stranding the path back to
  the original.
- Every GRUB config change must be driven from the one subvolume the ESP
  stub points at, as a standing operational constraint.

Some GRUB builds (notably openSUSE's and Fedora's, via a downstream patch)
support `set btrfs_relative_path="y"`, which makes the prefix resolve
against whichever subvolume is currently the filesystem's *default*,
removing this constraint entirely. Whether your GRUB build has this is not
a documented, portable feature — it's a downstream patch some distributions
carry and others don't. Confirm empirically:

```
grub-install --help | grep -iE 'btrfs|relative|subvol'
strings /usr/lib/grub/<platform>/btrfs.mod | grep -i relative_path
```

If both come back empty, the hard-coded-subvolume constraint is permanent
on that build, not a temporary workaround waiting for a flag — treat
"always regenerate GRUB config from the pinned subvolume" as a fixed
architectural rule for that system, and design any rollback tooling around
it rather than around fixing it.

## Further reading

- [GNU GRUB Manual](https://www.gnu.org/software/grub/manual/grub/grub.html)
  — full manual, including sections on writing configuration files and the
  command reference (`grub-mkconfig`, `grub-reboot`, `grub-set-default`,
  `grub-editenv`, etc.).
- [GNU GRUB Manual — Environment block](https://www.gnu.org/software/grub/manual/grub/html_node/Environment-block.html)
  — the storage-restriction wording quoted above, straight from the source.
- [GNU GRUB Manual — Invoking grub-mkconfig](https://www.gnu.org/software/grub/manual/grub/html_node/Invoking-grub_002dmkconfig.html)
  — the config-generation command itself.
- [`dpkg-divert(1)`](https://manpages.debian.org/bookworm/dpkg/dpkg-divert.1.en.html)
  — the diversion mechanism used for the conffile-survival pattern above.
