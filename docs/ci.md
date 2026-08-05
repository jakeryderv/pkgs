# CI

Three workflows, all thin wrappers over the same scripts a human runs — CI's
only privilege is holding the production credentials.

## verify and publish

`verify` runs on every push and PR: lints, then builds with a throwaway key
and installs in real Debian and Ubuntu containers, running each package's
smoke test and a negative test proving apt rejects the wrong key. Needs no
secrets, so it runs on PRs from anywhere. Branch protection requires it for
every merge to `main`.

Linting is `shellcheck -S warning` over the scripts, the packaged binaries and
the smoke tests, plus `sh -n scripts/install.sh` — dash's own parser rather
than shellcheck's, for the one file that ships to users. The tree is clean at
`warning`, so the gate is a ratchet rather than a cleanup task. It runs before
the container tests because it takes seconds and they take minutes.

`publish` runs on `main` only and requires `GPG_PRIVATE_KEY`,
`GPG_PASSPHRASE`, and `CLOUDFLARE_API_TOKEN`. It fails rather than
publishing an unsigned repository if the key is missing. After uploading it
installs from the live site in a clean container, as a user would — publishing
successfully is not the same as being installable.

`GPG_PASSPHRASE` is not optional: a runner has no gpg-agent and no tty, so
nothing can prompt for it. `build-repo.sh` feeds it through loopback
pinentry when set.

Nothing in the pipeline installs a CLI. R2 object operations live on the
ordinary v4 API and take the same bearer token as everything else, so
`publish.sh` uses `curl` — no wrangler, no `npx` download on every publish,
and no version to pin.

The Cloudflare token here should be scoped to **Workers R2 Storage → Edit
and nothing else** — CI only uploads objects. It never needs zone access.
Cache-rule work uses a separate token; see
[operations](operations.md#cache-rules).

No account id is needed. An account-owned token can only ever see one
account, so `publish.sh` resolves it by asking the API — verified by deleting
the secret and publishing successfully without it. It was never a secret
anyway: an account id appears in dashboard URLs and is routinely committed in
`wrangler.toml`.

To publish: edit `packages/`, bump the version, push to `main`.

## monitor

Daily, because both failures this repository has actually taken — a cache
rule that started caching error responses, and a bootstrap file missing from
the upload list — broke the live site while every push-triggered check stayed
green. It installs from `pkgs.jvs.sh` in a clean container exactly as a user
would, and reports cache-rule drift with a read-only token.

## autopin

Daily poll plus on-demand dispatch. Sees a newer upstream tag → takes the
asset names from the release, re-pins the hashes with
`fetch-releases.sh --update <name>`, verifies build provenance with
`gh attestation verify`, and opens a PR that auto-merges once `verify`
passes. The PR is the audit trail — a diff of exactly which bytes changed —
and closing one without merging is how a version is skipped for good.

Polling rather than a dispatch from the tool repo, deliberately.
`repository_dispatch` requires `contents: write` on this repository — there is
no dispatch-only permission — so every tool repo would hold a token able to
push here, and pushing here publishes under the signing key. The daily
schedule needs no token in any tool repo at all. A repo that wants
same-minute pickup rather than next-morning can trigger the run itself with a
fine-grained PAT scoped to **Actions: write** on this repository — enough to
ask for a run, not enough to change what the run checks or pushes:

```yaml
- name: Ask pkgs to pick up this release
  env:
    GH_TOKEN: ${{ secrets.PKGS_AUTOPIN_DISPATCH }}
  run: gh workflow run autopin.yml -R jakeryderv/pkgs
```

The workflow itself runs on `AUTOPIN_TOKEN`, a fine-grained PAT with contents
and pull-requests write on this repository only, not the built-in
`github.token`. Not a convenience: branches pushed with `github.token` never
trigger `pull_request` workflows, so a PR opened that way waits forever on a
required `verify` that never starts — and auto-merge waits with it. The
workflow fails loudly if the token is missing.

Both PATs live in the `pkgs` 1Password Environment and are placed by
`sync-secrets.sh`, like every other credential: `AUTOPIN_TOKEN` becomes a
secret on this repository, and the dispatch token is pushed to every repo a
`release` file declares — so a new fetched package gets it by being declared,
not by being remembered. Each is verified before being pushed anywhere: the
autopin token that it can actually push here, the dispatch token that it can
see the workflow it exists to trigger.
