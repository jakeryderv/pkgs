#!/usr/bin/env bash
# Push the signing credentials from 1Password into this repository's GitHub
# Actions secrets.
#
#   ./scripts/sync-secrets.sh              check and push
#   ./scripts/sync-secrets.sh --dry-run    check only, change nothing
#
# Rotating the signing key changes it in two places: the repository being
# signed, and the secrets CI signs with. The README procedure covers the first.
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
OP_CF_TOKEN_REF="${OP_CF_TOKEN_REF:-op://dev/pkgs.jvs.sh/cloudflare-token}"
OP_CF_ACCOUNT_REF="${OP_CF_ACCOUNT_REF:-op://dev/pkgs.jvs.sh/cloudflare-account-id}"
BUCKET="${BUCKET:-pkgs}"
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
  echo "Ship a keyring trusting it first -- see 'Rotating the signing key'." >&2
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
# Optional. A Cloudflare API token is shown once at creation and cannot be read
# back out of GitHub, so it may simply not be in the vault yet -- in which case
# leave the existing GitHub secret alone rather than clobbering a working one
# with nothing. Both values or neither: half-configured is a mistake, not a
# state worth supporting.
CF_TOKEN_LEN="$(ref_len "$OP_CF_TOKEN_REF")"
CF_ACCT_LEN="$(ref_len "$OP_CF_ACCOUNT_REF")"
CF=0
if [ "$CF_TOKEN_LEN" -gt 0 ] && [ "$CF_ACCT_LEN" -gt 0 ]; then
  CF=1
elif [ "$CF_TOKEN_LEN" -gt 0 ] || [ "$CF_ACCT_LEN" -gt 0 ]; then
  echo "ERROR: only one of the Cloudflare values is in the vault." >&2
  echo "  token   : $OP_CF_TOKEN_REF" >&2
  echo "  account : $OP_CF_ACCOUNT_REF" >&2
  echo "Set both, or neither." >&2
  exit 1
else
  echo "  cloudflare not in the vault, leaving its GitHub secrets untouched"
fi

if [ "$CF" -eq 1 ]; then
  CF_ACCOUNT="$(op read "$OP_CF_ACCOUNT_REF" 2>/dev/null)"

  # --config via process substitution rather than -H: a header on the command
  # line puts the token in argv, where any other process can read it.
  #
  # No -f, deliberately. Cloudflare answers a bad token with HTTP 400 and a
  # JSON body explaining why; -f discards the body and exits 22, which under
  # pipefail aborts with a curl error code instead of the actual reason.
  cf_api() { # path
    curl -sS -K <(printf 'header = "Authorization: Bearer %s"\n' "$(op read "$OP_CF_TOKEN_REF" 2>/dev/null)") \
      "https://api.cloudflare.com/client/v4/$1"
  }
  cf_errors() { jq -r '(.errors // []) | map(.message) | join("; ")'; }

  verify="$(cf_api user/tokens/verify)"
  if [ "$(printf '%s' "$verify" | jq -r '.success')" != "true" ]; then
    echo "ERROR: the Cloudflare token at $OP_CF_TOKEN_REF was rejected." >&2
    echo "  cloudflare says: $(printf '%s' "$verify" | cf_errors)" >&2
    exit 1
  fi
  status="$(printf '%s' "$verify" | jq -r '.result.status // "unknown"')"
  [ "$status" = "active" ] || {
    echo "ERROR: the Cloudflare token is '$status', not active" >&2; exit 1; }
  echo "  cloudflare token is active"

  # Proves three things at once, all of which publish.sh depends on: the token
  # carries R2 permissions, the account id goes with the token, and the bucket
  # exists. A token that verifies but cannot see the bucket would still fail
  # every publish.
  buckets="$(cf_api "accounts/$CF_ACCOUNT/r2/buckets")"
  if [ "$(printf '%s' "$buckets" | jq -r '.success')" != "true" ]; then
    echo "ERROR: could not list R2 buckets for account $CF_ACCOUNT" >&2
    echo "  cloudflare says: $(printf '%s' "$buckets" | cf_errors)" >&2
    echo "The token needs Workers R2 Storage -> Edit, and the account must match." >&2
    exit 1
  fi
  if ! printf '%s' "$buckets" | jq -e --arg b "$BUCKET" \
        '.result.buckets // [] | map(.name) | index($b)' >/dev/null; then
    echo "ERROR: bucket '$BUCKET' is not in account $CF_ACCOUNT" >&2
    exit 1
  fi
  echo "  cloudflare token can reach r2://$BUCKET"
fi

if [ "$DRY" -eq 1 ]; then
  echo
  echo "dry run: nothing pushed."
  echo "  would set: GPG_PRIVATE_KEY, GPG_PASSPHRASE$( [ "$CF" -eq 1 ] && printf ', CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID' )"
  exit 0
fi

echo "  pushing to $REPO"
op read "$OP_KEY_REF"  2>/dev/null | gh secret set GPG_PRIVATE_KEY --repo "$REPO"
op read "$OP_PASS_REF" 2>/dev/null | gh secret set GPG_PASSPHRASE  --repo "$REPO"
if [ "$CF" -eq 1 ]; then
  op read "$OP_CF_TOKEN_REF"   2>/dev/null | gh secret set CLOUDFLARE_API_TOKEN  --repo "$REPO"
  op read "$OP_CF_ACCOUNT_REF" 2>/dev/null | gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$REPO"
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
