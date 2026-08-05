#!/usr/bin/env bash
# Push the signing credentials from 1Password into this repository's GitHub
# Actions secrets.
#
#   ./scripts/sync-secrets.sh              check and push
#   ./scripts/sync-secrets.sh --dry-run    check only, change nothing
#
# Rotating the signing key changes it in two places: the repository being
# signed, and the secrets CI signs with. The docs/operations.md procedure
# covers the first.
# This is the second, and skipping it means the next push to main silently
# re-signs with the old key -- not broken, since machines still trust it at
# that point, but quietly back on the key you meant to retire.
#
# The alternative is pasting a private key into a browser form, which is the
# worst step in the whole procedure and the easiest to do wrong.
#
# Secret *references* are paths, not secrets, so they live here in the open.
# Override any of them in the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-jakeryderv/pkgs}"
OP_KEY_REF="${OP_KEY_REF:-op://dev/pkgs.jvs.sh/jvs-archive-signing-key.asc}"
OP_PASS_REF="${OP_PASS_REF:-op://dev/pkgs.jvs.sh/password}"
BUCKET="${BUCKET:-pkgs}"
# Not a secret and not in the vault: an account id appears in dashboard URLs
# and is routinely committed in wrangler.toml. It is only needed to check the
# token can reach the bucket, and comes from the token's own account list.
SHIPPED_KEYRING="$ROOT/packages/jvs-archive-keyring/files/usr/share/keyrings/jvs-archive-keyring.gpg"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

