# grub-btrfs

[grub-btrfs](https://github.com/Antynea/grub-btrfs) is a third-party
project (not part of GRUB or btrfs-progs, and not packaged by Ubuntu — it's
built from source) that adds a `/etc/grub.d/` script generating one GRUB
submenu per btrfs snapshot, with an entry inside it for every kernel it
finds in that snapshot's own `/boot`. It's the piece that turns "I have
snapshots" into "I can pick one from the boot menu."

## How it works

Per the project's own README, grub-btrfs "automatically lists snapshots
existing on the btrfs root partition" — it recognizes snapshots made
manually, or by snapper, Timeshift, or Yabsnap, reading each tool's own
tagging/metadata to label entries with useful descriptions. For each
snapshot found, it "automatically detect[s] kernel, initramfs and
Intel/AMD microcode in `/boot` directory within snapshots" and generates a
matching menu entry — it also automatically detects whether `/boot` sits on
a separate partition from the root filesystem, adjusting how it looks for
those files.

Two operational pieces of that:

- Regeneration normally happens through `grub-btrfsd`, a small daemon that
  watches the snapshot directory with inotify and regenerates
  `grub-btrfs.cfg` automatically whenever a snapshot is created or deleted
  — no manual `update-grub` needed per snapshot in steady state.
- It emits **nothing** until at least one real snapshot subvolume exists.
  A tool like snapper always has a synthetic "0 | current" pseudo-entry
  representing live state, but that alone isn't enough — the first real
  `update-grub` against an empty snapshot history prints something like
  "No snapshots found" and writes no config. Taking one real snapshot is
  what triggers the first real generation.

### The `configfile` → `source` detail

GRUB's `/etc/grub.d/41_snapshots-btrfs` script (the one grub-btrfs
installs) uses GRUB's `configfile` directive by default to load the
generated snapshot menu as a sub-configuration. `configfile` runs that
sub-config in an **isolated environment** — critically, `grub-reboot`'s
`next_entry` mechanism (see the [GRUB internals](grub.md) page) can't
address entries loaded that way; a scripted one-shot boot into a specific
snapshot silently falls through to entry 0 instead. Manual menu selection
at the boot screen still works either way. Patching that one line to use
`source` instead of `configfile` loads the same entries into the *main*
config's environment, making them addressable by `grub-reboot` — needed for
any automated "boot this snapshot once" workflow.

## Why the boot entries need to be self-contained

This is the structural point that matters most: **a grub-btrfs entry is
only trustworthy if the kernel, initrd, and userland it boots all come from
the same snapshot.**

If `/boot` is a separate, non-snapshotted filesystem (a common default
layout — a distinct `/boot` partition, or a separate btrfs subvolume
excluded from the root subvolume's snapshots), then every snapshot's `/boot`
directory, as far as grub-btrfs's kernel-detection code can see, is
**empty** — there is no kernel *inside* the snapshot to find. The tool's own
fallback logic in that situation (its "separate boot partition" code path)
degrades to emitting one menu entry per snapshot that all boot the
**currently installed** kernel — whatever that happens to be at
config-generation time — against the **reverted** (older) userland from
inside the snapshot. That combination is often unbootable outright (the
current kernel's modules don't match the reverted `/lib/modules`), and even
when it happens to boot, it silently defeats the entire purpose: the
snapshot you picked was supposed to represent a specific point in time, and
you're not actually booting that point in time.

The fix is structural, not a grub-btrfs setting: fold `/boot` into the
*same* subvolume that gets snapshotted (see the [openSUSE-style
subvolume layout](btrfs.md) convention), so each snapshot carries its own
complete `/boot`. Concretely verified, contrasting the two states:

**Separate `/boot`** (broken): every snapshot's entry boots the live
kernel off the separate, un-snapshotted `/boot`, regardless of which
snapshot was selected.

**`/boot` folded into the snapshotted subvolume** (correct): each
snapshot's entry pulls kernel, initrd, and root from *inside that same
snapshot*:

```
menuentry '  vmlinuz-6.8.0-117-generic & initrd.img-6.8.0-117-generic' … {
    search --no-floppy --fs-uuid  --set=root <btrfs-filesystem-UUID>
    linux "/@/.snapshots/1/snapshot/boot/vmlinuz-6.8.0-117-generic" root=<root-device> … rw rootflags=defaults,subvol="@/.snapshots/1/snapshot"
    initrd "/@/.snapshots/1/snapshot/boot/initrd.img-6.8.0-117-generic"
}
```

Kernel, initrd, and the `rootflags=...,subvol=` root selection all point at
the *same* snapshot path — booting this entry gets you the kernel, modules,
and userland exactly as they were when the snapshot was taken, as one
consistent unit. This is what "version-matched" boot entries means in
practice, and it's the thing worth checking for on any grub-btrfs setup
before trusting it as a real rollback path — inspect a generated entry and
confirm the kernel/initrd paths actually live under the snapshot's own
path, not a shared `/boot`.

## Booting a raw snapshot entry vs. actually rolling back

Booting a grub-btrfs entry directly boots the snapshot subvolume **as-is**
— which, for a tool like snapper, is normally a read-only btrfs subvolume.
The root filesystem mounts, but write attempts to `/`, `/etc`, `/usr` fail
(the subvolume's read-only property blocks them even though the mount
itself is nominally read-write) — fine for inspecting logs, config, or a
package database, not for running real workloads. Getting a genuinely
writable, "actually reverted" system is a separate operation — the
snapshot tool's own rollback command (e.g. snapper's `rollback`, see the
[snapper](snapper.md) page) makes a writable *copy* of the snapshot and
switches the default boot target to that copy, rather than booting the
read-only snapshot subvolume directly.

## Further reading

- [grub-btrfs](https://github.com/Antynea/grub-btrfs) — the project itself:
  README, installation instructions, and configuration options
  (`/etc/default/grub-btrfs/config`).
