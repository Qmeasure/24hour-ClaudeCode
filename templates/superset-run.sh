#!/usr/bin/env bash
# .superset/run.sh — runs when the user clicks Run in Superset.
#
# Replace this with your project's actual dev-server / run command.
# This stub auto-detects common patterns; edit to fit.
#
# FORBIDDEN here (do these in review-loop skill instead):
#   - trigger PR flow
#   - read CI / review feedback
#   - auto-merge

set -uo pipefail

# Common patterns — replace with your actual dev command:
if [[ -f package.json ]] && grep -q '"dev"' package.json; then
  if [[ -f pnpm-lock.yaml ]];   then exec pnpm dev
  elif [[ -f yarn.lock ]];      then exec yarn dev
  elif [[ -f bun.lockb ]];      then exec bun dev
  else                                exec npm run dev
  fi
elif [[ -f manage.py ]]; then
  exec python manage.py runserver
elif [[ -f main.go ]]; then
  exec go run main.go
elif [[ -f Cargo.toml ]]; then
  exec cargo run
else
  echo "No dev command detected. Edit .superset/run.sh to set the right command for this project."
  exit 1
fi
