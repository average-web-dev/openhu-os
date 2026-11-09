#!/usr/bin/env bash
# Builds the OpenHU OS image with mkosi in a Debian trixie container. The image lands in mkosi.output/.
#
#   scripts/build.sh [--profile dev|release] [--version VERSION] [--arch x86-64|arm64] [extra mkosi arguments]
#
# x86-64 (default): PC/VM image openhu-os_<version>.raw. arm64: Raspberry Pi 4/5 image openhu-os-rpi_<version>.raw
# (#39); on an x86 host this needs qemu-user for arm64 registered with binfmt (scripts/arm64-binfmt.sh).
# Needs the openhu and libaasdk packages of that architecture in packages/ (scripts/fetch-debs.sh, ARCH=arm64). The
# package cache and the incremental base image live in the Docker volume openhu-os-cache (openhu-os-cache-arm64).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="openhu-os-builder:trixie"
PROFILE="dev"
# dots only: "_", "-" and "+" have a meaning in the update and boot counting file names
VERSION="${OPENHU_OS_VERSION:-$(date -u +%Y.%m.%d.%H%M)}"
ARCH="x86-64"
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

case "$ARCH" in
  x86-64) DEB_ARCH=amd64; NAME=openhu-os; CACHE=openhu-os-cache ;;
  arm64) DEB_ARCH=arm64; NAME=openhu-os-rpi; CACHE=openhu-os-cache-arm64 ;;
  *) echo "--arch: x86-64 or arm64" >&2; exit 1 ;;
esac

cd "$REPO"
if ! ls packages/openhu_*_"$DEB_ARCH".deb packages/libaasdk_*_"$DEB_ARCH".deb >/dev/null 2>&1; then
  echo "packages/ needs openhu_*_$DEB_ARCH.deb and libaasdk_*_$DEB_ARCH.deb: run ARCH=$DEB_ARCH scripts/fetch-debs.sh first" >&2
  exit 1
fi
if [ "$ARCH" = arm64 ] && [ "$(uname -m)" != aarch64 ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  echo "arm64 image on $(uname -m): run scripts/arm64-binfmt.sh first (qemu-user for arm64 programs)" >&2
  exit 1
fi

# Builder image, rebuilt when its Dockerfile changes
hash="$(sha256sum docker/builder.Dockerfile | cut -c1-16)"
if [ "$(docker image inspect -f '{{index .Config.Labels "openhu-os.hash"}}' "$IMAGE" 2>/dev/null)" != "$hash" ]; then
  docker build --label openhu-os.hash="$hash" -t "$IMAGE" -f docker/builder.Dockerfile docker
fi

# Boot splash (Plymouth theme in splash/) as a package next to openhu and libaasdk: it is needed in the initrd too
stage="$(mktemp -d)"
splash_version="$(git log -1 --format=%cd --date=format:%Y.%m.%d.%H%M -- splash 2>/dev/null)"
[ -n "$splash_version" ] || splash_version="$(date -u +%Y.%m.%d.%H%M)"
install -Dm644 -t "$stage/usr/share/plymouth/themes/openhu" splash/theme/*
install -Dm755 splash/postinst "$stage/DEBIAN/postinst"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: openhu-os-splash
Version: $splash_version
Architecture: all
Maintainer: Leon Strauß <openhu.dev@alias.strauss-hub.de>
Depends: plymouth
Section: misc
Priority: optional
Description: OpenHU boot splash
 Plymouth theme: the OpenHU logo until OpenHU shows its first frame.
CONTROL
rm -f packages/openhu-os-splash_*.deb
dpkg-deb --root-owner-group -Zxz -b "$stage" packages/ >/dev/null
rm -rf "$stage"

# ssh key of the dev VM (scripts/ssh.sh), generated once, only for root login in dev images
mkdir -p local/dev-extra/root/.ssh
[ -f local/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "openhu-os dev VM" -f local/id_ed25519
cp local/id_ed25519.pub local/dev-extra/root/.ssh/authorized_keys
chmod 700 local/dev-extra/root/.ssh
chmod 600 local/dev-extra/root/.ssh/authorized_keys

tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-it)
echo "Building $NAME $VERSION (profile $PROFILE, $ARCH)"
# mkosi needs mount namespaces and its own /proc in the container. On the Pi mkosi only makes the directory tree,
# rpi/assemble.sh makes the disk from it (as root: the tree's files belong to root).
docker run --rm "${tty[@]}" --privileged \
  -v "$REPO:/src" -w /src \
  -v "$CACHE:/cache" \
  "$IMAGE" bash -euo pipefail -c '
    mkosi --architecture="$4" --profile="$1" --image-version="$2" \
          --cache-directory=/cache/incremental --package-cache-directory=/cache/packages \
          --workspace-directory=/cache/workspace "${@:6}" -f build
    if [ "$4" = arm64 ]; then
      rpi/assemble.sh "mkosi.output/$5_$2" "$1" "mkosi.output/$5_$2.raw"
      rm -rf "mkosi.output/$5_$2"
    fi
    chown -R "$3" mkosi.output' _ "$PROFILE" "$VERSION" "$(id -u):$(id -g)" "$ARCH" "$NAME" "${EXTRA[@]}"

ls -lh mkosi.output/"$NAME"_"$VERSION"*.raw