command -v op   >/dev/null || { echo "ERROR: 1Password CLI (op) is required" >&2; exit 1; }
command -v gh   >/dev/null || { echo "ERROR: gh is required" >&2; exit 1; }
command -v gpg  >/dev/null || { echo "ERROR: gpg is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }

# Length of whatever a reference resolves to, or 0 if it resolves to nothing.
# Not `op read | wc -c`: under pipefail a failed read makes the pipeline fail,
# so the fallback fires *as well as* wc, and the result is "0\n0".
ref_len() { # reference
  local v
  v="$(op read "$1" 2>/dev/null || true)"
  printf '%s' "${#v}"
}
op account list >/dev/null 2>&1 || { echo "ERROR: not signed in to 1Password (run: eval \$(op signin))" >&2; exit 1; }

# Everything is checked in a throwaway keyring before anything is pushed. The
# failure this exists to prevent is discovering, during a publish, that the
# key and passphrase in CI do not go together.
WORK="$(mktemp -d)"
chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
export GNUPGHOME="$WORK"

echo "  reading key from $OP_KEY_REF"
# Piped straight into gpg: the private key is never held in a shell variable
# and never touches disk outside the throwaway keyring.
op read "$OP_KEY_REF" 2>/dev/null | gpg --batch --quiet --import 2>/dev/null || {
  echo "ERROR: could not import a private key from $OP_KEY_REF" >&2
  exit 1
}

FPR="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || { echo "ERROR: no secret key found after import" >&2; exit 1; }
UID_LINE="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^uid:/{print $10; exit}')"
echo "  key      $FPR"
echo "  uid      ${UID_LINE:-<none>}"

# The same reasoning as build-repo.sh's rotation guard: a key installed
# machines do not trust cannot verify the repository, and therefore cannot
# deliver the update that would fix it. Refuse to arm CI with such a key.
[ -f "$SHIPPED_KEYRING" ] || { echo "ERROR: no shipped keyring at $SHIPPED_KEYRING" >&2; exit 1; }
if ! gpg --show-keys --with-colons "$SHIPPED_KEYRING" 2>/dev/null \
     | awk -F: '/^fpr:/{print $10}' | grep -qx "$FPR"; then
  echo "ERROR: $FPR is not in the keyring this repository ships." >&2
  echo "CI would sign with a key installed machines do not trust, and they" >&2
  echo "could not fetch the update that would fix it." >&2
  echo "Ship a keyring trusting it first -- see 'Rotating the signing key'" >&2
  echo "in docs/operations.md." >&2
  exit 1
fi
echo "  trusted  yes (present in the shipped keyring)"

# A passphrase that does not unlock the key would pass every check here and
# fail at the point of publishing, which is the worst time to find out.
if [ "$(ref_len "$OP_PASS_REF")" -eq 0 ]; then
  echo "ERROR: $OP_PASS_REF is empty." >&2
  echo "Put the key's passphrase in that field (or point OP_PASS_REF elsewhere)." >&2
  exit 1
fi
if ! printf 'sync-secrets test\n' \
  | gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
        --local-user "$FPR" --detach-sign --output /dev/null 3< <(op read "$OP_PASS_REF" 2>/dev/null); then
  echo "ERROR: the passphrase at $OP_PASS_REF does not unlock $FPR" >&2
  exit 1
fi
echo "  passphrase unlocks the key"

# ---- Cloudflare -----------------------------------------------------------
# From the environment only. The Cloudflare tokens live in the `pkgs`
# 1Password Environment, which holds environment variables and is not
# reachable by `op read` -- so they arrive by sourcing the mounted .env and
# there is nowhere else to look. There was a vault fallback here; it pointed
# at a field that does not exist, which is worse than no fallback.
#
# Absent is not an error: a token is displayed once at creation and cannot be
# read back out of GitHub, so leave the existing secret alone rather than
# overwriting a working one with nothing.
CF=0
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  CF=1
else
  echo "  no CLOUDFLARE_API_TOKEN in the environment, leaving its GitHub secret alone"
  echo "  (set -a; . ./.env; set +a  to load the pkgs Environment)"
fi

if [ "$CF" -eq 1 ]; then
  # --config via process substitution rather than -H: a header on the command
  # line puts the token in argv, where any other process can read it.
  #
  # No -f, deliberately. Cloudflare answers a bad token with HTTP 400 and a
  # JSON body explaining why; -f discards the body and exits 22, which under
  # pipefail aborts with a curl exit code instead of the actual reason.
  cf_api() { # path
    curl -sS -K <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
      "https://api.cloudflare.com/client/v4/$1"
  }
  cf_errors() { jq -r '(.errors // []) | map(.message) | join("; ")'; }

  # Account id first: an account-owned token can only ever see one account, so
  # it can be asked rather than stored. This also has to come first because the
  # verify endpoint below is account-scoped.
  accounts="$(cf_api accounts)"
  if [ "$(printf '%s' "$accounts" | jq -r '.success')" != "true" ]; then
    echo "ERROR: the Cloudflare token was rejected." >&2
    echo "  cloudflare says: $(printf '%s' "$accounts" | cf_errors)" >&2
    exit 1
  fi
  CF_ACCOUNT="$(printf '%s' "$accounts" | jq -r '.result[0].id // empty')"
  [ -n "$CF_ACCOUNT" ] || { echo "ERROR: the token belongs to no account" >&2; exit 1; }

  # Account-scoped verify, NOT /user/tokens/verify. The latter answers "Invalid
  # API Token" for a perfectly good account-owned token, because such a token
  # is tied to the account rather than to a user and cannot call user endpoints.
  verify="$(cf_api "accounts/$CF_ACCOUNT/tokens/verify")"
  if [ "$(printf '%s' "$verify" | jq -r '.success')" != "true" ]; then
    echo "ERROR: the Cloudflare token did not verify." >&2
    echo "  cloudflare says: $(printf '%s' "$verify" | cf_errors)" >&2
    exit 1
  fi
  status="$(printf '%s' "$verify" | jq -r '.result.status // "unknown"')"
  [ "$status" = "active" ] || {
    echo "ERROR: the Cloudflare token is '$status', not active" >&2; exit 1; }
  echo "  cloudflare token is active (account $CF_ACCOUNT)"

  # A token that verifies but cannot see the bucket fails every publish while
  # looking healthy, so check the thing publish.sh actually depends on.
  buckets="$(cf_api "accounts/$CF_ACCOUNT/r2/buckets")"
  if [ "$(printf '%s' "$buckets" | jq -r '.success')" != "true" ]; then
    echo "ERROR: could not list R2 buckets for account $CF_ACCOUNT" >&2
    echo "  cloudflare says: $(printf '%s' "$buckets" | cf_errors)" >&2
    echo "The token needs Workers R2 Storage -> Edit." >&2
    exit 1
  fi
  if ! printf '%s' "$buckets" | jq -e --arg b "$BUCKET" \
        '.result.buckets // [] | map(.name) | index($b)' >/dev/null; then
    echo "ERROR: bucket '$BUCKET' is not in account $CF_ACCOUNT" >&2
    exit 1
  fi
  echo "  cloudflare token can reach r2://$BUCKET"
fi

# ---- GitHub tokens --------------------------------------------------------
# Same channel as the Cloudflare pair: the pkgs 1Password Environment,
# arriving via the mounted .env. Absent is not an error for the same reason --
# a PAT is displayed once at creation, so leave a working GitHub secret alone
# rather than overwriting it with nothing. Unlike the Cloudflare pair the two
# are independent: either can be synced without the other.
AUTOPIN=0
if [ -n "${AUTOPIN_TOKEN:-}" ]; then
  # The check autopin actually depends on: the token can see the repository
  # and push to it. Pull-request write has no read-only probe, so a scope
  # mistake there still only surfaces when autopin next opens a PR.
  if [ "$(GH_TOKEN="$AUTOPIN_TOKEN" gh api "repos/$REPO" --jq '.permissions.push' 2>/dev/null || true)" != "true" ]; then
    echo "ERROR: AUTOPIN_TOKEN cannot push to $REPO." >&2
    echo "It needs a fine-grained PAT with Contents and Pull requests" >&2
    echo "read/write, scoped to $REPO only." >&2
    exit 1
  fi
  AUTOPIN=1
  echo "  autopin token can push to $REPO"
else
  echo "  no AUTOPIN_TOKEN in the environment, leaving its GitHub secret alone"
fi

DISPATCH=0
TOOL_REPOS=""
if [ -n "${PKGS_AUTOPIN_DISPATCH:-}" ]; then
  # Probe the exact surface the token exists to reach: the autopin workflow
  # on this repository. Seeing it requires Actions access; nothing else does.
  if ! GH_TOKEN="$PKGS_AUTOPIN_DISPATCH" gh api "repos/$REPO/actions/workflows/autopin.yml" --jq .id >/dev/null 2>&1; then
    echo "ERROR: PKGS_AUTOPIN_DISPATCH cannot see the autopin workflow on $REPO." >&2
    echo "It needs a fine-grained PAT with Actions read/write, scoped to $REPO only." >&2
    exit 1
  fi
  # The release files already name every tool repo, so sync from them: a new
  # fetched package gets the dispatch secret by being declared, not by being
  # remembered.
  TOOL_REPOS="$(for rel in "$ROOT"/packages/*/release; do
      [ -f "$rel" ] || continue
      awk '$1=="Repo:"{print $2; exit}' "$rel"
    done | sort -u)"
  if [ -z "$TOOL_REPOS" ]; then
    echo "  no package declares a release, nowhere to put the dispatch token"
  else
    DISPATCH=1
    echo "  dispatch token can reach the autopin workflow"
  fi
