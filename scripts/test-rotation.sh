#!/usr/bin/env bash
# Prove the signing key can be rotated without breaking installed machines.
#
# This is the scenario the keyring package exists for, and it is the one that
# cannot be checked by inspection: a machine installs while key A signs the
# repo, and must survive the switch to key B having only ever run apt.
#
#   phase 1  keyring {A}    signed A   -> machine installs, trusts A
#   phase 2  keyring {A,B}  signed A   -> machine upgrades, now trusts A and B
#   phase 3  keyring {A,B}  signed B   -> machine still works, never re-bootstrapped
#
# Phase 2 is the load-bearing step. Skipping it -- switching straight to B --
# leaves the machine unable to verify the repo and therefore unable to fetch
# the update that would fix it. build-repo.sh's guard refuses that, and this
# test confirms the supported path works.
#
# Hermetic: runs against a copy of the tree with throwaway keys, so the real
# committed keyring and signing key are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8901}"
IMAGE="${IMAGE:-debian:stable}"
CONTAINER="jvs-rotation-test"
BASE="http://127.0.0.1:$PORT"

WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ -n "${HTTPD:-}" ] && kill "$HTTPD" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cp -r "$ROOT/scripts" "$ROOT/packages" "$WORK/"

# Drop fetched packages from the copy. Rotation is about which key signs the
# repository, which has nothing to do with where a package came from -- and
# keeping them would mean this test downloads from GitHub on every run, making
# a hermetic test of signing fail whenever something unrelated is unreachable.
for def in "$WORK"/packages/*/; do
  if [ -f "$def/release" ]; then rm -rf "$def"; fi
done

mkdir -p "$WORK/gnupg"; chmod 700 "$WORK/gnupg"
export GNUPGHOME="$WORK/gnupg"

# The copied scripts write wherever PKGS_OUT points, and the caller's
# environment may aim that at a real build. Pin it inside WORK so the
# throwaway-key repo built here can never clobber one built to publish.
export PKGS_OUT="$WORK"

# Test keys. Deliberately not the real one.
for k in a b; do
  gpg --batch --quiet --generate-key /dev/stdin <<EOF
%no-protection
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Name-Real: Rotation Test Key $k
Name-Email: rot-$k@example.invalid
Expire-Date: 1d
%commit
EOF
done

# The shipped sources file points at production; aim it at the test server.
sed -i "s|^URIs: .*|URIs: $BASE|" \
  "$WORK/packages/jvs-archive-keyring/files/etc/apt/sources.list.d/jvs.sources"

# Output is captured rather than discarded. A build failing here used to
# surface as nothing but `exit 1` from whichever phase called it, which says
# nothing about what broke.
build() { # signer, keyring-manifest-version, keys...
  local signer="$1" kver="$2"; shift 2
  local log="$WORK/build.log"
  {
    "$WORK/scripts/update-keyring.sh" "$@"
    sed -i "s|^Version: .*|Version: $kver|" "$WORK/packages/jvs-archive-keyring/manifest"
    "$WORK/scripts/build-deb.sh"
    SIGNER="$signer" UPDATE_PINS=1 "$WORK/scripts/build-repo.sh"
  } >"$log" 2>&1 || {
    echo "  FAIL: build failed (signer=$signer keyring=$kver)" >&2
    echo "  ---- last 20 lines ----" >&2
    tail -20 "$log" >&2
    exit 1
  }
}

inc() { docker exec -e DEBIAN_FRONTEND=noninteractive "$CONTAINER" bash -c "$1" 2>/dev/null; }

say() { printf '\n=== %s ===\n' "$*"; }

# Assert how many keys the machine actually trusts. Counted inside the
# container, from the installed keyring -- not from what we think we shipped.
expect_keys() {
  local want="$1"
  local got
  got="$(inc 'gpg --show-keys --with-colons /usr/share/keyrings/jvs-archive-keyring.gpg | grep -c "^pub:"' || true)"
  if [ "$got" != "$want" ]; then
    echo "  FAIL: machine trusts ${got:-unknown} key(s), expected $want" >&2
    exit 1
  fi
  echo "  trusts $got key(s), keyring pkg $(inc 'dpkg -s jvs-archive-keyring | awk "/^Version:/{print \$2}"')"
}

# ---- phase 1: keyring {A}, signed by A ----------------------------------
say "phase 1: publish keyring 1.0.0 trusting A, signed by A"
build rot-a@example.invalid 1.0.0 rot-a@example.invalid
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/repo" >/dev/null 2>&1 &
HTTPD=$!
sleep 1

docker run -d --name "$CONTAINER" --network host "$IMAGE" sleep 3600 >/dev/null
inc "apt-get update -qq && apt-get install -y -qq curl gnupg >/dev/null"
inc "curl -fsSL $BASE/install.sh | JVS_BASE_URL=$BASE sh >/dev/null 2>&1"
inc "apt-get install -y -qq hello-jvs >/dev/null && hello-jvs"
expect_keys 1

# ---- phase 2: keyring {A,B}, still signed by A --------------------------
say "phase 2: publish keyring 1.1.0 trusting A and B, still signed by A"
build rot-a@example.invalid 1.1.0 rot-a@example.invalid rot-b@example.invalid
inc "apt-get update -qq && apt-get install -y -qq --only-upgrade jvs-archive-keyring >/dev/null"
expect_keys 2

# ---- phase 3: switch signing to B ---------------------------------------
say "phase 3: repo now signed by B; machine has never been re-bootstrapped"
build rot-b@example.invalid 1.1.0 rot-a@example.invalid rot-b@example.invalid
if inc "apt-get update 2>&1 | grep -qiE 'not signed|NO_PUBKEY|verification failed'"; then
  echo "  FAIL: apt rejected the repository after the key switch"; exit 1
fi
inc "apt-get install -y -qq --reinstall hello-jvs >/dev/null && hello-jvs"
echo "  PASS: machine survived the rotation using only apt"

say "rotation verified"
