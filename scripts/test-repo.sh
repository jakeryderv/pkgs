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
REPO="$ROOT/repo"
PORT="${PORT:-8899}"
IMAGES="${IMAGES:-debian:stable ubuntu:24.04}"

[ -d "$REPO" ] || { echo "ERROR: no repo/ — run build-repo.sh first" >&2; exit 1; }

# Install every package the index advertises, not just the smoke package.
# A package that is built and published but never installed in a test can be
# broken -- missing file, unsatisfiable dependency -- with everything green.
PKGS="$(awk '/^Package:/{print $2}' "$REPO/dists/stable/main/binary-amd64/Packages" | sort -u | tr '\n' ' ')"
[ -n "$PKGS" ] || { echo "ERROR: no packages in the index" >&2; exit 1; }
echo "  packages under test: $PKGS"

# Decoy key for the negative test, in its own keyring so it can never be
# confused with the real signing key.
DECOY="$ROOT/.decoy-gnupg"
rm -rf "$DECOY"; mkdir -p "$DECOY"; chmod 700 "$DECOY"
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
run_in() { # image, keyring-file-in-repo, expect-success(0/1)
  local image="$1" keyring="$2" expect="$3" rc=0
  docker run --rm -i --network host \
    -v "$REPO:/srv/repo:ro" -v "$ROOT/packages:/srv/packages:ro" \
    -e "KEYRING=$keyring" -e "PORT=$PORT" -e "PKGS=$PKGS" \
    -e DEBIAN_FRONTEND=noninteractive \
    "$image" bash -s >"$LOG" 2>&1 <<'CONTAINER' || rc=$?
set -e
mkdir -p /etc/apt/sources.list.d.bak
mv /etc/apt/sources.list.d/* /etc/apt/sources.list.d.bak/ 2>/dev/null || true
: > /etc/apt/sources.list 2>/dev/null || true
install -D -m 0644 "/srv/repo/$KEYRING" /usr/share/keyrings/jvs-archive-keyring.gpg

# printf rather than a heredoc: this script is itself being read from stdin,
# and a nested heredoc reads from that same stream.
printf 'Types: deb\nURIs: http://127.0.0.1:%s\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/jvs-archive-keyring.gpg\n' \
  "$PORT" > /etc/apt/sources.list.d/jvs.sources

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
    echo "  PASS  $image installs ($(awk '/smoke test\(s\) passed/{print $2}' "$LOG") smoke test(s))"
  elif [ "$expect" -ne 0 ] && [ "$rc" -ne 0 ]; then
    echo "  PASS  $image correctly rejects the wrong key (exit $rc)"
  else
    echo "  FAIL  $image: expected $( [ "$expect" -eq 0 ] && echo success || echo failure ), got exit $rc" >&2
    echo "  ---- last 30 lines ----" >&2
    tail -30 "$LOG" >&2
    return 1
  fi
}

fail=0
for img in $IMAGES; do run_in "$img" jvs-archive-keyring.gpg 0 || fail=1; done
run_in "${IMAGES%% *}" .wrong-keyring.gpg 1 || fail=1

[ "$fail" -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED" >&2; exit 1; }
