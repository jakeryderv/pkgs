# Design

Why the system is shaped the way it is. The scripts' header comments are the
reference for *how* each piece works; this records the decisions that would
otherwise have to be re-derived — most of them made because of a specific
failure that actually happened.

## The build system

```
./scripts/build-deb.sh       # packages/ -> dist/          (local, offline)
./scripts/fetch-releases.sh  # GitHub Releases -> vendor/  (network, pinned)
./scripts/build-repo.sh      # dist/ + vendor/ -> repo/, signed
```

Everything generated lands under `PKGS_OUT` — `~/.cache/pkgs-jvs` unless
overridden — so a build never leaves artifacts in the working tree. `dist/`,
`vendor/` and `repo/` throughout these documents mean the directories under
that root. The only tracked files a script ever writes are deliberate:
`update-keyring.sh` regenerates the shipped keyring, and `build-repo.sh`
rewrites the `install.sh` pin under `UPDATE_PINS=1` — both changes you review
and commit.

The `Makefile` is an index over the same scripts, not a second
implementation. Scripts hold all behavior and run identically without it.

The build targets do not require a Debian host. When the machine lacks
`dpkg-deb` — macOS, Windows — `make build` re-enters itself inside a
toolchain container (`docker/toolchain/`) carrying the packaging tools, with
the same scripts unchanged and output still landing under `PKGS_OUT`.
`PKGS_CONTAINED=1` forces the container on any host, which is also the way
to get a bit-identical build environment everywhere. Verification always
runs on the host, since it drives docker itself; trust operations never
enter a container at all.

`build-deb.sh` and `fetch-releases.sh` are independent and can run in either
order. `build-deb.sh` never touches the network — a GitHub outage should not
be able to break a build of packages that are entirely local — and
`fetch-releases.sh` is offline too once `vendor/` is warm, since a cached
asset matching its pin is not re-downloaded.

Three guards will stop you, all deliberately:

- `build-repo.sh` refuses to run if the key pins in `scripts/install.sh` do
  not match the signing key. Pass `UPDATE_PINS=1` when a key change is
  intentional.
- `fetch-releases.sh` refuses to accept an asset whose hash differs from its
  pin. Pass `--update` when the change is intentional.
- `publish.sh` refuses to upload a `pool/` object whose content differs from
  what is already in the bucket. See below.

## Versioning: same version means same bytes

A `pool/` path is cached at the edge for a year. Republishing a different
build under the same filename means apt fetches the stale `.deb`, its hash
disagrees with `Packages`, and the install fails — for a year, on every
machine. This is not hypothetical; it happened, and `publish.sh`'s guard
exists because of it.

So: **any content change requires a version bump.** New version, new
filename, new URL, no stale cache.

The counterpart is that builds are reproducible. `dpkg-deb` embeds mtimes,
so `build-deb.sh` pins `SOURCE_DATE_EPOCH` and the staged tree's mtimes to a
fixed constant. Rebuilding an unchanged package therefore produces
byte-identical output, and CI can republish without the guard tripping on
noise. Bytes change when the package changes, and not otherwise.

The constant is deliberate. Deriving it from the last commit touching a
package reads better but breaks under `actions/checkout`, which clones at
depth 1: when HEAD does not touch the package, `git log -- packages/<name>`
returns nothing and the epoch silently changes, so CI could only publish on
commits that happened to modify the package. Build output must depend on
package contents alone — not on repository history, checkout depth, or who
built it.

The compressor is pinned for the same reason. `dpkg-deb`'s default differs
by distro — zstd on Ubuntu-family, xz on Debian — and zstd does not promise
bitstream stability across versions, so `build-deb.sh` passes `-Zzstd` and
the toolchain container bases on the same distro CI publishes from. Without
both, "the same version" built in two places produced different bytes, and
the immutability guard rightly refused them.

Override with `SOURCE_DATE_EPOCH` in the environment if you ever need to.

One consequence worth knowing: "rebuild and republish without changing
anything" is a no-op, not an error — but it is also not a way to fix a bad
build. Bump the version.

## Only current versions are installable

The index carries one version per package — the one currently declared.
`apt install termtest=1.1.0` therefore stops working once 1.2.0 ships, and
apt cannot downgrade. Old `.deb` files stay in the bucket, because
`publish.sh` never deletes, but nothing references them.

This is a decision, not an accident. It is the same rule as above expressed
in the index: a bad release is fixed by rolling forward, not by asking anyone
to pin the previous one.

**The cost is that rollback is not available.** If a release is bad, shipping
a new version is the only remedy. That is fine for a smoke package and a
terminal utility; it is worth revisiting the first time something here is
load-bearing for machines you do not own.

Retention, if you ever want it, is **per package** and only worth expressing
for fetched ones. A `release` file may declare more than one version, and
assets bind to the `Tag` block above them:

```
Repo:   owner/name

Tag:    v1.2.0
Asset:  name_1.2.0_amd64.deb  sha256:9f2a…

Tag:    v1.1.0
Asset:  name_1.1.0_amd64.deb  sha256:c418…
```

No "current" marker is needed — apt installs the highest version it can see,
so the file is simply the list of what should be installable. Nothing enforces
a count: the file is the policy, and which versions stay reachable is a
decision worth making by hand.

Locally-built packages cannot do this, deliberately. Retaining one would mean
keeping dead `files/` trees around or building from git history, and build
output must depend on package contents alone.

**Never retain `jvs-archive-keyring`.** An older keyring trusts fewer keys, so
letting a machine install one after a rotation is a way to break something
that was working. Retention is not neutral for that package; it is a hazard.

## Why install.sh pins the artifact

`curl | sh` normally means trusting whatever the server returns. This script
pins the SHA-256 of the keyring package and aborts on mismatch, so a
substituted key fails closed instead of being silently trusted. The pin is
rewritten by `build-repo.sh` and verified on every build, so it cannot drift.

## The keyring package

`jvs-archive-keyring` owns the signing key and the apt sources entry. That
indirection is what makes the key replaceable: a new key reaches installed
machines through `apt upgrade`, like any other update — the procedure is the
rotation runbook in [operations](operations.md#rotating-the-signing-key).

Writing those files from a setup script instead would mean every machine
pins one key forever, with no way to reach them — which is why the key has
no expiry, and why that would otherwise be a problem rather than a choice.
