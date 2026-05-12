#!/usr/bin/env bash
# wait-for-current-sha-status.sh — wait for CI + Claude Code Review for one PR head SHA.

set -uo pipefail

PR=""
SHA=""
TIMEOUT=7200
INTERVAL=20
REVIEW_WORKFLOW="Claude Code Review"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --review-workflow) REVIEW_WORKFLOW="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

emit_json() {
  local status="$1" ci_json="$2" review_json="$3" failed_json="$4" warnings_json="$5"
  jq -n \
    --arg status "$status" \
    --arg pr "$PR" \
    --arg sha "$SHA" \
    --argjson ci "$ci_json" \
    --argjson review "$review_json" \
    --argjson failed "$failed_json" \
    --argjson warnings "$warnings_json" \
    '{status:$status, pr_number:($pr | tonumber? // null), head_sha:$sha, ci:$ci, review_action:$review, failed_checks:$failed, warnings:$warnings}'
}

empty_ci='{"status":"missing","checks":[]}'
empty_review='{"status":"missing","workflow_name":"Claude Code Review","run_id":null,"conclusion":null}'

if [[ -z "$PR" || -z "$SHA" ]]; then
  emit_json "inconclusive" "$empty_ci" "$empty_review" "[]" '["--pr and --sha are required"]'
  exit 0
fi

start=$(date +%s)
last_ci="$empty_ci"
last_review=$(jq -n --arg wf "$REVIEW_WORKFLOW" '{status:"missing",workflow_name:$wf,run_id:null,conclusion:null}')
last_failed="[]"
last_warnings="[]"

run_id_from_url() {
  printf '%s' "$1" | grep -oE '/runs/[0-9]+' | grep -oE '[0-9]+' | head -1 || true
}

