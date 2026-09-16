# dropbear-initramfs

[Dropbear](https://matt.ucc.asn.au/dropbear/dropbear.html) is a compact SSH
server and client built for resource-constrained environments — small
footprint, OpenSSH-compatible public-key authentication, no dependency on a
fully-booted system's usual services. Those properties make it the natural
choice for one specific niche: getting an SSH session **into an initramfs**,
before the real root filesystem is even mounted.

`dropbear-initramfs` is the Debian/Ubuntu package that wires Dropbear into
an `initramfs-tools`-built image (see the [initramfs and
kexec](initramfs-kexec.md) page for the generator itself). Once installed,
every initramfs image built afterward carries a Dropbear instance
configured to start early and listen for a connection — turning what would
otherwise be a console-only, pre-boot environment into something reachable
over the network.

## Key location and configuration

- Public keys go in `/etc/dropbear/initramfs/authorized_keys` on current
  Debian/Ubuntu releases (Debian 12+, Ubuntu 22.04+); older releases used
  `/etc/dropbear-initramfs/authorized_keys` — check
  `dpkg -L dropbear-initramfs` on your system if unsure which applies.
- Listening options (e.g. changing the port) go in
  `/etc/dropbear/initramfs/dropbear.conf`, via a `DROPBEAR_OPTIONS`
  variable (`DROPBEAR_OPTIONS="-p 2222"`, for example).
- Networking is brought up via `initramfs-tools`' own network
  configuration mechanism (the `ip=` kernel command-line parameter — see
  the initramfs/kexec page) before Dropbear starts listening; without a
  usable network at that point, nothing will be reachable no matter how
  Dropbear itself is configured.

## The install-order gotcha

Stage the authorized key **before** installing the package:

```
mkdir -p /etc/dropbear/initramfs
install -m 0600 /path/to/authorized_keys /etc/dropbear/initramfs/authorized_keys

apt-get install -y dropbear-initramfs
```

The package's post-install hook rebuilds the initramfs image immediately
(via `update-initramfs`), baking in whatever's currently at that key path.
Installing the package first and adding the key afterward means the very
first build happens with no valid key present — producing a spurious
"Invalid authorized_keys file" warning at build time, and — worse — an
image whose baked-in fail-shell doesn't actually accept your key until a
second rebuild. Getting the order right means the very first image built is
already correct.

## The fail-hold containment pattern

This is the part worth internalizing beyond "install dropbear and you get
SSH": when a custom initramfs premount script does real, potentially
fallible work (filesystem conversion, disk surgery — see the [initramfs
and kexec](initramfs-kexec.md) page), its **failure path** deserves as much
design attention as its success path. A script that panics or silently
reboots on failure turns any bug into a lost, unrecoverable attempt at
best, and a hung or corrupted system at worst.

The pattern that worked well here: declare the custom premount script as
depending on dropbear's own initramfs-tools prerequisite chain (via the
script's `PREREQ` field), so dropbear is guaranteed to have already started
by the time the custom script runs — win or fail. Then, on failure, don't
reboot and don't panic: hold the initramfs indefinitely (a plain
`sleep`-in-a-loop is enough) so the machine stays exactly where it is,
reachable over the SSH session dropbear already opened.

Sketch of the shape:

```sh
#!/bin/sh
# init-premount script
PREREQ="dropbear"
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

/bin/sh /my-task.sh
rc=$?

if [ "$rc" -eq 0 ]; then
    echo "task OK — rebooting in 8s"
    sleep 8
    reboot -f
else
    echo "task FAILED rc=$rc — holding for inspection over SSH"
    while true; do sleep 3600; done
fi
```

### Why this matters in practice

This exact pattern caught a real bug during this project's live
ext4→btrfs conversion work. The conversion script made an incorrect
assumption about a filesystem-check tool's exit code (it treats "corrected
some errors" and "hard failure" the same way by default, when in fact
they're different exit codes and only one is a real problem) — and that
assumption turned out to be wrong on the very first real run, immediately
after the machine had jumped into the custom initramfs via `kexec`.
Because the premount script's `PREREQ` ordering had guaranteed dropbear was
already listening, and its failure branch held the initramfs open instead
of giving up, the operator could SSH straight into the still-running
initramfs, fix the one bad assumption directly in the script, and re-run it
from there — no second `kexec`, no reboot, no restoring a VM snapshot. The
root filesystem was still safely unmounted the whole time, exactly where
the failure had left it.

That's the value of designing the failure path deliberately: a script bug
mid-conversion became a five-minute live fix instead of a lost attempt.

## Treat it as temporary

Once the risky operation it was staged for is done, remove
`dropbear-initramfs` (and any related tools installed only for that window)
rather than leaving it installed indefinitely:

```
apt-get purge -y dropbear-initramfs
```

An `authorized_keys` file baked into every future initramfs image is
standing SSH-into-pre-boot attack surface for as long as the package stays
installed — worth paying only while the operation that needed it is
actually in progress.

## Further reading

- [Dropbear SSH](https://matt.ucc.asn.au/dropbear/dropbear.html) — the
  project itself.
- [Debian Wiki: DropBear](https://wiki.debian.org/DropBear) — practical
  notes on `authorized_keys` locations across releases and
  `dropbear.conf`'s `DROPBEAR_OPTIONS`.
