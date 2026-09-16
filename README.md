# Book of Snapper

## Foreword

This proof of concept and its documentation were generated entirely with
[Claude Code](https://claude.com/claude-code). It may contain errors —
the same caveat that applies to any resource you'd find freely on the web.

I had three goals going into this:

- A real operational need: validate whether `snapper` on Ubuntu could
  serve as a rollback net ahead of a major OS upgrade campaign.
- Test how much an AI coding agent could actually carry a proof of
  concept like this — not just write code, but drive real infrastructure
  work end to end.
- Produce enough documentation along the way that my colleagues, and the
  wider community, could benefit from it too.

I'm genuinely happy with how it turned out. Claude saved me days of work
on this.

A field guide to OS-level rollback on Linux: snapper, btrfs, LVM, GRUB,
initramfs, kexec, and how they fit together to make a package upgrade
(or a full release upgrade) safely reversible without a reinstall. Written
up from a real proof-of-concept; contains no employer- or vendor-specific
detail — hostnames, internal IPs, and internal tool names are scrubbed.

## The problem

A stock Ubuntu install typically ships an ext4 root filesystem on a thick
LVM logical volume with the volume group fully allocated. None of that
supports the copy-on-write snapshots that make rollback cheap: no free
volume-group extents for an LVM snapshot volume, and no btrfs subvolumes
to snapshot in the first place. Getting real rollback means changing the
storage layer itself — see [btrfs](concepts/btrfs.md) and
[LVM](concepts/lvm.md) — and then making sure the layout, the boot loader,
and the snapshot tool all agree on what "rollback" actually reverts.

## The building blocks

- [btrfs](concepts/btrfs.md) — the copy-on-write filesystem this book
  builds on; subvolumes, snapshots, converting an existing ext4 filesystem
  in place.
- [LVM](concepts/lvm.md) — the layer underneath, and why a fully-allocated
  thick logical volume blocks CoW snapshots outright.
- [snapper](concepts/snapper.md) — the tool driving it all: config model,
  snapshot types, cleanup/retention, ambits, and what `rollback` actually
  does.
- [GRUB internals](concepts/grub.md) — how the boot config is generated,
  the environment block behind one-shot boot selection, and why that
  block breaks on LVM-backed storage.
- [grub-btrfs](concepts/grub-btrfs.md) — turning snapshots into bootable
  GRUB menu entries, and why those entries must be self-contained to mean
  anything.
- [initramfs and kexec](concepts/initramfs-kexec.md) — the mechanism that
  makes *live*, offline filesystem surgery possible at all, with no
  reboot into rescue media.
- [dropbear-initramfs](concepts/dropbear-initramfs.md) — SSH access into
  that offline environment, and a fail-hold pattern that turns a scripting
  bug into a five-minute live fix instead of a lost attempt.
- [Subvolume layout](concepts/subvolume-layout.md) — the design decision
  underneath everything else: what has to revert together with a rollback,
  what must not, and why that same logic rules certain hosts (etcd
  members, database primaries, Kubernetes nodes) out of OS-level rollback
  entirely.
- [apt/do-release-upgrade integration](concepts/apt-upgrade-integration.md)
  — where Ubuntu's own upgrade tooling helps, and the one place its
  built-in safety net silently disables itself on the layout this book
  recommends.

## The two assembled flows

1. **Get a system rollback-armed.**
   [Live ext4→btrfs conversion](how-to/live-btrfs-conversion.md) converts
   a running system's root filesystem with no reboot into rescue media,
   ending with the correct, rollback-ready subvolume layout. [Arm snapper
   + grub-btrfs](how-to/arm-snapper-rollback.md) installs and configures
   the tools on top of that layout and proves same-version rollback with a
   real drill. [Relocate the GRUB environment block to the
   ESP](how-to/relocate-grubenv-to-esp.md) fixes one-shot boot selection
   on LVM-backed storage — not required for rollback to work, but it's
   what turns rollback into a single scripted reboot instead of console
   surgery.
2. **Survive a full release upgrade.**
   [Cross-version upgrade with a rollback net](how-to/cross-version-upgrade-rollback.md)
   builds on flow 1 — it assumes a system that's already rollback-armed —
   and walks through a full `do-release-upgrade` under a manual snapshot
   bracket, plus the actual rollback procedure if the new release turns
   out broken.

## When not to use any of this

Not every host is a good candidate for OS-level rollback, regardless of
mechanism. See [when not to use OS-level
rollback](reference/when-not-to-use-os-level-rollback.md) before applying
any of the above to a host holding cluster or replication state another
system depends on.

## Recommended reading order

1. [btrfs](concepts/btrfs.md)
2. [LVM](concepts/lvm.md)
3. [snapper](concepts/snapper.md)
4. [GRUB internals](concepts/grub.md)
5. [grub-btrfs](concepts/grub-btrfs.md)
6. [initramfs and kexec](concepts/initramfs-kexec.md)
7. [dropbear-initramfs](concepts/dropbear-initramfs.md)
8. [Subvolume layout](concepts/subvolume-layout.md)
9. [apt/do-release-upgrade integration](concepts/apt-upgrade-integration.md)
10. [How-to: live ext4→btrfs conversion](how-to/live-btrfs-conversion.md)
11. [How-to: arm snapper + grub-btrfs](how-to/arm-snapper-rollback.md)
12. [How-to: relocate the GRUB environment block to the ESP](how-to/relocate-grubenv-to-esp.md)
13. [How-to: cross-version upgrade with a rollback net](how-to/cross-version-upgrade-rollback.md)
14. [Reference: when not to use OS-level rollback](reference/when-not-to-use-os-level-rollback.md)

Every page ends with a "Further reading" section linking real upstream
documentation for the tool(s) it covers.

## License

[CC-BY-4.0](LICENSE).
