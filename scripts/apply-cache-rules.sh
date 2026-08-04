#!/usr/bin/env bash
# Reconcile cloudflare/cache-rules.json with the zone's cache-settings phase.
#
#   ./scripts/apply-cache-rules.sh           report drift, change nothing
#   ./scripts/apply-cache-rules.sh --apply   write the file's rules to the zone
#
# The file has always been described as the source of truth for cache
# behaviour, but nothing read it: the rules were applied by hand and nothing
# noticed if they diverged. That matters more here than in most places --
# `/dists/*` being cached even briefly is a hash mismatch and apt exits 100,
# and a `/pool/*` object cached with the wrong TTL is wrong for a year.
#
# Drift reporting is the default because that is the mode worth running often,
# and the one safe to run from anywhere.
#
# Talks to the API with curl rather than a CLI. This is three requests, and a
# CLI bought nothing for them while costing a dependency the pipeline had to
# install, pin, and then never get update notifications for. It also has to
# resolve a zone *name* by listing zones, which needs a permission this token
# deliberately lacks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_FILE="$ROOT/cloudflare/cache-rules.json"
# The zone ID, not the name. A name has to be resolved by listing zones, which
# needs zone:read -- a permission this token deliberately does not have.
ZONE="${ZONE:-b7b9fa5ebf569a9d932b848c07ad4024}"   # jvs.sh
PHASE=http_request_cache_settings
API="https://api.cloudflare.com/client/v4"
OP_CF_CACHE_TOKEN_REF="${OP_CF_CACHE_TOKEN_REF:-op://dev/pkgs.jvs.sh/cloudflare-cache-token}"

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  "") ;;
  *) echo "usage: $0 [--apply]" >&2; exit 1 ;;
esac

command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$RULES_FILE" ] || { echo "ERROR: no $RULES_FILE" >&2; exit 1; }

# Deliberately CLOUDFLARE_CACHE_TOKEN and never CLOUDFLARE_API_TOKEN. The
# latter is the name wrangler reads by default, so it holds the R2 publish
# token -- which has no zone access. Picking it up here would fail with a 403
# that looks like a permissions bug rather than the wrong credential.
TOKEN="${CLOUDFLARE_CACHE_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  command -v op >/dev/null || { echo "ERROR: set CLOUDFLARE_CACHE_TOKEN or install the 1Password CLI" >&2; exit 1; }
  TOKEN="$(op read "$OP_CF_CACHE_TOKEN_REF" 2>/dev/null || true)"
  [ -n "$TOKEN" ] || {
    echo "ERROR: no token at $OP_CF_CACHE_TOKEN_REF, and CLOUDFLARE_CACHE_TOKEN is unset." >&2
    echo "It needs Zone -> Cache Settings -> Edit on $ZONE (Read is enough to report drift)." >&2
    exit 1
  }
fi

# --config via process substitution rather than -H: a header on the command
# line puts the token in argv, where any other process can read it.
#
# No -f. Cloudflare answers a rejected request with a JSON body explaining
# why; -f discards the body and exits 22, which under pipefail would abort
# with a curl exit code instead of the actual reason.
#
# The -K substitution has to sit on the curl invocation itself. Building it
# into an array first closes the descriptor when the assignment completes, and
# curl then fails with "error encountered when reading a file".
api() { # method, path, [body]
  if [ -n "${3:-}" ]; then
    curl -sS -X "$1" -H 'Content-Type: application/json' -d "$3" \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") "$API/$2"
  else
    curl -sS -X "$1" \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") "$API/$2"
  fi
}
# Every response carries success plus a machine-readable errors array, so
# failures can say what Cloudflare actually objected to.
check() { # json, what
  [ "$(printf '%s' "$1" | jq -r '.success')" = "true" ] && return 0
  echo "ERROR: $2" >&2
  echo "  cloudflare says: $(printf '%s' "$1" | jq -r '(.errors // []) | map(.message) | join("; ")')" >&2
  exit 1
}

# Only the fields we actually author. The API adds id, version, ref and
# last_updated to every rule, none of which belong in a diff against a file
# that cannot know them.
#
# Compared with `jq -S`, which sorts object keys but NOT array elements. That
# distinction is the whole point: the API returns object keys in a different
# order than the file writes them, which is not a difference at all -- while
# rule *order* is evaluation order, so a reordered array is a real change and
# must still register as drift.
NORMALISE='.rules | [ .[]? | {description, expression, action, action_parameters} ]'

listing="$(api GET "zones/$ZONE/rulesets")"
check "$listing" "could not list rulesets for zone $ZONE"
ruleset_id="$(printf '%s' "$listing" \
  | jq -r --arg p "$PHASE" '.result[]? | select(.phase == $p and .kind == "zone") | .id' | head -1)"

if [ -z "$ruleset_id" ]; then
  echo "no $PHASE ruleset on $ZONE yet"
  [ "$APPLY" -eq 1 ] || { echo "run with --apply to create it"; exit 1; }
  created="$(api POST "zones/$ZONE/rulesets" \
    "$(jq -c --arg p "$PHASE" '{name: "cache rules", kind: "zone", phase: $p, rules: .rules}' "$RULES_FILE")")"
  check "$created" "could not create the $PHASE ruleset"
  echo "created"
  exit 0
fi

current="$(api GET "zones/$ZONE/rulesets/$ruleset_id")"
check "$current" "could not read ruleset $ruleset_id"

live="$(printf '%s' "$current" | jq -S ".result | $NORMALISE")"
want="$(jq -S "$NORMALISE" "$RULES_FILE")"

if [ "$live" = "$want" ]; then
  echo "cache rules match $RULES_FILE ($(jq 'length' <<< "$want") rule(s), ruleset $ruleset_id)"
  exit 0
fi

echo "DRIFT: the zone does not match $RULES_FILE" >&2
diff <(printf '%s\n' "$want") <(printf '%s\n' "$live") | head -40 || true

if [ "$APPLY" -eq 0 ]; then
  echo >&2
  echo "run with --apply to write the file's rules to the zone" >&2
  exit 1
fi

updated="$(api PUT "zones/$ZONE/rulesets/$ruleset_id" "$(jq -c '{rules: .rules}' "$RULES_FILE")")"
check "$updated" "could not update ruleset $ruleset_id"
echo "applied"
