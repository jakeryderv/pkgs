# Entry points for the pipeline. Every target is a thin wrapper over a script
# in scripts/ -- the scripts hold all behavior, run identically outside make,
# and are what CI runs. This file is the index, not the logic.
#
# Generated output lands under PKGS_OUT, outside the working tree, so nothing
# a build produces ever appears in the repository. Override per invocation:
#
#   make repo PKGS_OUT=/somewhere/else

PKGS_OUT ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/pkgs-jvs
export PKGS_OUT

.PHONY: build repo verify test-repo test-rotation lint publish sync cache-rules clean toolchain

# ---- toolchain container ---------------------------------------------------
# The build chain needs Debian's packaging tools, which a macOS or Windows
# host does not have. When the host lacks dpkg-deb -- or PKGS_CONTAINED=1
# forces it -- the build targets re-enter this same Makefile inside the
# toolchain image, where the tools exist and the scripts run unchanged.
#
# Only the build targets are wrapped. Verification drives docker itself, and
# nesting docker inside docker buys nothing but a mounted socket. Trust
# operations (publish, sync) never enter a container at all.
#
# --user maps to the caller so everything under PKGS_OUT stays theirs, and
# HOME=/tmp keeps gpg from wanting a passwd entry for that uid.
TOOLCHAIN_IMAGE ?= pkgs-toolchain
NEED_CONTAIN := $(or $(PKGS_CONTAINED),$(shell command -v dpkg-deb >/dev/null 2>&1 || echo 1))

toolchain:
	docker build -q -t $(TOOLCHAIN_IMAGE) docker/toolchain >/dev/null

ifeq ($(strip $(NEED_CONTAIN)),)
## build: local packages -> dist/, pinned release assets -> vendor/
build:
	./scripts/build-deb.sh
	./scripts/fetch-releases.sh

## repo: assemble and sign the apt tree (needs a signing key in GNUPGHOME)
repo: build
	./scripts/build-repo.sh
else
# PKGS_CONTAINED is deliberately not forwarded: inside the image the tools
# exist, so the inner make takes the native branch instead of recursing.
build repo: toolchain
	mkdir -p "$(PKGS_OUT)"
	docker run --rm --user "$(shell id -u):$(shell id -g)" \
	  -v "$(CURDIR):/work" -v "$(PKGS_OUT):/out" -w /work \
	  -e PKGS_OUT=/out -e HOME=/tmp \
	  -e SIGNER -e ARCHES -e UPDATE_PINS -e GPG_PASSPHRASE -e SOURCE_DATE_EPOCH \
	  $(TOOLCHAIN_IMAGE) make $@
endif

## verify: everything CI's verify job proves, minus the lint
verify: test-repo test-rotation

test-repo:
	./scripts/test-repo.sh

test-rotation:
	./scripts/test-rotation.sh

## lint: exactly what CI lints -- shell first because it takes seconds
lint:
	shellcheck -S warning scripts/*.sh docker/verify/check.sh packages/*/smoke packages/*/files/usr/bin/*
	sh -n scripts/install.sh
	docker run --rm -v "$(CURDIR):/repo" -w /repo rhysd/actionlint:1.7.12

## publish: upload the built repo to R2. Production; everything else is local.
publish:
	./scripts/publish.sh

## sync: push credentials from 1Password to GitHub (load .env first)
sync:
	./scripts/sync-secrets.sh

## cache-rules: report drift against cloudflare/cache-rules.json
cache-rules:
	./scripts/apply-cache-rules.sh

clean:
	rm -rf "$(PKGS_OUT)"
