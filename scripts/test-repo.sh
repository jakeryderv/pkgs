#!/usr/bin/env bash
# Verify the locally-built repo actually installs, in real containers.
#
# Runs three checks:
#   1. install succeeds on Debian
#   2. install succeeds on Ubuntu
#   3. install FAILS when the client trusts the wrong key
#
# The third matters most. A green install proves apt found the package; only
# the failure case proves the signature was checked rather than ignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shared output root -- see build-deb.sh for why this is outside the tree.
OUT="${PKGS_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/pkgs-jvs}"
REPO="$OUT/repo"
PORT="${PORT:-8899}"
IMAGES="${IMAGES:-debian:stable ubuntu:24.04}"

# Architectures to install under. Defaults to amd64 alone, because arm64 needs
# binfmt emulation that a developer machine will not usually have; CI sets up
# QEMU and asks for both. Without this the arm64 index is published having
# never had anything installed from it.
ARCHES="${TEST_ARCHES:-amd64}"

[ -d "$REPO" ] || { echo "ERROR: no repo at $REPO — run build-repo.sh first" >&2; exit 1; }

# Install every package the index advertises for that architecture, not just
# the smoke package -- a package built and published but never installed can be
# broken (missing file, unsatisfiable dependency) with everything else green.
#
# Read per-architecture rather than once from amd64: the indexes are identical
# only while every package is Architecture: all, and the first genuinely
# per-arch package would otherwise be tested against the wrong list.
pkgs_for() { # arch
  local idx="$REPO/dists/stable/main/binary-$1/Packages"
  [ -f "$idx" ] || { echo "ERROR: no index for $1" >&2; return 1; }
  awk '/^Package:/{print $2}' "$idx" | sort -u | tr '\n' ' '
}

# Decoy key for the negative test, in its own throwaway keyring so it can
# never be confused with the real signing key.
DECOY="$(mktemp -d)"
GNUPGHOME="$DECOY" gpg --batch --quiet --generate-key /dev/stdin <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Name-Real: Decoy (negative test only)
Name-Email: decoy@example.invalid
Expire-Date: 1d
%commit
EOF
GNUPGHOME="$DECOY" gpg --export decoy@example.invalid > "$REPO/.wrong-keyring.gpg"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" >/dev/null 2>&1 &
HTTPD=$!
# Container output is captured rather than discarded. A failing smoke test
# reports a bare exit code otherwise, which says nothing about what broke.
LOG="$(mktemp)"
cleanup() {
  kill "$HTTPD" 2>/dev/null || true
  rm -rf "$DECOY" "$REPO/.wrong-keyring.gpg" "$LOG"
}
trap cleanup EXIT
sleep 1

# The container script is fed on stdin and takes its inputs through the
# environment, rather than being interpolated into a `bash -c` string. The
# smoke loop below needs its variables expanded inside the container, and
# escaping those through a host-side double-quoted string is unreadable.
#
# packages/ is mounted so smoke tests can run without being baked into the
# .deb: a smoke test asserts things a user should never have shipped to them.
run_in() { # image, arch, keyring-file-in-repo, expect-success(0/1)
  local image="$1" arch="$2" keyring="$3" expect="$4" rc=0 pkgs
  pkgs="$(pkgs_for "$arch")" || return 1
  docker run --rm -i --network host --platform "linux/$arch" \
    -v "$REPO:/srv/repo:ro" -v "$ROOT/packages:/srv/packages:ro" \
    -e "KEYRING=$keyring" -e "PORT=$PORT" -e "PKGS=$pkgs" -e "ARCH=$arch" \
    -e DEBIAN_FRONTEND=noninteractive \
    "$image" bash -s >"$LOG" 2>&1 <<'CONTAINER' || rc=$?
set -e
mkdir -p /etc/apt/sources.list.d.bak
mv /etc/apt/sources.list.d/* /etc/apt/sources.list.d.bak/ 2>/dev/null || true
: > /etc/apt/sources.list 2>/dev/null || true
install -D -m 0644 "/srv/repo/$KEYRING" /usr/share/keyrings/jvs-archive-keyring.gpg

# printf rather than a heredoc: this script is itself being read from stdin,
# and a nested heredoc reads from that same stream.
printf 'Types: deb\nURIs: http://127.0.0.1:%s\nSuites: stable\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/keyrings/jvs-archive-keyring.gpg\n' \
  "$PORT" "$ARCH" > /etc/apt/sources.list.d/jvs.sources

# The container must actually be the architecture we are testing. Under broken
# or missing emulation docker silently runs the host image instead, and the
# whole arm64 run would pass while proving nothing.
have="$(dpkg --print-architecture)"
[ "$have" = "$ARCH" ] || { echo "expected $ARCH container, got $have" >&2; exit 1; }

apt-get update
apt-get install -y $PKGS

# Installing a package proves dpkg accepted it, not that it works. Run every
# smoke test belonging to a package that actually got installed.
#
# PKG_VERSION comes from dpkg rather than from the manifest on the host, so a
# smoke test compares the binary against the version apt really installed.
ran=0
for def in /srv/packages/*/; do
  name="$(basename "$def")"
  [ -f "$def/smoke" ] || continue
  dpkg -s "$name" >/dev/null 2>&1 || continue
  echo "--- smoke: $name ---"
  PKG_NAME="$name" \
  PKG_VERSION="$(dpkg-query -W -f='${Version}' "$name")" \
    sh "$def/smoke"
  ran=$((ran+1))
done
echo "--- $ran smoke test(s) passed ---"
CONTAINER

  if [ "$expect" -eq 0 ] && [ "$rc" -eq 0 ]; then
    echo "  PASS  $image/$arch installs ($(awk '/smoke test\(s\) passed/{print $2}' "$LOG") smoke test(s))"
  elif [ "$expect" -ne 0 ] && [ "$rc" -ne 0 ]; then
    echo "  PASS  $image/$arch correctly rejects the wrong key (exit $rc)"
  else
    echo "  FAIL  $image/$arch: expected $( [ "$expect" -eq 0 ] && echo success || echo failure ), got exit $rc" >&2
    echo "  ---- last 30 lines ----" >&2
    tail -30 "$LOG" >&2
    return 1
  fi
}

echo "  architectures under test: $ARCHES"
fail=0
for arch in $ARCHES; do
  echo "  packages for $arch: $(pkgs_for "$arch")"
  for img in $IMAGES; do run_in "$img" "$arch" jvs-archive-keyring.gpg 0 || fail=1; done
done

# One negative test is enough: it proves apt verifies signatures at all, which
# is not an architecture-specific property.
run_in "${IMAGES%% *}" "${ARCHES%% *}" .wrong-keyring.gpg 1 || fail=1

[ "$fail" -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED" >&2; exit 1; }
