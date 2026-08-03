# pkgs

Package distribution for things I build. Serves `https://pkgs.jvs.sh` from a
Cloudflare R2 bucket.

```
curl -fsSL https://pkgs.jvs.sh/install.sh | sudo sh
sudo apt install hello-jvs
```

## Layout

The host is deliberately not `apt.jvs.sh`. Ecosystems are paths, so adding
macOS or Windows later is a new prefix rather than new DNS, a new bucket, and
a new pipeline.

```
pkgs.jvs.sh/
  install.sh                 bootstrap for Debian/Ubuntu
  jvs-archive-keyring.gpg    public signing key
  dists/stable/…             apt metadata (signed)
  pool/main/…                .deb files
```

Reserved for later, not built yet: `rpm/` for Fedora, `bin/<tool>/<version>/`
for raw binaries. Homebrew and Scoop need no hosting here — a tap is a git
repo, and its formula can point at `bin/` URLs.

## Repository

| | |
|---|---|
| Bucket | `pkgs` (Cloudflare R2) |
| Domain | `pkgs.jvs.sh`, min TLS 1.2 |
| Suite / component | `stable` / `main` |
| Architectures | `amd64`, `arm64` |

## Adding a package

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

### release

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
problem `install.sh`'s keyring pin exists to solve and gets the same
fail-closed answer.

They also buy back reproducibility. A local package gets byte-stability from
`SOURCE_DATE_EPOCH`; a fetched one is never rebuilt, so pinning its bytes is
what keeps `publish.sh`'s immutability guard meaningful.

This is also how a second architecture arrives. Local packages are all
`Architecture: all`, so `binary-amd64` and `binary-arm64` are currently
identical; a fetched package can declare a real per-arch asset for each, and
`dpkg-scanpackages` indexes them where they belong with no change here.

### Releasing a fetched package

Tag it upstream. That is the whole workflow — nothing here is edited by hand.

`.github/workflows/autopin.yml` polls each declared repository daily. When a
newer tag appears it takes the asset names from the release, re-pins the
hashes, verifies build provenance, and opens a PR. Merging publishes.

Provenance is checked with `gh attestation verify`, which proves the artifact
was built by that repository's own release workflow rather than uploaded by
someone who reached the repo. That is a different guarantee from the hash, and
both are kept: the pin says these bytes have not moved since we looked, the
attestation says who built them. A package whose upstream does not attest
cannot be picked up automatically, which is intended.

Polling rather than a dispatch from the tool repo, deliberately.
`repository_dispatch` requires `contents: write` on this repository — there is
no dispatch-only permission — so every tool repo would hold a token able to
push here, and pushing here publishes under the signing key. Polling needs no
token in any tool repo at all, at the cost of a latency nothing here is
sensitive to.

One wrinkle: GitHub does not start checks on a PR opened by
`github-actions[bot]` without approval, so each autopin PR needs *Approve and
run* before `verify` reports. That is not a safety gate — `publish` requires
`verify` on `main` regardless — so merging blind cannot publish something
broken; it would just leave `main` red.

`fetch-releases.sh` prunes `vendor/` of anything no longer declared. Without
that, retagging a package would leave its old `.deb` behind to be swept back
into the pool — the stale-artifact failure `build-deb.sh` wipes `dist/` to
prevent.

### smoke

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

## Building

```
./scripts/build-deb.sh       # packages/ -> dist/          (local, offline)
./scripts/fetch-releases.sh  # GitHub Releases -> vendor/  (network, pinned)
./scripts/build-repo.sh      # dist/ + vendor/ -> repo/, signed
./scripts/test-repo.sh       # verify in Debian + Ubuntu containers
./scripts/test-rotation.sh   # verify a key rotation survives, in containers
./scripts/publish.sh         # repo/ -> R2
./scripts/update-keyring.sh  # regenerate the keyring the keyring package ships
```

The first two are independent and can run in either order. `build-deb.sh`
never touches the network — a GitHub outage should not be able to break a
build of packages that are entirely local — and `fetch-releases.sh` is
offline too once `vendor/` is warm, since a cached asset matching its pin is
not re-downloaded.

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

