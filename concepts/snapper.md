# snapper

snapper is a general-purpose snapshot management tool for Linux. It doesn't
implement snapshots itself — it drives an underlying CoW-capable backend
(btrfs, or LVM) to create, list, compare, clean up, and roll back to
snapshots, all through one config-based CLI and D-Bus API.

## Config model

Everything snapper does is scoped to a **config** — a named policy stored at
`/etc/snapper/configs/<name>` (e.g. the usual `root` config for `/`),
created with `snapper -c <name> create-config <path>`. The config records
which filesystem type backs the path and every cleanup/retention setting
below.

`create-config`'s `--fstype` option, per the snapper manual:

> Manually set filesystem type. Supported values are btrfs, ext4
> (discontinued) and lvm. For lvm, snapper uses LVM thin-provisioned
> snapshots. The filesystem type on top of LVM must be provided in
> parentheses, e.g. `lvm(xfs)`. Without this option snapper tries to
> detect the filesystem.

Two things worth being precise about here:

- **Version-sensitive claim.** That "LVM = thin-provisioned snapshots"
  wording is from the current upstream manual. Some real-world hosts run
  older packaged snapper builds whose LVM support predates or diverges from
  that description — check `snapper --version`'s compiled feature flags and
  your own distro's man page before assuming thin-only LVM behavior.
  Example, a snapper 0.10.6 build (Ubuntu universe package):
  ```
  $ snapper --version
  snapper 0.10.6 / libsnapper 7.2.0  flags: btrfs,lvm,no-ext4,xattrs,rollback,btrfs-quota
  ```
  `no-ext4` in the flags corroborates the "ext4 discontinued" note above —
  that's compiled into the binary, not a runtime choice.
- **This page's LVM claims are unverified against real hardware.** Every
  hands-on fact below (rollback mechanics, the apt-hook interaction) was
  confirmed against a real `btrfs`-configured snapper instance. The `lvm`
  fstype is documented here from the manual only — treat it as
  "what the docs say," not "what was proven to work."

## Snapshot types

- **Single** — an ad-hoc, one-off snapshot (`snapper create`).
- **Pre/post** — a matched pair bracketing an operation, typically created
  by a package manager hook around an install/upgrade transaction.
- **Timeline** — created on a schedule (hourly/daily/etc.) by a timer unit,
  independent of any specific operation.

On Debian-family systems, the `snapper` package itself ships an apt hook
(`/etc/apt/apt.conf.d/80snapper`) that creates a pre/post pair around every
`dpkg` transaction automatically — no extra hook needs to be written for
basic pre/post bracketing to work out of the box. (This is worth stating
plainly because it's easy to assume otherwise, by analogy with openSUSE's
separate zypper plugin — worth double-checking against your own package's
contents before assuming either way, rather than trusting a blog post or an
old assumption written before actually checking.)

One quirk to know about with that automatic hook: a **multi-package**
transaction (an unattended-upgrade run, `apt full-upgrade`, a full release
upgrade) can trigger more than one `pre` snapshot per logical transaction —
apt sometimes runs a separate `dpkg` pass for packages with `Pre-Depends`,
and each pass fires the hook's pre-invoke independently. The result is an
orphaned extra `pre` snapshot with no matching `post`. Harmless, but it
means any automated tooling that picks a rollback target should look for a
*known-complete* pre/post pair (matching transaction metadata), never
assume "the two most recent snapshots" form a valid pair.

## Cleanup algorithms

Snapshots accumulate; two independent cleanup algorithms (per config,
enabled separately) cap how many stick around:

- **Number cleanup** (`NUMBER_CLEANUP`) keeps at most `NUMBER_LIMIT`
  (default 50) snapshots tagged for the "number" cleanup — which, by
  default, is *every* plain snapshot including automatic pre/post pairs.
  The oldest are evicted first, silently, by a periodic cleanup service.
- **Important snapshots get a separate budget.** A snapshot with
  `important=yes` in its userdata is counted against
  `NUMBER_LIMIT_IMPORTANT` (default 10) instead — independently from the
  normal budget. `snapper rollback` tags its own auto-created backup
  snapshot this way automatically.
- **A manually-created "permanent" milestone is *not* auto-tagged.** A
  plain `snapper create -d "before the risky change"` competes for the
  same 50-slot budget as routine automatic snapshots and can be reaped with
  no warning, at creation or deletion time. If a snapshot needs to survive
  routine cleanup, tag it explicitly:
  ```
  snapper create -d "<label>" --userdata important=yes
  ```
  That's a smaller, slower-filling budget, not a literal "never delete" —
  for a snapshot that must never be lost, record its number outside
  snapper's own retention system entirely (e.g. in your own change log) and
  verify it periodically.
- **Timeline cleanup** (`TIMELINE_CLEANUP`) works the same way but against
  scheduled snapshots, bucketed by age: `TIMELINE_LIMIT_HOURLY`,
  `_DAILY`, `_WEEKLY`, `_MONTHLY`, `_QUARTERLY`, `_YEARLY` (defaults 10,
  10, 0, 10, 0, 10 respectively).

## Ambits

snapper's `--ambit` option, per the manual: *"Operate in the specified
ambit. Can be used to override the ambit detection. Allowed ambits are
`auto`, `classic` and `transactional`."* An ambit tells snapper which
*style* of system it's rolling back on — a transactional-update /
read-only-root distro needs different rollback machinery than a plain,
directly-writable-root distro.

On a plain-GRUB system (nothing transactional, no read-only root, no
boot-loader-spec entries), ambit auto-detection can fail to recognize the
environment and needs to be told explicitly:

```
snapper --ambit classic rollback <N>
```

Only the *first* `rollback` on such a system typically needs the explicit
flag — once one rollback has run, later invocations detect correctly.

## `rollback` semantics

Per the manual: *"Creates two new snapshots and sets the default
subvolume. Per default the system boots from the default subvolume of the
root filesystem."* Concretely, on a btrfs backend:

- Called with no snapshot number: creates a read-only snapshot of the
  *current* default subvolume (a backup of "now"), then a read-write
  snapshot of the *current* subvolume, and sets that read-write copy as the
  new default.
- Called with a snapshot number `N`: creates a read-only backup of
  *current*, then a read-write snapshot **of snapshot `N`**, and sets that
  as the new default — this is the actual "go back to N" case.
- The command itself takes no `-p` flag (errors: "takes either one or no
  argument").
- On btrfs, none of this needs a reboot to *happen* — the snapshots and the
  default-subvolume flip are live filesystem operations. A reboot is only
  needed afterward, to actually boot into the new default and get the
  reverted userland running. The original subvolume you rolled back *from*
  is never touched or deleted — you simply stay on the new (rolled-back)
  default subvolume going forward, and can flip back to the original by the
  same `set-default` mechanism if needed.
- On an LVM-backed config, the manual describes the same two-snapshot
  concept, but making the resulting state live is necessarily an offline
  operation — the running system's block device can't be atomically
  swapped for a different LV out from under itself the way a subvolume
  default can be flipped live. (Not exercised firsthand for this page —
  see the LVM caveat above.)

## Further reading

- [snapper](https://github.com/openSUSE/snapper) — upstream project;
  `doc/snapper.xml.in` and `doc/snapper-configs.xml.in` are the docbook
  sources for the `snapper(8)` and `snapper-configs(5)` man pages quoted
  above. `man snapper` / `man snapper-configs` on an installed system is
  the more readable form of the same content.
- [openSUSE Snapper Tutorial](https://en.opensuse.org/openSUSE:Snapper_Tutorial)
  — openSUSE's own walkthrough, from the distro that originated the tool.
