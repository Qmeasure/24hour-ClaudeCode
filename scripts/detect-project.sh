#!/usr/bin/env bash
# detect-project.sh — Detect project characteristics so workflow YAML can be tailored.
#
# Outputs KEY=VALUE lines (and bash array literals) on stdout.
# Errors / progress logs go to stderr.
#
# Designed to be sourced via:
#     eval "$(bash scripts/detect-project.sh --quiet)"
#
# Run from repo root (or pass --root <path>).
#
# Detected keys:
#   PROJECT_TYPE         node / python / go / rust / ruby / php / dart / elixir / mixed:a+b / unknown
#   BASE_BRANCH          repo default branch (gh repo view → fallback git symbolic-ref → "main")
#   IS_MONOREPO          0 / 1
#   REPO_SIZE            small / medium / large (by tracked file count)
#   REPO_FILE_COUNT      integer
#   PACKAGE_MANAGER      pnpm / yarn / bun / npm / pip / poetry / uv / cargo / go / "" (Node/Python only)
#   TEST_COMMAND         best-guess test runner
#   LINT_COMMAND         best-guess linter
#   TYPECHECK_COMMAND    best-guess typecheck
#   REVIEW_MODEL         claude-sonnet-4-6 / claude-opus-4-7 (by repo size)
#   REVIEW_MAX_TURNS     5 / 8 (by size)
#   CLAUDE_MAX_TURNS     15 / 20 (by size)
#   PATHS_IGNORE         bash array of paths-ignore patterns
#   STYLE_FILES          bash array of detected style guide files
#   DANGER_PATHS         bash array of sensitive paths
#   SUPERSET_DETECTED    0 / 1 (whether Superset CLI is on PATH)

set -euo pipefail

ROOT="$(pwd)"
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

cd "$ROOT"

log() { (( QUIET == 0 )) && printf "▸ %s\n" "$*" >&2 || true; }

# ---- 1. Project type ----
TYPES=()
[[ -f package.json ]]        && TYPES+=("node")
if [[ -f pyproject.toml || -f setup.py || -f requirements.txt || -f Pipfile ]]; then
  TYPES+=("python")
fi
[[ -f go.mod ]]              && TYPES+=("go")
[[ -f Cargo.toml ]]          && TYPES+=("rust")
[[ -f Gemfile ]]             && TYPES+=("ruby")
[[ -f composer.json ]]       && TYPES+=("php")
[[ -f pubspec.yaml ]]        && TYPES+=("dart")
[[ -f mix.exs ]]             && TYPES+=("elixir")

