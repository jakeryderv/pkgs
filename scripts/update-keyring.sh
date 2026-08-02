#!/usr/bin/env bash
# Regenerate the public keyring shipped by the jvs-archive-keyring package.
#
#   ./scripts/update-keyring.sh <key-uid> [<key-uid> ...]
#
# The keyring is committed to git on purpose. It is the material every
# installed machine trusts, so a change to it should show up in a diff and be
# reviewed like code -- not appear as a side effect of whatever key happened
# to be in the builder's keyring at the time.
#
# During a rotation you list BOTH keys here. See "Rotating the signing key"
# in the README: machines must learn the new key before it starts signing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/packages/jvs-archive-keyring/files/usr/share/keyrings/jvs-archive-keyring.gpg"

[ "$#" -ge 1 ] || { echo "usage: $0 <key-uid> [<key-uid> ...]" >&2; exit 1; }

for uid in "$@"; do
  gpg --list-keys "$uid" >/dev/null 2>&1 || { echo "ERROR: no such key: $uid" >&2; exit 1; }
done

mkdir -p "$(dirname "$DEST")"
gpg --export "$@" > "$DEST"

echo "keyring written to ${DEST#"$ROOT"/}"
gpg --show-keys --with-colons "$DEST" | awk -F: '
  /^pub:/ { pub=1 }
  /^fpr:/ && pub { fpr=$10; pub=0 }
  /^uid:/ && fpr { printf "  %s  %s\n", fpr, $10; fpr="" }'
echo
echo "Remember to bump the version in packages/jvs-archive-keyring/manifest."
