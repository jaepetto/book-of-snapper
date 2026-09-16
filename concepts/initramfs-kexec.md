# initramfs and kexec

Two Linux boot-time mechanisms that, combined, make it possible to get an
offline filesystem-surgery environment on a running machine — no reboot
into rescue media, no console, no firmware changes.

## What an initramfs is

An initramfs (initial RAM filesystem) is a small, temporary root filesystem
loaded into memory alongside the kernel at boot. Its only job is to get far
enough — load whatever storage/filesystem drivers the real root needs, find
it, mount it — that the kernel can hand off execution to normal userspace
on the real root filesystem. It exists because a general-purpose kernel
can't statically compile in every possible storage driver a machine might
boot from; the initramfs carries just the ones this particular machine
needs, decided at image-build time.

Two generators build this image on Linux, and they are **not**
interchangeable at the configuration level — a system runs one or the
other, with its own hook/module format:

- **`initramfs-tools`** — Debian/Ubuntu's default. Hook scripts (under
  `/usr/share/initramfs-tools/hooks` and `/etc/initramfs-tools/hooks`) run
  at image-build time and copy in whatever binaries and kernel modules a
  feature needs; boot scripts run *inside* the built image, before the real
  root is mounted. `mkinitramfs` builds the image.
- **`dracut`** — used by Fedora, RHEL, openSUSE, and some other builds.
  Module-based rather than hook-script-based: functionality is organized
  into dracut modules, added or omitted via configuration.

Installing a package that depends on one generator on a system running the
other can silently swap which one is active — e.g. a package requiring
`initramfs-tools` installed on a `dracut`-based system can pull in
`initramfs-tools` and remove the `dracut` metapackage as a dependency side
effect. The system still boots either way, but this is a decision worth
making deliberately (know which generator is active before you build a
custom image) rather than discovering as a side effect of installing
something unrelated.

### Building a custom initramfs for one specific task

The same tooling used for the normal boot initramfs can build a **separate**
image file for a one-off task, without touching normal boot at all:

```
mkinitramfs -o /var/tmp/custom.img <kernel-version>
```

A hook script under `/etc/initramfs-tools/hooks/<name>` copies in whatever
the task needs (`manual_add_modules <fs-type>` for a filesystem driver,
`copy_exec` for a binary and its shared libraries). A premount script under
`/etc/initramfs-tools/scripts/init-premount/<name>` is where the actual
task logic runs, before the real root would normally be mounted — this is
the hook point that lets an initramfs boot do real work (filesystem
conversion, disk surgery) instead of just chaining to the next stage.

## What kexec is

`kexec` boots a new kernel directly from a currently-running one, skipping
the firmware and boot-loader stages entirely — the new kernel starts
executing with (almost) none of the normal power-on-to-kernel path
repeated. There are two ways to load the image, and the difference matters
a great deal on a Secure Boot system:

- **`kexec -l` / `--load`** — the legacy `KEXEC_LOAD` syscall. No integrity
  checking: anyone with the right capability can stage an arbitrary kernel
  image.
- **`kexec -s` / `--kexec-file-syscall`** — the newer `KEXEC_FILE_LOAD`
  syscall, which enforces signature verification and is, per the manual,
  "required on systems with locked-down secure boot for kernel signature
  verification."

(`kexec -a` / `--kexec-syscall-auto` is the default: try the newer syscall
first, fall back to the legacy one — explicit `-s` is what you want when
you specifically need the signature-checked path.)

### Secure Boot / kernel lockdown interaction

A system with EFI Secure Boot active typically also runs the kernel in
lockdown mode, which restricts a long list of capabilities that could
otherwise be used to tamper with or bypass the running kernel. Per
`kernel_lockdown(7)`:

> "Only validly signed binaries may be kexec'd (waived if the binary image
> file to be executed is vouched for by IMA appraisal)."

