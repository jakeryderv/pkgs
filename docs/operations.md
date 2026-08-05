# Operations

The procedures a human runs. Everything here is deliberate local action —
CI reports and publishes, but the trust-changing acts (rotating keys, pushing
credentials, writing cache rules) never run from automation.

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

# 3. switch signing to the new key -- locally AND in CI
SIGNER=new@jvs.sh UPDATE_PINS=1 ./scripts/build-repo.sh
./scripts/publish.sh
./scripts/sync-secrets.sh                          # <- easy to forget, see below

# 4. later, once nothing needs the old key, drop it
./scripts/update-keyring.sh new@jvs.sh
```

The `sync-secrets.sh` line in step 3 is load-bearing and was missing for a
while. CI publishes on every push to `main` using `secrets.GPG_PRIVATE_KEY`
and `vars.SIGNER_UID` — so rotating locally without updating those means the
next push silently re-signs with the *old* key. Not broken, since machines
still trust it at that point, but quietly back on the key you meant to retire.

Step 2 is the load-bearing one and has no shortcut: a machine that has not
upgraded its keyring before step 3 lands will start failing `apt update` and
has to be fixed by re-running `install.sh` by hand.

`./scripts/test-rotation.sh` runs this whole sequence against throwaway keys
in a container, asserting the machine trusts 1 key, then 2, then survives the
switch — without ever re-bootstrapping. It runs in CI.

## Syncing credentials

`sync-secrets.sh` reads the credentials from 1Password and pushes them to
GitHub, rather than pasting a private key into a browser form. Before pushing
anything it checks:

- the key imports and yields a fingerprint
- that fingerprint is in the keyring this repository ships — the same guard
  `build-repo.sh` applies, for the same reason
- the passphrase actually unlocks the key
- if the Cloudflare credentials are in the vault, that the token is active and
  can list `r2://pkgs` under the given account, which is what `publish.sh`
  needs of it
- the GitHub PATs can do what they exist for — the autopin token can push
  here, the dispatch token can see the workflow it triggers (see
  [ci](ci.md#autopin) for what each is)

Each of those otherwise surfaces as a failed publish, which is the worst
moment to learn any of them.

The Cloudflare pair is optional — a token is displayed once at creation and
cannot be read back out of GitHub, so it may not be in the vault. When absent
the existing GitHub secrets are left alone rather than overwritten with
nothing; when only one of the two is present, that is an error rather than a
supported state. The PATs follow the same absent-is-not-an-error rule, and
the dispatch token is pushed to every repo a `release` file declares — a new
fetched package gets it by being declared, not by being remembered.

`--dry-run` runs every check and changes nothing.

## Cache rules

`cloudflare/cache-rules.json` is the source of truth for the zone's cache
behaviour, applied to the `http_request_cache_settings` phase by
`./scripts/apply-cache-rules.sh`:

```
./scripts/apply-cache-rules.sh           report drift, change nothing
./scripts/apply-cache-rules.sh --apply   write the file's rules to the zone
```

Drift reporting is the default because it is the mode worth running often and
is safe anywhere. It compares only the fields we author — the API adds `id`,
`version`, `ref` and `last_updated` to every rule, none of which belong in a
diff against a file that cannot know them — and preserves order, since rule
order is evaluation order.

It talks to the API with `curl` — three requests, for which a CLI bought
nothing while costing a dependency to install and pin. The token is read from
1Password so no long-lived Cloudflare credential sits on disk. It needs **Zone
→ Cache Settings → Edit**, or just **Read** to report drift, and is
deliberately not the token CI publishes with, which never needs zone access.

The daily drift check in `monitor.yml` uses a read-only token: CI reports
divergence, fixing it stays a deliberate local act.

The rules themselves:

- `/dists/*` — **never cached.** A stale `Packages.gz` served against a fresh
  `InRelease` is a hash mismatch, and apt exits 100. This is reproducible;
  it is the failure mode the rule exists to prevent.
- `/pool/*` — cached for a year. Version-addressed, so it never mutates.

Both are scoped `http.host eq "pkgs.jvs.sh"` and do not affect `jvs.sh`.

## Testing without touching production

Everything except `publish.sh` is local. `test-repo.sh` runs the matrix in
`docker/verify/compose.yaml`: a service serving the built repo over the
compose network, one client per distro × architecture installing from it in
parallel, and a negative client proving apt rejects a wrong key. The full
chain can be verified without publishing, and a failing client reports its
own log rather than an interleaved one.
