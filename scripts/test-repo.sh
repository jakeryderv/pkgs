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
cleanup() { kill "$HTTPD" 2>/dev/null || true; rm -rf "$DECOY" "$REPO/.wrong-keyring.gpg"; }
trap cleanup EXIT
sleep 1

run_in() { # image, keyring-file-in-repo, expect-success(0/1)
  local image="$1" keyring="$2" expect="$3" rc=0
  docker run --rm --network host -v "$REPO:/srv/repo:ro" "$image" bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/apt/sources.list.d.bak
mv /etc/apt/sources.list.d/* /etc/apt/sources.list.d.bak/ 2>/dev/null || true
: > /etc/apt/sources.list 2>/dev/null || true
install -D -m 0644 /srv/repo/$keyring /usr/share/keyrings/jvs-archive-keyring.gpg
cat > /etc/apt/sources.list.d/jvs.sources <<EOF
Types: deb
URIs: http://127.0.0.1:$PORT
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/jvs-archive-keyring.gpg
EOF
apt-get update
apt-get install -y hello-jvs
hello-jvs
" >/dev/null 2>&1 || rc=$?

  if [ "$expect" -eq 0 ] && [ "$rc" -eq 0 ]; then
    echo "  PASS  $image installs"
  elif [ "$expect" -ne 0 ] && [ "$rc" -ne 0 ]; then
    echo "  PASS  $image correctly rejects the wrong key (exit $rc)"
  else
    echo "  FAIL  $image: expected $( [ "$expect" -eq 0 ] && echo success || echo failure ), got exit $rc" >&2
    return 1
  fi
}

fail=0
for img in $IMAGES; do run_in "$img" jvs-archive-keyring.gpg 0 || fail=1; done
run_in "${IMAGES%% *}" .wrong-keyring.gpg 1 || fail=1

[ "$fail" -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED" >&2; exit 1; }
