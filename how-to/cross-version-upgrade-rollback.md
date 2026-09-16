# How-to: cross-version upgrade with a rollback net

This is the capstone procedure: running a full release upgrade
(`do-release-upgrade`, e.g. one LTS to the next) under a manual snapshot
bracket, and having a real, tested path back if the new release turns out
broken. It draws on nearly everything else in this book.

**Prerequisites**: [live btrfs conversion](live-btrfs-conversion.md) (a
rollback-ready layout), [arm snapper + grub-btrfs](arm-snapper-rollback.md)
(snapper and grub-btrfs installed and same-version-tested), and ideally
[relocate the GRUB environment block to the ESP](relocate-grubenv-to-esp.md).
Without the last one, rollback still works — just with a more manual
sequence, covered at the end of this page instead of as the primary path.

## 1. Check the upgrade path is actually offered

```
do-release-upgrade -c
```

`do-release-upgrade` doesn't always offer the very next release by
default. If the target isn't offered, `-d` may unlock it — check per-hop,
don't assume it's always needed or never needed.

## 2. Pre-sweep pending updates

```
apt-get update
apt-get -y --allow-downgrades -o Dpkg::Options::=--force-confold dist-upgrade
```

The non-interactive release-upgrade frontend doesn't do this sweep
itself, and a pending update queue left in place going into a release
upgrade can complicate an already complex transaction. Do it first, as
its own step.

## 3. Bracket the upgrade manually

```
snapper -c root create -t pre -c number -p -d "pre do-release-upgrade"
```

Record the returned snapshot number. Don't rely on the automatic
`80snapper` pre/post pairs the upgrade will fire on its own — a release
upgrade runs through several distinct dpkg passes, and none of the
automatic pairs brackets the whole thing (see the
[apt/do-release-upgrade integration](../concepts/apt-upgrade-integration.md)
page). That page also covers why `do-release-upgrade`'s own built-in
btrfs safety net (`apt-btrfs-snapshot`) is silently off on a
correctly-configured rollback layout — this manual bracket is the *only*
net, not a backup to one that already exists.

## 4. Run the upgrade inside `tmux` or `screen`

```
tmux new-session -d -s upg "export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; \
  do-release-upgrade -f DistUpgradeViewNonInteractive \
  > /var/log/release-upgrade.log 2>&1; \
  echo EXIT=\$? >> /var/log/release-upgrade.log; \
  touch /var/tmp/upgrade.done"
```

(Add `-d` before `-f` if step 1 required it.)

Running this as a plain, bare SSH command doesn't work reliably — the
non-interactive upgrader frontend refuses to run at all without a TTY
present. `tmux`/`screen` gives it one, and detaches cleanly so the upgrade
survives an SSH disconnection.

Poll for completion (a release upgrade commonly takes 20–60 minutes):

```
test -f /var/tmp/upgrade.done && tail -40 /var/log/release-upgrade.log
```

Periodically tail the log while waiting, not just at the end — the
non-interactive frontend can, rarely, still stall waiting on input despite
its name. If the log goes idle for more than roughly 15 minutes at what
looks like a prompt, stop and inspect rather than assuming it's just slow.

## 5. Watch for the conffile-stall failure mode

Even with `--force-confold` set, a specific conffile (a well-known
troublemaker is `cloud.cfg`) can still trigger an interactive prompt the
non-interactive frontend doesn't fully suppress, wedging the whole
transaction. If the log goes idle at exactly this kind of point, attach to
the session (`tmux attach -t upg` or `screen -r`) and answer the prompt
directly — this is a live-recovery situation, not something a flag alone
reliably prevents. Treat "the preventive flag didn't work this time" as
expected, not a sign something is fundamentally broken.

## 6. Post-upgrade housekeeping

A `grub2-common` version bump during the release upgrade ships a new
packaged `10_linux` to the diversion target set up during the [live btrfs
conversion](live-btrfs-conversion.md) how-to — the *active*, de-pinned
`/etc/grub.d/10_linux` is now stale, derived from the pre-upgrade version.
Regenerate it from the new original (see the [GRUB
internals](../concepts/grub.md) page for the general `dpkg-divert`
pattern this follows):

