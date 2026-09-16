# LVM

LVM (Logical Volume Manager) is a layer of storage virtualization between
raw block devices and filesystems on Linux. It exists so that "how big is
this filesystem, and on which physical disk does it live" doesn't have to
be decided once, permanently, at partition time.

## PV → VG → LV

Three layers, bottom to top:

- **Physical Volume (PV)** — a raw block device or partition, initialized
  for LVM use (`pvcreate`). It contributes its space to a volume group.
- **Volume Group (VG)** — a pool of storage made up of one or more PVs
  (`vgcreate`). Space in a VG is allocated in fixed-size chunks called
  extents.
- **Logical Volume (LV)** — a virtual block device carved out of a VG's
  free extents (`lvcreate`). An LV is what actually gets formatted with a
  filesystem and mounted — from the filesystem's point of view it's just a
  block device, indistinguishable from a plain partition.

This indirection is what lets you resize, move, or snapshot a "partition"
without touching physical partition tables.

## Thick vs. thin provisioning

- A **thick** LV pre-allocates its entire declared size from the VG at
  creation time. If you create a 20 GB thick LV, 20 GB of VG extents are
  reserved for it immediately, used or not.
- A **thin** LV is carved out of a **thin pool** (itself a special LV) and
  only consumes real space as data is actually written to it. Multiple thin
  LVs can share one pool and collectively over-provision it — convenient,
  but it means the pool itself must be monitored so it can't silently fill
  up under all its thin LVs at once.

### Why this matters for CoW-style snapshots

An LVM snapshot (the LVM-level kind, distinct from a filesystem-level CoW
snapshot like a btrfs snapshot) needs somewhere to store the blocks that
change after the snapshot is taken:

- On a **thin pool**, a snapshot is just another thin LV sharing the same
  pool — cheap, and it grows only as the original and the snapshot diverge.
- On a **thick** LV, taking a snapshot means creating a *separate*,
  fixed-size thick snapshot LV to hold the copy-on-write deltas. Two
  consequences follow directly from that: (1) the VG needs enough **free
  (unallocated) extents** to create that snapshot LV in the first place,
  and (2) the snapshot has a hard size cap — if the original diverges more
  than the snapshot LV's capacity, the snapshot is invalidated (not
  silently extended).

### A layout where neither option works

A VG with a single thick LV consuming 100% of its space has **zero free
extents** (`vgs` reports `VFree 0`) — there is no room to create a thick
snapshot LV, and the pool that a thin snapshot would need doesn't exist
either. Concretely, this is what a stock Ubuntu Server install's default
partitioning looked like on inspection:

```
$ vgs
  VG        #PV #LV #SN Attr   VSize   VFree
  ubuntu-vg   1   1   0 wz--n- <36.95g    0

$ lvs
  LV        VG        Attr       LSize   Pool Origin Data% ...
  ubuntu-lv ubuntu-vg -wi-ao---- <36.95g
```

`-wi-ao----` (no `Pool`/`Origin` populated) confirms `ubuntu-lv` is a plain
thick LV, and `VFree 0` confirms the VG has nothing left to allocate a
snapshot volume from. Neither an LVM thick snapshot nor a thin-pool
conversion is possible without first reclaiming space — e.g. shrinking the
filesystem and the LV to free VG extents, which is itself a live,
mounted-root-filesystem resize and worth treating as a deliberate,
confirmed operation rather than a routine step.

## Further reading

- [`lvm(8)`](https://man7.org/linux/man-pages/man8/lvm.8.html) — the LVM
  command-line tools, PV/VG/LV concepts, command reference.
- [Red Hat Enterprise Linux 9: Configuring and managing logical volumes](https://docs.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index)
  — practical walkthroughs of both thick and thin logical volume creation,
  snapshots, and resizing.
