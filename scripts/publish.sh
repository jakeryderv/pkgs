#!/usr/bin/env bash
# Upload the built repo to R2.
#
# Order matters. Packages are written before the metadata that references
# them, so a client that reads mid-publish sees either the old consistent
# state or the new one — never metadata pointing at a .deb that is not there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$ROOT/repo"
BUCKET="${BUCKET:-pkgs}"
# Locally this is the globally installed wrangler. CI has no global install,
# so the workflow sets WRANGLER="npx --yes wrangler@4".
WRANGLER="${WRANGLER:-wrangler}"

[ -d "$REPO" ] || { echo "ERROR: $REPO does not exist — run build-repo.sh first" >&2; exit 1; }

ctype() {
  case "$1" in
    *.deb)        echo "application/vnd.debian.binary-package" ;;
    *.gz)         echo "application/gzip" ;;
    *Release.gpg) echo "application/pgp-signature" ;;
    *keyring.gpg) echo "application/pgp-keys" ;;
    *.sh)         echo "text/x-shellscript" ;;
    *InRelease|*Release|*Packages) echo "text/plain" ;;
    *)            echo "application/octet-stream" ;;
  esac
}

put() {
  local key="$1"
  $WRANGLER r2 object put "$BUCKET/$key" --file "$REPO/$key" \
    --content-type "$(ctype "$key")" --remote >/dev/null 2>&1 \
    && printf '  put  %s\n' "$key" \
    || { printf '  FAIL %s\n' "$key" >&2; return 1; }
}

cd "$REPO"

# Guard: a pool object is cached at the edge for a year on the promise that a
# given filename's content never changes. Republishing the same version with
# different content silently breaks every client until that cache expires --
# apt fetches the stale .deb, its hash disagrees with Packages, and the
# install fails. Debian's rule is the fix: new content means a new version.
stale=0
probe="$(mktemp)"
while read -r k; do
  # `if cmd; then` rather than a command substitution: under `set -e` a failed
  # substitution aborts the script silently, and a missing object -- the
  # normal case for anything new -- makes wrangler exit non-zero.
  if $WRANGLER r2 object get "$BUCKET/$k" --file "$probe" --remote >/dev/null 2>&1; then
    if [ "$(sha256sum "$probe" | cut -d' ' -f1)" != "$(sha256sum "$REPO/$k" | cut -d' ' -f1)" ]; then
      echo "ERROR: $k already exists in the bucket with different content." >&2
      stale=1
    fi
  fi
done < <(find pool -type f -printf '%p\n' 2>/dev/null | sort)
rm -f "$probe"
if [ "$stale" -ne 0 ]; then
  echo "Bump the package version instead of republishing the same one." >&2
  exit 1
fi

# 1. payload first
find pool -type f -printf '%p\n' 2>/dev/null | sort | while read -r k; do put "$k"; done
# 2. then the indexes that reference it
find dists -type f ! -name 'InRelease' ! -name 'Release.gpg' -printf '%p\n' | sort | while read -r k; do put "$k"; done
# 3. signatures last — these are what apt validates everything else against
for k in dists/stable/Release.gpg dists/stable/InRelease; do [ -f "$k" ] && put "$k"; done
# 4. bootstrap files
for k in jvs-archive-keyring.gpg install.sh; do [ -f "$k" ] && put "$k"; done

echo "published to r2://$BUCKET"