Override with `SOURCE_DATE_EPOCH` in the environment if you ever need to.

One consequence worth knowing: "rebuild and republish without changing
anything" is a no-op, not an error — but it is also not a way to fix a bad
build. Bump the version.

### Only current versions are installable

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
machines through `apt upgrade`, like any other update.

Writing those files from a setup script instead would mean every machine
pins one key forever, with no way to reach them — which is why the key has
no expiry, and why that would otherwise be a problem rather than a choice.

## Rotating the signing key

Order matters, and getting it wrong is unrecoverable. Machines trust exactly
the keys in the keyring they have. Signing with a key they do not yet trust
means they cannot verify the repository, and therefore cannot fetch the
keyring update that would teach them the new key.

`build-repo.sh` refuses to sign with a key absent from the shipped keyring,
so the deadlock cannot be reached by accident. The supported path:

```
# 1. ship a keyring trusting BOTH keys, still signed by the old one
./scripts/update-keyring.sh old@jvs.sh new@jvs.sh
$EDITOR packages/jvs-archive-keyring/manifest      # bump the version
SIGNER=old@jvs.sh UPDATE_PINS=1 ./scripts/build-repo.sh
./scripts/publish.sh

# 2. wait. every machine must run apt upgrade before step 3.

# 3. switch signing to the new key
SIGNER=new@jvs.sh UPDATE_PINS=1 ./scripts/build-repo.sh
./scripts/publish.sh

# 4. later, once nothing needs the old key, drop it
./scripts/update-keyring.sh new@jvs.sh
```

Step 2 is the load-bearing one and has no shortcut: a machine that has not
upgraded its keyring before step 3 lands will start failing `apt update` and
has to be fixed by re-running `install.sh` by hand.

`./scripts/test-rotation.sh` runs this whole sequence against throwaway keys
in a container, asserting the machine trusts 1 key, then 2, then survives the
switch — without ever re-bootstrapping. It runs in CI.

## Cache rules

`cloudflare/cache-rules.json` is the source of truth for the zone's cache
behaviour, applied to the `http_request_cache_settings` phase:

- `/dists/*` — **never cached.** A stale `Packages.gz` served against a fresh
  `InRelease` is a hash mismatch, and apt exits 100. This is reproducible;
  it is the failure mode the rule exists to prevent.
- `/pool/*` — cached for a year. Version-addressed, so it never mutates.

Both are scoped `http.host eq "pkgs.jvs.sh"` and do not affect `jvs.sh`.

## CI

`verify` runs on every push and PR: lints, then builds with a throwaway key
and installs in real Debian and Ubuntu containers, running each package's
smoke test and a negative test proving apt rejects the wrong key. Needs no
secrets, so it runs on PRs from anywhere.

Linting is `shellcheck -S warning` over the scripts, the packaged binaries and
the smoke tests, plus `sh -n scripts/install.sh` — dash's own parser rather
than shellcheck's, for the one file that ships to users. The tree is clean at
`warning`, so the gate is a ratchet rather than a cleanup task. It runs before
the container tests because it takes seconds and they take minutes.

`publish` runs on `main` only and requires `GPG_PRIVATE_KEY`,
`GPG_PASSPHRASE`, `CLOUDFLARE_API_TOKEN`, and `CLOUDFLARE_ACCOUNT_ID`. It
fails rather than publishing an unsigned repository if the key is missing.

`GPG_PASSPHRASE` is not optional: a runner has no gpg-agent and no tty, so
nothing can prompt for it. `build-repo.sh` feeds it through loopback
pinentry when set.

The Cloudflare token here should be scoped to **Workers R2 Storage → Edit
and nothing else** — CI only uploads objects. It never needs zone access.

To publish: edit `packages/`, bump the version, push to `main`.

## Testing without touching production

Everything except `publish.sh` is local. `test-repo.sh` serves `repo/` over
127.0.0.1 and installs from containers, so the full chain can be verified
without publishing.
