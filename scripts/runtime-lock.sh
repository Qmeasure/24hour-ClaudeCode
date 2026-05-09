#!/usr/bin/env bash
# runtime-lock.sh — Cooperative lock for <project>/.claude/runtime/24hour-ClaudeCode/lock.
#
# Used by on-edit.sh to prevent concurrent invocations (e.g., when Claude does
# multiple Edits in quick succession). The "queued" pattern lets the holder
# know more work landed during its run, so it can re-debounce after release.
#
# Subcommands:
#   acquire             Try to acquire the lock atomically.
#                       Exits 0 on success.
#                       If lock is held: writes <runtime>/lock.queued and exits 1.
#   release             Remove the lock. Idempotent.
#   is-held             Exit 0 if lock is held, 1 otherwise.
#   was-queued          Exit 0 if a queue request landed during the held period, 1 otherwise.
#                       Side effect: clears the queue flag.
#   path                Print the lock file path.
#
# Implementation: uses `mkdir <dir>` for atomic acquisition (POSIX-safe; works on
# macOS without `flock`). The lockfile is a directory; presence = held.
#
# Required env: CLAUDE_PROJECT_DIR (or fallback to current cwd).

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
LOCK_DIR="$RUNTIME_DIR/lock"
QUEUE_FILE="$RUNTIME_DIR/lock.queued"

mkdir -p "$RUNTIME_DIR"

cmd="${1:-is-held}"

case "$cmd" in
  acquire)
    # Stale-lock detection: clear the lock if the holder PID is dead AND
    # the lock is older than 30 minutes. The Stop hook timeout is 900s (15 min),
    # so anything past 1800s means the previous run was killed (SIGKILL, OOM,
    # session terminated) and the trap couldn't release. Without this,
    # one orphaned lock breaks the runtime forever.
    if [[ -d "$LOCK_DIR" && -f "$LOCK_DIR/holder" ]]; then
      pid=$(grep -oE 'pid=[0-9]+' "$LOCK_DIR/holder" 2>/dev/null | cut -d= -f2)
      acquired_at=$(grep -oE 'acquired_at=[^[:space:]]+' "$LOCK_DIR/holder" 2>/dev/null | cut -d= -f2)
      pid_alive=1
      [[ -z "$pid" ]] || kill -0 "$pid" 2>/dev/null || pid_alive=0

      # Compute age. Try GNU date first, fall back to BSD date (macOS).
      age=0
      if [[ -n "$acquired_at" ]]; then
        if t=$(date -u -d "$acquired_at" +%s 2>/dev/null); then
          age=$(( $(date -u +%s) - t ))
        elif t=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$acquired_at" +%s 2>/dev/null); then
          age=$(( $(date -u +%s) - t ))
        fi
      fi

      if (( pid_alive == 0 )) && (( age > 1800 )); then
        rm -rf "$LOCK_DIR" 2>/dev/null
        # fall through and try to acquire fresh
      fi
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # Got the lock. Record holder PID + timestamp for diagnostics.
      printf 'pid=%s\nacquired_at=%s\n' "$$" "$(date -u +%FT%TZ)" > "$LOCK_DIR/holder"
      exit 0
    else
      # Lock held by someone else; signal we wanted it.
      touch "$QUEUE_FILE"
      exit 1
    fi
    ;;

  release)
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    exit 0
    ;;

  is-held)
    [[ -d "$LOCK_DIR" ]] && exit 0 || exit 1
    ;;

  was-queued)
    if [[ -f "$QUEUE_FILE" ]]; then
      rm -f "$QUEUE_FILE"
      exit 0
    fi
    exit 1
    ;;

  path)
    echo "$LOCK_DIR"
    ;;

  *)
    echo "Unknown: $cmd. Valid: acquire, release, is-held, was-queued, path" >&2
    exit 2
    ;;
esac
