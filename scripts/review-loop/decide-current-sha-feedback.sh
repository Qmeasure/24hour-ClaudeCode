#!/usr/bin/env bash
# decide-current-sha-feedback.sh — decide pass/rework/stop from current-SHA status + verdict.

set -uo pipefail

STATUS_FILE=""
VERDICT_FILE=""
STATE_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_FILE="$2"; shift 2 ;;
    --verdict) VERDICT_FILE="$2"; shift 2 ;;
    --state) STATE_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

emit() {
  jq -n --arg token "$1" --arg reason "$2" --arg kind "$3" '{token:$token,reason:$reason,kind:$kind}'
}

[[ -f "$STATUS_FILE" ]] || { emit "stop" "status file missing" "infra"; exit 0; }
[[ -f "$VERDICT_FILE" ]] || { emit "stop" "verdict file missing" "infra"; exit 0; }

round=0
max_rounds=5
same_feedback=0
if [[ -f "$STATE_FILE" ]]; then
  round=$(jq -r '.round // .iteration // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  max_rounds=$(jq -r '.max_rounds // .max_iterations // 5' "$STATE_FILE" 2>/dev/null || echo 5)
  same_feedback=$(jq -r '.same_feedback_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
fi
[[ "$round" =~ ^[0-9]+$ ]] || round=0
[[ "$max_rounds" =~ ^[0-9]+$ ]] || max_rounds=5
[[ "$same_feedback" =~ ^[0-9]+$ ]] || same_feedback=0

status_sha=$(jq -r '.head_sha // empty' "$STATUS_FILE")
verdict_sha=$(jq -r '.head_sha // empty' "$VERDICT_FILE")
ci_status=$(jq -r '.ci.status // "missing"' "$STATUS_FILE")
review_status=$(jq -r '.review_action.status // "missing"' "$STATUS_FILE")
verdict=$(jq -r '.verdict // "inconclusive"' "$VERDICT_FILE")
verdict_status=$(jq -r '.status // "missing"' "$VERDICT_FILE")
confidence=$(jq -r '.confidence // "low"' "$VERDICT_FILE")

if [[ -z "$status_sha" ]]; then
  emit "stop" "status did not include a head SHA" "infra"
  exit 0
fi

if [[ "$ci_status" == "failed" ]]; then
  failed_count=$(jq '.failed_checks // [] | length' "$STATUS_FILE" 2>/dev/null || echo 0)
  if (( failed_count > 0 )); then
    if (( round >= max_rounds )); then
      emit "stop" "max rounds reached ($round/$max_rounds)" "max_rounds"
      exit 0
    fi
    if (( same_feedback >= 2 )); then
      emit "stop" "same blocking CI feedback repeated $same_feedback times" "repeated_feedback"
      exit 0
    fi
    list=$(jq -r '[.failed_checks[]?.name] | join(", ")' "$STATUS_FILE")
    emit "rework_required" "CI failed for current head SHA $status_sha: $list" "ci"
  else
    emit "stop" "CI failed for current head SHA $status_sha, but no failed check/log details were available" "ci"
  fi
  exit 0
fi

case "$ci_status" in
  success) ;;
  timeout|pending|missing|inconclusive|"")
    emit "stop" "CI did not reach a reliable success state for current head SHA $status_sha (ci.status=$ci_status)" "infra"
    exit 0
    ;;
  *)
    emit "stop" "unknown CI status for current head SHA $status_sha: $ci_status" "infra"
    exit 0
    ;;
esac

if [[ "$review_status" != "success" ]]; then
  emit "stop" "Claude Code Action review did not complete successfully for current head SHA $status_sha (review.status=$review_status)" "infra"
  exit 0
fi

if [[ "$verdict_status" != "ok" ]]; then
  emit "stop" "review verdict is missing or stale for current head SHA $status_sha (verdict.status=$verdict_status)" "infra"
  exit 0
fi

if [[ "$verdict_sha" != "$status_sha" ]]; then
  emit "stop" "review verdict SHA mismatch: expected $status_sha, got ${verdict_sha:-empty}" "infra"
  exit 0
fi

blocking_count=$(jq '.blocking_findings // [] | length' "$VERDICT_FILE" 2>/dev/null || echo 0)

case "$verdict" in
  fail)
    if (( blocking_count > 0 )); then
      if (( round >= max_rounds )); then
        emit "stop" "max rounds reached ($round/$max_rounds)" "max_rounds"
        exit 0
      fi
      if (( same_feedback >= 2 )); then
        emit "stop" "same blocking review feedback repeated $same_feedback times" "repeated_feedback"
        exit 0
      fi
      emit "rework_required" "Claude Code Action returned fail with $blocking_count blocking finding(s)." "review"
    else
      emit "stop" "Claude Code Action returned fail without blocking_findings; refusing automatic rework" "infra"
    fi
    ;;
  pass)
    if (( blocking_count > 0 )); then
      emit "stop" "verdict=pass included blocking_findings; refusing merge" "infra"
    elif [[ "$confidence" == "low" ]]; then
      emit "stop" "verdict=pass had low confidence; refusing automatic merge" "infra"
    else
      emit "pass" "CI and Claude Code Action review passed for current head SHA $status_sha." "review"
    fi
    ;;
  needs_human)
    emit "stop" "Claude Code Action requested human review." "review"
    ;;
  inconclusive|"")
    emit "stop" "Claude Code Action verdict is inconclusive." "review"
    ;;
  *)
    emit "stop" "unknown Claude Code Action verdict: $verdict" "infra"
    ;;
esac
