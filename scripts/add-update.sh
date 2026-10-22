#!/usr/bin/env bash
# Adds a built version to the update directory that scripts/serve-updates.sh serves (and CI will publish):
# openhu-os_<version>.root.raw.gz (root partition), openhu-os_<version>.efi (unified kernel image), SHA256SUMS.
# For a Raspberry Pi build (scripts/build.sh --arch arm64, #39): openhu-os-rpi_<version>.root.raw.gz and
# openhu-os-rpi_<version>.boot.raw.gz (boot partition). Both images of a version can share one directory.
#
#   scripts/add-update.sh [VERSION] [DIR]      default: the newest build, mkosi.output/updates
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
DIR="${2:-$REPO/mkosi.output/updates}"
OUT="$REPO/mkosi.output"

if [ -z "$VERSION" ]; then
  newest="$(ls -t "$OUT"/openhu-os_*.efi "$OUT"/openhu-os-rpi_*.boot.raw 2>/dev/null | head -1)"
  [ -n "$newest" ] || { echo "no build in mkosi.output, run scripts/build.sh" >&2; exit 1; }
  VERSION="$(basename "$newest")"; VERSION="${VERSION#*_}"; VERSION="${VERSION%.efi}"; VERSION="${VERSION%.boot.raw}"
fi

mkdir -p "$DIR"
gz=gzip; command -v pigz >/dev/null && gz=pigz
compress() {  # the partitions are mostly zeros after their file system: they compress to about their content
  "$gz" -1 -c "$1" > "$2.part"
  mv "$2.part" "$2"
}
found=0
if [ -f "$OUT/openhu-os_$VERSION.root.raw" ] && [ -f "$OUT/openhu-os_$VERSION.efi" ]; then
  compress "$OUT/openhu-os_$VERSION.root.raw" "$DIR/openhu-os_$VERSION.root.raw.gz"
  cp "$OUT/openhu-os_$VERSION.efi" "$DIR/openhu-os_$VERSION.efi"
  found=1
fi
if [ -f "$OUT/openhu-os-rpi_$VERSION.root.raw" ] && [ -f "$OUT/openhu-os-rpi_$VERSION.boot.raw" ]; then
  compress "$OUT/openhu-os-rpi_$VERSION.root.raw" "$DIR/openhu-os-rpi_$VERSION.root.raw.gz"
  compress "$OUT/openhu-os-rpi_$VERSION.boot.raw" "$DIR/openhu-os-rpi_$VERSION.boot.raw.gz"
  found=1
fi
[ "$found" = 1 ] || { echo "no build of $VERSION in mkosi.output (.root.raw with .efi or .boot.raw)" >&2; exit 1; }
(cd "$DIR" && sha256sum $(ls openhu-os_*.root.raw.gz openhu-os_*.efi openhu-os-rpi_*.root.raw.gz \
                              openhu-os-rpi_*.boot.raw.gz 2>/dev/null) > SHA256SUMS)
ls -lh "$DIR"
