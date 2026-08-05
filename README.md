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

| | |
|---|---|
| Bucket | `pkgs` (Cloudflare R2) |
| Domain | `pkgs.jvs.sh`, min TLS 1.2 |
| Suite / component | `stable` / `main` |
| Architectures | `amd64`, `arm64` |

## Working on it

All behavior lives in `scripts/`; the `Makefile` is the index over it, and CI
runs the same scripts. `make` alone lists the targets:

```
make build      # local .debs + pinned release fetches -> $PKGS_OUT
make repo       # assemble and sign the apt tree
make verify     # install + rotation tests, in real containers
make lint       # exactly what CI lints
make publish    # upload to R2 (production; everything else is local)
```

Generated output lands under `PKGS_OUT` (`~/.cache/pkgs-jvs`), never in the
tree. To ship: edit `packages/`, bump the version, push to `main` — `verify`
gates, `publish` uploads.

## Documentation

- [Adding a package](docs/adding-packages.md) — the `manifest`/`files`
  format, fetched packages and their hash pins, the smoke-test convention,
  and why releasing a fetched package is just tagging its repo.
- [Design](docs/design.md) — the decisions and the incidents behind them:
  same version means same bytes, reproducibility, retention, the keyring
  package, the toolchain container.
- [Operations](docs/operations.md) — the runbooks: rotating the signing key,
  syncing credentials from 1Password, cache-rule management, testing without
  touching production.
- [CI](docs/ci.md) — the three workflows (verify/publish, monitor, autopin),
  the token model, and what each check actually proves.

The scripts' header comments are the reference for how each piece works —
start there when a doc and the code seem to disagree, and flag the doc.
