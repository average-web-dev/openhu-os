#!/usr/bin/env bash
# Release files of a build in mkosi.output (scripts/build.sh --profile release): the disk image to flash, the update
# for "openhu-cli update" (root partition, unified kernel image or the Pi's boot partition), the package manifest and
# SHA256SUMS over all of them. Takes the x86 image (openhu-os_<version>) and the Raspberry Pi image
# (openhu-os-rpi_<version>, #39) of the version, whichever is there; SHA256SUMS covers every release file of the
# version in DIR, so the files of both builds can be put together in one directory.
#
#   scripts/release.sh VERSION [DIR]      default dist/
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$1"
DIR="${2:-$REPO/dist}"
OUT="$REPO/mkosi.output"

images=()
for name in openhu-os openhu-os-rpi; do
  [ -f "$OUT/${name}_$VERSION.raw" ] && images+=("$name")
done
[ ${#images[@]} -gt 0 ] || { echo "no image of $VERSION in mkosi.output, run scripts/build.sh --profile release --version $VERSION" >&2; exit 1; }

mkdir -p "$DIR"
"$REPO/scripts/add-update.sh" "$VERSION" "$DIR" >/dev/null
for name in "${images[@]}"; do
  # 3.6 GB, mostly empty: grows to the whole SD card/disk on the first boot
  xz -T0 -6 -c "$OUT/${name}_$VERSION.raw" > "$DIR/${name}_$VERSION.raw.xz.part"
  mv "$DIR/${name}_$VERSION.raw.xz.part" "$DIR/${name}_$VERSION.raw.xz"
  cp "$OUT/${name}_$VERSION.manifest" "$DIR/${name}_$VERSION.manifest.json"
done
(cd "$DIR" && sha256sum $(ls "openhu-os_$VERSION".* "openhu-os-rpi_$VERSION".* 2>/dev/null) > SHA256SUMS)
ls -lh "$DIR"
