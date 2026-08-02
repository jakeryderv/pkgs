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
```

Anything with a real build should produce its `.deb` in its own repo, publish
it to a GitHub Release, and land in `dist/` — the indexer does not care where
a `.deb` came from.

## Building

```
./scripts/build-deb.sh     # packages/ -> dist/
./scripts/build-repo.sh    # dist/ -> repo/, signed
./scripts/test-repo.sh     # verify in Debian + Ubuntu containers
./scripts/publish.sh       # repo/ -> R2
```

Two guards will stop you, both deliberately:

- `build-repo.sh` refuses to run if the key pins in `scripts/install.sh` do
  not match the signing key. Pass `UPDATE_PINS=1` when a key change is
  intentional.
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

## Why install.sh pins the key

`curl | sh` normally means trusting whatever key the server returns. This
script pins the key's SHA-256 (and its fingerprint when `gpg` is available)
and aborts on mismatch, so a substituted key fails closed instead of being
silently trusted.

## Cache rules

`cloudflare/cache-rules.json` is the source of truth for the zone's cache
behaviour, applied to the `http_request_cache_settings` phase:

- `/dists/*` — **never cached.** A stale `Packages.gz` served against a fresh
  `InRelease` is a hash mismatch, and apt exits 100. This is reproducible;
  it is the failure mode the rule exists to prevent.
- `/pool/*` — cached for a year. Version-addressed, so it never mutates.

Both are scoped `http.host eq "pkgs.jvs.sh"` and do not affect `jvs.sh`.

## CI

`verify` runs on every push and PR: builds with a throwaway key and installs
in real Debian and Ubuntu containers, including a negative test proving apt
rejects the wrong key. Needs no secrets, so it runs on PRs from anywhere.

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
