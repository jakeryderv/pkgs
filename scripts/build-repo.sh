#!/usr/bin/env bash
# Assemble and sign the apt repository from the .deb files in dist/.
#
# Env:
#   SIGNER      uid of the signing key            (default: contact@jvs.sh)
#   ARCHES      space-separated list              (default: "amd64 arm64")
#   GNUPGHOME   keyring to sign from              (default: gnupg/ under PKGS_OUT)
#   UPDATE_PINS set to 1 to rewrite the key pins in scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shared output root -- see build-deb.sh for why this is outside the tree.
OUT="${PKGS_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/pkgs-jvs}"
DIST="$OUT/dist"
VENDOR="$OUT/vendor"
REPO="$OUT/repo"
SIGNER="${SIGNER:-pkgs@jvs.sh}"
ARCHES="${ARCHES:-amd64 arm64}"
SUITE=stable
COMPONENT=main
export GNUPGHOME="${GNUPGHOME:-$OUT/gnupg}"

compgen -G "$DIST/*.deb" >/dev/null || compgen -G "$VENDOR/*.deb" >/dev/null || {
  echo "ERROR: no .deb files in $DIST or $VENDOR — run build-deb.sh (and" >&2
  echo "fetch-releases.sh, if any package declares a release) first" >&2
  exit 1
}

rm -rf "$REPO"
mkdir -p "$REPO/dists/$SUITE/$COMPONENT"

# ---- pool ---------------------------------------------------------------
# Debian convention: pool/<component>/<first letter of source>/<source>/
#
# Two sources, and the distinction stops here: dist/ is what build-deb.sh
# built from packages/, vendor/ is what fetch-releases.sh pulled from GitHub
# Releases. The index does not care which is which.
shopt -s nullglob
for deb in "$DIST"/*.deb "$VENDOR"/*.deb; do
  name="$(dpkg-deb -f "$deb" Package)"
  letter="${name:0:1}"
  dest="$REPO/pool/$COMPONENT/$letter/$name"
  mkdir -p "$dest"
  # Same filename from both sources would mean one silently winning. It
  # cannot happen by construction -- a package is built or fetched, never
  # both -- so if it does, something is wrong enough to stop for.
  [ -e "$dest/$(basename "$deb")" ] && {
    echo "ERROR: $(basename "$deb") appears in both dist/ and vendor/" >&2
    exit 1
  }
  cp "$deb" "$dest/"
done

# Every package that declares a release must actually be present. Otherwise a
# forgotten fetch-releases.sh silently publishes a repository missing one of
# its packages, and every other check stays green.
for def in "$ROOT"/packages/*/; do
  [ -f "$def/release" ] || continue
  name="$(basename "$def")"
  [ -d "$REPO/pool/$COMPONENT/${name:0:1}/$name" ] || {
    echo "ERROR: $name declares a release but nothing in vendor/ provides it." >&2
    echo "Run ./scripts/fetch-releases.sh" >&2
    exit 1
  }
done

# ---- per-architecture Packages indexes ----------------------------------
# dpkg-scanpackages --arch correctly includes Architecture: all packages in
# every per-arch index, which a plain apt-ftparchive run would not.
cd "$REPO"
for arch in $ARCHES; do
  outdir="dists/$SUITE/$COMPONENT/binary-$arch"
  mkdir -p "$outdir"
  dpkg-scanpackages --arch "$arch" pool 2>/dev/null > "$outdir/Packages"
  gzip -9kf "$outdir/Packages"
  count=$(grep -c '^Package:' "$outdir/Packages" || true)
  echo "  $arch: $count package(s)"
done

# ---- Release ------------------------------------------------------------
# Written to a temp path first: apt-ftparchive hashes every file in the
# directory it is pointed at, and would otherwise hash a stale Release.
release_tmp="$(mktemp)"
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="jvs.sh" \
  -o APT::FTPArchive::Release::Label="jvs.sh" \
  -o APT::FTPArchive::Release::Suite="$SUITE" \
  -o APT::FTPArchive::Release::Codename="$SUITE" \
  -o APT::FTPArchive::Release::Architectures="$ARCHES" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="jvs.sh package repository" \
  release "dists/$SUITE" > "$release_tmp"
