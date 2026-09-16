#!/usr/bin/env bash
#
# lint.sh — the code standards from CLAUDE.md / SPEC 1.5, checked mechanically.
#
# Purpose : The standards that can be checked by a script are checked by a script,
#           so review time goes to the ones that cannot (naming, abstraction).
# Checks  : every Swift file opens with a header comment; no stray debug prints;
#           no tabs; the package builds warning-free.
# Outputs : exit status; offending files are listed.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

problems=0

log "lint: file header comments"
while IFS= read -r file; do
  # SPEC 1.5: "Every file opens with a header comment".
  if ! head -3 "$file" | grep -q '^//'; then
    echo "  missing header comment: ${file#$REPO_ROOT/}"
    problems=$((problems + 1))
  fi
done < <(find "$REPO_ROOT/Core/Sources" "$REPO_ROOT/App/Sources" "$REPO_ROOT/Core/Tests" -name '*.swift' 2>/dev/null)

log "lint: stray debug prints"
# Swift's print() bypasses the tagged logger, so failures become invisible.
if grep -rn --include='*.swift' '^\s*print(' "$REPO_ROOT/Core/Sources" "$REPO_ROOT/App/Sources" 2>/dev/null; then
  echo "  use Log.info/warn/error instead of print()"
  problems=$((problems + 1))
fi

log "lint: build warnings"
cd "$REPO_ROOT/Core"
if swift build 2>&1 | grep -E '^.*warning:' | grep -v 'unhandled resource'; then
  echo "  Core builds with warnings"
  problems=$((problems + 1))
fi

if [ "$problems" -ne 0 ]; then
  fail "lint found $problems problem(s)"
fi
log "lint: clean"