The practical consequence: under lockdown, the legacy `kexec -l` path is
blocked outright — no way to load an unsigned kernel (a rescue-ISO kernel,
for instance) that way. But `kexec -s` **is** allowed, for a kernel that
carries a valid signature the running kernel's keyring trusts. A stock
distro kernel — e.g. Ubuntu's own `/boot/vmlinuz-$(uname -r)` — is already
signed by the distro (Canonical, in Ubuntu's case). That means a
locked-down system can still `kexec -s` **its own, already-running
kernel** back into memory, paired with a **different initramfs** of your
choosing.

This is the key insight that makes offline surgery possible without
touching Secure Boot at all: the kernel image is what gets
signature-checked, not the initramfs. The initramfs is the kernel's own
concern to interpret once it's running — it isn't a separately verified
boot artifact the way the kernel itself is. So: reboot the *same* signed
kernel, but hand it a custom initramfs built for the task at hand, and you
get an offline environment with zero MOK, NVRAM, or firmware changes, and
no console interaction needed — everything can be driven over SSH (adding
`dropbear-initramfs` gets you a shell in the initramfs itself over the
network; see the dropbear-initramfs page).

## Putting it together: a worked recipe

```
apt-get install -y dropbear-initramfs          # SSH into the initramfs
# hook:      /etc/initramfs-tools/hooks/<name>
#            -> copy_exec <tools>; copy the task script into the image;
#               manual_add_modules <fs-type>
# premount:  /etc/initramfs-tools/scripts/init-premount/zz-<name>
#            -> runs /script.sh; reboot -f on success; sleep-loop on failure

mkinitramfs -o /var/tmp/custom.img $(uname -r)  # separate file; does NOT
                                                 # touch normal boot

kexec -s -l /boot/vmlinuz-$(uname -r) --initrd=/var/tmp/custom.img \
  --command-line="root=<device> ro ip=<client>::<gateway>:<netmask>:<hostname>::off:<dns> panic=0"

kexec -e                                        # fires the loaded image —
                                                 # NOT `systemctl kexec`
```

The `ip=` parameter is `initramfs-tools`' own `configure_networking`
syntax (`client-ip::gateway-ip:netmask:hostname:device:autoconf:dns0-ip`);
leaving the device field empty lets it autodetect on a single-NIC machine.
`dropbear-initramfs` calls `configure_networking` itself and starts an SSH
daemon using `/etc/dropbear/initramfs/authorized_keys`.

### Gotchas worth knowing before trying this

- **`systemctl kexec` hangs** at "Reached target kexec.target" against a
  `kexec_file_load`-loaded image. Use `kexec -e` directly instead.
- **A hypervisor console may not repaint through a kexec** — the screen can
  freeze on the last frame while the new kernel runs headless-looking.
  Absence of new console output is not evidence the jump failed; check for
  the expected post-jump state some other way (an SSH port coming up, for
  instance).
- **A VM snapshot captures NVRAM, not just the disk.** Reverting a disk
  snapshot can also revert firmware-level state (Secure Boot validation
  state, one-shot boot-order changes) — don't rely on a disk-only snapshot
  to preserve or restore firmware state changes made outside this flow.
- **`set -e` combined with `e2fsck` is a footgun.** `e2fsck` exits 1
  whenever it corrects anything — which it always will after a `kexec -e`
  jump, since that skips a clean shutdown and leaves the filesystem's
  journal dirty. Under `set -e`, a bare `e2fsck -fy "$dev"; c=$?` never
  reaches the second statement — the script aborts on the `e2fsck` line
  itself. Use `e2fsck -fy "$dev" || c=$?` instead.
- **busybox's `mount` needs an explicit `-t <fstype>`** for
  `-o subvolid=`/`-o subvol=`-style options — omitting it produces
  `mount: Invalid argument`. A normal (util-linux) `mount` binary a hook
  copies into the image can be shadowed by busybox's own applet living at
  the same path, so `-t` isn't optional the way it might be outside an
  initramfs.
- **busybox's `ps` silently ignores `-ef`** — `ps -ef | grep <x>` can
  return nothing and look like a process crashed, when really the flag was
  just not honored. Use bare `ps` or `ps aux` inside an initramfs.

### Automating this safely

- A script that runs before `/` is mounted can't be trusted until it has
  been proven to run **autonomously, end to end, at least once** — a list
  of caveats in a comment block is worth nothing if the code doesn't
  actually clear them under real conditions.
- Make each phase resumable against **observable on-disk state** (a
  filesystem-type check, a marker file, whatever's appropriate) rather than
  assuming a clean start every time — turns "it failed halfway" into "fix
  the bug, re-run, it picks up where it left off," with no new `kexec`
  needed.
- If the custom initramfs holds on failure (rather than panicking or
  rebooting), a script bug can often be fixed and re-run directly over the
  same SSH session, without repeating the `kexec` step at all.
- A `preflight | stage | fire | verify` split keeps "build and load the
  image" (`kexec -s -l`, no reboot yet) cleanly separate from "actually
  jump" (`kexec -e`) — useful for staging the risky step and reviewing
  before committing to it.

## Further reading

- [`kexec(8)`](https://man7.org/linux/man-pages/man8/kexec.8.html) — the
  `kexec` command, `-l` vs. `-s` vs. `-a` load-syscall options.
- [`kernel_lockdown(7)`](https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html)
  — what kernel lockdown restricts, including the kexec signature
  requirement quoted above.
- [`initramfs-tools(7)`](https://manpages.debian.org/bookworm/initramfs-tools-core/initramfs-tools.7.en.html)
  — hook and boot script structure, helper functions like
  `manual_add_modules`.
- [`dracut(8)`](https://man7.org/linux/man-pages/man8/dracut.8.html) — the
  other major initramfs generator, module-based configuration.