if (( ${#TYPES[@]} == 0 )); then
  # Fallback: no manifest detected. Look for source files at the repo root by
  # extension. Useful for scratch-style repos like a single `web_clipper.py`
  # with no requirements.txt — we still want a tailored review prompt.
  if compgen -G "*.py" >/dev/null 2>&1 || compgen -G "src/*.py" >/dev/null 2>&1; then
    TYPES+=("python")
  elif compgen -G "*.ts" >/dev/null 2>&1 || compgen -G "*.js" >/dev/null 2>&1 \
       || compgen -G "src/*.ts" >/dev/null 2>&1 || compgen -G "src/*.js" >/dev/null 2>&1; then
    TYPES+=("node")
  elif compgen -G "*.go" >/dev/null 2>&1; then
    TYPES+=("go")
  elif compgen -G "*.rs" >/dev/null 2>&1; then
    TYPES+=("rust")
  fi
fi

if (( ${#TYPES[@]} == 0 )); then
  PROJECT_TYPE="unknown"
elif (( ${#TYPES[@]} == 1 )); then
  PROJECT_TYPE="${TYPES[0]}"
else
  PROJECT_TYPE="mixed:$(IFS=+; echo "${TYPES[*]}")"
fi

log "Project type: $PROJECT_TYPE"

# ---- 2. Base branch ----
BASE_BRANCH=""
if command -v gh >/dev/null 2>&1; then
  BASE_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
fi
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "")
fi
[[ -z "$BASE_BRANCH" ]] && BASE_BRANCH="main"

log "Base branch: $BASE_BRANCH"

# ---- 3. Monorepo ----
IS_MONOREPO="0"
if [[ -f pnpm-workspace.yaml ]] || [[ -f lerna.json ]] || [[ -f nx.json ]] || [[ -f rush.json ]]; then
  IS_MONOREPO="1"
elif [[ -f package.json ]] && grep -q '"workspaces"' package.json 2>/dev/null; then
  IS_MONOREPO="1"
fi

log "Monorepo: $IS_MONOREPO"

# ---- 4. Package manager (Node/Python primarily) ----
PACKAGE_MANAGER=""
case "$PROJECT_TYPE" in
  *node*)
    if   [[ -f pnpm-lock.yaml ]]; then PACKAGE_MANAGER="pnpm"
    elif [[ -f yarn.lock ]];      then PACKAGE_MANAGER="yarn"
    elif [[ -f bun.lockb ]];      then PACKAGE_MANAGER="bun"
    else                                PACKAGE_MANAGER="npm"
    fi
    ;;
  *python*)
    if   [[ -f poetry.lock ]];     then PACKAGE_MANAGER="poetry"
    elif [[ -f uv.lock ]];         then PACKAGE_MANAGER="uv"
    elif [[ -f Pipfile.lock ]];    then PACKAGE_MANAGER="pipenv"
    else                                PACKAGE_MANAGER="pip"
    fi
    ;;
  *go*)    PACKAGE_MANAGER="go" ;;
  *rust*)  PACKAGE_MANAGER="cargo" ;;
esac

# ---- 5. Test / lint / typecheck commands ----
TEST_COMMAND=""
LINT_COMMAND=""
TYPECHECK_COMMAND=""

case "$PROJECT_TYPE" in
  node|mixed:*node*)
    if [[ -f package.json ]]; then
      grep -q '"test"' package.json      && TEST_COMMAND="$PACKAGE_MANAGER test"
      grep -q '"lint"' package.json      && LINT_COMMAND="$PACKAGE_MANAGER run lint"
      if grep -q '"typecheck"' package.json; then
        TYPECHECK_COMMAND="$PACKAGE_MANAGER run typecheck"
      elif [[ -f tsconfig.json ]]; then
        TYPECHECK_COMMAND="$PACKAGE_MANAGER tsc --noEmit"
      fi
    fi
    ;;
  python|mixed:*python*)
    if [[ -f pyproject.toml ]]; then
      grep -q 'pytest'  pyproject.toml && TEST_COMMAND="pytest"
      grep -q 'ruff'    pyproject.toml && LINT_COMMAND="ruff check ."
      grep -q 'mypy'    pyproject.toml && TYPECHECK_COMMAND="mypy ."
      grep -q 'pyright' pyproject.toml && TYPECHECK_COMMAND="${TYPECHECK_COMMAND:-pyright}"
    fi
    [[ -z "$TEST_COMMAND" && -d tests ]] && TEST_COMMAND="python -m pytest"
    ;;
  go|mixed:*go*)
    TEST_COMMAND="go test ./..."
    LINT_COMMAND="golangci-lint run"
    TYPECHECK_COMMAND="go vet ./..."
    ;;
  rust|mixed:*rust*)
    TEST_COMMAND="cargo test"
    LINT_COMMAND="cargo clippy"
    TYPECHECK_COMMAND="cargo check"
    ;;
  ruby|mixed:*ruby*)
    [[ -f Gemfile ]] && grep -q 'rspec'    Gemfile && TEST_COMMAND="bundle exec rspec"
    [[ -f Gemfile ]] && grep -q 'rubocop'  Gemfile && LINT_COMMAND="bundle exec rubocop"
    ;;
esac

log "test:      ${TEST_COMMAND:-<none>}"
log "lint:      ${LINT_COMMAND:-<none>}"
log "typecheck: ${TYPECHECK_COMMAND:-<none>}"

# ---- 6. Style guide files (repo root) ----
STYLE_FILES=()
for name in CLAUDE.md AGENTS.md STYLE_GUIDE.md CONTRIBUTING.md CODE_STYLE.md .cursorrules; do
  [[ -f "$name" ]] && STYLE_FILES+=("$name")
done
log "Style guides: ${STYLE_FILES[*]:-<none>}"

# ---- 7. Paths-ignore extras (per project type) ----
PATHS_IGNORE=("**.md" "**/CHANGELOG*" "**/*.lock")
case "$PROJECT_TYPE" in
  node|mixed:*node*)
    PATHS_IGNORE+=("**/node_modules/**" "**/dist/**" "**/build/**" "**/.next/**" "**/coverage/**")
    ;;
  python|mixed:*python*)
    PATHS_IGNORE+=("**/__pycache__/**" "**/*.pyc" "**/.venv/**" "**/dist/**" "**/build/**" "**/.tox/**")
    ;;
  go|mixed:*go*)
    PATHS_IGNORE+=("**/vendor/**" "**/bin/**")
    ;;
  rust|mixed:*rust*)
    PATHS_IGNORE+=("**/target/**")
    ;;
  ruby|mixed:*ruby*)
    PATHS_IGNORE+=("**/vendor/bundle/**" "**/tmp/**" "**/log/**")
    ;;
esac

