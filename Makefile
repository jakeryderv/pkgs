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

.PHONY: build repo verify test-repo test-rotation lint publish sync cache-rules clean

## build: local packages -> dist/, pinned release assets -> vendor/
build:
	./scripts/build-deb.sh
	./scripts/fetch-releases.sh

## repo: assemble and sign the apt tree (needs a signing key in GNUPGHOME)
repo: build
	./scripts/build-repo.sh

## verify: everything CI's verify job proves, minus the lint
verify: test-repo test-rotation

test-repo:
	./scripts/test-repo.sh

test-rotation:
	./scripts/test-rotation.sh

## lint: exactly what CI lints -- shell first because it takes seconds
lint:
	shellcheck -S warning scripts/*.sh packages/*/smoke packages/*/files/usr/bin/*
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
