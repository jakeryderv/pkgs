# Adding a package

Simple, self-contained packages live here:

```
packages/<name>/
  manifest          Debian control fields
  files/            tree to install, rooted at /
  scripts/          optional postinst, prerm, …
  smoke             optional; run in the container after install
```

Anything with a real build should produce its `.deb` in its own repo, publish
it to a GitHub Release, and declare a `release` file instead — the indexer
does not care where a `.deb` came from.

## release

A package is either built here or fetched, never both. A fetched one replaces
`manifest` and `files/` with a `release`:

```
packages/<name>/
  release           where to fetch the .deb, and its pinned hashes
  smoke             optional; same convention as a local package
```

```
Repo:   owner/name
Tag:    v1.2.0
Asset:  name_1.2.0_amd64.deb  sha256:9f2a…
Asset:  name_1.2.0_arm64.deb  sha256:c418…
```

`./scripts/fetch-releases.sh` downloads these into `vendor/` and verifies each
against its pin. `--update` re-pins to whatever upstream currently serves,
which is the only way a hash changes — mirroring `UPDATE_PINS=1` on
`build-repo.sh`. It takes an optional package name, `--update <name>`, which
the automation below relies on: re-pinning everything to bump one package
would quietly accept a change in any of the others, which is precisely the
tampering the pins refuse.

The pins are the point. A GitHub release asset is mutable: a tag can be
deleted and re-pushed, an asset replaced. An unpinned fetch therefore trusts
whatever the server returns on the day CI happens to run, which is the same
problem `install.sh`'s keyring pin exists to solve
(see [design](design.md#why-installsh-pins-the-artifact)) and gets the same
fail-closed answer.

They also buy back reproducibility. A local package gets byte-stability from
`SOURCE_DATE_EPOCH`; a fetched one is never rebuilt, so pinning its bytes is
what keeps `publish.sh`'s immutability guard meaningful.

This is also how a second architecture arrives. Local packages are all
`Architecture: all`, so `binary-amd64` and `binary-arm64` are currently
identical; a fetched package can declare a real per-arch asset for each, and
`dpkg-scanpackages` indexes them where they belong with no change here.

A `release` file may also declare more than one version, which is how
per-package retention would be expressed if ever wanted — see
[design](design.md#only-current-versions-are-installable) for the policy and
its costs.

## Releasing a fetched package

Tag it upstream. That is the whole workflow — nothing here is edited by hand.

`.github/workflows/autopin.yml` polls each declared repository daily. When a
newer tag appears it takes the asset names from the release, re-pins the
hashes, verifies build provenance, and opens a PR that auto-merges once
`verify` passes. Merging publishes, so a green tag reaches the repository
with no clicks here at all. A tool repo that wants same-minute pickup rather
than next-morning can also trigger the run directly — the tokens involved,
and why polling is the default, are covered in [ci](ci.md#autopin).

Provenance is checked with `gh attestation verify`, which proves the artifact
was built by that repository's own release workflow rather than uploaded by
someone who reached the repo. That is a different guarantee from the hash, and
both are kept: the pin says these bytes have not moved since we looked, the
attestation says who built them. A package whose upstream does not attest
cannot be picked up automatically, which is intended.

`fetch-releases.sh` prunes `vendor/` of anything no longer declared. Without
that, retagging a package would leave its old `.deb` behind to be swept back
into the pool — the stale-artifact failure `build-deb.sh` wipes `dist/` to
prevent.

## smoke

Installing a package proves dpkg accepted it, not that it works. `test-repo.sh`
runs `packages/<name>/smoke` inside the container after install, for every
package that has one, and fails the build if it exits non-zero.

It runs with `PKG_NAME` and `PKG_VERSION` set from dpkg's view of the
installed package, so assertions are made against what apt really put on disk
rather than against whatever the builder believed. `termtest`'s smoke test
compares the two, which now spans repositories: its upstream tag, the control
version of the `.deb` that tag produced, and the version the binary reports
all have to agree, and nothing but this notices if they stop.

There is no tty, so `smoke` should stick to what works headless. It is not
shipped in the `.deb`; `build-deb.sh` only copies `files/` and `scripts/`.

A convention rather than a list in `test-repo.sh` on purpose: a new package
should be tested because it exists, not because someone remembered to go and
add it. `termtest` shipped for a release installed-but-never-run for exactly
that reason.
