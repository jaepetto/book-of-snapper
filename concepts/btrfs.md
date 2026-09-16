# btrfs

Btrfs ("B-tree filesystem") is a copy-on-write (CoW) filesystem for Linux.
Copy-on-write means a write never overwrites data in place: it writes the
new version to a fresh block and updates metadata to point at it, leaving
the old block untouched until nothing references it anymore. That single
property is what makes cheap snapshots possible — snapshotting a CoW
filesystem is just "keep pointing at the old blocks too," not "copy
everything."

## Subvolumes

A btrfs subvolume is an independent file/directory hierarchy inside one
filesystem. It behaves like its own filesystem tree (it can be mounted on
its own, given its own default, listed independently) while still sharing
the same underlying block allocation and CoW machinery as every other
subvolume on the same btrfs filesystem. A fresh btrfs filesystem always has
one implicit top-level subvolume (ID 5); everything else — including any
subvolume layout a distro's installer creates — lives inside that.

Subvolumes matter for snapshot design because they define the *boundary* of
a snapshot: `btrfs subvolume snapshot` snapshots one subvolume, not the
whole filesystem. A layout that splits, say, the OS root from user home
directories into separate subvolumes lets you snapshot (and roll back) one
without touching the other.

## Snapshots

A btrfs snapshot is a subvolume created with the current content of another
subvolume — at the instant it's taken, a snapshot and its source subvolume
share every extent. It costs essentially nothing in space or time at
creation; space is only consumed later, incrementally, as the two diverge
(the source keeps being written to, and each CoW write to a shared block
allocates a new block instead of touching the shared one). A snapshot can be
read-only or read-write; read-only is the usual choice for a rollback point,
since nothing should be able to modify history after the fact.

Because a snapshot is CoW, "rolling back" is conceptually just "make the
snapshot the thing that's live instead of the subvolume it diverged from" —
no data is copied, no time proportional to disk size is spent. The
mechanics of *how* a rollback tool actually switches which subvolume is
live (bind-mount tricks, default-subvolume changes, boot-loader-level
selection) vary by tool.

## Converting an existing filesystem to btrfs

`btrfs-convert` converts an ext2/3/4 (or reiserfs, or NTFS via an external
tool) filesystem to btrfs **in place** — no reformat, no full copy. The
original filesystem's metadata and data become one subvolume inside the new
btrfs filesystem (conventionally named `ext2_saved`), so the conversion
itself is reversible: as long as nothing has run a `btrfs balance` yet, the
tool can convert back. Running a balance afterward reclaims that space but
also permanently forecloses the rollback path.

### Gotcha: the `orphan_file` feature must be cleared first

On e2fsprogs ≥ 1.47 (where `mkfs.ext4` enables the `orphan_file` feature by
default), `btrfs-convert` will refuse to proceed against a source
filesystem that still has it set. Clear it before converting, on the
unmounted, freshly-`fsck`ed filesystem:

```
tune2fs -O ^orphan_file /dev/<the-device>
```

This was hit converting a stock, recently-installed Ubuntu root filesystem
(ext4, `e2fsprogs` mkfs ≥ 1.47.0) — the feature is on by default on any
similarly recent ext4 filesystem, not something unusual about that one
install.

## Further reading

- [Official btrfs documentation](https://btrfs.readthedocs.io/en/latest/) —
  filesystem overview, feature list, subvolume/snapshot administration.
- [`btrfs-subvolume(8)`](https://man7.org/linux/man-pages/man8/btrfs-subvolume.8.html)
  — subvolume and snapshot creation, listing, defaults, read-only vs.
  read-write.
- [`btrfs-convert(8)`](https://man7.org/linux/man-pages/man8/btrfs-convert.8.html)
  — in-place ext2/3/4→btrfs conversion, rollback subvolume, the `btrfs
  balance` point of no return.
