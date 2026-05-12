#!/usr/bin/env bash
# fetch-review-verdict.sh — fetch machine-readable Claude review verdict for one SHA.

set -uo pipefail

PR=""
SHA=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

emit_missing() {
  local reason="$1"
  jq -n --arg pr "$PR" --arg sha "$SHA" --arg reason "$reason" \
    '{schema_version:1, pr_number:($pr|tonumber? // null), head_sha:"", reviewer:"claude-code-action", review_run_id:null, verdict:"inconclusive", summary:$reason, blocking_findings:[], non_blocking_findings:[], confidence:"low", status:"missing"}'
}

validate_and_emit() {
  local file="$1" source="$2"
  if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    return 1
  fi
  local verdict_sha
  verdict_sha=$(jq -r '.head_sha // empty' "$file")
  if [[ "$verdict_sha" != "$SHA" ]]; then
    jq --arg source "$source" --arg expected "$SHA" \
      '. + {source:$source,status:"stale",expected_head_sha:$expected}' "$file"
    return 0
  fi
  jq --arg source "$source" '. + {source:$source,status:"ok"}' "$file"
  return 0
}

if [[ -z "$PR" || -z "$SHA" ]]; then
  emit_missing "--pr and --sha are required"
  exit 0
fi

artifact_name="review-verdict-$SHA"

if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
  tmpdir=$(mktemp -d)
  if gh run download "$RUN_ID" -n "$artifact_name" -D "$tmpdir" >/dev/null 2>&1; then
    verdict_file=$(find "$tmpdir" -type f \( -name "$artifact_name.json" -o -name "*.json" \) | head -1)
    if [[ -n "$verdict_file" ]] && validate_and_emit "$verdict_file" "artifact"; then
      rm -rf "$tmpdir"
      exit 0
    fi
  fi
  rm -rf "$tmpdir"
fi

comments_json=$(gh pr view "$PR" --json reviews,comments 2>/dev/null || echo '{}')
tmpdir=$(mktemp -d)
printf '%s' "$comments_json" | jq -r '[.reviews[]?.body, .comments[]?.body] | .[]? // empty' \
  | TMPDIR_OUT="$tmpdir" perl -0ne 'my $i=0; while(/\s*<!--\s*claude-review-verdict\s*\n(.*?)\n\s*-->/sg){$i++; open my $fh, ">", $ENV{"TMPDIR_OUT"} . "/block-$i.json"; print $fh $1; close $fh;}' \
  2>/dev/null || true

stale_block=""
for block in "$tmpdir"/block-*.json; do
  [[ -f "$block" ]] || continue
  if ! jq -e 'type == "object"' "$block" >/dev/null 2>&1; then
    continue
  fi
  block_sha=$(jq -r '.head_sha // empty' "$block")
  if [[ "$block_sha" == "$SHA" ]]; then
    validate_and_emit "$block" "hidden-comment"
    rm -rf "$tmpdir"
    exit 0
  fi
  stale_block="$block"
done
if [[ -n "$stale_block" && -f "$stale_block" ]]; then
  validate_and_emit "$stale_block" "hidden-comment"
  rm -rf "$tmpdir"
  exit 0
fi
rm -rf "$tmpdir"

emit_missing "No review verdict artifact or hidden JSON block found for current head SHA."
exit 0
