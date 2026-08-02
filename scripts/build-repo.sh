#!/usr/bin/env bash
# Assemble and sign the apt repository from the .deb files in dist/.
#
# Env:
#   SIGNER      uid of the signing key            (default: contact@jvs.sh)
#   ARCHES      space-separated list              (default: "amd64 arm64")
#   GNUPGHOME   keyring to sign from              (default: gnupg/ in repo root)
#   UPDATE_PINS set to 1 to rewrite the key pins in scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
REPO="$ROOT/repo"
SIGNER="${SIGNER:-pkgs@jvs.sh}"
ARCHES="${ARCHES:-amd64 arm64}"
SUITE=stable
COMPONENT=main
export GNUPGHOME="${GNUPGHOME:-$ROOT/gnupg}"

compgen -G "$DIST/*.deb" >/dev/null || { echo "ERROR: no .deb files in $DIST — run build-deb.sh first" >&2; exit 1; }

rm -rf "$REPO"
mkdir -p "$REPO/dists/$SUITE/$COMPONENT"

# ---- pool ---------------------------------------------------------------
# Debian convention: pool/<component>/<first letter of source>/<source>/
for deb in "$DIST"/*.deb; do
  name="$(dpkg-deb -f "$deb" Package)"
  letter="${name:0:1}"
  dest="$REPO/pool/$COMPONENT/$letter/$name"
  mkdir -p "$dest"
  cp "$deb" "$dest/"
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
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="jvs.sh" \
  -o APT::FTPArchive::Release::Label="jvs.sh" \
  -o APT::FTPArchive::Release::Suite="$SUITE" \
  -o APT::FTPArchive::Release::Codename="$SUITE" \
  -o APT::FTPArchive::Release::Architectures="$ARCHES" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="jvs.sh package repository" \
  release "dists/$SUITE" > "$ROOT/.Release.tmp"
mv "$ROOT/.Release.tmp" "dists/$SUITE/Release"

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

# ---- public keyring + install.sh ----------------------------------------
gpg --export "$SIGNER" > "$REPO/jvs-archive-keyring.gpg"
cp "$ROOT/scripts/install.sh" "$REPO/install.sh"

FPR="$(gpg --with-colons --fingerprint "$SIGNER" | awk -F: '/^fpr:/{print $10; exit}')"
SHA="$(sha256sum "$REPO/jvs-archive-keyring.gpg" | cut -d' ' -f1)"

if [ "${UPDATE_PINS:-0}" = "1" ]; then
  sed -i "s|^KEY_FINGERPRINT=.*|KEY_FINGERPRINT=\"$FPR\"|" "$ROOT/scripts/install.sh"
  sed -i "s|^KEYRING_SHA256=.*|KEYRING_SHA256=\"$SHA\"|"   "$ROOT/scripts/install.sh"
  cp "$ROOT/scripts/install.sh" "$REPO/install.sh"
  echo "  pins updated in scripts/install.sh"
else
  # install.sh pins the key it expects. If they drift, every new machine would
  # silently trust whatever key the repo happens to serve — so fail loudly.
  want_fpr="$(awk -F'"' '/^KEY_FINGERPRINT=/{print $2}' "$ROOT/scripts/install.sh")"
  want_sha="$(awk -F'"' '/^KEYRING_SHA256=/{print $2}'  "$ROOT/scripts/install.sh")"
  if [ "$want_fpr" != "$FPR" ] || [ "$want_sha" != "$SHA" ]; then
    echo "ERROR: scripts/install.sh pins do not match the signing key." >&2
    echo "  install.sh fingerprint: ${want_fpr:-<unset>}" >&2
    echo "  signing key            : $FPR" >&2
    echo "Re-run with UPDATE_PINS=1 if this key change is intentional." >&2
    exit 1
  fi
fi

echo "repo built at $REPO"
echo "  signed by : $FPR"
