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

# dist/ is a staging area for this build, not an archive. Letting it
# accumulate means a stale .deb from an earlier version gets swept back into
# the pool on the next publish. Published history lives in the bucket.
rm -rf "$BUILD" "$DIST"; mkdir -p "$BUILD" "$DIST"

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

  # Normalise permissions. `cp -a` preserves whatever the working tree has,
  # which is the builder's umask -- 0664 here, 0644 from a git checkout in CI.
  # That difference lands in the .deb and makes the same version produce
  # different bytes depending on who built it.
  find "$stage" -type d -exec chmod 0755 {} +
  find "$stage" -type f -exec chmod 0644 {} +

  # Then restore the things that must be executable: anything in a bin
  # directory, and the maintainer scripts.
  for d in usr/bin usr/local/bin bin usr/sbin sbin; do
    [ -d "$stage/$d" ] && chmod 0755 "$stage/$d"/* || true
  done
  if [ -d "$def/scripts" ]; then
    for s in "$def"/scripts/*; do chmod 0755 "$stage/DEBIAN/$(basename "$s")"; done
  fi

  # Reproducibility. dpkg-deb embeds mtimes, so a rebuild of an unchanged
  # package would otherwise produce different bytes -- which publish.sh
  # rightly refuses, since a pool filename must always mean the same content.
  #
  # A fixed constant, deliberately. Deriving this from git history looks
  # tidier but breaks under `actions/checkout`, which clones at depth 1: if
  # HEAD does not touch this package, `git log -- packages/<name>` returns
  # nothing and the epoch silently changes. Build output must depend on the
  # package's contents and nothing else.
  epoch="${SOURCE_DATE_EPOCH:-1700000000}"
  export SOURCE_DATE_EPOCH="$epoch"
  find "$stage" -exec touch -h -d "@$epoch" {} +

  # --root-owner-group so files install as root:root rather than inheriting
  # the uid of whoever ran the build.
  dpkg-deb --root-owner-group --build "$stage" "$DIST/${name}_${version}_${arch}.deb" >/dev/null
  echo "  built  ${name}_${version}_${arch}.deb"
  found=$((found+1))
done

[ "$found" -gt 0 ] || { echo "ERROR: no packages built" >&2; exit 1; }
echo "$found package(s) in $DIST"
