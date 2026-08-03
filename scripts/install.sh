#!/bin/sh
# Configure the jvs.sh apt repository.
#
#   curl -fsSL https://pkgs.jvs.sh/install.sh | sudo sh
#
# Idempotent: safe to re-run.
#
# This installs the jvs-archive-keyring package, which owns both the signing
# key and the apt sources entry. Everything after this point -- including a
# future change of signing key -- arrives through apt upgrade like any other
# update, so nobody has to re-run this script.
#
# The pin below is rewritten by scripts/build-repo.sh (UPDATE_PINS=1) and
# checked on every build, so it cannot silently drift from the real artifact.
set -eu

BASE_URL="${JVS_BASE_URL:-https://pkgs.jvs.sh}"
KEYRING_DEB_SHA256="3b020c09143bd1405bfbf3afb11cbd8d2506c8f901e974de5b835752e033189d"

SOURCES=/etc/apt/sources.list.d/jvs.sources
KEYRING=/usr/share/keyrings/jvs-archive-keyring.gpg

die() { echo "install.sh: $*" >&2; exit 1; }

# ---- preflight ----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root (pipe to 'sudo sh', not 'sh')"
command -v apt-get   >/dev/null 2>&1 || die "this repository is Debian/Ubuntu only (no apt-get found)"
command -v dpkg      >/dev/null 2>&1 || die "dpkg is required"
command -v curl      >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "unsupported architecture '$ARCH' (this repo builds amd64 and arm64)" ;;
esac

# ---- fetch and verify the keyring package -------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE_URL/jvs-archive-keyring.deb" -o "$TMP/keyring.deb" \
  || die "could not download the keyring package from $BASE_URL"

got="$(sha256sum "$TMP/keyring.deb" | cut -d' ' -f1)"
if [ "$got" != "$KEYRING_DEB_SHA256" ]; then
  die "keyring package checksum mismatch.
  expected: $KEYRING_DEB_SHA256
  got     : $got
The package served does not match what this script was built to trust. Do
not proceed. Re-download install.sh; if it persists, something is wrong
upstream."
fi

# An earlier version of this script wrote these files directly, so they may
# exist without belonging to any package. Clear them so dpkg owns them.
dpkg -S "$SOURCES" >/dev/null 2>&1 || rm -f "$SOURCES"
dpkg -S "$KEYRING" >/dev/null 2>&1 || rm -f "$KEYRING"

dpkg -i "$TMP/keyring.deb" >/dev/null || die "failed to install the keyring package"

echo "install.sh: installed jvs-archive-keyring, configured $BASE_URL"
apt-get update -o Dir::Etc::sourcelist="$SOURCES" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0

cat <<EOF

The jvs.sh repository is configured. Install something with:

  sudo apt install hello-jvs

Key updates now arrive automatically via apt upgrade. To remove the
repository:

  sudo apt remove jvs-archive-keyring && sudo apt update
EOF
