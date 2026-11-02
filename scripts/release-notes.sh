#!/usr/bin/env bash
# Release notes of an OpenHU OS release in Markdown on stdout: what changed since the previous release
# (OpenHU, libaasdk, merged pull requests, Debian packages), then installation and update.
#
#   scripts/release-notes.sh VERSION [PREVIOUS_TAG]
#
# Needs mkosi.output/openhu-os_VERSION.manifest (scripts/build.sh) and gh (GH_TOKEN in CI).
# PREVIOUS_TAG defaults to the newest release before vVERSION; its manifest is downloaded from GitHub.
# packages.source (scripts/fetch-debs.sh) names the OpenHU commit the packages were built from.
set -euo pipefail

VERSION="${1:?usage: $0 VERSION [PREVIOUS_TAG]}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OS_REPO=average-web-dev/openhu-os
MANIFEST="$REPO/mkosi.output/openhu-os_$VERSION.manifest"
[ -f "$MANIFEST" ] || { echo "$MANIFEST missing: build the release first" >&2; exit 1; }

PREVIOUS="${2:-$(gh release list -R "$OS_REPO" --exclude-drafts --limit 50 --json tagName -q '.[].tagName' |
                 grep -vx "v$VERSION" | head -1 || true)}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PREVIOUS_MANIFEST=""
PREVIOUS_DATE=""
if [ -n "$PREVIOUS" ]; then
  gh release download "$PREVIOUS" -R "$OS_REPO" -p 'openhu-os_*.manifest.json' -D "$tmp" >/dev/null 2>&1 &&
    PREVIOUS_MANIFEST="$(ls "$tmp"/*.manifest.json | head -1)"
  PREVIOUS_DATE="$(gh release view "$PREVIOUS" -R "$OS_REPO" --json publishedAt -q .publishedAt)"
fi

OPENHU_COMMIT=""
[ -f "$REPO/packages.source" ] && OPENHU_COMMIT="$(sed -n 's/^OPENHU_COMMIT=//p' "$REPO/packages.source")"

# merged pull requests of a repository since the previous release (titles with links)
merged_prs() {
  [ -n "$PREVIOUS_DATE" ] || return 0
  gh pr list -R "$1" --state merged --limit 100 --search "merged:>$PREVIOUS_DATE" \
      --json number,title,url -q '.[] | "- \(.title) ([#\(.number)](\(.url)))"' 2>/dev/null |
    grep -viE '^- (version [0-9]|aasdk [0-9.]+: depend)' || true
}

python3 - "$MANIFEST" "$PREVIOUS_MANIFEST" "$PREVIOUS" "$VERSION" "$OPENHU_COMMIT" > "$tmp/packages.md" <<'EOF'
import json, sys

current_file, previous_file, previous_tag, version, openhu_commit = sys.argv[1:6]

def packages(path):
    if not path:
        return {}
    return {p["name"]: p["version"] for p in json.load(open(path))["packages"]}

def upstream(version):
    # 2026.10.13-1+deb13u1 -> 2026.10.13, 1.4.0-1+deb13u1 -> 1.4.0
    return version.split("-")[0]

current, previous = packages(current_file), packages(previous_file)

lines = []
openhu = current.get("openhu")
if openhu:
    old = previous.get("openhu")
    text = f"**OpenHU** {upstream(openhu)}"
    if old and upstream(old) != upstream(openhu):
        text = f"**OpenHU** {upstream(old)} → {upstream(openhu)}"
    if openhu_commit:
        text += f" (commit [`{openhu_commit[:7]}`](https://github.com/average-web-dev/openhu/commit/{openhu_commit}))"
    lines.append(f"- {text}")
aasdk = current.get("libaasdk")
if aasdk:
    old = previous.get("libaasdk")
    if old and upstream(old) != upstream(aasdk):
        lines.append(f"- **libaasdk** {upstream(old)} → [{upstream(aasdk)}](https://github.com/average-web-dev/aasdk/releases/tag/openhu-v{upstream(aasdk)})")
    else:
        lines.append(f"- **libaasdk** [{upstream(aasdk)}](https://github.com/average-web-dev/aasdk/releases/tag/openhu-v{upstream(aasdk)})")
kernel = current.get("linux-image-amd64")
if kernel:
    old = previous.get("linux-image-amd64")
    lines.append(f"- **Linux** {old} → {kernel}" if old and old != kernel else f"- **Linux** {kernel}")

