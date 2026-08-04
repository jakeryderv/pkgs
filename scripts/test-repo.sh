#!/usr/bin/env bash
# Verify the locally-built repo actually installs, in real containers.
#
# The matrix lives in docker/verify/compose.yaml: a service serving the built
# tree, one client per distro x architecture installing from it, and a
# negative client proving apt rejects a wrong key. The clients are
# independent, so they run in parallel; this script builds their inputs,
# starts the topology, and holds every client to the same bar -- exited 0.
#
# The negative test matters most. A green install proves apt found the
# package; only the failure case proves the signature was checked rather
# than ignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shared output root -- see build-deb.sh for why this is outside the tree.
OUT="${PKGS_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/pkgs-jvs}"
REPO="$OUT/repo"

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

# Everything compose.yaml interpolates. Both arch lists are exported even
# when only one is under test, so the file always parses without warnings.
export VERIFY_REPO="$REPO"
export VERIFY_PACKAGES="$ROOT/packages"
export VERIFY_CHECK="$ROOT/docker/verify/check.sh"
PKGS_AMD64="$(pkgs_for amd64)"; export PKGS_AMD64
PKGS_ARM64="$(pkgs_for arm64)"; export PKGS_ARM64

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

# The profile gates the emulated services; everything else always runs.
COMPOSE=(docker compose -f "$ROOT/docker/verify/compose.yaml" -p pkgs-verify)
CLIENTS=(debian-amd64 ubuntu-amd64 wrong-key)
case " $ARCHES " in *" arm64 "*)
  COMPOSE+=(--profile arm64)
  CLIENTS+=(debian-arm64 ubuntu-arm64)
esac

# Docker's classic image store keys an image by name alone, so debian:stable
# cannot hold amd64 and arm64 at once -- letting compose pull the matrix in
# parallel races the two platforms on the same tag. Pull serially instead,
# parking each platform under its own local tag for compose to use.
for arch in $ARCHES; do
  for img in debian:stable ubuntu:24.04; do
    docker pull -q --platform "linux/$arch" "$img" >/dev/null
    docker tag "$img" "pkgs-verify/${img%%:*}:$arch"
  done
done

UP_LOG="$(mktemp)"
cleanup() {
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$DECOY" "$REPO/.wrong-keyring.gpg" "$UP_LOG"
}
trap cleanup EXIT

echo "  architectures under test: $ARCHES"
for arch in $ARCHES; do echo "  packages for $arch: $(pkgs_for "$arch")"; done

# Quiet on success, but never silent on failure -- a swallowed compose error
# reports as a bare exit 1 that says nothing about what broke.
"${COMPOSE[@]}" up -d --quiet-pull >"$UP_LOG" 2>&1 || {
  echo "ERROR: compose up failed:" >&2
  cat "$UP_LOG" >&2
  exit 1
}

# `docker wait` blocks until a container exits and prints its exit code.
# Waiting serially costs nothing -- the clients are already running in
# parallel; this loop just collects them in a fixed order.
fail=0
for svc in "${CLIENTS[@]}"; do
  cid="$("${COMPOSE[@]}" ps -aq "$svc")"
  [ -n "$cid" ] || { echo "  FAIL  $svc never started" >&2; fail=1; continue; }
  rc="$(docker wait "$cid")"
  if [ "$rc" -eq 0 ]; then
    echo "  PASS  $svc"
  else
    # Per-service logs, so parallel failures cannot interleave into mush.
    echo "  FAIL  $svc (exit $rc)" >&2
    echo "  ---- last 30 lines of $svc ----" >&2
    "${COMPOSE[@]}" logs --no-log-prefix --tail 30 "$svc" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED" >&2; exit 1; }
