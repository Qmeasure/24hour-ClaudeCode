# PR Review Prompt — 24hour-ClaudeCode

Rendered into `<project>/.claude/24hour-ClaudeCode/review-prompt.md` at onboarding time with project-specific substitutions. **Both** `claude-code-review.yml` and `codex-review.yml` load this file via `cat` at workflow runtime and pass its body to the review action as `prompt:`. This is the single source of truth for review behavior.

**Edit this file freely** to tune review depth, focus, or tone for your project. Changes apply to the next PR — no re-render of workflow YAMLs needed.

---

## Project context (auto-filled at render time)

- **Type:** {{PROJECT_TYPE}}
- **Base branch:** {{BASE_BRANCH}}
- **Monorepo:** {{IS_MONOREPO}}
- **Repo size:** {{REPO_SIZE}}
- **Package manager:** {{PACKAGE_MANAGER}}
- **Test command:** {{TEST_COMMAND}}
- **Lint command:** {{LINT_COMMAND}}
- **Typecheck command:** {{TYPECHECK_COMMAND}}
- **Style guides:** {{STYLE_FILES}}

## Review priorities (in order)

1. **Correctness:** logic bugs, edge cases, error handling, race conditions
2. **Security:** input validation at boundaries, auth, secrets, injection vectors
3. **Tests:** new behavior should have a test (project uses `{{TEST_COMMAND}}`)
4. **Types:** PR should pass `{{TYPECHECK_COMMAND}}`
5. **Maintainability:** naming, single-responsibility, dead code, duplication

## Sensitive paths (require extra scrutiny)

The following paths are flagged by this project's `danger_paths` config. Reviews touching these MUST explicitly call out the change and the rationale:

{{DANGER_PATHS_LIST}}

## Project-specific style guides

If these files exist at the repo root, treat their top-of-file rules as hard constraints. Quoting them in a review comment is acceptable; ignoring them is not.

{{STYLE_GUIDE_LINKS}}

## Output format

- **Cite file:line** for every issue. No vague "consider improving naming" without a location.
- **Group findings by severity:**
  - **Reject** (blocks merge): correctness bug, security issue, broken contract, danger-path edit without justification
  - **Major:** logic concern, missing test for important branch, type hole, breaking API change without versioning
  - **Minor:** style / naming / organization
  - **Nit:** subjective taste
- **Skip trivial nits if the PR is large** — lead with structural issues.
- **Be concise.** No preamble, no "great work!" filler, no recap of what the PR does.
- **If the PR is small (< 30 lines of pure docs/typo)**, respond `looks good, skipping detailed review`.

## What NOT to flag

- Line width / indentation / blank lines (formatter's job)
- Comment density (unless misleading)
- Variable name style (unless against project convention)
- Commit message format

## Trust the auto-loop

This PR is part of an auto-loop that will iterate based on your feedback. Be specific about what you want changed; vague suggestions waste an iteration cycle.
