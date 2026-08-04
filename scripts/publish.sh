#!/usr/bin/env bash
# Upload the built repo to R2.
#
# Order matters. Packages are written before the metadata that references
# them, so a client that reads mid-publish sees either the old consistent
# state or the new one — never metadata pointing at a .deb that is not there.
#
# Talks to the R2 REST API with curl. Object operations live on the ordinary
# v4 API and take the same bearer token everything else here uses, so no
# SigV4 signing and no CLI are involved -- the previous wrangler dependency
# was an `npx` download of a large package on every publish.
set -euo pipefail

# Shared output root -- see build-deb.sh for why this is outside the tree.
OUT="${PKGS_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/pkgs-jvs}"
REPO="$OUT/repo"
BUCKET="${BUCKET:-pkgs}"
API="https://api.cloudflare.com/client/v4"

command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
[ -d "$REPO" ] || { echo "ERROR: $REPO does not exist — run build-repo.sh first" >&2; exit 1; }
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || {
  echo "ERROR: CLOUDFLARE_API_TOKEN is not set (needs Workers R2 Storage -> Edit)" >&2
  exit 1
}

# The account id is asked of the token rather than configured: an account-owned
# token can only ever see one account, so there is nothing to get wrong.
#
# The -K substitution has to sit on each curl invocation. Building it into an
# args array first closes the descriptor when the assignment completes.
ACCOUNT="$(curl -sS -K <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
  "$API/accounts" | jq -r '.result[0].id // empty')"
[ -n "$ACCOUNT" ] || { echo "ERROR: the token cannot see any account" >&2; exit 1; }
OBJ="$API/accounts/$ACCOUNT/r2/buckets/$BUCKET/objects"

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
  local key="$1" resp
  resp="$(curl -sS -X PUT \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
    -H "Content-Type: $(ctype "$key")" \
    --data-binary "@$REPO/$key" "$OBJ/$key")"
  if [ "$(printf '%s' "$resp" | jq -r '.success')" = "true" ]; then
    printf '  put  %s\n' "$key"
  else
    printf '  FAIL %s — %s\n' "$key" \
      "$(printf '%s' "$resp" | jq -r '(.errors // []) | map(.message) | join("; ")')" >&2
    return 1
  fi
}

# Writes the object to $1 and reports its HTTP status, so callers can tell
# "absent" (404, the normal case for anything new) from "present" from a real
# failure. Exit codes cannot make that distinction.
fetch_status() { # key, destination
  curl -sS -o "$2" -w '%{http_code}' \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
    "$OBJ/$1"
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
  code="$(fetch_status "$k" "$probe")"
  case "$code" in
    404) ;;   # not published yet, which is the normal case for a new version
    200)
      if [ "$(sha256sum "$probe" | cut -d' ' -f1)" != "$(sha256sum "$REPO/$k" | cut -d' ' -f1)" ]; then
        echo "ERROR: $k already exists in the bucket with different content." >&2
        stale=1
      fi
      ;;
    *)
      # Anything else -- auth, rate limit, an outage -- must not be mistaken
      # for "absent", or the guard would wave through the very thing it exists
      # to catch.
      echo "ERROR: could not check $k in the bucket (HTTP $code)" >&2
      stale=1
      ;;
  esac
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
# 4. bootstrap files. The .deb at this stable path is what install.sh fetches;
#    it is a copy of the pool object at a version-independent URL.
for k in jvs-archive-keyring.deb jvs-archive-keyring.gpg install.sh; do
  [ -f "$k" ] && put "$k"
done

echo "published to r2://$BUCKET"
