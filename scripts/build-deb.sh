#!/usr/bin/env bash
# Build a .deb for every definition under packages/ into dist/.
#
# A package definition is a directory containing:
#   manifest        Debian control fields (Package, Version, Architecture, ...)
#   files/          the filesystem tree to install, rooted at /
#   scripts/        optional maintainer scripts (postinst, prerm, ...)
#
# This is for simple, self-contained packages. Anything with a real build
# (Go, Rust, C) should produce its .deb in its own repo and land in dist/
# via scripts/fetch-releases.sh instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
BUILD="$ROOT/build"

rm -rf "$BUILD"; mkdir -p "$BUILD" "$DIST"

shopt -s nullglob
found=0
for def in "$ROOT"/packages/*/; do
  name="$(basename "$def")"
  [ -f "$def/manifest" ] || { echo "skip $name: no manifest" >&2; continue; }

  version="$(awk -F': *' '/^Version:/{print $2; exit}' "$def/manifest")"
  arch="$(awk -F': *' '/^Architecture:/{print $2; exit}' "$def/manifest")"
  [ -n "$version" ] && [ -n "$arch" ] || { echo "ERROR $name: manifest needs Version and Architecture" >&2; exit 1; }

  stage="$BUILD/${name}_${version}_${arch}"
  mkdir -p "$stage/DEBIAN"
  cp "$def/manifest" "$stage/DEBIAN/control"

  if [ -d "$def/files" ]; then
    cp -a "$def/files/." "$stage/"
  fi
  if [ -d "$def/scripts" ]; then
    for s in "$def"/scripts/*; do
      install -m 0755 "$s" "$stage/DEBIAN/$(basename "$s")"
    done
  fi

  # Anything landing in a bin directory must be executable regardless of the
  # umask that checked it out.
  for d in "$stage/usr/bin" "$stage/usr/local/bin" "$stage/bin"; do
    [ -d "$d" ] && chmod 0755 "$d"/* || true
  done

  # --root-owner-group so files install as root:root rather than inheriting
  # the uid of whoever ran the build.
  dpkg-deb --root-owner-group --build "$stage" "$DIST/${name}_${version}_${arch}.deb" >/dev/null
  echo "  built  ${name}_${version}_${arch}.deb"
  found=$((found+1))
done

[ "$found" -gt 0 ] || { echo "ERROR: no packages built" >&2; exit 1; }
echo "$found package(s) in $DIST"