```
diff -u /etc/grub.d/10_linux /usr/share/<project>/10_linux.orig
sed 's|rootflags=subvol=${rootsubvol} ||' /usr/share/<project>/10_linux.orig > /etc/grub.d/10_linux
chmod 0755 /etc/grub.d/10_linux
```

Re-run the GRUB install for the new GRUB version:

```
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=<id> --recheck
update-grub
```

Confirm the `41_snapshots-btrfs` `configfile`→`source` edit (see the
[grub-btrfs](../concepts/grub-btrfs.md) page) survived — it isn't
dpkg-managed, so it should be untouched, but a `grub-btrfs` reinstall
happening as a side effect of the upgrade could have reverted it. Reapply
if needed.

## 7. Close the bracket, verify

```
snapper -c root create -t post --pre-number <N_pre> -c number -d "post do-release-upgrade"
```

Verify the upgrade landed clean before moving on: OS version, kernel
version, `apt-get check`, `dpkg --audit`, no unexpected failed units, and
`grub-btrfsd` still active.

## 8. If something's wrong — roll back (primary path, needs the ESP fix)

```
snapper --ambit classic rollback <N_pre>
```

Run this directly from the still-live, already-upgraded system — record
the new read-write snapshot number it creates. `grub-btrfsd` will already
have auto-regenerated its per-snapshot config via inotify by the time this
command returns; no manual `update-grub` needed for that part.

Find that new snapshot's grub-btrfs entry and extract its exact
`>`-delimited submenu title **programmatically** (parsing the generated
config file), not by hand — these titles are whitespace-sensitive, and a
hand-typed title silently fails to match rather than erroring clearly.

```
poc-grub-reboot '<extracted title>'
grub-editenv <ESP-grubenv-path> list   # confirm next_entry is set
systemctl reboot
```

After reboot, verify **with no manual GRUB surgery anywhere in this
sequence** — that's the actual bar to clear, not just "it looks like it
worked":

```
findmnt /                # shows the rollback snapshot's subvolume
uname -r                 # shows the pre-upgrade kernel
apt-get check; dpkg --audit
systemctl --failed       # at baseline
grub-editenv <ESP-grubenv-path> list   # next_entry has self-cleared
```

## 9. If the ESP fix isn't in place yet — the more manual fallback

Without a relocated `grubenv`, `grub-reboot`'s one-shot mechanism doesn't
reliably clear on LVM-backed storage (see [relocate the GRUB environment
block](relocate-grubenv-to-esp.md)), so the sequence above isn't available
as cleanly. A more cautious approach that's been proven to work: boot into
the pre-upgrade snapshot's own raw grub-btrfs entry *first* (a one-shot
`grub-reboot` targeting that exact submenu title, via the console if
needed), and only **then**, from within that already-booted (read-only,
degraded) tree, run `snapper --ambit classic rollback <N_pre>` — followed
by regenerating GRUB (`update-grub` and `grub-install`) from that same
booted context before rebooting into the properly rolled-back system.

Worth being honest about this: the reasoning for needing this extra care
in some drills and not others isn't fully pinned down here — it may relate
to how large a GRUB version jump the upgrade itself caused, or to
differences in the two example runs this page draws from. If in doubt,
prefer this more cautious sequence — booting into the target snapshot's
own tree before regenerating anything is the more conservative choice
either way.

## 10. Return to the upgraded state

If the rollback was just a drill (proving the path works, not responding
to a real incident):

```
btrfs subvolume set-default <original-@-subvolume-id> /
update-grub
systemctl reboot
```

Confirm `findmnt /` shows the original subvolume again. As with
same-version rollback, `snapper rollback` never touched the original
subvolume it rolled back from — anything installed there before the
rollback is still there.

## Further reading

- [apt/do-release-upgrade integration](../concepts/apt-upgrade-integration.md)
- [snapper](../concepts/snapper.md)
- [grub-btrfs](../concepts/grub-btrfs.md)
- [GRUB internals](../concepts/grub.md)
- [Arm snapper + grub-btrfs](arm-snapper-rollback.md)
- [Relocate the GRUB environment block to the ESP](relocate-grubenv-to-esp.md)
