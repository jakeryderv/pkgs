#!/bin/sh
# Configure the jvs.sh apt repository.
#
#   curl -fsSL https://pkgs.jvs.sh/install.sh | sudo sh
#
# Idempotent: safe to re-run. Removes nothing it did not create.
#
# The two pins below are rewritten by scripts/build-repo.sh (UPDATE_PINS=1)
# and checked on every build, so they cannot silently drift from the key that
# actually signs the repository.
set -eu

BASE_URL="${JVS_BASE_URL:-https://pkgs.jvs.sh}"
SUITE=stable
COMPONENT=main
KEYRING=/usr/share/keyrings/jvs-archive-keyring.gpg
SOURCES=/etc/apt/sources.list.d/jvs.sources

KEY_FINGERPRINT="5476924FEB97ADDDCCFF3279BFF7BFE89B658385"
KEYRING_SHA256="601383120279e5d6f0bd71e63ce4cbe3f12fcab4aeb0695d48b7525c3606ae23"

die() { echo "install.sh: $*" >&2; exit 1; }

# ---- preflight ----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root (pipe to 'sudo sh', not 'sh')"
command -v apt-get >/dev/null 2>&1 || die "this repository is Debian/Ubuntu only (no apt-get found)"
command -v curl    >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "unsupported architecture '$ARCH' (this repo builds amd64 and arm64)" ;;
esac

# ---- fetch and verify the signing key -----------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE_URL/jvs-archive-keyring.gpg" -o "$TMP/keyring.gpg" \
  || die "could not download the signing key from $BASE_URL"

got_sha="$(sha256sum "$TMP/keyring.gpg" | cut -d' ' -f1)"
if [ "$got_sha" != "$KEYRING_SHA256" ]; then
  die "signing key checksum mismatch.
  expected: $KEYRING_SHA256
  got     : $got_sha
This means the key served does not match the one this script was built to
trust. Do not proceed. Re-download install.sh; if it persists, something is
wrong upstream."
fi

# Belt and braces: if gpg is available, check the fingerprint too. Absence of
# gpg is not fatal — the checksum above is the binding check.
if command -v gpg >/dev/null 2>&1; then
  got_fpr="$(gpg --show-keys --with-colons "$TMP/keyring.gpg" 2>/dev/null \
             | awk -F: '/^fpr:/{print $10; exit}')"
  [ "$got_fpr" = "$KEY_FINGERPRINT" ] \
    || die "signing key fingerprint mismatch: expected $KEY_FINGERPRINT, got ${got_fpr:-none}"
fi

install -o root -g root -m 0644 "$TMP/keyring.gpg" "$KEYRING"

# ---- write the sources file ---------------------------------------------
# deb822 format. apt-key has been removed from modern Debian and Ubuntu;
# Signed-By pointing at a keyring file is the supported mechanism.
cat > "$SOURCES" <<EOF
Types: deb
URIs: $BASE_URL
Suites: $SUITE
Components: $COMPONENT
Architectures: $ARCH
Signed-By: $KEYRING
EOF
chmod 0644 "$SOURCES"

echo "install.sh: configured $BASE_URL ($SUITE/$COMPONENT, $ARCH)"
apt-get update -o Dir::Etc::sourcelist="$SOURCES" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0

cat <<EOF

The jvs.sh repository is configured. Install something with:

  sudo apt install hello-jvs

To remove the repository later:

  sudo rm $SOURCES $KEYRING && sudo apt update
EOF
