#!/usr/bin/env bash
# Runs inside each verify client container; docker/verify/compose.yaml mounts
# it. Two modes, selected by EXPECT:
#
#   ok      install every package the index advertises, run the smoke tests
#   reject  prove apt refuses the repository when the trusted keyring is the
#           wrong one -- and refuses it for the signature, not the network
#
# Inputs come through the environment (ARCH, KEYRING, PKGS, EXPECT) rather
# than arguments, because compose declares them per service.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

mkdir -p /etc/apt/sources.list.d.bak
mv /etc/apt/sources.list.d/* /etc/apt/sources.list.d.bak/ 2>/dev/null || true
: > /etc/apt/sources.list 2>/dev/null || true
install -D -m 0644 "/srv/repo/$KEYRING" /usr/share/keyrings/jvs-archive-keyring.gpg

# `repo` is the compose service serving the built tree; service DNS replaces
# the host-port dance the pre-compose version needed.
printf 'Types: deb\nURIs: http://repo\nSuites: stable\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/keyrings/jvs-archive-keyring.gpg\n' \
  "$ARCH" > /etc/apt/sources.list.d/jvs.sources

# The container must actually be the architecture under test. Under broken or
# missing emulation docker silently runs the host image instead, and the
# whole arm64 run would pass while proving nothing.
have="$(dpkg --print-architecture)"
[ "$have" = "$ARCH" ] || { echo "expected $ARCH container, got $have" >&2; exit 1; }

if [ "${EXPECT:-ok}" = "reject" ]; then
  # Exit 0 on the failure we are looking for, so the host can hold every
  # service to the same "exited 0" bar instead of special-casing this one.
  if out="$(apt-get update 2>&1)"; then
    echo "apt accepted a repository signed by a key it should not trust" >&2
    exit 1
  fi
  printf '%s\n' "$out" | grep -qiE 'not signed|NO_PUBKEY|verification failed' || {
    echo "apt failed, but for the wrong reason:" >&2
    printf '%s\n' "$out" | tail -5 >&2
    exit 1
  }
  echo "correctly rejected the wrong key"
  exit 0
fi

apt-get update
# shellcheck disable=SC2086  # PKGS is a deliberate word-split list
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
