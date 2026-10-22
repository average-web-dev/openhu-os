#!/usr/bin/env bash
# Lets an x86 host run arm64 programs, which mkosi needs for the Raspberry Pi image (scripts/build.sh --arch arm64):
# registers Debian trixie's qemu-aarch64 (qemu-user) with the kernel's binfmt_misc. Nothing is installed on the host:
# the "F" flag makes the kernel keep the interpreter it opened from the container. Lasts until the next reboot.
#
#   scripts/arm64-binfmt.sh            register (if not yet there)
#   scripts/arm64-binfmt.sh --remove   unregister
set -euo pipefail

entry=/proc/sys/fs/binfmt_misc/qemu-aarch64
if [ "${1:-}" = --remove ]; then
  [ -e "$entry" ] || { echo "qemu-aarch64 is not registered"; exit 0; }
  docker run --rm --privileged debian:trixie-slim sh -c "echo -1 > $entry"
  echo "qemu-aarch64 unregistered"
  exit 0
fi
if [ -e "$entry" ]; then
  echo "qemu-aarch64 is already registered:"
  cat "$entry"
  exit 0
fi

# Debian's own entry (qemu-user-binfmt: /usr/lib/binfmt.d/qemu-aarch64.conf), flags OPF; qemu-aarch64 is static
docker run --rm --privileged debian:trixie-slim sh -euc '
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends qemu-user qemu-user-binfmt >/dev/null
  [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
  grep -v "^#" /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register'
cat "$entry"
