# Subvolume layout: designing the rollback boundary

A btrfs subvolume boundary is a rollback boundary. Everything living
inside the subvolume that gets rolled back (typically the root subvolume)
reverts together, as one atomic unit; anything excluded onto its own
sibling subvolume does not revert at all when its parent does. Getting
[snapper rollback](snapper.md) to do something *useful* — not just
something that technically works — is mostly a question of designing that
boundary deliberately, directory by directory.

The convention that answers this well originates with openSUSE (the distro
that built snapper in the first place) and is worth adopting largely
as-is, even on a distro that didn't ship it by default.

## The general principle

Ask, for each top-level directory: **should this revert together with the
OS packages a rollback is undoing, or not?**

- Package binaries and the package manager's own database should revert
  *together* — reverting one without the other leaves a package database
  claiming versions that aren't actually installed, or vice versa.
- Logs that would explain *why* a rollback was needed should **not**
  revert — you need them intact precisely when things went wrong, which is
  exactly when a rollback happens.
- Large, easily-regenerated caches don't need version history at all —
  keeping them out of every snapshot saves real space with zero downside.
- User data and anything another system depends on staying
  monotonically forward (see the eligibility discussion below) generally
  shouldn't be tied to the OS's own rollback boundary either.

## The layout

- **`@`** — the root subvolume, and critically, the btrfs **default**
  subvolume. Nothing anywhere in the system should hard-code `subvol=@` by
  name (not in `/etc/fstab`, not in a GRUB config generator) — a rollback
  works by flipping *which subvolume is the default*, not by touching `@`
  itself. Anything that pins a mount to the literal name `@` defeats that
  mechanism regardless of how correct the rest of the layout is. (See the
  [GRUB internals](grub.md) page for the matching fstab/GRUB-conffile
  changes this requires.)
- **`@home`** — a sibling of `@`, holding user data. Not something a
  package-upgrade rollback needs to touch, so it's kept out of the
  rollback boundary entirely as a matter of principle, even where nothing
  technically forces the separation.