# ---- 8. Danger paths (sensitive paths) ----
DANGER_PATHS=()
[[ -d migrations ]]             && DANGER_PATHS+=("migrations/**")
[[ -d db/migrations ]]          && DANGER_PATHS+=("db/migrations/**")
[[ -d alembic/versions ]]       && DANGER_PATHS+=("alembic/versions/**")
[[ -d prisma/migrations ]]      && DANGER_PATHS+=("prisma/migrations/**")
[[ -f prisma/schema.prisma ]]   && DANGER_PATHS+=("prisma/schema.prisma")
[[ -f .env.production ]]        && DANGER_PATHS+=(".env.production")
[[ -d infra ]]                  && DANGER_PATHS+=("infra/**")
[[ -d terraform ]]               && DANGER_PATHS+=("terraform/**")
[[ -d k8s ]]                    && DANGER_PATHS+=("k8s/**")
[[ -d helm ]]                   && DANGER_PATHS+=("helm/**")
[[ -d .github/workflows ]]      && DANGER_PATHS+=(".github/workflows/**")
[[ -f Dockerfile ]]             && DANGER_PATHS+=("Dockerfile")

log "Sensitive paths: ${#DANGER_PATHS[@]} entries"

# ---- 9. Repo size (for model/turn sizing) ----
REPO_FILE_COUNT=$(git ls-files 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if   (( REPO_FILE_COUNT > 5000 )); then REPO_SIZE="large"
elif (( REPO_FILE_COUNT > 500  )); then REPO_SIZE="medium"
else                                    REPO_SIZE="small"
fi
log "Repo size: $REPO_SIZE ($REPO_FILE_COUNT files)"

# ---- 10. Recommended model / turns by size ----
case "$REPO_SIZE" in
  large)  REVIEW_MODEL="claude-opus-4-7";    REVIEW_MAX_TURNS=8;  CLAUDE_MAX_TURNS=20 ;;
  medium) REVIEW_MODEL="claude-sonnet-4-6";  REVIEW_MAX_TURNS=5;  CLAUDE_MAX_TURNS=15 ;;
  *)      REVIEW_MODEL="claude-sonnet-4-6";  REVIEW_MAX_TURNS=5;  CLAUDE_MAX_TURNS=15 ;;
esac

# ---- 11. Superset CLI presence ----
SUPERSET_DETECTED=0
if command -v superset >/dev/null 2>&1; then
  SUPERSET_DETECTED=1
fi

# ---- 12. Repo structure scan (for project-specific inline review prompt) ----
# These values get baked into .github/workflows/claude-code-review.yml at
# render time so reviews are tailored to THIS repo's actual layout — not a
# generic template. Three signals:
#   REPO_DESCRIPTION  one-line summary (README first paragraph / package.json description / fallback)
#   TOP_DIRS          top-level non-hidden source dirs (filtering out build/cache dirs)
#   ENTRY_FILES       main entry points by project type (where reviewers should anchor)

REPO_DESCRIPTION=""
# Try README.md first paragraph (after first H1 line if present).
# Skip the language-switcher / badge rows that often precede the H1.
# After the H1, take the first **bold one-liner** OR first regular text line.
if [[ -f README.md ]]; then
  REPO_DESCRIPTION=$(awk '
    /^#[[:space:]]/ { h1=1; next }
    !h1 { next }
    /^\*\*[^[:space:]]/ { sub(/^\*\*/, ""); sub(/\*\*[[:space:]]*$/, ""); print; exit }
    /^[^#>`*[:space:]-]/ { print; exit }
  ' README.md 2>/dev/null | head -c 280)
fi
# Fallback: package.json "description"
if [[ -z "$REPO_DESCRIPTION" && -f package.json ]]; then
  REPO_DESCRIPTION=$(jq -r '.description // ""' package.json 2>/dev/null || echo "")
fi
# Fallback: pyproject.toml description
if [[ -z "$REPO_DESCRIPTION" && -f pyproject.toml ]]; then
  REPO_DESCRIPTION=$(grep -E '^description\s*=' pyproject.toml 2>/dev/null | head -1 | sed -E 's/.*=\s*"([^"]*)".*/\1/')
fi
# Fallback: Cargo.toml description
if [[ -z "$REPO_DESCRIPTION" && -f Cargo.toml ]]; then
  REPO_DESCRIPTION=$(grep -E '^description\s*=' Cargo.toml 2>/dev/null | head -1 | sed -E 's/.*=\s*"([^"]*)".*/\1/')
fi
[[ -z "$REPO_DESCRIPTION" ]] && REPO_DESCRIPTION="a $PROJECT_TYPE project"
# Strip newlines/tabs so it stays a one-liner inside YAML
REPO_DESCRIPTION=$(printf '%s' "$REPO_DESCRIPTION" | tr -s '\n\t ' ' ' | sed -E 's/^ +| +$//g')

# Top-level dirs (filter out build/cache/vendor/test-output)
TOP_DIRS=()
for d in */; do
  d="${d%/}"
  case "$d" in
    node_modules|dist|build|.next|coverage|target|__pycache__|.venv|venv|.tox|.cache|.idea|.vscode|tmp|vendor|bin|out|.git|.github) continue ;;
    *) TOP_DIRS+=("$d") ;;
  esac
