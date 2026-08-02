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
# 1. payload first
find pool -type f -printf '%p\n' 2>/dev/null | sort | while read -r k; do put "$k"; done
# 2. then the indexes that reference it
find dists -type f ! -name 'InRelease' ! -name 'Release.gpg' -printf '%p\n' | sort | while read -r k; do put "$k"; done
# 3. signatures last — these are what apt validates everything else against
for k in dists/stable/Release.gpg dists/stable/InRelease; do [ -f "$k" ] && put "$k"; done
# 4. bootstrap files
for k in jvs-archive-keyring.gpg install.sh; do [ -f "$k" ] && put "$k"; done

echo "published to r2://$BUCKET"
