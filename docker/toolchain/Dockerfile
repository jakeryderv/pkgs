# The Debian packaging toolchain the build chain needs and a macOS or Windows
# host does not have: dpkg-deb (build-deb.sh), dpkg-scanpackages and
# apt-ftparchive (build-repo.sh), gnupg (signing), curl (fetch-releases.sh),
# and make so the Makefile can re-enter itself inside the container.
#
# The base matches what CI publishes from (ubuntu-latest), NOT debian:stable,
# and that choice is load-bearing. A .deb's bytes depend on the compressor
# library's exact output, and zstd does not promise bitstream stability
# across versions -- dpkg 1.22.22 on Debian trixie produces different bytes
# than 1.22.6 here for identical input, which publish.sh's immutability
# guard would refuse. This image exists to reproduce the publisher's bytes,
# so it tracks the publisher's environment.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      make dpkg-dev apt-utils gnupg curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