else
  echo "  no PKGS_AUTOPIN_DISPATCH in the environment, leaving tool repos alone"
fi

if [ "$DRY" -eq 1 ]; then
  echo
  echo "dry run: nothing pushed."
  echo "  would set: GPG_PRIVATE_KEY, GPG_PASSPHRASE$( [ "$CF" -eq 1 ] && printf ', CLOUDFLARE_API_TOKEN' )$( [ -n "${CLOUDFLARE_CACHE_RO_TOKEN:-}" ] && printf ', CLOUDFLARE_CACHE_RO_TOKEN' )$( [ "$AUTOPIN" -eq 1 ] && printf ', AUTOPIN_TOKEN' )"
  if [ "$DISPATCH" -eq 1 ]; then
    echo "  would set PKGS_AUTOPIN_DISPATCH in:$(printf ' %s' $TOOL_REPOS)"
  fi
  exit 0
fi

echo "  pushing to $REPO"
op read "$OP_KEY_REF"  2>/dev/null | gh secret set GPG_PRIVATE_KEY --repo "$REPO"
op read "$OP_PASS_REF" 2>/dev/null | gh secret set GPG_PASSPHRASE  --repo "$REPO"
if [ "$CF" -eq 1 ]; then
  printf '%s' "$CLOUDFLARE_API_TOKEN" | gh secret set CLOUDFLARE_API_TOKEN --repo "$REPO"
fi

# The read-only cache token, used only by the monitor workflow's drift check.
# Separate from the one above on purpose: that one can write to R2, this one
# cannot write anything at all, and CI never needs to change cache rules.
if [ -n "${CLOUDFLARE_CACHE_RO_TOKEN:-}" ]; then
  printf '%s' "$CLOUDFLARE_CACHE_RO_TOKEN" | gh secret set CLOUDFLARE_CACHE_RO_TOKEN --repo "$REPO"
  echo "  CLOUDFLARE_CACHE_RO_TOKEN pushed"
fi

if [ "$AUTOPIN" -eq 1 ]; then
  printf '%s' "$AUTOPIN_TOKEN" | gh secret set AUTOPIN_TOKEN --repo "$REPO"
  echo "  AUTOPIN_TOKEN pushed"
fi

# One dispatch token, placed in every repo a release file declares. Pushed by
# the logged-in gh account, not by the token itself -- it cannot write
# secrets anywhere, which is the point of its scope.
if [ "$DISPATCH" -eq 1 ]; then
  for toolrepo in $TOOL_REPOS; do
    printf '%s' "$PKGS_AUTOPIN_DISPATCH" | gh secret set PKGS_AUTOPIN_DISPATCH --repo "$toolrepo"
    echo "  PKGS_AUTOPIN_DISPATCH pushed to $toolrepo"
  done
fi

# CI signs with vars.SIGNER_UID, defaulting to pkgs@jvs.sh. During a rotation
# the uid changes, and leaving this behind is how CI ends up holding the new
# key while still asking to sign with the old name.
SIGNER_EMAIL="$(printf '%s' "$UID_LINE" | sed -n 's/.*<\(.*\)>.*/\1/p')"
if [ -n "$SIGNER_EMAIL" ]; then
  gh variable set SIGNER_UID --repo "$REPO" --body "$SIGNER_EMAIL" >/dev/null
  echo "  SIGNER_UID set to $SIGNER_EMAIL"
fi

echo
echo "synced. CI will sign with $FPR"
