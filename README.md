# Book of Snapper

A field guide to OS-level rollback on Linux: snapper, btrfs, LVM, GRUB,
initramfs, kexec, and how they fit together to make a package upgrade
(or a full release upgrade) safely reversible without a reinstall. Written
up from a real proof-of-concept; contains no employer- or vendor-specific
detail — hostnames, internal IPs, and internal tool names are scrubbed.

## Layout

- `concepts/` — what each piece is and how it works on its own (snapper,
  btrfs, LVM, GRUB internals, grub-btrfs, initramfs/kexec, dropbear-initramfs,
  the openSUSE subvolume layout convention, the Ubuntu-vs-openSUSE packaging
  gap).
- `how-to/` — end-to-end procedures that combine several concepts (live
  ext4→btrfs conversion, arming snapper as an apt hook, relocating the GRUB
  environment block, a full cross-version upgrade with a rollback net).
- `reference/` — decision guides and scope notes (e.g. when *not* to rely on
  OS-level rollback).

Every page ends with a "Further reading" section linking real upstream
documentation for the tool(s) it covers.

## License

[CC-BY-4.0](LICENSE).