log_tail_for_check() {
  local url="$1" run_id job_id
  run_id=$(run_id_from_url "$url")
  job_id=$(printf '%s' "$url" | grep -oE '/job/[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [[ -z "$run_id" ]] && return 0
  if [[ -n "$job_id" ]]; then
    gh run view "$run_id" --job "$job_id" --log 2>/dev/null | tail -80 || true
  else
    gh run view "$run_id" --log-failed 2>/dev/null | tail -80 || true
  fi | sed 's/\x1b\[[0-9;]*m//g'
}

while true; do
  warnings="[]"
  pr_json=$(gh pr view "$PR" --json number,headRefOid,headRefName,statusCheckRollup 2>/tmp/wait-current-sha-pr.$$)
  pr_exit=$?
  if (( pr_exit != 0 )); then
    err_line=$(head -1 /tmp/wait-current-sha-pr.$$ 2>/dev/null || echo "gh pr view failed")
    rm -f /tmp/wait-current-sha-pr.$$ 2>/dev/null
    warnings=$(jq -n --arg e "$err_line" '[$e]')
    emit_json "inconclusive" "$last_ci" "$last_review" "$last_failed" "$warnings"
    exit 0
  fi
  rm -f /tmp/wait-current-sha-pr.$$ 2>/dev/null

  pr_head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')
  branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty')
  if [[ -n "$pr_head" && "$pr_head" != "$SHA" ]]; then
    warnings=$(jq -n --arg want "$SHA" --arg got "$pr_head" '["PR head SHA changed while waiting: wanted \($want), got \($got)"]')
    emit_json "inconclusive" "$last_ci" "$last_review" "$last_failed" "$warnings"
    exit 0
  fi

  checks=$(printf '%s' "$pr_json" | jq \
    '[.statusCheckRollup[]? | {
      name: (.name // ""),
      workflowName: (.workflowName // ""),
      status: (.status // ""),
      conclusion: (.conclusion // ""),
      detailsUrl: (.detailsUrl // "")
    }]')

  review_checks=$(printf '%s' "$checks" | jq --arg wf "$REVIEW_WORKFLOW" \
    '[.[] | select(((.name + " " + .workflowName) | ascii_downcase) | contains($wf | ascii_downcase))]')
  ci_checks=$(printf '%s' "$checks" | jq --arg wf "$REVIEW_WORKFLOW" \
    '[.[] | select((((.name + " " + .workflowName) | ascii_downcase) | contains($wf | ascii_downcase)) | not)]')

  ci_count=$(printf '%s' "$ci_checks" | jq 'length')
  ci_failed=$(printf '%s' "$ci_checks" | jq '[.[] | select((.conclusion // "" | ascii_downcase) | IN("failure","cancelled","timed_out","startup_failure"))]')
  ci_pending=$(printf '%s' "$ci_checks" | jq '[.[] | select(((.conclusion // "") == "") or ((.status // "" | ascii_downcase) | IN("queued","pending","in_progress","requested","waiting","action_required")))]')
  failed_count=$(printf '%s' "$ci_failed" | jq 'length')
  pending_count=$(printf '%s' "$ci_pending" | jq 'length')

  if (( ci_count == 0 )); then
    ci_status="missing"
  elif (( failed_count > 0 )); then
    ci_status="failed"
  elif (( pending_count > 0 )); then
    ci_status="pending"
  else
    ci_status="success"
  fi
  last_ci=$(jq -n --arg s "$ci_status" --argjson checks "$ci_checks" '{status:$s,checks:$checks}')

  failed_items="[]"
  if (( failed_count > 0 )); then
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      name=$(printf '%s' "$item" | jq -r '.name')
      url=$(printf '%s' "$item" | jq -r '.detailsUrl')
      log_tail=$(log_tail_for_check "$url")
      failed_items=$(printf '%s' "$failed_items" | jq \
        --arg n "$name" --arg u "$url" --arg l "$log_tail" \
        '. + [{name:$n,detailsUrl:$u,log_tail:$l}]')
    done <<< "$(printf '%s' "$ci_failed" | jq -c '.[]')"
  fi
  last_failed="$failed_items"

  review_run_json=""
  review_run_id=""
  if [[ -n "$branch" ]]; then
    review_run_json=$(gh run list --workflow "$REVIEW_WORKFLOW" --commit "$SHA" --branch "$branch" --limit 10 \
      --json databaseId,headSha,status,conclusion,workflowName,name,url,createdAt 2>/dev/null \
      | jq 'sort_by(.createdAt // "") | reverse | .[0] // empty' 2>/dev/null || echo "")
  fi

  if [[ -n "$review_run_json" && "$review_run_json" != "null" ]]; then
    review_run_id=$(printf '%s' "$review_run_json" | jq -r '.databaseId // empty')
    review_status_raw=$(printf '%s' "$review_run_json" | jq -r '.status // ""')
    review_conclusion=$(printf '%s' "$review_run_json" | jq -r '.conclusion // ""')
  elif [[ "$(printf '%s' "$review_checks" | jq 'length')" != "0" ]]; then
    review_item=$(printf '%s' "$review_checks" | jq '.[0]')
    review_run_id=$(run_id_from_url "$(printf '%s' "$review_item" | jq -r '.detailsUrl')")
    review_status_raw=$(printf '%s' "$review_item" | jq -r '.status // ""')
    review_conclusion=$(printf '%s' "$review_item" | jq -r '.conclusion // ""')
  else
    review_status_raw=""
    review_conclusion=""
  fi

  review_status_lc=$(printf '%s' "$review_status_raw" | tr '[:upper:]' '[:lower:]')
  review_conclusion_lc=$(printf '%s' "$review_conclusion" | tr '[:upper:]' '[:lower:]')

  if [[ -z "$review_run_id" && -z "$review_status_raw" && -z "$review_conclusion" ]]; then
    review_status="missing"
  elif [[ "$review_status_lc" != "completed" && -z "$review_conclusion" ]]; then
    review_status="pending"
  elif [[ "$review_conclusion_lc" == "success" ]]; then
    review_status="success"
  elif [[ "$review_conclusion_lc" =~ ^(failure|cancelled|timed_out|startup_failure)$ ]]; then
    review_status="failed"
  else
    review_status="inconclusive"
  fi
  last_review=$(jq -n \
    --arg s "$review_status" \
    --arg wf "$REVIEW_WORKFLOW" \
    --arg rid "$review_run_id" \
    --arg c "$review_conclusion" \
    '{status:$s,workflow_name:$wf,run_id:($rid | if . == "" then null else (tonumber? // null) end),conclusion:($c | if . == "" then null else . end)}')

  if [[ "$ci_status" == "failed" || "$review_status" == "failed" ]]; then
    emit_json "failed" "$last_ci" "$last_review" "$last_failed" "$last_warnings"
    exit 0
  fi

  if [[ "$ci_status" == "success" && "$review_status" == "success" ]]; then
    emit_json "success" "$last_ci" "$last_review" "$last_failed" "$last_warnings"
    exit 0
  fi

  now=$(date +%s)
  if (( now - start >= TIMEOUT )); then
    warnings=$(jq -n --arg t "$TIMEOUT" '["Timed out waiting for current SHA status after \($t)s"]')
    emit_json "timeout" "$last_ci" "$last_review" "$last_failed" "$warnings"
    exit 0
  fi

  sleep "$INTERVAL"
done
