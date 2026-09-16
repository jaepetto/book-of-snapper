# How-to: arm snapper + grub-btrfs on a rollback-ready btrfs root

This procedure picks up where [live ext4→btrfs
conversion](live-btrfs-conversion.md) leaves off: a btrfs root with the
correct subvolume layout and an un-pinned GRUB config, but no `snapper`
installed yet and no boot-menu integration. By the end of this page, the
system is actually **rollback-armed** — proven with a real drill, not just
configured.

## 1. Install and configure snapper

```
apt-get install -y snapper
snapper -c root create-config /
```

Two things worth checking right after `create-config`, both covered on the
[subvolume layout](../concepts/subvolume-layout.md) page — this is the
verification step for that layout surviving into the running system:

```
# the GRUB-modules subvolume must still be a subvolume, not absorbed back
# into @ — otherwise a future rollback would revert GRUB's own modules
btrfs subvolume show /boot/grub/<platform>

# the kernel must be reachable inside @/boot (the fold from the
# conversion how-to)
ls /boot/vmlinuz-*
```

`create-config` creates the `@/.snapshots` subvolume but — on Ubuntu,
unlike openSUSE's own tooling — does **not** add an `/etc/fstab` entry for
it. Without one, booting into a snapshot (which is what [`snapper
rollback`](../concepts/snapper.md) does) leaves `/.snapshots` inside that
snapshot pointing at an empty directory, and snapper loses its own history
right when a rollback has just happened. Pin it explicitly:

```
BUUID=$(findmnt -no UUID /)
printf 'UUID=%s  /.snapshots  btrfs  defaults,subvol=@/.snapshots  0  0\n' "$BUUID" >> /etc/fstab
systemctl daemon-reload
mount /.snapshots
```

Confirm the config and the mount:

```
snapper -c root list
snapper list-configs
findmnt /.snapshots
```

If this whole sequence needs to run automatically right after the
conversion how-to's reboot (rather than by hand) — a reasonable choice,
since installing a package needs a working network the conversion's
initramfs phase doesn't have — a `Type=oneshot` systemd unit gated on
`ConditionPathExists=!/etc/snapper/configs/root` and
`After=network-online.target` that removes itself once done is a clean,
idempotent way to do it (see the [initramfs and
kexec](../concepts/initramfs-kexec.md) page's note on keeping
network-dependent work out of the initramfs phase itself).

## 2. Install grub-btrfs

`grub-btrfs` isn't distro-packaged on Ubuntu — build it from source:

```
apt-get install -y git make inotify-tools
git clone https://github.com/Antynea/grub-btrfs /path/to/grub-btrfs
cd /path/to/grub-btrfs && git checkout v4.14   # check the project's
                                                # releases page for the
                                                # current tag; v4.14 was
                                                # current at time of writing
make install GRUB_UPDATE_EXCLUDE=true
```

`GRUB_UPDATE_EXCLUDE=true` keeps the install step from silently running a
full config regeneration as a side effect — regenerate deliberately once
everything else below is in place.

Two edits, per the [grub-btrfs](../concepts/grub-btrfs.md) page:

- `/etc/grub.d/41_snapshots-btrfs`: change `configfile` to `source` (needed
  for a scripted one-shot boot into a specific snapshot to be addressable
  at all — manual menu selection works either way, but don't skip this if
  any automation will ever target a snapshot entry).
- `/etc/default/grub-btrfs/config`:
  ```
  GRUB_BTRFS_LIMIT="20"
  GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="rw"
  GRUB_BTRFS_SHOW_SNAPSHOTS_FOUND="true"
  ```

Enable the regeneration daemon and confirm it's pointed at the right path:

```
systemctl cat grub-btrfsd | grep ExecStart   # expect --syslog /.snapshots
systemctl enable --now grub-btrfsd
```

Regenerate once:

```
update-grub
```

Don't be surprised if this first run reports something like "No snapshots
found" — grub-btrfs has nothing to generate entries for until at least one
real snapshot subvolume exists (the drill below creates one).

## 3. Prove it: a same-version rollback drill

This is the acceptance test for everything above — not optional polish.

```
snapper -c root create -t single -d "baseline" -c number -p
# note the returned snapshot number as N_base

apt-get install -y hello   # any small, harmless, easily-verified package
# note the pre/post snapshot numbers from:
snapper -c root list
snapper -c root status <N_pre>..<N_post>   # confirm it captured the change
```

Roll back to before the test package was installed:

```
snapper --ambit classic rollback <N_pre>
systemctl reboot
```

(The explicit `--ambit classic` is normally only needed for the *first*
rollback on a plain-GRUB system — see the [snapper](../concepts/snapper.md)
page on ambits. `rollback` itself takes no `-p` flag.)

After the reboot, verify the rollback actually took effect:

```
findmnt -no SOURCE,OPTIONS /   # now on the rollback (read-write copy) subvolume
dpkg -l hello                  # reverted — package no longer installed
apt-get check
dpkg --audit
systemctl --failed             # expect 0 failed units
```

To return to the original subvolume:

```
btrfs subvolume set-default <original-@-subvolume-id> /
update-grub
systemctl reboot
```

One behavior worth knowing before it surprises anyone: `snapper rollback`
never touches the original subvolume it rolled back *from* — only the new
target it created. So once back on the original subvolume, the test
package is back too (it was never actually removed from that subvolume,
only from the rollback copy). Purge it there if it was only ever meant as
a throwaway test:

```
apt-get purge -y hello
```

## What this proves — and what it doesn't yet

This drill proves **same-version** rollback: undoing a bad patch within
the same OS release. It says nothing about surviving a full release
upgrade (`do-release-upgrade`) — that has its own extra requirements and
gotchas, covered separately.

## Further reading

- [snapper](../concepts/snapper.md)
- [grub-btrfs](../concepts/grub-btrfs.md)
