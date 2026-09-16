#!/usr/bin/env bash
#
# verify.sh — the gate. Must exit 0 before any phase counts as done.
#
# Purpose : build + test + lint in one command, so "is this phase finished?" has a
#           single mechanical answer.
# Inputs  : the whole repo.
# Outputs : exit status. Anything non-zero means the phase is not done.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_toolchain

log "verify: 1/4 Core tests"
"$REPO_ROOT/scripts/test.sh"

log "verify: 2/4 build app"
"$REPO_ROOT/scripts/build.sh" release

log "verify: 3/4 lint"
"$REPO_ROOT/scripts/lint.sh"

log "verify: 4/4 offscreen self-QA"
"$REPO_ROOT/scripts/selfqa.sh" offscreen

log "verify: OK"
