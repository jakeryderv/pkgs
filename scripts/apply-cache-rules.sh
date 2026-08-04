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
# Uses `cf`, whose rulesets commands cover the zone-level phase directly. Its
# token comes from 1Password, so no long-lived Cloudflare credential needs to
# exist on disk or in a shell profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_FILE="$ROOT/cloudflare/cache-rules.json"
# The zone ID, not the name. Resolving a name means listing zones, which needs
# zone:read -- a permission this token deliberately does not have. Passing the
# id keeps the token scoped to cache settings and nothing else.
ZONE="${ZONE:-b7b9fa5ebf569a9d932b848c07ad4024}"   # jvs.sh
PHASE=http_request_cache_settings
OP_CF_CACHE_TOKEN_REF="${OP_CF_CACHE_TOKEN_REF:-op://dev/pkgs.jvs.sh/cloudflare-cache-token}"

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  "") ;;
  *) echo "usage: $0 [--apply]" >&2; exit 1 ;;
esac

command -v cf >/dev/null || { echo "ERROR: the cf CLI is required (npm i -g cf)" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$RULES_FILE" ] || { echo "ERROR: no $RULES_FILE" >&2; exit 1; }

# A token rather than the OAuth login: `cf auth login` grants zone:read but not
# the ruleset permissions this needs, and a scoped token is the right shape for
# something that edits cache behaviour anyway.
#
# Deliberately CLOUDFLARE_CACHE_TOKEN and never CLOUDFLARE_API_TOKEN. The
# latter is the name wrangler and cf read by default, so it holds the R2
# publish token -- which has no zone access. Picking it up here would fail with
# a 403 that looks like a permissions bug rather than the wrong token.
TOKEN="${CLOUDFLARE_CACHE_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  command -v op >/dev/null || { echo "ERROR: set CLOUDFLARE_CACHE_TOKEN or install the 1Password CLI" >&2; exit 1; }
  TOKEN="$(op read "$OP_CF_CACHE_TOKEN_REF" 2>/dev/null || true)"
  [ -n "$TOKEN" ] || {
    echo "ERROR: no token at $OP_CF_CACHE_TOKEN_REF, and CLOUDFLARE_CACHE_TOKEN is unset." >&2
    echo "It needs Zone -> Cache Rules -> Edit on $ZONE." >&2
    exit 1
  }
fi
# cf reads this name; the value is the cache token, not the publish one.
export CLOUDFLARE_API_TOKEN="$TOKEN"

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

listing="$(cf rulesets list -z "$ZONE" 2>&1)" || {
  echo "ERROR: could not list rulesets for zone $ZONE" >&2
  printf '%s\n' "$listing" | head -10 >&2
  exit 1
}
ruleset_id="$(printf '%s' "$listing" \
  | jq -r --arg p "$PHASE" '.[]? | select(.phase == $p and .kind == "zone") | .id' 2>/dev/null | head -1)"

if [ -z "$ruleset_id" ]; then
  echo "no $PHASE ruleset on $ZONE yet"
  [ "$APPLY" -eq 1 ] || { echo "run with --apply to create it"; exit 1; }
  cf rulesets create -z "$ZONE" --body "$(jq -c \
    --arg p "$PHASE" '{name: "cache rules", kind: "zone", phase: $p, rules: .rules}' "$RULES_FILE")" >/dev/null
  echo "created"
  exit 0
fi

current="$(cf rulesets get "$ruleset_id" -z "$ZONE" 2>&1)" || {
  echo "ERROR: could not read ruleset $ruleset_id" >&2
  printf '%s\n' "$current" | head -10 >&2
  exit 1
}
live="$(printf '%s' "$current" | jq -S "$NORMALISE")"
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

cf rulesets update "$ruleset_id" -z "$ZONE" \
  --body "$(jq -c '{rules: .rules}' "$RULES_FILE")" >/dev/null
echo "applied"
