#!/usr/bin/env bash
# Fetch externally-built .debs into vendor/, verifying each against its pin.
#
#   ./scripts/fetch-releases.sh                  fetch and verify everything
#   ./scripts/fetch-releases.sh --update         re-pin everything
#   ./scripts/fetch-releases.sh --update <name>  re-pin one package
#
# The single-package form exists for automation. Re-pinning everything to bump
# one package would quietly accept a change in any of the others -- which is
# precisely the tampering the pins are here to refuse.
#
# Not everything worth publishing is a shell script. Anything with a real
# build (Go, Rust, C) should build in its own repo, attach the .deb to a
# GitHub Release, and arrive here. The indexer does not care where a .deb
# came from.
#
# A package directory declares a fetched artifact with a `release` file
# instead of a manifest and files/:
#
#   Repo:   owner/name
#   Tag:    v1.2.0
#   Asset:  name_1.2.0_amd64.deb  sha256:9f2a...
#   Asset:  name_1.2.0_arm64.deb  sha256:c418...
#
# The pins are the point. A GitHub release asset is mutable -- a tag can be
# deleted and re-pushed, an asset replaced -- so an unpinned fetch trusts
# whatever the server happens to return on the day CI runs. That is the same
# problem install.sh's keyring pin exists to solve, and the same fail-closed
# answer: a mismatch is an error, never a warning.
#
# The pins also buy back reproducibility. Locally-built packages get it from
# SOURCE_DATE_EPOCH; a fetched .deb is not rebuilt at all, so pinning its
# bytes is what lets publish.sh's immutability guard stay meaningful.
#
# Public repositories only. A private one would need the release API and an
# authenticated redirect, which nothing here needs yet.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"

UPDATE=0
ONLY=""
usage() { echo "usage: $0 [--update] [package]" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) UPDATE=1 ;;
    -*)       usage ;;
    *)        if [ -n "$ONLY" ]; then usage; fi; ONLY="$1" ;;
  esac
  shift
done

command -v curl     >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "ERROR: dpkg-deb is required" >&2; exit 1; }

mkdir -p "$VENDOR"

# `Key: value`, tolerating aligned whitespace.
field() { # key, file
  awk -v k="$1:" '$1==k { $1=""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }' "$2"
}

# Each `Asset:` line as "<filename> <sha256>". A missing pin yields an empty
# second field, which the caller treats as an error unless --update.
assets() { # file
  awk '$1=="Asset:" {
        name = $2; sha = ""
        for (i = 3; i <= NF; i++) if ($i ~ /^sha256:/) sha = substr($i, 8)
        print name, sha
      }' "$1"
}

shopt -s nullglob
declare -a expected=()
declared=0

for def in "$ROOT"/packages/*/; do
  name="$(basename "$def")"
  rel="$def/release"
  [ -f "$rel" ] || continue
  if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi
  declared=$((declared+1))

  repo="$(field Repo "$rel")"
  tag="$(field Tag "$rel")"
  [ -n "$repo" ] && [ -n "$tag" ] || {
    echo "ERROR $name: release needs Repo and Tag" >&2; exit 1; }

  had_asset=0
  while read -r asset want; do
    [ -n "$asset" ] || continue
    had_asset=1
    expected+=("$asset")
    dest="$VENDOR/$asset"
    url="https://github.com/$repo/releases/download/$tag/$asset"

    # Already downloaded and still matching its pin. This is what makes a
    # repeat build work offline, and what keeps CI from re-downloading every
    # asset on every run.
    if [ "$UPDATE" -eq 0 ] && [ -n "$want" ] && [ -f "$dest" ] &&
       [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then
      echo "  cached  $asset"
      continue
    fi

    tmp="$(mktemp)"
    curl -fsSL "$url" -o "$tmp" || {
      rm -f "$tmp"
      echo "ERROR $name: could not fetch $url" >&2
      exit 1
    }
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"

    if [ "$UPDATE" -eq 1 ]; then
      # Rewrite in place with awk rather than sed: an asset filename is a
      # regex minefield, and matching it as a literal field avoids escaping
      # it at all.
      rewritten="$(mktemp)"
      awk -v a="$asset" -v s="$got" '
        $1 == "Asset:" && $2 == a { printf "Asset:  %s  sha256:%s\n", a, s; next }
        { print }
      ' "$rel" > "$rewritten"
      mv "$rewritten" "$rel"
      [ "$want" = "$got" ] && echo "  ok      $asset" || echo "  pinned  $asset  $got"
    elif [ -z "$want" ]; then
      rm -f "$tmp"
      echo "ERROR $name: $asset has no sha256 pin." >&2
      echo "An unpinned fetch trusts whatever the server returns. Re-run with" >&2
      echo "--update to pin what upstream currently serves." >&2
      exit 1
    elif [ "$got" != "$want" ]; then
      rm -f "$tmp"
      echo "ERROR $name: $asset does not match its pin." >&2
      echo "  pinned : $want" >&2
      echo "  server : $got" >&2
      echo "Upstream replaced this asset, or it was tampered with. If the" >&2
      echo "change is expected, re-pin deliberately with --update." >&2
      exit 1
    else
      echo "  fetched $asset"
    fi

    # The directory name is what the pool and the smoke loop key on, so a
    # .deb containing some other package would install something nobody
    # declared.
    pkg="$(dpkg-deb -f "$tmp" Package 2>/dev/null || true)"
    [ "$pkg" = "$name" ] || {
      rm -f "$tmp"
      echo "ERROR $name: $asset contains package '${pkg:-<unreadable>}'" >&2
      exit 1
    }

    install -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
  done < <(assets "$rel")

  [ "$had_asset" -eq 1 ] || { echo "ERROR $name: release declares no Asset" >&2; exit 1; }
done

if [ -n "$ONLY" ] && [ "$declared" -eq 0 ]; then
  echo "ERROR: no package named '$ONLY' declares a release" >&2
  exit 1
fi

# Drop anything vendor/ still holds that is no longer declared. Without this a
# retagged package leaves its previous .deb behind and build-repo.sh sweeps it
# back into the pool -- exactly the stale-artifact failure that build-deb.sh
# wipes dist/ to prevent.
#
# Skipped when scoped to one package: `expected` then covers only that
# package, so pruning against it would delete every other package's artifacts.
if [ -z "$ONLY" ]; then
  for f in "$VENDOR"/*.deb; do
    base="$(basename "$f")"
    keep=0
    for e in ${expected[@]+"${expected[@]}"}; do
      [ "$base" = "$e" ] && { keep=1; break; }
    done
    [ "$keep" -eq 1 ] || { rm -f "$f"; echo "  pruned  $base"; }
  done
fi

if [ "$declared" -eq 0 ]; then
  echo "no packages declare a release; nothing to fetch"
else
  echo "$declared package(s) fetched into $VENDOR"
fi