- **`.snapshots`, nested *inside* `@`** (as `@/.snapshots`, not a
  top-level sibling) — this placement matters specifically because of how
  `rollback` works: it flips the default-subvolume pointer, it never
  deletes or destroys `@` itself. Nesting `.snapshots` inside `@` means
  every rollback target still has an intact snapshot history to look at
  afterward. (A top-level `@snapshots` subvolume is only needed for a
  manual, `mv`-based rollback scheme, which isn't what `snapper rollback`
  does.) One fstab detail this placement needs to get right: a snapshot
  excludes any nested subvolume by definition, so booting into a snapshot
  makes the `.snapshots` path *inside* it appear as an empty directory —
  an explicit fstab entry pinning `.snapshots` to `@/.snapshots` (which
  `snapper create-config` doesn't add automatically on every distro) keeps
  the history reachable regardless of which snapshot is currently live.
- **Split `/var` children, each on their own subvolume**: `/var/log`,
  `/var/cache`, `/var/tmp`, `/var/crash`, `/var/spool`. Logs survive a
  rollback so you can see what went wrong; caches, temp files, and crash
  dumps have no reason to carry version history at all.
- **Split top-level extras**: `/srv` (served data), `/opt` (third-party
  software, often managed outside the distro's own package manager),
  `/root` (the admin's home directory — arguably user data, kept separate
  the same way `/home` is), `/usr/local` (locally-installed software,
  outside the package manager's purview).
- **Everything else stays in `@`**, most importantly **`/var/lib`** — this
  is where a package manager's own state database lives (e.g. dpkg's on
  Debian-family systems). Keeping it inside the rollback boundary is
  deliberate: package state has to revert *consistently* with the binaries
  a rollback is undoing, or the two disagree about what's actually
  installed. `/var/backups`, `/etc`, and `/usr` stay in `@` for the same
  reason — configuration and installed software are exactly what a
  rollback is supposed to be reverting.

## Why the split alone doesn't fix rollback

Getting the subvolume split right is necessary but not sufficient. A
well-known Ubuntu bug illustrates why: Ubuntu's installer puts the fstab
entry for the root filesystem's mount as `subvol=@` explicitly. That
single line overrides btrfs's own default-subvolume mechanism —
`rollback`'s `set-default` call still runs and appears to succeed, but the
system keeps booting the literal subvolume named `@` regardless, because
the fstab pin says so. No amount of subvolume splitting fixes that; the
fstab (and the matching GRUB config generator pin — see the [GRUB
internals](grub.md) page) has to stop pinning the mount to a literal name
before "default subvolume" means anything a rollback can act on.

## The same logic, one level up: when rollback shouldn't happen at all

The inside-vs-outside-the-boundary question doesn't stop at individual
directories — it scales up to whole host classes.

A layout that keeps `/var/lib` inside the rollback boundary (the common
and, per above, *correct* choice for consistent package state) has a
consequence worth being deliberate about: any service whose data directory
happens to live under `/var/lib/<service>` — etcd, most database engines,
kubelet, container runtimes — sits inside that same boundary. A rollback
doesn't skip service data; it reverts it right along with the OS packages
that manage it.

For a stateless service, or one whose config genuinely should track the OS
packages, that's exactly the desired behavior. For anything holding state
another system depends on staying monotonically forward, it's actively
dangerous:

- **A Raft-based store (etcd and similar)**: each member's write-ahead log
  carries a term/index its peers use to determine who's ahead or behind.
  Rolling one member's filesystem back resurrects it with a stale but
  internally *consistent* log — unlike a crash, there's no corruption or
  gap for the rest of the cluster to detect. The member just quietly
  claims to be at an earlier point in history than it actually reached.
- **A database primary**: reverting its data directory reverts
  transactions already acknowledged to clients and, in a replicated setup,
  already shipped to replicas. The replicas end up *ahead* of a
  "resurrected" primary — the same failure shape as restoring a stale
  backup onto a live primary without pausing replication first.
- **A Kubernetes node**: the local state a node's components track (pod
  assignments, network allocations, volume mounts, image cache) describes
  its current contract with the rest of the cluster. Reverting it while
  the cluster has moved forward produces a node that comes back claiming
  resources it no longer holds — a desync the node has no way to detect on
  its own.

This is worth stating precisely because it's easy to draw the wrong
conclusion from it: the failure mode has nothing to do with *which*
mechanism performs the revert. A VM-level snapshot revert has the
identical problem — it's exactly the same kind of local, offline,
no-peer-awareness disk-state revert as a filesystem-level rollback.
"Switching from filesystem snapshots to VM snapshots" fixes nothing; the
real, orthogonal question is **eligibility**, not mechanism — does this
host hold state that another system depends on staying monotonic? A host
that fails that test doesn't become safe to roll back by changing which
tool performs the revert. The actual recovery path for these host classes
is a completely different strategy: a Raft store's own
snapshot/restore-and-rejoin procedure, database replica promotion or
point-in-time recovery, or replacing a Kubernetes node outright — never an
OS-level filesystem or VM-snapshot revert of a live member.

One untested but plausible mitigation, worth flagging as an open
possibility rather than a proven fix: excluding a specific service's data
directory (`/var/lib/<service>`) onto its own subvolume — the same pattern
already used for `/var/log` — could in principle let a rollback revert the
surrounding OS packages without touching that service's data at all. Not
verified here; it would depend heavily on whether the service in question
actually tolerates its binaries and configuration reverting out from under
a data directory that didn't.

## Further reading

- [Launchpad bug #1734496](https://bugs.launchpad.net/ubuntu/+source/snapper/+bug/1734496)
  — the concrete Ubuntu bug this convention exists to work around: the
  default `subvol=@` fstab pin defeating `snapper rollback`'s reliance on
  the btrfs default-subvolume mechanism.
- [openSUSE: SDB:BTRFS](https://en.opensuse.org/SDB:BTRFS) — openSUSE's
  own subvolume-layout documentation, the origin of this convention.
- [Arch Wiki: Snapper](https://wiki.archlinux.org/title/Snapper) —
  independent write-up of the same btrfs/snapper layout pattern.