done

# Entry files by project type — first hit, capped at ~3 each
ENTRY_FILES=()
case "$PROJECT_TYPE" in
  *node*)
    if [[ -f package.json ]]; then
      main=$(jq -r '.main // ""' package.json 2>/dev/null)
      [[ -n "$main" && -f "$main" ]] && ENTRY_FILES+=("$main")
    fi
    for f in src/index.ts src/index.js src/main.ts src/main.js index.ts index.js; do
      [[ -f "$f" ]] && ENTRY_FILES+=("$f") && break
    done
    ;;
  *python*)
    for f in main.py app.py __main__.py src/main.py; do
      [[ -f "$f" ]] && ENTRY_FILES+=("$f")
    done
    # Largest .py at repo root if no main yet
    if (( ${#ENTRY_FILES[@]} == 0 )); then
      while IFS= read -r f; do
        ENTRY_FILES+=("$f")
        [[ ${#ENTRY_FILES[@]} -ge 2 ]] && break
      done < <(ls -S *.py 2>/dev/null | head -2)
    fi
    ;;
  *go*)
    if [[ -d cmd ]]; then
      for d in cmd/*/; do
        [[ -f "${d}main.go" ]] && ENTRY_FILES+=("${d}main.go")
        [[ ${#ENTRY_FILES[@]} -ge 3 ]] && break
      done
    fi
    [[ -f main.go ]] && ENTRY_FILES+=("main.go")
    ;;
  *rust*)
    [[ -f src/main.rs ]] && ENTRY_FILES+=("src/main.rs")
    [[ -f src/lib.rs ]]  && ENTRY_FILES+=("src/lib.rs")
    ;;
esac
# Truncate entry files to first 3
if (( ${#ENTRY_FILES[@]} > 3 )); then
  ENTRY_FILES=("${ENTRY_FILES[@]:0:3}")
fi

log "Repo description: ${REPO_DESCRIPTION:0:80}..."
log "Top-level dirs: ${TOP_DIRS[*]:-<none>}"
log "Entry files: ${ENTRY_FILES[*]:-<none>}"

# ---- Output ----
emit_array() {
  local name="$1"; shift
  printf '%s=(' "$name"
  for v in "$@"; do printf ' %q' "$v"; done
  printf ' )\n'
}

cat <<EOF
PROJECT_TYPE=$(printf '%q' "$PROJECT_TYPE")
BASE_BRANCH=$(printf '%q' "$BASE_BRANCH")
IS_MONOREPO=$(printf '%q' "$IS_MONOREPO")
REPO_SIZE=$(printf '%q' "$REPO_SIZE")
REPO_FILE_COUNT=$(printf '%q' "$REPO_FILE_COUNT")
PACKAGE_MANAGER=$(printf '%q' "$PACKAGE_MANAGER")
TEST_COMMAND=$(printf '%q' "$TEST_COMMAND")
LINT_COMMAND=$(printf '%q' "$LINT_COMMAND")
TYPECHECK_COMMAND=$(printf '%q' "$TYPECHECK_COMMAND")
REVIEW_MODEL=$(printf '%q' "$REVIEW_MODEL")
REVIEW_MAX_TURNS=$(printf '%q' "$REVIEW_MAX_TURNS")
CLAUDE_MAX_TURNS=$(printf '%q' "$CLAUDE_MAX_TURNS")
SUPERSET_DETECTED=$(printf '%q' "$SUPERSET_DETECTED")
REPO_DESCRIPTION=$(printf '%q' "$REPO_DESCRIPTION")
$(emit_array PATHS_IGNORE  ${PATHS_IGNORE[@]+"${PATHS_IGNORE[@]}"})
$(emit_array STYLE_FILES   ${STYLE_FILES[@]+"${STYLE_FILES[@]}"})
$(emit_array DANGER_PATHS  ${DANGER_PATHS[@]+"${DANGER_PATHS[@]}"})
$(emit_array TOP_DIRS      ${TOP_DIRS[@]+"${TOP_DIRS[@]}"})
$(emit_array ENTRY_FILES   ${ENTRY_FILES[@]+"${ENTRY_FILES[@]}"})
EOF
