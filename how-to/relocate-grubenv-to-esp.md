# How-to: relocate the GRUB environment block to the ESP

The [GRUB internals](../concepts/grub.md) page explains why
`grub-reboot`'s one-shot boot selection silently stops working when
`grubenv` lives on LVM-backed storage: GRUB's own manual restricts that
storage to a plain disk, no LVM or RAID. This page is the concrete fix —
relocating the environment block onto the EFI System Partition (ESP), a
plain vfat partition every UEFI system already has — with the exact patch
and, critically, the verification that actually proves it worked.

## 1. Confirm the restriction actually applies

Before changing anything, check whether the problem is real on this
system:

```
grub-reboot <some-menu-entry>
grub-editenv list
reboot
```

After reboot, check `grub-editenv list` again. If `next_entry` is still
set to what you chose (rather than cleared), the one-shot mechanism is
stuck — this fix applies. If it cleared correctly, this system's `grubenv`
is already on writable storage and none of the below is needed.

## 2. Create a real grubenv on the ESP

```
grub-editenv /boot/efi/EFI/<id>/grubenv create
```

(`<id>` is whatever directory your GRUB install already uses on the ESP —
commonly the distro name, e.g. `ubuntu`.)

## 3. Divert and patch `/etc/grub.d/00_header`

Same pattern as any other GRUB script edit meant to survive a package
upgrade (see the [GRUB internals](../concepts/grub.md) page for why
`dpkg-divert` beats a plain `sed` edit here):

```
mkdir -p /usr/share/<project>
dpkg-divert --local --divert /usr/share/<project>/00_header.orig --rename --add /etc/grub.d/00_header
```

The stock `00_header` reads the environment block unconditionally from
the main GRUB prefix (which, on LVM-backed storage, is exactly the
unwritable device), with a separate conditional block attempting a
relocation. Both need replacing — patching only one half reproduces the
identical "stuck forever" bug against a different file. Replace this:

```diff
-if [ -s $prefix/grubenv ]; then
+search --no-floppy --fs-uuid --set=esp_root <ESP-UUID>
+set env_block="(${esp_root})/EFI/<id>/grubenv"
+export env_block
+if [ -s "${env_block}" ]; then
   set have_grubenv=true
-  load_env
-fi
-
-if [ "${env_block}" ] ; then
-  set env_block="(${root})${env_block}"
-  export env_block
   load_env -f "${env_block}"
 fi
```

`<ESP-UUID>` is the ESP's own filesystem UUID (`blkid` the ESP partition to
find it). Leave everything else in the file untouched — the `save_env -f
"${env_block}" ...` calls further down the stock template already
reference the `env_block` variable this patch sets, so only the read path
at the top needs changing.

Apply the patch to the diverted-from copy and install it:

```
# edit /usr/share/<project>/00_header.orig with the change above,
# writing the result to /etc/grub.d/00_header
chmod 0755 /etc/grub.d/00_header
```

## 4. Regenerate and verify the patch landed

```
update-grub
grep -A3 'esp_root' /boot/grub/grub.cfg
```

Confirm the generated config actually carries the `search`/`set
env_block`/`load_env -f` block from the patch, not the original.

## 5. Replace the one-shot tool

Stock `grub-reboot`/`grub-set-default` have no option to target a
non-default `grubenv` path — they always write to the main prefix's
location, which is exactly the file this fix moved away from. Use a direct
`grub-editenv` call against the ESP file instead:

```sh
#!/bin/sh
set -e
ESP_GRUBENV=/boot/efi/EFI/<id>/grubenv
[ -n "$1" ] || { echo "usage: $0 MENU_ENTRY_ID" >&2; exit 1; }
exec grub-editenv "$ESP_GRUBENV" set next_entry="$1"
```

`MENU_ENTRY_ID` is whatever GRUB expects for `next_entry` — a numeric
index, or a `>`-delimited title path for a submenu entry (match the title
text verbatim, including any leading/trailing spaces the menu generator
produces).

## 6. Verify with a real three-cycle reboot test

This is the actual acceptance criterion — a config that merely looks
right is not proof it works. Confirm:

1. Set a one-shot target (entry A), reboot, confirm the system actually
   booted entry A, and that `next_entry` in the ESP's `grubenv` cleared
   itself immediately — GRUB should have consumed and reset it on its own,
   with no manual cleanup.
2. Repeat with a different target (entry B) — confirm it booted B and
   cleared again.
3. Reboot a third time with **nothing** set — confirm it falls back to
   the real default entry, not stuck on whatever B was. This step is what
   actually proves the fix works: it's easy to accidentally build a patch
   that boots the one-shot target correctly but never truly returns to
   "no override," which defeats the purpose.

If `next_entry` doesn't clear after step 1, or step 3 doesn't fall back to
the real default, the most common cause is the read path and the write
path disagreeing on which file they're using — double-check that the
patch in step 3 above replaced *both* halves of the original block, and
that the wrapper script in step 5 points at the exact same ESP path the
patched `00_header` searches for.

## A note on porting this patch

This exact patch is tied to the specific `00_header` your GRUB package
ships — different GRUB versions structure that script differently around
this block. Don't copy a patched `00_header` from one system onto another
running a different GRUB version; instead, diff the patch above against
*that* system's own original `00_header` and reapply it there.

## Further reading

- [GRUB internals](../concepts/grub.md) — the LVM/RAID storage
  restriction this fix works around, cited directly from the GRUB manual.
