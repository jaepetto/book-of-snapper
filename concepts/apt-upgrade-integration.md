# apt / do-release-upgrade integration: what Ubuntu's own tooling does and doesn't cover

The [snapper](snapper.md) page already covers that Ubuntu's `snapper`
package ships its own apt hook (`80snapper`) out of the box — no custom
pre/post plumbing needs to be written for ordinary package installs. This
page covers what's specific to a **release upgrade**
(`do-release-upgrade`) rather than an ordinary `apt install`, and one
finding worth knowing before trusting it as a safety net: the layout that
makes [`snapper rollback` actually work](subvolume-layout.md) is exactly
what silently disables Ubuntu's *own*, built-in upgrade safety net.

## Why a single automatic pre/post pair isn't enough for a release upgrade

`do-release-upgrade` doesn't run as one atomic `apt` transaction — it
proceeds through several distinct dpkg passes (handling prerequisites,
then the main distribution upgrade, then removing obsolete packages).
Each of those passes invokes dpkg through apt independently, and
`80snapper`'s `DPkg::Pre-Invoke`/`Post-Invoke` hook fires on **every one**
of them. The practical result is several separate automatic pre/post
snapshot pairs over the course of one logical upgrade, none of which
brackets the *whole* thing.

Conclusion: for a release upgrade specifically, create the rollback
bracket manually, around the entire `do-release-upgrade` invocation:

```
snapper create -t pre  -d "before do-release-upgrade"
do-release-upgrade ...
snapper create -t post -d "after do-release-upgrade"
```

That manually-created pair — not any of the automatic ones fired mid-run —
is the one to use as the actual rollback target if something needs
reverting afterward.

## The bigger finding: `do-release-upgrade`'s own safety net can be silently off

`do-release-upgrade` doesn't rely solely on external tools for rollback
safety — it ships integration with its own built-in pre-upgrade btrfs
snapshot mechanism, via the
[`apt-btrfs-snapshot`](https://github.com/skorokithakis/apt-btrfs-snapshot)
package. When active, it takes a snapshot before the upgrade begins,
tagged something like `@apt-snapshot-release-upgrade-<release>-<timestamp>`.

That mechanism is gated on a support check before it does anything. The
project's own source makes the exact condition explicit:

```python
entry.mountpoint == "/" and entry.fstype == "btrfs" and "subvol=@" in entry.options
```

In plain terms: it looks for a **literal `subvol=@` string** in the root
filesystem's `/etc/fstab` entry. Not "is btrfs's default-subvolume
mechanism in use" — a specific, hard-coded fstab option string.

This is where the two halves of a well-configured snapper/btrfs setup
collide. The [subvolume layout](subvolume-layout.md) page explains why the
correct fstab entry for a rollback-capable system has **no** `subvol=`
option at all — the whole point is following the btrfs *default*
subvolume, which is exactly what `snapper rollback` flips. That's the
right choice, and it's necessary for `snapper rollback` to function. But
it also means the check above evaluates false, silently, with no warning
at upgrade time — `apt-btrfs-snapshot`'s own snapshot step gets skipped
entirely.

The practical consequence: **never assume `do-release-upgrade` has a
working snapshot safety net just because the system runs btrfs.** On a
properly-configured snapper/btrfs system, it typically won't — check
explicitly (`dpkg -l apt-btrfs-snapshot`, or just don't rely on the
built-in mechanism at all) and treat the manual `snapper` pre/post bracket
above as the *only* net, not a belt-and-suspenders extra. A related
upstream bug report documents further rough edges in this same built-in
mechanism even when it does activate — a leftover snapshot consuming disk
space with no clear notification or command-line opt-out — reinforcing
that the manual bracket is the more predictable path either way.

## Operational note: mask autonomous upgrades during the operation

`unattended-upgrades` and the `apt-daily*` systemd timers can fire package
installs in the background on their own schedule. During a deliberate,
high-stakes operation — a manual upgrade-and-rollback drill, or any window
where you're specifically controlling what apt does and when — mask them
first and restore them afterward:

```
systemctl mask --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service

# ... perform the deliberate operation ...

systemctl unmask unattended-upgrades apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service
systemctl enable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
```

A background upgrade firing mid-operation is exactly the kind of
interference a manual snapshot bracket can't protect against — the
snapshot only knows about the transaction it was placed around.

## Further reading

- [apt-btrfs-snapshot](https://github.com/skorokithakis/apt-btrfs-snapshot)
  — the project itself; source for the `subvol=@` gating condition quoted
  above.
- [Launchpad bug #1723285](https://bugs.launchpad.net/ubuntu/+source/update-manager/+bug/1723285)
  — a related, confirmed bug documenting further rough edges in
  `do-release-upgrade`'s built-in btrfs snapshot handling (a leftover
  snapshot consuming disk space, no notification, no opt-out flag).
