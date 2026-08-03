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
OP_KEY_REF="${OP_KEY_REF:-op://Private/pkgs.jvs.sh/jvs-archive-signing-key.asc}"
OP_PASS_REF="${OP_PASS_REF:-op://Private/pkgs.jvs.sh/password}"
SHIPPED_KEYRING="$ROOT/packages/jvs-archive-keyring/files/usr/share/keyrings/jvs-archive-keyring.gpg"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

command -v op  >/dev/null || { echo "ERROR: 1Password CLI (op) is required" >&2; exit 1; }
command -v gh  >/dev/null || { echo "ERROR: gh is required" >&2; exit 1; }
command -v gpg >/dev/null || { echo "ERROR: gpg is required" >&2; exit 1; }
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
PASS_BYTES="$(op read "$OP_PASS_REF" 2>/dev/null | wc -c || echo 0)"
if [ "$PASS_BYTES" -le 1 ]; then
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

if [ "$DRY" -eq 1 ]; then
  echo
  echo "dry run: nothing pushed. Would set GPG_PRIVATE_KEY and GPG_PASSPHRASE on $REPO."
  exit 0
fi

echo "  pushing to $REPO"
op read "$OP_KEY_REF"  2>/dev/null | gh secret set GPG_PRIVATE_KEY --repo "$REPO"
op read "$OP_PASS_REF" 2>/dev/null | gh secret set GPG_PASSPHRASE  --repo "$REPO"

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
