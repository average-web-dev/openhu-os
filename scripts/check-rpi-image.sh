#!/usr/bin/env bash
# Checks a Raspberry Pi image (scripts/build.sh --arch arm64, #39) without a Pi: the partition table (FAT partitions
# first, as the firmware counts them), autoboot.txt, the boot partition's files and command line, 512-byte FAT
# sectors, and the root partition's os-release and tryboot helper. Runs the tools in the builder container. CI runs it
# for every Pi image; booting it needs a real Pi (QEMU does not run the Pi firmware).
#
#   scripts/check-rpi-image.sh mkosi.output/openhu-os-rpi_<version>.raw
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
image="$(realpath "$1")"
name="$(basename "$image" .raw)"
version="${name#openhu-os-rpi_}"
[ "$name" != "$version" ] || { echo "not a Raspberry Pi image: $image" >&2; exit 1; }

docker run --rm -v "$(dirname "$image"):/out:ro" -v "$REPO/rpi:/rpi:ro" openhu-os-builder:trixie \
    bash -euo pipefail -c '
  image="/out/$1"; version="$2"
  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok() { echo "ok: $*"; }
  table="$(sfdisk --json "$image")"
  field() { python3 -c "import json, sys; p = json.loads(sys.argv[1])[\"partitiontable\"][\"partitions\"]; print(p[int(sys.argv[2])].get(sys.argv[3], \"\"))" "$table" "$@"; }
  count="$(python3 -c "import json, sys; print(len(json.loads(sys.argv[1])[\"partitiontable\"][\"partitions\"]))" "$table")"
  [ "$count" = 4 ] || fail "$count partitions, expected 4 (autoboot, boot A, boot B, root A)"
  esp=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  root=B921B045-1DF0-41C3-AF44-4C6F280D3FAE
  expect() {  # index type label
    [ "$(field "$1" type)" = "$2" ] || fail "partition $(($1 + 1)): type $(field "$1" type), expected $2"
    [ "$(field "$1" name)" = "$3" ] || fail "partition $(($1 + 1)): label \"$(field "$1" name)\", expected \"$3\""
  }
  expect 0 $esp openhu-autoboot
  expect 1 $esp "openhu-boot_$version"
  expect 2 $esp _empty
  expect 3 $root "openhu_$version"
  ok "partitions: autoboot, boot A, boot B (empty), root A (arm64)"
  offset() { echo $(( $(field "$1" start) * 512 )); }

  for i in 0 1 2; do
    sector="$(minfo -i "$image@@$(offset $i)" :: | sed -n "s/^sector size: \([0-9]*\) bytes/\1/p")"
    [ "$sector" = 512 ] || fail "partition $((i + 1)): FAT with $sector-byte sectors, the firmware reads 512 only"
  done
  ok "FAT with 512-byte sectors"

  [ "$(mtype -i "$image@@$(offset 0)" ::/autoboot.txt)" = "$(cat /rpi/autoboot.txt)" ] || fail "autoboot.txt differs from rpi/autoboot.txt"
  ok "autoboot.txt: $(mtype -i "$image@@$(offset 0)" ::/autoboot.txt | tr "\n" " ")"

  boot="$image@@$(offset 1)"
  for f in start4.elf fixup4.dat config.txt cmdline.txt kernel8.img kernel_2712.img initramfs8 initramfs_2712 \
           bcm2711-rpi-4-b.dtb bcm2712-rpi-5-b.dtb overlays/vc4-kms-v3d.dtbo; do
    mdir -b -i "$boot" "::/$f" >/dev/null 2>&1 || fail "boot partition: $f missing"
  done
  ok "boot partition: firmware, both kernels and initrds, device trees, overlays"
  cmdline="$(mtype -i "$boot" ::/cmdline.txt)"
  case " $cmdline " in *" root=PARTLABEL=openhu_$version "*) ;; *) fail "cmdline.txt: no root=PARTLABEL=openhu_$version";; esac
  case " $cmdline " in *" rootfstype=erofs "*) ;; *) fail "cmdline.txt: no rootfstype=erofs";; esac
  ok "cmdline.txt: root=PARTLABEL=openhu_$version"

  rootfs() { dump.erofs --offset="$(offset 3)" --path="$1" "${@:2}" "$image"; }
  release="$(rootfs /usr/lib/os-release --cat)"
  for line in IMAGE_ID=\"openhu-os\" "IMAGE_VERSION=\"$version\"" VARIANT_ID=rpi; do
    grep -qx "$line" <<<"$release" || fail "os-release: no $line"
  done
  ok "os-release: IMAGE_ID=openhu-os, VARIANT_ID=rpi, IMAGE_VERSION=$version"
  for f in /usr/libexec/openhu-os/tryboot /usr/lib/systemd/system/openhu-tryboot-check.service \
           /usr/lib/systemd/system/bluetooth.service.d/openhu-os.conf /usr/libexec/openhu/openhu; do
    rootfs "$f" >/dev/null 2>&1 || fail "root partition: $f missing"
  done
  [ "$(rootfs /usr/lib/modules --ls | grep -c "+rpt-rpi-")" = 2 ] || fail "root partition: expected the modules of two Pi kernels"
  ok "root partition: tryboot helper and check, bluetoothd drop-in, OpenHU, modules of both kernels"
' _ "$(basename "$image")" "$version"