mv "$release_tmp" "dists/$SUITE/Release"

# ---- signatures ---------------------------------------------------------
# A real signing key has a passphrase. Interactively gpg-agent supplies it;
# in CI there is no agent and no tty, so GPG_PASSPHRASE is fed through
# loopback pinentry instead. Without this, CI hangs or fails on the prompt.
gpg_sign=(gpg --batch --yes --default-key "$SIGNER")
if [ -n "${GPG_PASSPHRASE:-}" ]; then
  gpg_sign+=(--pinentry-mode loopback --passphrase "$GPG_PASSPHRASE")
fi

"${gpg_sign[@]}" --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
"${gpg_sign[@]}" -abs       -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"

# ---- rotation deadlock guard --------------------------------------------
# Installed machines trust exactly the keys in the shipped keyring. Signing
# with a key that is not in it means they cannot verify the repository -- and
# therefore cannot fetch the keyring update that would teach them the new
# key. That is unrecoverable without every user re-bootstrapping by hand, so
# refuse rather than allow it.
SHIPPED_KEYRING="$ROOT/packages/jvs-archive-keyring/files/usr/share/keyrings/jvs-archive-keyring.gpg"
[ -f "$SHIPPED_KEYRING" ] || { echo "ERROR: no shipped keyring at $SHIPPED_KEYRING" >&2; exit 1; }

FPR="$(gpg --with-colons --fingerprint "$SIGNER" | awk -F: '/^fpr:/{print $10; exit}')"
if ! gpg --show-keys --with-colons "$SHIPPED_KEYRING" \
     | awk -F: '/^fpr:/{print $10}' | grep -qx "$FPR"; then
  echo "ERROR: signing key $FPR is not in the shipped keyring." >&2
  echo "Installed machines would be unable to verify this repository, and" >&2
  echo "unable to fetch the update that would fix it." >&2
  echo "Add it first:  ./scripts/update-keyring.sh <old-key> $SIGNER" >&2
  echo "then bump packages/jvs-archive-keyring/manifest and publish that." >&2
  exit 1
fi

# ---- bootstrap artifacts ------------------------------------------------
# The published keyring is the committed one, not a fresh export of whatever
# key is signing. During a rotation those differ, and the committed file is
# the reviewed source of truth.
cp "$SHIPPED_KEYRING" "$REPO/jvs-archive-keyring.gpg"

# Stable, version-independent path so install.sh does not need to know the
# current version. Not under pool/, so it is not edge-cached.
keyring_deb="$(ls "$DIST"/jvs-archive-keyring_*_all.deb 2>/dev/null | head -1)"
[ -n "$keyring_deb" ] || { echo "ERROR: no jvs-archive-keyring .deb in $DIST" >&2; exit 1; }
cp "$keyring_deb" "$REPO/jvs-archive-keyring.deb"

SHA="$(sha256sum "$REPO/jvs-archive-keyring.deb" | cut -d' ' -f1)"

if [ "${UPDATE_PINS:-0}" = "1" ]; then
  sed -i "s|^KEYRING_DEB_SHA256=.*|KEYRING_DEB_SHA256=\"$SHA\"|" "$ROOT/scripts/install.sh"
  echo "  pin updated in scripts/install.sh"
else
  # install.sh pins the exact bootstrap artifact it expects. Without this a
  # new machine would trust whatever the server happened to return.
  want_sha="$(awk -F'"' '/^KEYRING_DEB_SHA256=/{print $2}' "$ROOT/scripts/install.sh")"
  if [ "$want_sha" != "$SHA" ]; then
    echo "ERROR: scripts/install.sh pin does not match the keyring package." >&2
    echo "  install.sh : ${want_sha:-<unset>}" >&2
    echo "  built      : $SHA" >&2
    echo "Re-run with UPDATE_PINS=1 if this change is intentional." >&2
    exit 1
  fi
fi
cp "$ROOT/scripts/install.sh" "$REPO/install.sh"

echo "repo built at $REPO"
echo "  signed by : $FPR"
echo "  trusts    : $(gpg --show-keys --with-colons "$SHIPPED_KEYRING" | grep -c '^pub:') key(s)"
