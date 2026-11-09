#!/usr/bin/env bash
# Raspberry Pi image from mkosi's directory tree (#39), run by scripts/build.sh in the builder container as root:
# the boot partition (firmware, both kernels with their initrds, device trees, config.txt, cmdline.txt) and
# autoboot.txt, then the GPT disk with systemd-repart (rpi/repart) and its split partitions for updates
# (<output without .raw>.root.raw, .boot.raw).
#
#   rpi/assemble.sh TREE PROFILE OUTPUT      e.g. mkosi.output/openhu-os-rpi_V dev mkosi.output/openhu-os-rpi_V.raw
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tree="$1"
profile="$2"
output="$3"

stage="$tree/boot/rpi"
rm -rf "$stage"
mkdir -p "$stage/boot/overlays" "$stage/autoboot"
boot="$stage/boot"

# mkosi's boot entries (Bootloader=none), one per kernel: /boot/loader/entries/<token>-<kver>.conf names the kernel,
# the initrds (the shared one and the kernel's modules) and the command line, all paths relative to /boot
cmdline=""
kernels=0
for entry in "$tree"/boot/loader/entries/*.conf; do
  kver="$(sed -n 's/^version //p' "$entry")"
  case "$kver" in
    *-rpi-v8) suffix=8; dtbs=bcm2711 ;;     # Pi 4, 400, CM4
    *-rpi-2712) suffix=_2712; dtbs=bcm2712 ;; # Pi 5, 500, CM5
    *) echo "assemble: unknown kernel $kver" >&2; exit 1 ;;
  esac
  cp "$tree/boot$(sed -n 's/^linux //p' "$entry")" "$boot/kernel$suffix.img"
  # concatenated cpio archives: the kernel unpacks them one after the other
  sed -n 's/^initrd //p' "$entry" | while read -r initrd; do cat "$tree/boot$initrd"; done > "$boot/initramfs$suffix"
  cp "$tree/usr/lib/linux-image-$kver/broadcom/$dtbs"*.dtb "$boot/"
  cp -n "$tree/usr/lib/linux-image-$kver/overlays/"* "$boot/overlays/"
  options="$(sed -n 's/^options //p' "$entry")"
  [ -z "$cmdline" ] || [ "$cmdline" = "$options" ] || { echo "assemble: different command lines" >&2; exit 1; }
  cmdline="$options"
  kernels=$((kernels + 1))
done
[ "$kernels" = 2 ] || { echo "assemble: expected the Pi 4 and the Pi 5 kernel, found $kernels" >&2; exit 1; }

# GPU firmware of the Pi 4 (the Pi 5 has it in its EEPROM)
cp "$tree"/usr/lib/raspi-firmware/{start4.elf,fixup4.dat,LICENCE.broadcom} "$boot/"
cp "$here/config.txt" "$boot/config.txt"
if [ "$profile" = dev ]; then
  # serial console on GPIO 14/15 (the dev profile's console=ttyS0)
  printf '# dev profile: serial console on GPIO 14/15 (console=ttyS0)\nenable_uart=1\n' >> "$boot/config.txt"
fi
echo "$cmdline" > "$boot/cmdline.txt"
cp "$here/autoboot.txt" "$stage/autoboot/autoboot.txt"

rm -f "$output" "${output%.raw}".*.raw
# --architecture: the builder runs on x86, the root partition's type must be the arm64 one. --sector-size=512: the Pi
# bootloader reads FAT with 512-byte sectors only (repart formats an image file with 4096 by default)
systemd-repart --empty=create --size=auto --dry-run=no --offline=yes --split=yes --architecture=arm64 --sector-size=512 \
               --root="$tree" --copy-source="$tree" --definitions="$here/repart" "$output"