own = {"openhu", "libaasdk", "openhu-os-splash"}
updated = sorted(n for n in current if n in previous and current[n] != previous[n] and n not in own)
added = sorted(n for n in current if n not in previous and n not in own)
removed = sorted(n for n in previous if n not in current and n not in own)
if previous:
    lines.append(f"- **Debian packages:** {len(updated)} updated, {len(added)} new, {len(removed)} removed")
print("\n".join(lines))

if previous and (updated or added or removed):
    print("\n<details><summary>Debian packages compared to " + previous_tag + "</summary>\n")
    for n in updated:
        print(f"- {n}: {previous[n]} → {current[n]}")
    for n in added:
        print(f"- {n}: new ({current[n]})")
    for n in removed:
        print(f"- {n}: removed ({previous[n]})")
    print("\n</details>")
EOF

AASDK_NEW="$(python3 -c 'import json,sys; print({p["name"]: p["version"] for p in json.load(open(sys.argv[1]))["packages"]}.get("libaasdk","").split("-")[0])' "$MANIFEST")"
AASDK_OLD=""
[ -n "$PREVIOUS_MANIFEST" ] && AASDK_OLD="$(python3 -c 'import json,sys; print({p["name"]: p["version"] for p in json.load(open(sys.argv[1]))["packages"]}.get("libaasdk","").split("-")[0])' "$PREVIOUS_MANIFEST")"

{
  echo "Debian 13 \"trixie\" with OpenHU in the cage kiosk, x86_64 (UEFI)."
  echo
  if [ -n "$PREVIOUS" ]; then echo "## Changes since $PREVIOUS"; else echo "## Contents"; fi
  echo
  sed -n '1,/^$/p' "$tmp/packages.md" | sed '/^$/d'

  os_prs="$(merged_prs "$OS_REPO")"
  openhu_prs="$(merged_prs average-web-dev/openhu)"
  if [ -n "$os_prs" ]; then echo; echo "### OpenHU OS"; echo; echo "$os_prs"; fi
  if [ -n "$openhu_prs" ]; then
    echo; echo "### OpenHU"; echo
    echo "$openhu_prs"
  fi
  if [ -n "$AASDK_OLD" ] && [ "$AASDK_OLD" != "$AASDK_NEW" ]; then
    echo; echo "### libaasdk"; echo
    gh release list -R average-web-dev/aasdk --limit 50 --json tagName,name -q '.[] | "\(.tagName) \(.name)"' |
      while read -r tag name; do
        v="${tag#openhu-v}"
        # releases newer than the previous one, up to the current one
        if [ "$(printf '%s\n%s\n' "$AASDK_OLD" "$v" | sort -V | head -1)" = "$AASDK_OLD" ] && [ "$v" != "$AASDK_OLD" ] &&
           [ "$(printf '%s\n%s\n' "$v" "$AASDK_NEW" | sort -V | tail -1)" = "$AASDK_NEW" ]; then
          echo "- [$v](https://github.com/average-web-dev/aasdk/releases/tag/$tag)"
        fi
      done
  fi
  sed -n '/^<details>/,$p' "$tmp/packages.md" | { read -r first && { echo; echo "$first"; cat; }; } || true

  echo
  echo "## Installation"
  echo
  echo "**New installation:** \`xz -d openhu-os_$VERSION.raw.xz\` (PC, UEFI) or"
  echo "\`openhu-os-rpi_$VERSION.raw.xz\` (Raspberry Pi 4 and 5), write it to the disk or SD card (\`dd\`,"
  echo "balenaEtcher, Raspberry Pi Imager). It grows to the whole disk on the first boot. A Raspberry Pi 4 needs a"
  echo "bootloader from 2022-11-25 or newer (Raspberry Pi Imager: Misc utility images → Bootloader)."
  echo
  echo "**Update** of a running OpenHU OS: Settings → System, or \`openhu-cli update install --reboot\` (root"
  echo "partition and kernel image of this release, back to the version before if OpenHU does not come up; images"
  echo "from before openhu-cli: \`openhu update install --reboot\`)."
  echo
  echo "**Without internet:** copy \`SHA256SUMS\`, \`openhu-os_$VERSION.root.raw.gz\` and"
  echo "\`openhu-os_$VERSION.efi\` (PC) or \`openhu-os-rpi_$VERSION.root.raw.gz\` and"
  echo "\`openhu-os-rpi_$VERSION.boot.raw.gz\` (Raspberry Pi) to a USB stick (FAT32, exFAT, NTFS or ext4) and plug"
  echo "it in: OpenHU offers the update (Settings → System)."
}
